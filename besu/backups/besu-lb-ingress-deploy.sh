#!/bin/bash

# Configurações
NAMESPACE="paladin"
NODE_COUNT=${NODE_COUNT:-3} # Valor padrão 3 se não definido
DOMAIN=${DOMAIN:-cluster.eita.cloud}
LOG_FILE="besu-loadbalancer-deployment-$(date +%Y%m%d-%H%M%S).log"
RETRY_ATTEMPTS=3
RETRY_DELAY=5
BACKUP_DIR="backups/$(date +%Y%m%d-%H%M%S)"  # Arquivos de configuração
SERVICES_FILE="besu-services.yaml"
MIDDLEWARES_FILE="besu-middlewares.yaml"
INGRESSROUTES_FILE="besu-ingressroutes.yaml"

# Templates
SERVICES_TEMPLATE="besu-services.yaml.tpl"
MIDDLEWARES_TEMPLATE="besu-middlewares.yaml.tpl"
INGRESSROUTES_TEMPLATE="besu-ingressroutes.yaml.tpl"

# Função para logging
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a $LOG_FILE
}

# Função para verificação de erros
check_error() {
  if [ $? -ne 0 ]; then
    log "❌ ERROR" "$1"
    if [ "$2" == "exit" ]; then
      log "❌ ERROR" "Script abortado."
      exit 1
    fi
    return 1
  fi
  return 0
}

# Função para backup de recursos existentes
backup_resources() {
  log "ℹ️ INFO" "Criando backup dos recursos existentes..."
  
  mkdir -p $BACKUP_DIR
  
  # Backup de serviços
  kubectl get services -n $NAMESPACE -o yaml > $BACKUP_DIR/services-backup.yaml 2>/dev/null || true
  
  # Backup de ingressroutes
  kubectl get ingressroutes.traefik.io -n $NAMESPACE -o yaml > $BACKUP_DIR/ingressroutes-backup.yaml 2>/dev/null || true
  
  # Backup de middlewares
  kubectl get middlewares.traefik.io -n $NAMESPACE -o yaml > $BACKUP_DIR/middlewares-backup.yaml 2>/dev/null || true
  
  # Backup de certificados
  kubectl get certificates -n $NAMESPACE -o yaml > $BACKUP_DIR/certificates-backup.yaml 2>/dev/null || true
  
  log "ℹ️ INFO" "Backup criado em $BACKUP_DIR"
}

# Função para rollback
rollback() {
  log "⚠️ WARNING" "Iniciando rollback..."
  
  # Verificar se diretório de backup existe
  if [ ! -d "$BACKUP_DIR" ]; then
    log "❌ ERROR" "Diretório de backup não encontrado. Rollback não é possível."
    return 1
  fi
  
  # Aplicar backups se existirem - serviços
  if [ -f "$BACKUP_DIR/services-backup.yaml" ]; then
    log "ℹ️ INFO" "Restaurando serviços..."
    kubectl apply -f $BACKUP_DIR/services-backup.yaml 2>/dev/null || true
  fi
  
  # Para evitar conflitos, primeiro deletamos os recursos que podem estar em conflito
  log "ℹ️ INFO" "Excluindo recursos conflitantes antes de restaurar..."
  
  # Excluir middlewares
  kubectl delete middleware.traefik.io -n $NAMESPACE besu-ws-middleware 2>/dev/null || true
  kubectl delete middleware.traefik.io -n $NAMESPACE besu-retry-middleware 2>/dev/null || true
  
  # Excluir certificados
  kubectl delete certificate -n $NAMESPACE rpc-besu 2>/dev/null || true
  kubectl delete certificate -n $NAMESPACE ws-besu 2>/dev/null || true
  kubectl delete certificate -n $NAMESPACE graphql-besu 2>/dev/null || true
  
  # Excluir ingressroutes
  kubectl delete ingressroute -n $NAMESPACE besu-rpc-route 2>/dev/null || true
  kubectl delete ingressroute -n $NAMESPACE besu-ws-route 2>/dev/null || true
  kubectl delete ingressroute -n $NAMESPACE besu-graphql-route 2>/dev/null || true
  
  # Aguarde um momento para que as exclusões sejam processadas
  sleep 2
  
  # Aplicar backups se existirem - outros recursos
  if [ -f "$BACKUP_DIR/ingressroutes-backup.yaml" ]; then
    log "ℹ️ INFO" "Restaurando ingressroutes..."
    kubectl apply -f $BACKUP_DIR/ingressroutes-backup.yaml 2>/dev/null || true
  fi
  
  if [ -f "$BACKUP_DIR/middlewares-backup.yaml" ]; then
    log "ℹ️ INFO" "Restaurando middlewares..."
    kubectl apply -f $BACKUP_DIR/middlewares-backup.yaml 2>/dev/null || true
  fi
  
  if [ -f "$BACKUP_DIR/certificates-backup.yaml" ]; then
    log "ℹ️ INFO" "Restaurando certificados..."
    kubectl apply -f $BACKUP_DIR/certificates-backup.yaml 2>/dev/null || true
  fi
  
  log "ℹ️ INFO" "Rollback concluído."
}

