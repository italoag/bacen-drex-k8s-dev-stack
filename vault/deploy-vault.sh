#!/usr/bin/env bash
# Deploy / upgrade HashiCorp Vault com auto-unseal para ambiente de desenvolvimento
set -Eeuo pipefail

# --- Configurações Globais ---
readonly RELEASE="vault"                   # Nome do Helm release
readonly NS="vault"                        # Namespace a usar / criar
readonly VALUES="vault-values.yaml"        # Arquivo de valores
readonly CHART="hashicorp/vault"           # Chart do Vault
readonly CHART_VERSION="0.30.0"          # Versão do chart
readonly POD_NAME="${RELEASE}-0"           # Nome do pod principal (StatefulSet)
readonly SCRIPT_TIMEOUT=600                # Timeout global do script em segundos

# --- Funções de Log ---
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*" >&2; }
warn()  { printf '\e[33m[WARN]\e[0m %s\n' "$*" >&2; }
err()   { printf '\e[31m[ERR ]\e[0m  %s\n' "$*" >&2; }

# --- Tratamento de Erros e Rollback ---
cleanup_and_exit() {
  local line_num=${1:-$LINENO}
  err "❌ Ocorreu um erro na linha $line_num"
  
  info "Status atual dos recursos do Vault:"
  kubectl get pods,svc,pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NS" 2>/dev/null || true
  
  warn "O script falhou. Verifique os logs acima para diagnosticar o problema."
  warn "Você pode tentar executar o script novamente. Se o problema persistir, considere resetar o PVC."
  exit 1
}
trap 'cleanup_and_exit $LINENO' ERR

# --- Funções Utilitárias ---
check_command() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Comando '$cmd' não encontrado. Por favor, instale-o e tente novamente."
      exit 1
    fi
  done
}

wait_for_pod() {
  info "Aguardando o pod '$POD_NAME' ficar no estado 'Running'..."
  local retries=0
  local max_retries=60 # 5 minutos (60 * 5s)
  
  while [[ $retries -lt $max_retries ]]; do
    local status
    status=$(kubectl get pod "$POD_NAME" -n "$NS" -o 'jsonpath={.status.phase}' 2>/dev/null || echo "Pending")
    
    if [[ "$status" == "Running" ]]; then
      info "✅ Pod '$POD_NAME' está 'Running'."
      # Aguarda um pouco mais para o processo interno do Vault iniciar
      sleep 10
      return 0
    fi
    
    printf "." >&2
    sleep 5
    retries=$((retries + 1))
  done
  
  err "Tempo de espera esgotado. O pod '$POD_NAME' não atingiu o estado 'Running'."
  kubectl describe pod "$POD_NAME" -n "$NS" >&2
  kubectl logs "$POD_NAME" -n "$NS" --tail=50 >&2
  return 1
}

# --- Funções de Deploy ---
setup_environment() {
  info "Configurando ambiente..."
  
  info "Adicionando repositório Helm do HashiCorp..."
  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo update >/dev/null
  
  info "Verificando namespace..."
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
}

install_vault() {
  info "Instalando/atualizando o release Helm '$RELEASE'..."
  if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    info "Release existente encontrado. Executando upgrade..."
    helm upgrade "$RELEASE" "$CHART" --version "$CHART_VERSION" -f "$VALUES" -n "$NS" --timeout 300s --wait
  else
    info "Nenhum release existente. Executando instalação..."
    helm install "$RELEASE" "$CHART" --version "$CHART_VERSION" -f "$VALUES" -n "$NS" --timeout 300s --wait
  fi
  info "✅ Deploy/Upgrade do Helm concluído."
}

