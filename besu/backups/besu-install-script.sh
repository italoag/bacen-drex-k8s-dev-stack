#!/bin/bash
# Script para configurar múltiplos validadores Besu em uma rede privada com consenso QBFT
set -e

# Configurações
NAMESPACE="blockchain"
NUM_VALIDATORS=4
BESU_VERSION="24.12.2"
CHAIN_ID=22012022
FORCE_REINSTALL=true # Sempre reinstalar

# Cores para a saída
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Função de log
log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_success() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}$1${NC}"
}

log_warning() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}$1${NC}"
}

log_error() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}$1${NC}"
}

# Função para verificar se kubectl está disponível
check_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    log_error "kubectl não está disponível. Instale-o antes de continuar."
    exit 1
  fi
}

# Função para verificar se o namespace existe
check_namespace() {
  if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    log_warning "Namespace '$NAMESPACE' não existe. Criando..."
    kubectl create namespace $NAMESPACE
    log_success "Namespace '$NAMESPACE' criado."
  else
    log_success "Namespace '$NAMESPACE' já existe."
  fi
}

# Função para limpar recursos existentes do Besu
clean_besu_resources() {
  log "Limpando recursos existentes do Besu no namespace '$NAMESPACE'..."
  
  # Remover StatefulSets primeiro (isso removerá os pods gerenciados automaticamente)
  if kubectl get statefulset -n $NAMESPACE -l app=besu,component=validator &> /dev/null; then
    log "Removendo StatefulSets existentes..."
    kubectl delete statefulset -n $NAMESPACE -l app=besu,component=validator --cascade=foreground --timeout=120s || true
    sleep 20  # Espera mais tempo para que o StatefulSet gerencie corretamente a finalização dos pods
  fi
  
  # Remover pods apenas se ainda existirem (pods órfãos)
  if kubectl get pods -n $NAMESPACE -l app=besu,component=validator &> /dev/null; then
    log "Removendo pods órfãos remanescentes..."
    kubectl delete pods -n $NAMESPACE -l app=besu,component=validator --force --grace-period=0 --timeout=30s || true
    sleep 5
  fi
  
  # Limpeza dos serviços
  if kubectl get service -n $NAMESPACE -l app=besu,component=validator &> /dev/null; then
    log "Removendo Services dos validadores..."
    kubectl delete service -n $NAMESPACE -l app=besu,component=validator --timeout=30s || true
  fi
  
  if kubectl get service -n $NAMESPACE besu-headless &> /dev/null; then
    log "Removendo Service besu-headless..."
    kubectl delete service -n $NAMESPACE besu-headless --timeout=30s || true
  fi
  
  # Espera para garantir que todos os serviços foram removidos
  sleep 5
  
  # Remover as PVCs também (após garantir que todos os StatefulSets e pods foram removidos)
  if kubectl get pvc -n $NAMESPACE -l app=besu,component=validator &> /dev/null; then
    log "Removendo PVCs existentes..."
    kubectl delete pvc -n $NAMESPACE -l app=besu,component=validator --timeout=30s || true
    sleep 5
  fi
  
  # Não remova os ConfigMaps do genesis ou das chaves dos validadores
  # Remover apenas os ConfigMaps de conectividade que serão recriados
  for CM in besu-nodes-allowlist besu-endpoints besu-static-nodes; do
    if kubectl get configmap -n $NAMESPACE $CM &> /dev/null; then
      log "Removendo ConfigMap $CM..."
      kubectl delete configmap -n $NAMESPACE $CM --timeout=10s || true
    fi
  done
  
  # Verificação final para garantir que tudo foi limpo
  REMAINING_PODS=$(kubectl get pods -n $NAMESPACE -l app=besu,component=validator --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  REMAINING_STS=$(kubectl get statefulset -n $NAMESPACE -l app=besu,component=validator --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  REMAINING_SVC=$(kubectl get service -n $NAMESPACE -l app=besu,component=validator --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  
  REMAINING_RESOURCES=$((REMAINING_PODS + REMAINING_STS + REMAINING_SVC))
  
  if [ "$REMAINING_RESOURCES" -gt 0 ]; then
    log_warning "Ainda existem $REMAINING_RESOURCES recursos após a limpeza. Aguardando mais 30 segundos..."
    sleep 30
  else
    log_success "Limpeza de recursos do Besu concluída com sucesso!"
  fi
}

# Função para verificar ConfigMaps do genesis e chaves
verify_genesis_configmaps() {
  log "Verificando ConfigMaps de chaves dos validadores no namespace '$NAMESPACE'..."
  
  # Verificar ConfigMaps das chaves dos validadores
  for i in $(seq 1 $NUM_VALIDATORS); do
    if ! kubectl get configmap -n $NAMESPACE "besu-validator$i-keys" &> /dev/null; then
      log_error "ConfigMap 'besu-validator$i-keys' não encontrado no namespace '$NAMESPACE'."
      log_error "Execute o script besu-genesis-script.sh primeiro."
      exit 1
    fi
  done
  log_success "ConfigMaps de chaves encontrados."
  
  # Verificar o ConfigMap do Genesis
  if ! kubectl get configmap -n $NAMESPACE besu-genesis &> /dev/null; then
    log_error "ConfigMap 'besu-genesis' não encontrado no namespace '$NAMESPACE'."
    log_error "Execute o script besu-genesis-script.sh primeiro."
    exit 1
  fi
  log_success "ConfigMap 'besu-genesis' encontrado."
}

# Função para criar ConfigMaps necessários
create_network_configmaps() {
  log "Criando ConfigMaps de rede para permissionamento..."
  
  # Inicialmente, vamos ter listas vazias
  # Os valores reais serão coletados depois que os nós estiverem em execução
  
  # Criando ConfigMap vazio para permissionamento de nós
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: besu-nodes-allowlist
  namespace: $NAMESPACE
data:
  nodes-allowlist.toml: |
    # Nós permitidos (temporariamente vazio)
    nodes-allowlist=[]
EOF
  
  # Criando ConfigMap inicial vazio para nós estáticos
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: besu-static-nodes
  namespace: $NAMESPACE
data:
  static-nodes.json: |
    []
EOF
  
  log_success "ConfigMaps de rede criados com sucesso."
}

# Função para criar o serviço headless
create_headless_service() {
  log "Criando Service Headless 'besu-headless' no namespace '$NAMESPACE'..."
  P2P_PORT=30303
  RPC_HTTP_PORT=8545
  RPC_WS_PORT=8546
  
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: besu-headless
  namespace: $NAMESPACE
  labels:
    app: besu
spec:
  clusterIP: None
  ports:
  - port: $RPC_HTTP_PORT
    name: json-rpc
  - port: $RPC_WS_PORT
    name: ws
  - port: $P2P_PORT
    name: p2p
  selector:
    app: besu
    component: validator
EOF
  
  # Verificar se o serviço foi criado
  if ! kubectl get service -n $NAMESPACE besu-headless &> /dev/null; then
    log_error "Falha ao criar Service 'besu-headless'. Abortando..."
    exit 1
  fi
  
  log_success "Service Headless 'besu-headless' criado com sucesso."
}

# Função para criar um validador (serviço e statefulset)
create_validator() {
  local i=$1
  local validator_index=$((i + 1))
  local validator_name="besu-$i"
  local key_configmap_name="besu-validator${validator_index}-keys"
  
  P2P_PORT=30303
  RPC_HTTP_PORT=8545
  RPC_WS_PORT=8546
  GRAPHQL_HTTP_PORT=8547
  
  # Valores padrão para recursos
  CPU_REQUEST="500m"
  MEM_REQUEST="512Mi"
  CPU_LIMIT="1000m"
  MEM_LIMIT="1Gi"
  STORAGE_SIZE="5Gi"
  BESU_IMAGE="hyperledger/besu:$BESU_VERSION"
  
  log "Criando Service para o validador $validator_name..."
  
  # Criar o Service
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $validator_name
  namespace: $NAMESPACE
  labels:
    app: besu
    component: validator
    instance: $validator_name
spec:
  ports:
  - name: rpc-http
    port: $RPC_HTTP_PORT
    targetPort: $RPC_HTTP_PORT
  - name: rpc-ws
    port: $RPC_WS_PORT
    targetPort: $RPC_WS_PORT
  - name: p2p
    port: $P2P_PORT
    targetPort: $P2P_PORT
  selector:
    app: besu
    component: validator
    instance: $validator_name
EOF
  
  # Verificar se o serviço foi criado
  if ! kubectl get service -n $NAMESPACE $validator_name &> /dev/null; then
    log_error "Falha ao criar Service '$validator_name'. Abortando..."
    exit 1
  fi
  
  log_success "Service '$validator_name' criado com sucesso."
  sleep 3
  
  # Verificar novamente os ConfigMaps antes de criar o StatefulSet
  if ! kubectl get configmap -n $NAMESPACE besu-nodes-allowlist &> /dev/null; then
    log_error "ConfigMap 'besu-nodes-allowlist' não encontrado antes de criar StatefulSet. Abortando..."
    exit 1
  fi
  
  if ! kubectl get configmap -n $NAMESPACE besu-genesis &> /dev/null; then
    log_error "ConfigMap 'besu-genesis' não encontrado antes de criar StatefulSet. Abortando..."
    exit 1
  fi
  
  log "Criando StatefulSet para o validador $validator_name..."
  
  # Criar o StatefulSet
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $validator_name
  namespace: $NAMESPACE
  labels:
    app: besu
    component: validator
    instance: $validator_name
spec:
  serviceName: "besu-headless" 
  replicas: 1
  selector:
    matchLabels:
      app: besu
      component: validator
      instance: $validator_name
  template:
    metadata:
      labels:
        app: besu
        component: validator
        instance: $validator_name
    spec:
      terminationGracePeriodSeconds: 60
      initContainers:
      - name: init-check-configmap
        image: busybox
        command:
        - sh
        - -c
        - |
          # Verificar ConfigMap besu-nodes-allowlist
          echo "Verificando ConfigMap 'besu-nodes-allowlist'..."
          if [ ! -f /mnt/config-perm/nodes-allowlist.toml ]; then
            echo "ERRO: O arquivo nodes-allowlist.toml não está montado corretamente"
            exit 1
          fi
          echo "ConfigMap 'besu-nodes-allowlist' está corretamente montado"
          
          # Verificar ConfigMap besu-genesis
          echo "Verificando ConfigMap 'besu-genesis'..."
          if [ ! -f /mnt/config-genesis/genesis.json ]; then
            echo "ERRO: O arquivo genesis.json não está montado corretamente"
            exit 2
          fi
          echo "ConfigMap 'besu-genesis' está corretamente montado"
          
          # Verificar ConfigMap do validador
          echo "Verificando ConfigMap '$key_configmap_name'..."
          if [ ! -f /mnt/config-keys/key ]; then
            echo "ERRO: O arquivo key não está montado corretamente"
            exit 3
          fi
          echo "ConfigMap '$key_configmap_name' está corretamente montado"
          
          echo "Todas as verificações passaram com sucesso!"
        volumeMounts:
        - name: node-permissioning
          mountPath: /mnt/config-perm
        - name: genesis
          mountPath: /mnt/config-genesis
        - name: keys
          mountPath: /mnt/config-keys
        - name: static-nodes
          mountPath: /mnt/config-static-nodes
      containers:
      - name: besu
        image: $BESU_IMAGE
        ports:
        - containerPort: $P2P_PORT
          name: p2p
        - containerPort: $RPC_HTTP_PORT
          name: rpc-http
        - containerPort: $RPC_WS_PORT
          name: rpc-ws
        volumeMounts:
        - name: data
          mountPath: /opt/besu/data
        - name: keys
          mountPath: /opt/besu/keys
          readOnly: true
        - name: genesis
          mountPath: /opt/besu/genesis
          readOnly: true
        - name: node-permissioning
          mountPath: /opt/besu/config
        - name: static-nodes
          mountPath: /opt/besu/static-nodes
        args:
          - --data-path=/opt/besu/data
          - --genesis-file=/opt/besu/genesis/genesis.json
          - --network-id=$CHAIN_ID
          - --min-gas-price=0
          - --host-allowlist="*"
          - --rpc-http-enabled=true
          - --rpc-http-api=ETH,NET,QBFT,WEB3,ADMIN,DEBUG,PERM,TXPOOL,TRACE
          - --rpc-http-cors-origins="*"
          - --rpc-http-port=$RPC_HTTP_PORT
          - --rpc-ws-enabled=true
          - --rpc-ws-api=ETH,NET,QBFT,WEB3,ADMIN,DEBUG,PERM,TXPOOL,TRACE
          - --rpc-ws-port=$RPC_WS_PORT
          - --graphql-http-enabled=true
          - --graphql-http-port=$GRAPHQL_HTTP_PORT
          - --graphql-http-cors-origins="*"
          - --p2p-port=$P2P_PORT
          - --logging=DEBUG
          - --node-private-key-file=/opt/besu/keys/key
          - --profile=ENTERPRISE
          - --data-storage-format=FOREST
          - --sync-mode=FULL
          - --Xp2p-check-maintained-connections-frequency=60000
          # Configurações de rede P2P e discovery (compatíveis com Besu 24.12.2)
          - --Xdns-enabled=true
          - --p2p-enabled=true
          - --p2p-host=$validator_name-0.besu-headless.$NAMESPACE.svc.cluster.local
          - --p2p-interface=0.0.0.0
          - --p2p-port=30303
          # Desabilitar temporariamente permissões
          - --permissions-nodes-config-file-enabled=false
          # Configurações de discovery
          - --discovery-enabled=true
          - --nat-method=NONE
          - --static-nodes-file=/opt/besu/static-nodes/static-nodes.json
          # Performance e limites
          - --max-peers=25
          - --min-gas-price=0
        resources:
          requests:
            cpu: $CPU_REQUEST
            memory: $MEM_REQUEST
          limits:
            cpu: $CPU_LIMIT
            memory: $MEM_LIMIT
        readinessProbe:
          httpGet:
            path: /health
            port: $RPC_HTTP_PORT
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 30
          successThreshold: 1
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /liveness
            port: $RPC_HTTP_PORT
          initialDelaySeconds: 90
          periodSeconds: 30
          timeoutSeconds: 25
          successThreshold: 1
          failureThreshold: 3
      volumes:
      - name: keys
        configMap:
          name: $key_configmap_name
      - name: genesis
        configMap:
          name: besu-genesis
      - name: node-permissioning
        configMap:
          name: besu-nodes-allowlist
      - name: static-nodes
        configMap:
          name: besu-static-nodes
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: $STORAGE_SIZE
EOF
  
  # Verificar se o StatefulSet foi criado
  if ! kubectl get statefulset -n $NAMESPACE $validator_name &> /dev/null; then
    log_error "Falha ao criar StatefulSet '$validator_name'. Abortando..."
    exit 1
  fi
  
  log_success "StatefulSet '$validator_name' criado com sucesso."
}

# Função para aguardar pods prontos
wait_for_pods_ready() {
  local label="$1"
  local expected_count=$2
  local timeout=${3:-300}
  local interval=30
  local elapsed=0
  local count=0
  
  log "Aguardando os pods $label estarem prontos (timeout: ${timeout}s)..."
  
  while [ $elapsed -lt $timeout ]; do
    # Contar pods ready
    local ready_pods=$(kubectl get pods -n $NAMESPACE -l $label -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c "Running\ttrue" 2>/dev/null || echo 0)
    local total_pods=$(kubectl get pods -n $NAMESPACE -l $label --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    
    count=$((count+1))
    log "Tentativa $count: $ready_pods/$expected_count validadores prontos (Total pods: $total_pods)"
    
    # Verifica se o número esperado de pods está pronto
    if [ "$ready_pods" -eq "$expected_count" ]; then
      log_success "Todos os $expected_count pods com label '$label' estão prontos!"
      return 0
    fi
    
    # Exibir status detalhado dos pods
    echo "POD        STATUS    READY"
    kubectl get pods -n $NAMESPACE -l $label -o custom-columns=POD:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready 2>/dev/null || echo "Nenhum pod encontrado ainda"
    
    # Verificar erros nos pods (para depuração)
    if [ "$total_pods" -gt 0 ]; then
      for pod in $(kubectl get pods -n $NAMESPACE -l $label -o name 2>/dev/null); do
        if kubectl get $pod -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null | grep -q -v "Running"; then
          log_warning "Pod $pod não está em estado Running. Verificando eventos:"
          kubectl describe $pod -n $NAMESPACE | grep -A 5 "Events:" || true
        fi
      done
    fi
    kubectl describe pod $pod -n $NAMESPACE | grep -A 20 Events:
    
    log "=== Logs do container init-check-configmap no pod $pod ==="
    kubectl logs $pod -n $NAMESPACE -c init-check-configmap || true
    
    log "=== Logs do container besu no pod $pod ==="
    kubectl logs $pod -n $NAMESPACE -c besu || true
  done
  
  return 1
}

# Função para verificar rede blockchain
verify_blockchain_network() {
  log "Verificando se os validadores estão participando do consenso QBFT..."
  local start_time=$(date +%s)
  local max_wait_time=300 # 5 minutos
  local end_time=$((start_time + max_wait_time))
  local current_time=$start_time
  local attempt=1
  
  while [ $current_time -lt $end_time ]; do
    log "Tentativa $attempt de verificação da rede blockchain..."
    local all_synced=true
    local blocks_by_validator=()
    
    for i in $(seq 0 $(($NUM_VALIDATORS-1))); do
      local service_name="besu-$i"
      local local_port=$((10000 + RANDOM % 10000))
      
      # Iniciar port-forward em background
      kubectl port-forward -n $NAMESPACE svc/$service_name $local_port:8545 &
      local pf_pid=$!
      sleep 5
      
      # Verificar o número do bloco
      local block_num_output=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                            -H "Content-Type: application/json" http://localhost:$local_port)
      
      # Buscar os peers
      local peers_output=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' \
                        -H "Content-Type: application/json" http://localhost:$local_port)
      
      # Matar o processo de port-forward
      kill $pf_pid 2>/dev/null || true
      sleep 1
      
      local block_num_hex=$(echo $block_num_output | jq -r .result 2>/dev/null || echo "")
      local peer_count=$(echo $peers_output | jq '.result | length' 2>/dev/null || echo "0")
      
      if [[ "$block_num_hex" = "null" || -z "$block_num_hex" || "$peer_count" -lt 1 ]]; then
        all_synced=false
        log_warning "Validador $service_name não está sincronizado: bloco=$block_num_hex, peers=$peer_count"
      else
        if [[ "$block_num_hex" == "0x"* ]]; then
          local block_num_dec=$(printf "%d" $block_num_hex 2>/dev/null || echo "0")
          blocks_by_validator[$i]=$block_num_dec
          log_success "Validador $service_name: bloco=$block_num_dec, peers=$peer_count"
        else
          all_synced=false
          log_warning "Validador $service_name retornou formato de bloco inválido: $block_num_hex"
        fi
      fi
    done
    
    # Verificar se todos os validadores estão no mesmo bloco
    if [[ ${#blocks_by_validator[@]} -eq $NUM_VALIDATORS ]]; then
      local first_block=${blocks_by_validator[0]}
      local all_same_block=true
      
      for block in "${blocks_by_validator[@]}"; do
        if [ "$block" != "$first_block" ]; then
          all_same_block=false
          log_warning "Validadores em blocos diferentes: $first_block vs $block"
          break
        fi
      done
      
      if [ "$all_same_block" = true ] && [ "$first_block" -gt 0 ]; then
        log_success "Todos os validadores estão sincronizados no bloco $first_block!"
        return 0
      fi
    fi
    
    attempt=$((attempt + 1))
    log "Aguardando mais tempo para sincronização da rede..."
    sleep 30
    current_time=$(date +%s)
  done
  
  log_warning "Tempo limite atingido. A rede pode não estar totalmente sincronizada, mas continuaremos."
  return 0
}

# Função para atualizar o ConfigMap de permissionamento
update_node_allowlist() {
  log "Coletando ENODEs de todos os validadores..."
  
  # Aguardar todos os pods estarem em execução e prontos
  wait_for_pods_ready "app=besu,component=validator" $NUM_VALIDATORS
  
  # Espere um pouco mais para garantir que os nós estão completamente inicializados
  log "Aguardando 30 segundos para garantir que os nós estejam inicializados..."
  sleep 30
  
  local enodes=""
  local count=0
  local dns_names=()
  
  # Coletar enodes de todos os validadores
  for ((i=0; i<$NUM_VALIDATORS; i++)); do
    local validator="besu-$i"
    log "Coletando enode do validador $validator..."
    
    # Adicione o nome DNS à lista para o bootnode
    dns_names+=($validator-0.besu-headless.$NAMESPACE.svc.cluster.local)
    
    # Tentar 10 vezes para obter o enode, com intervalo de 5 segundos
    local retry=0
    local enode=""
    local success=false
    
    while [ $retry -lt 10 ] && [ "$success" = false ]; do
      # Executar comando para obter enode e node id
      local result=$(kubectl exec -n $NAMESPACE $validator-0 -- curl -s -X POST --data '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' http://localhost:8545 2>/dev/null)
      
      if [ $? -ne 0 ]; then
        log_warning "Tentativa $((retry+1)): Falha ao executar comando no pod $validator-0. Tentando novamente em 5 segundos..."
      else
        enode=$(echo $result | jq -r '.result.enode' 2>/dev/null)
        
        # Verificar se obtivemos um enode válido
        if [[ $enode == enode://* ]]; then
          success=true
          break
        else
          log_warning "Tentativa $((retry+1)): Enode inválido para $validator: $enode"
        fi
      fi
      
      retry=$((retry+1))
      sleep 5
    done
    
    if [ "$success" = false ]; then
      log_error "Não foi possível obter enode para o validador $validator após 10 tentativas."
      continue
    fi
    
    # Modificar o enode para usar o DNS interno do k8s em vez do IP
    # Extract node ID from enode URL
    local node_id=$(echo $enode | sed -E 's/enode:\/\/([^@]*)@.*/\1/')
    # Create the kubernetes DNS version of the enode URL
    local k8s_enode="enode://$node_id@$validator-0.besu-headless.$NAMESPACE.svc.cluster.local:30303"
    
    # Adicionar enode à lista
    if [ $count -gt 0 ]; then
      enodes="$enodes,"
    fi
    enodes="$enodes\"$k8s_enode\""
    count=$((count+1))
    
    log "Enode do validador $validator: $k8s_enode"
  done
  
  if [ $count -eq 0 ]; then
    log_error "Nenhum enode válido foi coletado. Não é possível atualizar a lista de permissões."
    exit 1
  fi
  
  # Atualizar o ConfigMap da lista de permissões
  log "Atualizando ConfigMap 'besu-nodes-allowlist' com $count nós..."
  
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: besu-nodes-allowlist
  namespace: $NAMESPACE
data:
  nodes-allowlist.toml: |
    # Lista de nós permitidos
    nodes-allowlist=[$enodes]
EOF
  
  # Atualizar o ConfigMap dos nós estáticos
  log "Atualizando ConfigMap 'besu-static-nodes' com $count nós..."
  
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: besu-static-nodes
  namespace: $NAMESPACE
data:
  static-nodes.json: |
    [$enodes]
EOF
  
  log_success "ConfigMaps atualizados com $count nós."
  
  # Criar um arquivo com os bootnodes para futuras referências
  local bootnode="enode://$node_id@besu-0.besu-headless.$NAMESPACE.svc.cluster.local:30303"
  echo "Bootnode: $bootnode" > bootnodes.txt
  log "Bootnode configurado: $bootnode"
}

# Reiniciar os validadores
restart_validators() {
  log "Reiniciando os pods dos validadores para aplicar a nova configuração de permissionamento..."
  
  for i in $(seq 0 $(($NUM_VALIDATORS-1))); do
    kubectl delete pod -n $NAMESPACE "besu-$i-0" || true
    log "Pod besu-$i-0 reiniciado."
    sleep 2
  done
  
  log_success "Todos os pods reiniciados."
}

# Função para criar o ConfigMap de endpoints para o FireFly
create_endpoints_configmap() {
  log "Criando ConfigMap 'besu-endpoints' com endereços dos validadores..."
  
  local besu_endpoints=""
  for i in $(seq 0 $(($NUM_VALIDATORS-1))); do
    local service_name="besu-$i"
    local endpoint="http://$service_name.$NAMESPACE.svc.cluster.local:8545"
    
    if [ -n "$besu_endpoints" ]; then
      besu_endpoints+=",$endpoint"
    else
      besu_endpoints="$endpoint"
    fi
  done
  
  # Criar/Atualizar o ConfigMap
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: besu-endpoints
  namespace: $NAMESPACE
data:
  # Usar uma chave que o FireFly possa ler facilmente
  rpcUrls: "${besu_endpoints}"
EOF
  
  log_success "ConfigMap 'besu-endpoints' criado/atualizado com os seguintes endpoints: $besu_endpoints"
}

# Verificar status final da blockchain
check_final_status() {
  log "Verificando status final da blockchain..."
  
  for i in $(seq 0 $(($NUM_VALIDATORS-1))); do
    local service_name="besu-$i"
    
    # Usar port-forward para verificar o status
    local local_port=$((10000 + RANDOM % 10000))
    kubectl port-forward -n $NAMESPACE svc/$service_name $local_port:8545 &
    local pf_pid=$!
    sleep 5
    
    # Verificar o número do bloco
    local block_num_output=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                           -H "Content-Type: application/json" http://localhost:$local_port)
    
    # Verificar conectividade entre os peers
    local peers_output=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' \
                        -H "Content-Type: application/json" http://localhost:$local_port)
    
    # Matar o processo de port-forward
    kill $pf_pid 2>/dev/null || true
    sleep 1
    
    local block_num_hex=$(echo $block_num_output | jq -r .result 2>/dev/null || echo "")
    if [ "$block_num_hex" != "null" ] && [ -n "$block_num_hex" ]; then
      if [[ "$block_num_hex" == "0x"* ]]; then
        local block_num_dec=$(printf "%d" $block_num_hex 2>/dev/null || echo "N/A")
        log_success "$service_name - Bloco atual: $block_num_dec ($block_num_hex)"
      else
        log_warning "$service_name - Número de bloco em formato não-hexadecimal: $block_num_hex"
      fi
    else
      log_warning "$service_name - Não foi possível obter o número do bloco."
    fi
    
    local peer_count=$(echo $peers_output | jq '.result | length' 2>/dev/null || echo "0")
    log_success "$service_name - Número de peers conectados: $peer_count"
  done
}

# Função principal
main() {
  echo "====================================================================="
  echo "         INSTALAÇÃO HYPERLEDGER BESU - REDE PRIVADA QBFT             "
  echo "====================================================================="
  
  # Verificações iniciais
  check_kubectl
  check_namespace
  
  # Limpar recursos existentes se necessário
  clean_besu_resources
  
  # Verificar ConfigMaps do genesis e chaves
  verify_genesis_configmaps
  
  # Criar ConfigMaps de rede
  create_network_configmaps
  
  # Criar serviço headless
  create_headless_service
  
  # Aguardar a propagação dos ConfigMaps
  log "Aguardando a propagação dos ConfigMaps no cluster..."
  sleep 10
  
  # Criar validadores (um por um)
  log "Criando validadores..."
  for i in $(seq 0 $(($NUM_VALIDATORS-1))); do
    create_validator $i
  done
  
  # Aguardar os pods ficarem prontos
  wait_for_pods_ready 300 || exit 1
  
  # Aguardar inicialização da rede
  log "Aguardando inicialização da rede e criação do bloco genesis..."
  sleep 60
  
  # Verificar rede blockchain
  verify_blockchain_network
  
  # Atualizar lista de permissionamento
  update_node_allowlist
  
  # Reiniciar validadores com nova configuração
  restart_validators
  
  # Aguardar os pods ficarem prontos novamente
  wait_for_pods_ready 300 || exit 1
  
  # Criar ConfigMap de endpoints
  create_endpoints_configmap
  
  # Verificar status final
  check_final_status
  
  log_success "Hyperledger Besu com $NUM_VALIDATORS validadores foi configurado com sucesso no namespace '$NAMESPACE'!"
  echo "====================================================================="
  echo "                      INSTALAÇÃO CONCLUÍDA                           "
  echo "====================================================================="
}

# Executar a função principal
main