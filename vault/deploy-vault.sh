#!/usr/bin/env bash
# Deploy / upgrade HashiCorp Vault com auto-unseal para ambiente de desenvolvimento
set -Eeuo pipefail

################################################################################################
# VARIÁVEIS GLOBAIS                                                                            #
################################################################################################
RELEASE=vault                   # nome do Helm release
NS=vault                        # namespace a usar / criar
VALUES=vault-values.yaml        # arquivo de valores
CHART=hashicorp/vault           # chart do vault
CHART_VERSION="0.30.0"          # versão do chart
TIMEOUT=600s                    # timeout para operações (helm, kubernetes waits)
MAX_RETRIES=30                  # número máximo de tentativas para operações que podem falhar

################################################################################################
# FUNÇÕES UTILITÁRIAS                                                                          #
################################################################################################
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }
err()   { printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }

# Variável para configurar token inicial (opcional, para desenvolvimento)
ROOT_TOKEN="${VAULT_ROOT_TOKEN:-root}"

# Definir timeout global para prevenir que o script fique preso indefinidamente
SCRIPT_TIMEOUT=600  # 10 minutos

# Função para retry com número máximo de tentativas e intervalo
retry() { 
  local n=1 
  local max=$1
  shift
  until "$@"; do 
    if [ "$n" -ge "$max" ]; then
      return 1
    fi
    warn "Tentativa $n/$max falhou. Tentando novamente em 5s..."
    sleep 5
    n=$((n+1))
  done
}

# Função para fazer rollback em caso de falha
rollback() {
  local line_num=${1:-$LINENO}
  local proceed
  
  err "❌ Ocorreu um erro na linha $line_num"
  
  # Mostrar status atual antes de perguntar sobre rollback
  info "Status atual dos recursos do Vault:"
  kubectl get pods,svc,pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NS" 2>/dev/null || true
  
  # Perguntar se deseja fazer rollback
  read -rp "⚠️  Deseja fazer rollback completo (remover todos os recursos)? [y/N]: " proceed
  
  if [[ "$proceed" =~ ^[Yy]$ ]]; then
    info "Iniciando processo de rollback..."
    
    # Remover pods forçadamente primeiro para liberar PVCs
    info "Removendo pods forçadamente..."
    kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o name | 
      xargs -r kubectl delete -n "$NS" --force --grace-period=0 || true
    
    # Aguardar um pouco para os pods serem removidos
    sleep 3
    
    info "Removendo release do Helm..."
    helm uninstall "$RELEASE" -n "$NS" --timeout 60s || true
    
    info "Removendo PVCs relacionados..."
    kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NS" --wait=false || true
    
    # Verificar se ainda existem recursos
    if kubectl get pods,svc -l app.kubernetes.io/instance="$RELEASE" -n "$NS" 2>/dev/null | grep -q .; then
      warn "⚠️ Ainda existem recursos do Vault. Tentando remover manualmente..."
      kubectl delete pods,svc,pvc,statefulset,deployment,secret -l app.kubernetes.io/instance="$RELEASE" -n "$NS" --wait=false || true
    fi
    
    info "Rollback concluído. Agora você pode executar o script novamente."
  else
    warn "Rollback ignorado. O ambiente pode estar em estado inconsistente."
    warn "Você pode tentar executar o script novamente ou fazer rollback manual posteriormente."
  fi
  
  exit 1
}
trap 'rollback $LINENO' ERR

# Verificador de existência de binários
check_command() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "❌ Comando '$cmd' não encontrado. Por favor, instale-o antes de continuar."
      exit 1
    fi
  done
}

# Verifica pré-requisitos
check_prerequisites() {
  info "Verificando pré-requisitos..."
  check_command kubectl helm
  
  # Verifica se consegue acessar o cluster
  if ! kubectl get nodes >/dev/null 2>&1; then
    err "❌ Não foi possível acessar o cluster Kubernetes. Verifique sua conexão e configuração."
    exit 1
  fi
}