initialize_and_unseal_vault() {
  info "Iniciando processo de inicialização e unseal do Vault..."
  
  # Tenta obter o status para verificar se já está inicializado
  local status_output
  status_output=$(kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status" 2>/dev/null || echo "failed")

  info "--- DEBUG: Saída do vault status ---" >&2
  echo "$status_output" >&2
  info "------------------------------------" >&2

  # Verifica se o Vault está inicializado
  if echo "$status_output" | grep -q "Initialized *true"; then
    info "Vault já inicializado."
    if echo "$status_output" | grep -q "Sealed *true"; then
      warn "Vault está selado. Tentando fazer unseal com a chave do arquivo..."
      if [[ ! -f vault-unseal.txt ]]; then
        err "Arquivo 'vault-unseal.txt' não encontrado. Não é possível fazer unseal."
        err "Se você perdeu a chave, precisa resetar o PVC do Vault."
        return 1
      fi
      local key_from_file
      key_from_file=$(cut -d':' -f1 < vault-unseal.txt)
      kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal $key_from_file" >&2
      info "✅ Tentativa de unseal enviada."
    else
      info "✅ Vault já está 'unsealed'. Nenhuma ação necessária."
    fi
    return 0
  fi

  # Se não está inicializado, executa o processo de init/unseal
  info "Vault não está inicializado. Executando 'operator init'..."
  local init_cmd="VAULT_ADDR=http://127.0.0.1:8200 vault operator init -key-shares=1 -key-threshold=1 -format=json"
  local init_output
  
  # Executa o comando e captura a saída limpa
  init_output=$(kubectl exec "$POD_NAME" -n "$NS" -- sh -c "$init_cmd")

  # Extrai as chaves usando jq para parsear o JSON
  local unseal_key
  local root_token
  unseal_key=$(echo "$init_output" | jq -r '.unseal_keys_b64[0]')
  root_token=$(echo "$init_output" | jq -r '.root_token')

  if [[ -z "$unseal_key" || "$unseal_key" == "null" || -z "$root_token" || "$root_token" == "null" ]]; then
    err "Falha ao extrair unseal key ou root token da saída JSON da inicialização."
    echo "--- SAÍDA DO INIT ---" >&2
    echo "$init_output" >&2
    echo "---------------------" >&2
    return 1
  fi
  
  info "✅ Chaves extraídas com sucesso."
  # Salva as chaves no arquivo
  echo "${unseal_key}:${root_token}" > vault-unseal.txt
  info "Chaves salvas em 'vault-unseal.txt'."

  # Realiza o unseal automático com a chave recém-obtida
  info "Realizando unseal automático..."
  kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal $unseal_key" >&2
  info "✅ Vault inicializado e unsealed com sucesso."
}

show_summary() {
  info "=================================================="
  info "✅ DEPLOYMENT DO VAULT CONCLUÍDO"
  info "=================================================="
  
  local node_ip
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")
  
  local node_port
  node_port=$(kubectl get service -n "$NS" "${RELEASE}-ui" -o 'jsonpath={.spec.ports[0].nodePort}' 2>/dev/null || echo "30800")

  info "URL do Vault UI: http://${node_ip}:${node_port}"

  if [[ -f vault-unseal.txt ]]; then
    local unseal_key
    local root_token
    unseal_key=$(cut -d':' -f1 < vault-unseal.txt)
    root_token=$(cut -d':' -f2 < vault-unseal.txt)
    
    info "🔑 Unseal Key: $unseal_key"
    info "🔒 Root Token: $root_token"
    info "As chaves foram salvas em 'vault-unseal.txt'."
  else
    warn "Arquivo 'vault-unseal.txt' não encontrado. As chaves não puderam ser exibidas."
  fi
  
  info "Para verificar o status a qualquer momento, execute:"
  info "kubectl exec $POD_NAME -n $NS -- vault status"
  info "--------------------------------------------------"
}

# --- Função Principal ---
main() {
  check_command kubectl helm jq
  
  setup_environment
  install_vault
  wait_for_pod
  initialize_and_unseal_vault
  show_summary
}

# --- Ponto de Entrada ---
main "$@"