# Função para verificar a existência dos nós Besu
check_besu_nodes() {
  log "ℹ️ INFO" "Verificando a existência dos StatefulSets Besu..."
  
  for ((i=1; i<=NODE_COUNT; i++)); do
    node="besu-node${i}"
    kubectl get statefulset $node -n $NAMESPACE &>/dev/null
    if [ $? -ne 0 ]; then
      log "❌ ERROR" "StatefulSet $node não encontrado no namespace $NAMESPACE."
      return 1
    fi

    # Verificar se o pod está em execução
    kubectl get pod $node-0 -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"
    if [ $? -ne 0 ]; then
      log "❌ ERROR" "Pod $node-0 não está em execução."
      return 1
    fi
  done
  
  log "ℹ️ INFO" "Todos os nós Besu estão disponíveis."
  return 0
}

# Função para aplicar recursos com retry
apply_with_retry() {
  local file=$1
  local resource_type=$2
  local attempt=1
  local force_recreate=${3:-false}
  
  # Se forçar a recriação, primeiro tentamos excluir os recursos
  if [ "$force_recreate" = true ]; then
    log "ℹ️ INFO" "Excluindo recursos existentes de $resource_type antes de recriar..."
    
    # Para Middlewares, precisamos excluir cada um individualmente
    if [ "$resource_type" = "Middlewares" ]; then
      kubectl delete middleware.traefik.io -n $NAMESPACE besu-ws-middleware 2>/dev/null || true
      kubectl delete middleware.traefik.io -n $NAMESPACE besu-retry-middleware 2>/dev/null || true
      sleep 2
    elif [ "$resource_type" = "TraefikServices" ]; then
      kubectl delete traefikservice.traefik.io -n $NAMESPACE besu-rpc-lb 2>/dev/null || true
      kubectl delete traefikservice.traefik.io -n $NAMESPACE besu-ws-lb 2>/dev/null || true
      kubectl delete traefikservice.traefik.io -n $NAMESPACE besu-graphql-lb 2>/dev/null || true
      sleep 2
    elif [ "$resource_type" = "IngressRoutes" ]; then
      kubectl delete ingressroute.traefik.io -n $NAMESPACE besu-rpc-route 2>/dev/null || true
      kubectl delete ingressroute.traefik.io -n $NAMESPACE besu-ws-route 2>/dev/null || true
      kubectl delete ingressroute.traefik.io -n $NAMESPACE besu-graphql-route 2>/dev/null || true
      sleep 2
    fi
  fi
  
  while [ $attempt -le $RETRY_ATTEMPTS ]; do
    log "ℹ️ INFO" "Tentativa $attempt de $RETRY_ATTEMPTS para aplicar $resource_type..."
    kubectl apply -f $file
    
    if [ $? -eq 0 ]; then
      log "ℹ️ INFO" "$resource_type aplicado com sucesso."
      return 0
    else
      log "⚠️ WARNING" "Falha ao aplicar $resource_type. Tentando novamente em $RETRY_DELAY segundos..."
      attempt=$((attempt + 1))
      
      # Se estamos na última tentativa e ainda não forçamos a recriação, tente forçar
      if [ $attempt -eq $RETRY_ATTEMPTS ] && [ "$force_recreate" = false ]; then
        log "ℹ️ INFO" "Última tentativa: tentando forçar recriação dos recursos..."
        apply_with_retry "$file" "$resource_type" true
        return $?
      fi
      sleep $RETRY_DELAY
    fi
  done
  
  log "❌ ERROR" "Falha ao aplicar $resource_type após $RETRY_ATTEMPTS tentativas."
  return 1
}