# Função para aguardar pods estarem em execução
wait_for_pods() {
  local namespace=$1
  local label_selector=$2
  local retries=$3
  local count=0

  info "Aguardando por pods com selector: $label_selector em namespace: $namespace"
  
  while [ $count -lt $retries ]; do
    # Obter apenas os nomes dos pods (sem tipo/recurso)
    local pod_names=$(kubectl get pods -n "$namespace" -l "$label_selector" -o custom-columns=":metadata.name" --no-headers 2>/dev/null)
    
    if [ -z "$pod_names" ]; then
      count=$((count + 1))
      info "[$count/$retries] Nenhum pod encontrado com selector '$label_selector'. Aguardando..."
      sleep 5
      continue
    fi
    
    # Verifica se todos os pods estão pelo menos em Running (não aguarda Ready)
    local all_running=true
    for pod_name in $pod_names; do
      local pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
      
      if [ "$pod_status" != "Running" ]; then
        all_running=false
        info "[$count/$retries] Pod $pod_name está em estado $pod_status, esperando por Running..."
        break
      fi
    done
    
    if $all_running; then
      info "✅ Todos os pods estão em estado Running."
      for pod_name in $pod_names; do
        info "🛒 Pod: $pod_name"
      done
      return 0
    fi
    
    count=$((count + 1))
    sleep 5
  done
  
  warn "❌ Tempo de espera esgotado. Alguns pods não estão em estado Running."
  local pod_names=$(kubectl get pods -n "$namespace" -l "$label_selector" -o custom-columns=":metadata.name" --no-headers 2>/dev/null)
  for pod_name in $pod_names; do
    local pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
    info "Pod: $pod_name, Status: $pod_status"
    
    # Mostrar detalhes adicionais para diagnóstico
    kubectl describe pod "$pod_name" -n "$namespace" | grep -A10 "State:" || true
    kubectl logs "$pod_name" -n "$namespace" --tail=10 || true
  done
  
  return 1
}

################################################################################################
# FUNÇÕES DE INSTALAÇÃO E TESTES                                                              #
################################################################################################

# Função para adicionar repositório Helm e criar namespace
setup_environment() {
  info "Configurando ambiente..."
  
  info "Adicionando repositório Helm do HashiCorp..."
  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo update >/dev/null
  
  info "Verificando namespace..."
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
}

# Função para instalar/atualizar o Vault via Helm
install_vault() {
  info "Instalando/atualizando HashiCorp Vault..."
  
  # Verificar se o release já existe
  if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    info "Release existe → upgrade."
    helm upgrade "$RELEASE" "$CHART" \
      --namespace "$NS" \
      --timeout "$TIMEOUT" \
      -f "$VALUES" \
      --version "$CHART_VERSION" \
      --reuse-values
  else
    info "Release não existe → install."
    helm install "$RELEASE" "$CHART" \
      --namespace "$NS" \
      --timeout "$TIMEOUT" \
      -f "$VALUES" \
      --version "$CHART_VERSION"
  fi
}