# Função para verificar a existência dos arquivos de configuração
check_config_files() {
  for file in "$SERVICES_FILE" "$MIDDLEWARES_FILE" "$INGRESSROUTES_FILE"; do
    if [ ! -f "$file" ]; then
      log "❌ ERROR" "Arquivo de configuração $file não encontrado."
      return 1
    fi
  done
  
  log "ℹ️ INFO" "Todos os arquivos de configuração estão disponíveis."
  return 0
}

# Função para verificar acesso ao cluster
check_cluster_access() {
  log "ℹ️ INFO" "Verificando acesso ao cluster Kubernetes..."
  
  kubectl get nodes &>/dev/null
  if [ $? -ne 0 ]; then
    log "❌ ERROR" "Não foi possível acessar o cluster Kubernetes."
    return 1
  fi
  
  # Verificar acesso ao namespace
  kubectl get namespace $NAMESPACE &>/dev/null
  if [ $? -ne 0 ]; then
    log "❌ ERROR" "Namespace $NAMESPACE não encontrado ou sem acesso."
    return 1
  fi
  
  log "ℹ️ INFO" "Acesso ao cluster e namespace $NAMESPACE confirmado."
  return 0
}

# Função para verificar o deployment atualizada para aguardar mais tempo pelos recursos
verify_deployment() {
  local success=true
  local retry_count=0
  local max_retries=3
  
  while [ $retry_count -lt $max_retries ]; do
    success=true
    
    # Verificar serviços dinamicamente
    log "ℹ️ INFO" "Verificando serviços..."
    for ((i=1; i<=NODE_COUNT; i++)); do
      for svc_type in rpc ws graphql; do
        local svc="besu-node${i}-${svc_type}"
        kubectl get service $svc -n $NAMESPACE &>/dev/null
        if [ $? -ne 0 ]; then
          log "❌ ERROR" "Serviço $svc não encontrado. Tentativa $(($retry_count + 1))/$max_retries."
          success=false
        fi
      done
    done
    
    # Verificar certificados
    log "ℹ️ INFO" "Verificando certificados..."
    for cert in "rpc-besu" "ws-besu" "graphql-besu"; do
      kubectl get certificate $cert -n $NAMESPACE &>/dev/null
      if [ $? -ne 0 ]; then
        log "⚠️ WARNING" "Certificado $cert não encontrado. Isso pode ser normal se o cert-manager não estiver configurado."
      fi
    done
    
    # Verificar Middlewares
    log "ℹ️ INFO" "Verificando Middlewares..."
    for mw in "besu-ws-middleware" "besu-retry-middleware"; do
      kubectl get middlewares.traefik.io $mw -n $NAMESPACE &>/dev/null
      if [ $? -ne 0 ]; then
        log "❌ ERROR" "Middleware $mw não encontrado. Tentativa $(($retry_count + 1))/$max_retries."
        success=false
      fi
    done
    
    # Verificar IngressRoutes
    log "ℹ️ INFO" "Verificando IngressRoutes..."
    for ir in "besu-rpc-route" "besu-ws-route" "besu-graphql-route"; do
      kubectl get ingressroute $ir -n $NAMESPACE &>/dev/null
      if [ $? -ne 0 ]; then
        log "❌ ERROR" "IngressRoute $ir não encontrado. Tentativa $(($retry_count + 1))/$max_retries."
        success=false
      fi
    done
    
    if [ "$success" = true ]; then
      log "ℹ️ INFO" "Todos os recursos foram implantados com sucesso!"
      return 0
    fi
    
  # Aguardar mais tempo entre tentativas
  retry_count=$((retry_count + 1))
  if [ $retry_count -lt $max_retries ]; then
    log "⚠️ WARNING" "Alguns recursos não foram verificados corretamente. Aguardando 15 segundos e tentando novamente..."
    sleep 15
  fi
    if [ $retry_count -lt $max_retries ]; then
      log "⚠️ WARNING" "Alguns recursos não foram verificados corretamente. Aguardando 15 segundos e tentando novamente..."
      sleep 15
    fi
  done
  
  log "❌ ERROR" "Verificação dos recursos falhou após $max_retries tentativas."
  return 1
}

# Função para criar certificados e aplicar recursos
deploy_resources() {
  log "ℹ️ INFO" "Iniciando implantação dos recursos..."
  
  # Criar certificados TLS
  if kubectl get clusterissuer letsencrypt-certmanager &>/dev/null; then
    log "ℹ️ INFO" "ClusterIssuer letsencrypt-certmanager encontrado, criando certificados TLS..."
    create_tls_certificates
  else
    log "⚠️ WARNING" "ClusterIssuer letsencrypt-certmanager não encontrado. Os certificados não serão criados automaticamente."
  fi
  
  # Aplicar recursos
  apply_with_retry "$SERVICES_FILE" "Serviços"
  apply_with_retry "$MIDDLEWARES_FILE" "Middlewares"
  apply_with_retry "$INGRESSROUTES_FILE" "IngressRoutes"
  
  log "ℹ️ INFO" "Recursos aplicados com sucesso!"
}

# Função para diagnosticar problemas de conectividade 
diagnose_connectivity() {
  log "ℹ️ INFO" "Iniciando diagnóstico de conectividade..."

  # Verificar se os pods estão em execução
  log "ℹ️ INFO" "Verificando status dos pods Besu..."
  for ((i=1; i<=NODE_COUNT; i++)); do
    kubectl get pod besu-node${i}-0 -n $NAMESPACE -o wide
  done

  # Verificar endpoints dos serviços
  log "ℹ️ INFO" "Verificando endpoints dos serviços..."
  for ((i=1; i<=NODE_COUNT; i++)); do
    kubectl get endpoints besu-node${i}-rpc -n $NAMESPACE
    kubectl get endpoints besu-node${i}-ws -n $NAMESPACE
    kubectl get endpoints besu-node${i}-graphql -n $NAMESPACE
  done

  # Verificar IngressRoutes
  log "ℹ️ INFO" "Verificando IngressRoutes..."
  kubectl get ingressroute -n $NAMESPACE

  # Verificar Certificados
  log "ℹ️ INFO" "Verificando Certificados..."
  kubectl get certificates -n $NAMESPACE
  
  # Verificar se o Traefik está funcionando corretamente - procurar em todos os namespaces
  log "ℹ️ INFO" "Verificando pods do Traefik em todos os namespaces..."
  TRAEFIK_NS=$(kubectl get pods --all-namespaces | grep -i traefik | awk '{print $1}' | head -1)
  
  if [ -z "$TRAEFIK_NS" ]; then
    log "⚠️ WARNING" "Não foram encontrados pods do Traefik em nenhum namespace."
  else
    log "ℹ️ INFO" "Pods do Traefik encontrados no namespace: $TRAEFIK_NS"
    kubectl get pods -n $TRAEFIK_NS -l app.kubernetes.io/name=traefik -o wide || kubectl get pods -n $TRAEFIK_NS -l app=traefik -o wide
    
    # Verificar logs do Traefik para rotas relacionadas ao besu
    TRAEFIK_POD=$(kubectl get pods -n $TRAEFIK_NS -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || kubectl get pods -n $TRAEFIK_NS -l app=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$TRAEFIK_POD" ]; then
      log "ℹ️ INFO" "Verificando logs do Traefik relacionados ao besu..."
      kubectl logs -n $TRAEFIK_NS $TRAEFIK_POD --tail=50 | grep -i "besu\|rpc\|ws\|graphql" || echo "Nenhuma menção aos endpoints besu nos logs recentes do Traefik."
      
      # Verificar informações de configuração
      log "ℹ️ INFO" "Verificando configuração do Traefik..."
      kubectl get cm -n $TRAEFIK_NS -l app.kubernetes.io/name=traefik -o yaml || kubectl get cm -n $TRAEFIK_NS -l app=traefik -o yaml
    fi
  fi
  
  # Tentar acesso direto com port-forward em vez de criar um pod
  log "ℹ️ INFO" "Tentando acessar diretamente um serviço via port-forward..."
  
  kubectl port-forward -n $NAMESPACE svc/besu-node1-rpc 8545:8545 &
  PORT_FWD_PID=$!
  
  # Aguarde um momento para o port-forward iniciar
  sleep 2
  
  # Teste o acesso local
  log "ℹ️ INFO" "Testando acesso local ao serviço besu-node1-rpc via port-forward..."
  curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
    http://localhost:8545 || echo "Falha ao conectar localmente via port-forward"
  
  # Encerrar o port-forward
  kill $PORT_FWD_PID
  
  log "ℹ️ INFO" "Diagnóstico de conectividade concluído."
}

# Função para gerar blocos de serviços dinamicamente
build_service_blocks() {
  local blocks=""
  for ((i=1; i<=NODE_COUNT; i++)); do
    blocks+="---\napiVersion: v1\nkind: Service\nmetadata:\n  name: besu-node${i}-rpc\n  namespace: ${NAMESPACE}\nspec:\n  selector:\n    statefulset.kubernetes.io/pod-name: besu-node${i}-0\n  ports:\n    - name: rpc-http\n      port: 8545\n      targetPort: 8545\n      protocol: TCP\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: besu-node${i}-ws\n  namespace: ${NAMESPACE}\nspec:\n  selector:\n    statefulset.kubernetes.io/pod-name: besu-node${i}-0\n  ports:\n    - name: rpc-ws\n      port: 8546\n      targetPort: 8546\n      protocol: TCP\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: besu-node${i}-graphql\n  namespace: ${NAMESPACE}\nspec:\n  selector:\n    statefulset.kubernetes.io/pod-name: besu-node${i}-0\n  ports:\n    - name: graphql\n      port: 8547\n      targetPort: 8547\n      protocol: TCP\n"
  done
  echo -e "$blocks"
}

# Função para criar os certificados para TLS
create_tls_certificates() {
  log "ℹ️ INFO" "Criando certificados TLS para os endpoints Besu..."
  
  # RPC Certificate
  cat <<EOF > rpc-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rpc-besu
  namespace: ${NAMESPACE}
spec:
  secretName: rpc-besu-tls
  issuerRef:
    name: letsencrypt-certmanager
    kind: ClusterIssuer
  dnsNames:
  - rpc-besu.${DOMAIN}
EOF

  # WS Certificate
  cat <<EOF > ws-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ws-besu
  namespace: ${NAMESPACE}
spec:
  secretName: ws-besu-tls
  issuerRef:
    name: letsencrypt-certmanager
    kind: ClusterIssuer
  dnsNames:
  - ws-besu.${DOMAIN}
EOF

  # GraphQL Certificate
  cat <<EOF > graphql-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: graphql-besu
  namespace: ${NAMESPACE}
spec:
  secretName: graphql-besu-tls
  issuerRef:
    name: letsencrypt-certmanager
    kind: ClusterIssuer
  dnsNames:
  - graphql-besu.${DOMAIN}
EOF

  # Aplicar certificados
  kubectl apply -f rpc-certificate.yaml -n ${NAMESPACE}
  kubectl apply -f ws-certificate.yaml -n ${NAMESPACE}
  kubectl apply -f graphql-certificate.yaml -n ${NAMESPACE}
}

# Geração dos arquivos finais a partir dos templates
export NAMESPACE NODE_COUNT DOMAIN
BESU_SERVICE_BLOCKS="$(build_service_blocks)"
export BESU_SERVICE_BLOCKS

# Gerar arquivos finais
envsubst < "$SERVICES_TEMPLATE" > "$SERVICES_FILE"
envsubst < "$MIDDLEWARES_TEMPLATE" > "$MIDDLEWARES_FILE"
envsubst < "$INGRESSROUTES_TEMPLATE" > "$INGRESSROUTES_FILE"

log "ℹ️ INFO" "Templates processados e arquivos finais gerados."

# Início do script
log "ℹ️ INFO" "Iniciando implantação do balanceador de carga para Besu..."

# Verificar acesso ao cluster
check_cluster_access
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Não foi possível acessar o cluster. Encerrando script."
  exit 1
fi

# Verificar a existência dos nós Besu
check_besu_nodes
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Verificação dos nós Besu falhou. Encerrando script."
  exit 1
fi

# Verificar arquivos de configuração
check_config_files
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Verificação dos arquivos de configuração falhou. Encerrando script."
  exit 1
fi

# Backup dos recursos existentes
backup_resources

# Aplicar recursos
log "ℹ️ INFO" "Aplicando serviços..."
apply_with_retry $SERVICES_FILE "Serviços"
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Falha ao aplicar serviços. Iniciando rollback..."
  rollback
  exit 1
fi

log "ℹ️ INFO" "Aplicando Middlewares..."
apply_with_retry $MIDDLEWARES_FILE "Middlewares" true  # Forçar recriação dos middlewares
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Falha ao aplicar middlewares. Iniciando rollback..."
  rollback
  exit 1
fi

log "ℹ️ INFO" "Aplicando TraefikServices..."
apply_with_retry $TRAEFIK_SERVICES_FILE "TraefikServices" true  # Forçar recriação dos TraefikServices
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Falha ao aplicar TraefikServices. Iniciando rollback..."
  rollback
  exit 1
fi

log "ℹ️ INFO" "Aplicando IngressRoutes..."
apply_with_retry $INGRESSROUTES_FILE "IngressRoutes" true  # Forçar recriação dos IngressRoutes
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Falha ao aplicar IngressRoutes. Iniciando rollback..."
  rollback
  exit 1
fi

log "⚠️ WARNING" "Aguarde enquanto verificamos a implantação..."
# Verificar implantação
verify_deployment
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Implantação falhou. Iniciando rollback..."
  rollback
  exit 1
fi

log "✅ SUCCESS" "Balanceador de carga para Besu implantado com sucesso!"
log "ℹ️ INFO" "Os seguintes endpoints estão disponíveis:"
log "ℹ️ INFO" "- RPC HTTP: http://rpc-besu.${DOMAIN}"
log "ℹ️ INFO" "- RPC WebSocket: ws://ws-besu.${DOMAIN}"
log "ℹ️ INFO" "- GraphQL: http://graphql-besu.${DOMAIN}"

# Após a implantação, execute um diagnóstico de conectividade
log "ℹ️ INFO" "Executando diagnóstico de conectividade para verificar os endpoints..."
diagnose_connectivity

exit 0