# Função para verificar se a instalação foi bem-sucedida
verify_installation() {
  info "Verificando instalação do Vault..."
  
  # Esperar por todos os recursos do Vault
  info "Aguardando recursos do Vault serem criados..."
  sleep 5  # Aguarda um pouco para os recursos serem criados
  
  # Verificar se o deployment/statefulset foi criado corretamente
  local deployment_type=""
  local resource_name=""
  
  # Verificar qual tipo de recurso o Vault criou (pode ser statefulset ou deployment)
  if kubectl get statefulset -l app.kubernetes.io/instance="$RELEASE" -n "$NS" >/dev/null 2>&1; then
    deployment_type="statefulset"
    resource_name=$(kubectl get statefulset -l app.kubernetes.io/instance="$RELEASE" -n "$NS" -o jsonpath="{.items[0].metadata.name}")
  elif kubectl get deployment -l app.kubernetes.io/instance="$RELEASE" -n "$NS" >/dev/null 2>&1; then
    deployment_type="deployment"
    resource_name=$(kubectl get deployment -l app.kubernetes.io/instance="$RELEASE" -n "$NS" -o jsonpath="{.items[0].metadata.name}")
  else
    err "❌ Não foi possível encontrar deployment ou statefulset do Vault após a instalação."
    exit 1
  fi
  
  info "Detectado $deployment_type: $resource_name"
  
  # Aguardar o recurso ficar pronto
  info "Aguardando $deployment_type $resource_name ficar Ready..."
  
  # Alterando estratégia para aguardar os pods diretamente
  info "Aguardando pods do $resource_name ficarem prontos..."
  sleep 10  # Dá tempo para os pods iniciarem
  
  # Em vez de usar rollout status, aguardar diretamente pelos pods
  local selector="app.kubernetes.io/instance=$RELEASE"
  
  # Esperar até que pelo menos um pod esteja em estado Running
  if ! wait_for_pods "$NS" "$selector" "$MAX_RETRIES"; then
    err "❌ Timeout aguardando pods com seletor $selector ficarem em estado Running"
    kubectl get all -n "$NS" -o wide
    exit 1
  fi
  
  info "Pods encontrados, verificando status..."

  # Verificar se o pod do Vault está pronto
  info "Verificando pod do Vault..."
  local pod_name
  
  # Aguardar pelo menos um pod estar disponível - com retry
  local retries=0
  while [ $retries -lt "$MAX_RETRIES" ]; do
    if pod_name=$(kubectl get pods -l app.kubernetes.io/name=vault -n "$NS" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null) && [ -n "$pod_name" ]; then
      info "✅ Pod do Vault encontrado: $pod_name"
      break
    fi
    retries=$((retries+1))
    warn "Tentativa $retries/$MAX_RETRIES: Pod do Vault ainda não está disponível. Aguardando 5s..."
    sleep 5
  done
  
  if [ -z "$pod_name" ]; then
    err "❌ Não foi possível encontrar pods do Vault após $MAX_RETRIES tentativas."
    kubectl get pods -n "$NS" -o wide
    exit 1
  fi
  
  # Verificar status do pod
  info "Verificando status do pod: $pod_name"
  kubectl get pod "$pod_name" -n "$NS" -o wide
  kubectl describe pod "$pod_name" -n "$NS" | grep -A5 "Conditions:" || true
  
  # Aguardar até que o contêiner principal do Vault esteja em execução 
  # Não esperamos que esteja "ready" porque o Vault inicialmente estará sealed
  info "Aguardando o contêiner Vault ficar em execução (pode não ficar Ready devido ao estado Sealed)..."
  retries=0
  while [ $retries -lt "$MAX_RETRIES" ]; do
    pod_status=$(kubectl get pod "$pod_name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    container_running=$(kubectl get pod "$pod_name" -n "$NS" -o jsonpath='{.status.containerStatuses[0].started}' 2>/dev/null)
    
    if [[ "$pod_status" == "Running" && "$container_running" == "true" ]]; then
      info "✅ Pod $pod_name está em execução (embora possa estar sealed e não pronto)!"
      break
    fi
    
    retries=$((retries+1))
    warn "Tentativa $retries/$MAX_RETRIES: Pod está no estado '$pod_status', contêiner started=$container_running. Aguardando 5s..."
    if (( retries % 5 == 0 )); then
      # Mostrar readiness probe a cada 5 tentativas para diagnóstico
      kubectl describe pod "$pod_name" -n "$NS" | grep -A3 "Readiness:" || true
    fi
    sleep 5
  done
  
  if [ $retries -ge "$MAX_RETRIES" ]; then
    # Aqui não paramos a execução, apenas mostramos um aviso
    warn "⚠️ O pod $pod_name pode não estar totalmente pronto, mas vamos continuar e tentar inicializá-lo"
    kubectl describe pod/"$pod_name" -n "$NS" | grep -A10 "Conditions:"
    kubectl logs "$pod_name" -n "$NS" --tail=20 || true
  fi
  
  # Retornar o nome do pod para ser usado por outras funções
  echo "$pod_name"
}

# Função para testar a conectividade com o Vault
test_vault_connection() {
  local pod_name=$1
  
  info "Testando conectividade com o Vault..."
  
  # Verificar se o pod existe, com retry para dar tempo ao Kubernetes
  local retries=0
  while [ $retries -lt 10 ]; do
    if kubectl get pod "$pod_name" -n "$NS" >/dev/null 2>&1; then
      info "✅ Pod $pod_name encontrado."
      break
    fi
    retries=$((retries+1))
    warn "Tentativa $retries/10: Pod $pod_name não encontrado. Aguardando 10s..."
    sleep 10
  done
  
  # Se ainda não encontrou o pod, tentar uma busca mais genérica antes de falhar
  if ! kubectl get pod "$pod_name" -n "$NS" >/dev/null 2>&1; then
    warn "⚠️ Pod específico não encontrado. Procurando por qualquer pod do Vault..."
    local alternate_pod=$(kubectl get pods -l app.kubernetes.io/name=vault -n "$NS" -o custom-columns=":metadata.name" --no-headers 2>/dev/null | head -1)
    if [ -n "$alternate_pod" ]; then
      info "🔄 Usando pod alternativo: $alternate_pod"
      pod_name="$alternate_pod"
      
      # Se foi fornecido um nome de variável para retorno, atualizar globalmente
      if [ -n "$2" ]; then
        # Retornar o novo nome do pod como um valor global
        export POD_NAME_GLOBAL="$alternate_pod"
      fi
    else
      warn "⚠️ Nenhum pod do Vault encontrado. Continuando mesmo assim, mas provavelmente haverá falhas."
    fi
  fi
  
  # Verificar se o container principal está rodando
  info "Verificando o status do contêiner Vault..."
  local container_status
  container_status=$(kubectl get pod "$pod_name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  
  if [[ "$container_status" == "Running" ]]; then
    info "✅ Pod está no estado Running"
  else
    warn "⚠️ Pod está no estado $container_status, não Running. Continuando mesmo assim..."
  fi
  
  # Verificar eventos do pod para diagnóstico
  info "Eventos recentes do pod:"
  kubectl get events --field-selector involvedObject.name="$pod_name" -n "$NS" --sort-by='.lastTimestamp' | tail -5 || true
  
  # Aguardar o Vault estar respondendo dentro do pod (se o pod existir)
  if kubectl get pod "$pod_name" -n "$NS" >/dev/null 2>&1; then
    local retries=0
    while [ $retries -lt 10 ]; do  # Reduzido para 10 tentativas, já que sabemos que provavelmente falhará
      # Usar -i ao invés de -it para evitar problemas de TTY
      if kubectl exec "$pod_name" -n "$NS" -- sh -c "vault version" &>/dev/null; then
        info "✅ Conexão com o Vault estabelecida com sucesso"
        return 0
      fi
      retries=$((retries+1))
      warn "Tentativa $retries/10: Vault ainda não está respondendo. Aguardando 10s..."
      sleep 10
    done
  else
    warn "⚠️ Pod $pod_name não existe. Não é possível testar a conectividade com o Vault."
  fi
  
  # Mesmo que falhe, continuamos (isso é esperado para Vault selado)
  info "ℹ️  Vault ainda não está respondendo, o que é esperado neste estágio (selado)."
  info "Continuando com o processo de inicialização."
  
  # Verificar se podemos acessar o shell do contêiner
  if kubectl exec "$pod_name" -n "$NS" -- sh -c "echo 'Shell acessível'" &>/dev/null; then
    info "✅ Shell do contêiner está acessível"
  else
    warn "⚠️ Não foi possível acessar o shell do contêiner. Continuando mesmo assim..."
  fi
}

# Função para obter informações de acesso ao Vault
get_access_info() {
  local pod_name=$1
  
  info "Obtendo informações de acesso ao Vault..."
  
  # Obter IP do node
  local node_ip
  if ! node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
    warn "⚠️ Não foi possível obter o IP do node. Usando localhost."
    node_ip="localhost"
  fi
  
  # Obter porta do serviço com retry e fallback
  local node_port=30820  # valor padrão
  local retries=0
  while [ $retries -lt 5 ]; do
    if temp_port=$(kubectl get service "$RELEASE"-ui -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null) && [ -n "$temp_port" ]; then
      node_port=$temp_port
      info "✅ Porta NodePort encontrada: $node_port"
      break
    fi
    retries=$((retries+1))
    warn "Tentativa $retries/5: Não foi possível obter a porta do serviço UI. Tentando novamente em 10s..."
    sleep 10
  done
  
  if [ $retries -ge 5 ]; then
    warn "⚠️ Não foi possível obter a porta do serviço NodePort após várias tentativas. Usando porta padrão 30820."
  fi
  
  # Testar acesso via curl
  info "Testando acesso ao UI do Vault via NodePort..."
  if command -v curl &>/dev/null; then
    # Timeout curto para não bloquear muito tempo
    if curl -s --connect-timeout 3 -o /dev/null -w "%{http_code}" "http://${node_ip}:${node_port}/ui/" 2>/dev/null | grep -q -e "200" -e "307" -e "302"; then
      info "✅ Acesso ao UI do Vault confirmado via http://${node_ip}:${node_port}/ui/"
    else
      warn "⚠️ UI do Vault não está acessível via http://${node_ip}:${node_port}/ui/"
      warn "Isso pode ser normal se o Vault ainda estiver inicializando ou se o NodePort estiver bloqueado."
    fi
  fi
  
  echo "${node_ip}:${node_port}"
}

# Função para inicializar o Vault
initialize_vault() {
  # Verificar se jq está disponível para parsear JSON
  if ! command -v jq >/dev/null 2>&1; then
    err "O utilitário 'jq' é necessário para parsear o JSON de inicialização do Vault. Instale com: brew install jq"
    exit 1
  fi
  local pod_name=$1
  
  info "Verificando se o Vault precisa ser inicializado..."
  
  # Verificar se o pod está em execução
  if ! kubectl get pod "$pod_name" -n "$NS" -o jsonpath='{.status.phase}' | grep -q "Running"; then
    warn "⚠️ O pod $pod_name não está em execução. Aguardando 10s..."
    sleep 10
    if ! kubectl get pod "$pod_name" -n "$NS" -o jsonpath='{.status.phase}' | grep -q "Running"; then
      err "❌ O pod $pod_name ainda não está em execução após espera. Saindo."
      exit 1
    fi
  fi
  
  info "Verificando se o binário vault está acessível..."
  # Detectar onde está o binário do vault
  local vault_path=""
  
  # Tentativa 1: Caminho padrão
  if kubectl exec "$pod_name" -n "$NS" -- sh -c "test -x /usr/local/bin/vault && echo found" 2>/dev/null | grep -q "found"; then
    vault_path="/usr/local/bin/vault"
    info "✅ Binário vault encontrado em $vault_path"
  # Tentativa 2: Caminho alternativo
  elif kubectl exec "$pod_name" -n "$NS" -- sh -c "test -x /bin/vault && echo found" 2>/dev/null | grep -q "found"; then
    vault_path="/bin/vault"
    info "✅ Binário vault encontrado em $vault_path"
  else
    warn "⚠️ Não foi possível encontrar o binário vault nos caminhos padrão."
    info "Tentando inicializar mesmo assim..."
    vault_path="vault"  # Tentar usar o comando diretamente
  fi
  
  # Aguardar um pouco para garantir que o pod esteja estável antes de tentar inicializar
  info "Aguardando 10s para estabilização do pod antes de inicializar..."
  sleep 10

  # Obter status do Vault (mesmo que falhe)
  info "Tentando obter status do Vault..."
  local vault_status=""
  local cmd_status="VAULT_ADDR=http://127.0.0.1:8200 $vault_path status -format=json 2>/dev/null || echo '{\"initialized\": false}'"
  
  # Tenta até 10 vezes obter o status, com mais tempo entre as tentativas
  for i in {1..10}; do
    info "Tentativa $i de obter status: kubectl exec $pod_name -n $NS -- sh -c \"$cmd_status\""
    if vault_status=$(kubectl exec "$pod_name" -n "$NS" -- sh -c "$cmd_status" 2>/dev/null); then
      if [ -n "$vault_status" ] && echo "$vault_status" | grep -q "{"; then
        info "✅ Status do Vault obtido com sucesso na tentativa $i"
        info "Status: $vault_status"
        break
      fi
    fi
    info "Tentativa $i: Aguardando Vault ficar disponível..."
    
    # A cada 3 tentativas, mostrar mais diagnósticos
    if (( i % 3 == 0 )); then
      info "Diagnóstico do pod:"
      kubectl describe pod "$pod_name" -n "$NS" | grep -E "State:|Ready:|Readiness:" || true
      kubectl logs "$pod_name" -n "$NS" --tail=10 || true
    fi
    
    sleep 5
  done
  
  # Verificar se conseguiu obter status ou se precisa inicializar
  local needs_init=true
  if [ -n "$vault_status" ] && echo "$vault_status" | grep -q "initialized"; then
    if echo "$vault_status" | grep -q '"initialized": true'; then
      info "✅ Vault já está inicializado."
      needs_init=false
    elif echo "$vault_status" | grep -q '"initialized": false'; then
      info "Vault não inicializado. Iniciando processo de inicialização..."
    else
      # Tentar verificar usando o status em formato texto
      info "Verificando status em formato texto..."
      local text_status=""
      text_status=$(kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 $vault_path status" 2>/dev/null || echo "")
      
      if [ -n "$text_status" ] && echo "$text_status" | grep -q "Initialized.*true"; then
        info "✅ Vault já está inicializado (verificado via status texto)."
        needs_init=false
      else
        info "Vault precisa ser inicializado..."
      fi
    fi
  else
    info "Não foi possível obter status do Vault. Assumindo que precisa ser inicializado..."
    vault_status='{"initialized": false, "sealed": true}'
  fi

  # Processo de inicialização, se necessário
  local unseal_key=""
  local root_token=""
  
  if $needs_init; then
    info "Inicializando Vault..."
    local init_cmd="VAULT_ADDR=http://127.0.0.1:8200 $vault_path operator init -key-shares=1 -key-threshold=1 -format=json"
    local init_output=""

    for i in {1..10}; do
      info "Tentativa $i de inicializar o Vault..."
      info "Executando: kubectl exec $pod_name -n $NS -- sh -c \"$init_cmd\""
      init_output=$(kubectl exec "$pod_name" -n "$NS" -- sh -c "$init_cmd")

      # Tentar parsear JSON com jq
      if echo "$init_output" | jq . >/dev/null 2>&1; then
        unseal_key=$(echo "$init_output" | jq -r '.unseal_keys_b64[0] // .keys[0] // .keys_base64[0] // empty')
        root_token=$(echo "$init_output" | jq -r '.root_token // empty')
        if [ -n "$unseal_key" ] && [ -n "$root_token" ]; then
          info "✅ Vault inicializado com sucesso!"
          info "Chaves extraídas com sucesso!"
          info "Unseal Key: $unseal_key"
          break
        else
          warn "⚠️ Falha ao extrair chaves do JSON. Saída recebida:"
          echo "$init_output"
        fi
      else
        warn "⚠️ Saída da inicialização não é um JSON válido ou não contém root_token:"
        echo "$init_output"
      fi

      if (( i % 2 == 0 )); then
        info "Diagnóstico do pod:"
        kubectl describe pod "$pod_name" -n "$NS" | grep -A5 "State:" || true
        kubectl logs "$pod_name" -n "$NS" --tail=10 || true
      fi
      sleep 5
    done

    if [ -z "$unseal_key" ] || [ -z "$root_token" ]; then
      warn "⚠️ Não foi possível inicializar o Vault ou extrair as chaves após várias tentativas."
      warn "Você precisará inicializar o Vault manualmente usando:"
      warn "kubectl exec $pod_name -n $NS -- sh -c \"VAULT_ADDR=http://127.0.0.1:8200 vault operator init -key-shares=1 -key-threshold=1\""
      return 1
    fi

    # Tentar fazer unseal
    info "Realizando unseal do Vault..."
    local unseal_cmd="VAULT_ADDR=http://127.0.0.1:8200 $vault_path operator unseal $unseal_key"
    local unseal_result=""

    for i in {1..5}; do
      info "Tentativa $i de unseal..."
      if unseal_result=$(kubectl exec "$pod_name" -n "$NS" -- sh -c "$unseal_cmd" 2>/dev/null) && [ -n "$unseal_result" ]; then
        if echo "$unseal_result" | grep -q "Sealed.*false"; then
          info "✅ Vault unsealed com sucesso!"
          break
        fi
      fi
      sleep 3
    done

    info ""
    info "⚠️  IMPORTANTE: Guarde estas informações em local seguro!" >&2
    info "🔑 Unseal Key: $unseal_key" >&2
    info "🔒 Root Token: $root_token" >&2

    # Só retorna a linha se ambos existirem e forem válidos
    if [[ "$unseal_key" =~ ^[A-Za-z0-9+/=]{20,}$ && "$root_token" =~ ^hvs\.[A-Za-z0-9]+$ ]]; then
      echo "$unseal_key:$root_token"
    fi
  else
    # Verificar se está selado
    if echo "$vault_status" | grep -q '"sealed": true'; then
      warn "⚠️  Vault está atualmente selado. Use a chave de unseal para deselá-lo." >&2
      warn "Execute o comando: ./unseal-vault.sh <sua-chave-de-unseal>" >&2
    else
      info "✅ Vault está funcionando normalmente (unsealed)." >&2
    fi
    # Não imprime nada no stdout
  fi
}  # Função principal
main() {
  check_prerequisites
  setup_environment
  install_vault
  
  # Obter o nome do pod principal do Vault
  local pod_name
  pod_name=$(verify_installation)
  
  # Dar tempo ao pod para estabilizar
  info "Aguardando 5 segundos para estabilização do pod..."
  sleep 5
  
  # Variável global que pode ser atualizada por funções
  export POD_NAME_GLOBAL=""
  
  # Testar conexão com o Vault (mesmo que falhe, continuamos)
  test_vault_connection "$pod_name" "update"
  
  # Atualizar o nome do pod se foi alterado na função test_vault_connection
  if [ -n "$POD_NAME_GLOBAL" ]; then
    pod_name="$POD_NAME_GLOBAL"
    info "Nome do pod atualizado para: $pod_name"
  fi
  
  # Verificar se o pod existe antes de continuar
  if ! kubectl get pod "$pod_name" -n "$NS" >/dev/null 2>&1; then
    err "❌ Pod $pod_name não encontrado. Não é possível continuar com a inicialização."
    exit 1
  fi
  
  # Inicializar o Vault
  info "Iniciando processo de inicialização do Vault..."
  local init_result=""
  # Tentamos até 3 vezes em caso de falha
  for i in {1..3}; do
    info "Tentativa $i de inicialização do Vault..."
    if init_result=$(initialize_vault "$pod_name" 2>/dev/null); then
      info "✅ Inicialização concluída com sucesso!"
      break
    else
      warn "⚠️ Tentativa $i de inicialização falhou."
      sleep 3
    fi
  done
  
  # Tentar obter informações de acesso (com tolerância a falhas)
  local access_info="IP_DO_NODE:30820"  # valor padrão caso falhe
  local temp_info
  temp_info=$(get_access_info "$pod_name" 2>/dev/null) || true
  if [ -n "$temp_info" ]; then
    access_info="$temp_info"
  fi
  
  # Exibir resumo das informações
  info ""
  info "================================="
  info "    DEPLOYMENT CONCLUÍDO"
  info "================================="
  info ""
  info "🌐 URL do Vault UI: http://$access_info/ui/"
  
  # Sempre tentar obter status e fazer unseal se necessário
  local unseal_key=""
  local root_token=""
  local found_keys=false

  # 1. Tentar extrair do resultado da inicialização (apenas se for uma linha simples <unseal_key>:<root_token>)
  if [[ -n "$init_result" ]]; then
    # Remove espaços e quebras de linha
    local clean_init=$(echo "$init_result" | tr -d '\r' | grep -E '^[^:]+:[^:]+$' || true)
    if [[ -n "$clean_init" ]]; then
      unseal_key=$(echo "$clean_init" | cut -d':' -f1)
      root_token=$(echo "$clean_init" | cut -d':' -f2)
      if [[ -n "$unseal_key" && -n "$root_token" ]]; then
        found_keys=true
        # Só grava se for exatamente o formato esperado
        if [[ "$clean_init" =~ ^[^:]+:[^:]+$ ]]; then
          echo "$clean_init" > vault-unseal.txt
        fi
      fi
    fi
  fi

  # 2. Se não conseguiu extrair do init, tentar obter do arquivo de backup (se existir)
  if [[ "$found_keys" = false && -f "vault-unseal.txt" ]]; then
    # Só aceita se for uma linha simples, sem logs
    local file_line=$(head -n1 vault-unseal.txt | grep -E '^[^:]+:[^:]+$' || true)
    if [[ -n "$file_line" ]]; then
      unseal_key=$(echo "$file_line" | cut -d':' -f1)
      root_token=$(echo "$file_line" | cut -d':' -f2)
      if [[ -n "$unseal_key" && -n "$root_token" ]]; then
        found_keys=true
      fi
    fi
  fi

  # 3. Exibir as chaves se encontradas, tentar unseal se necessário
  if [[ "$found_keys" = true && -n "$unseal_key" && -n "$root_token" ]]; then
    info "🔑 Unseal Key: $unseal_key"
    info "🔒 Root Token: $root_token"
    # Verificar se está selado
    local is_sealed=true
    if status_output=$(kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status" 2>/dev/null); then
      if ! echo "$status_output" | grep -q "Sealed.*true"; then
        is_sealed=false
        info "✅ Vault já está unsealed. Nada a fazer."
      fi
    fi
    if [[ "$is_sealed" = true ]]; then
      info "🔓 Realizando unseal automático do Vault..."
      if kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal $unseal_key" &>/dev/null; then
        info "✅ Unseal realizado com sucesso!"
      else
        warn "⚠️ Falha ao realizar unseal automático."
        warn "   Execute manualmente: ./unseal-vault.sh $unseal_key"
      fi
    fi
  else
    warn "⚠️ Não foi possível obter a chave de unseal nem o root token."
    warn "   Isso ocorre porque o Vault já estava inicializado e as chaves não estão salvas em vault-unseal.txt."
    warn "   Se você inicializou o Vault anteriormente, recupere as chaves do backup seguro."
    warn "   Caso contrário, será necessário resetar o PVC ou inicializar manualmente."
    info "🔍 Para verificar o status do Vault manualmente, use:"
    info "    kubectl exec $pod_name -n $NS -- sh -c \"VAULT_ADDR=http://127.0.0.1:8200 vault status\""
    info "Se necessário, inicialize manualmente e salve a chave de unseal."
  fi
  
  # Verificar status do pod
  info ""
  info "📊 Status atual do pod:"
  kubectl get pod "$pod_name" -n "$NS" -o wide
  
  info ""
  info "🔍 Para verificar o status do Vault:"
  info "    kubectl exec $pod_name -n $NS -- vault status"
  info ""
  info "🔓 Para fazer unseal após reinicialização:"
  info "    ./unseal-vault.sh <unseal-key>"
  info "    ou"
  info "    kubectl exec $pod_name -n $NS -- vault operator unseal <unseal-key>"
  info ""
  info "🐞 Para diagnósticos:"
  info "    kubectl logs $pod_name -n $NS"
  info "    kubectl describe pod $pod_name -n $NS"
  info ""
  info "⚠️  IMPORTANTE: Guarde a chave de unseal e o token root em local seguro!"
}

# Executa o script
main "$@"
