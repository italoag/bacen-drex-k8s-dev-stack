#!/usr/bin/env bash
# Script para instalar apenas o vault-autounseal em um Vault existente
set -Eeuo pipefail

# --- Configurações Globais ---
readonly NS="vault"                        # Namespace a usar (deve ser o mesmo do Vault)
readonly RELEASE="vault-autounseal"        # Nome do Helm release para o vault-autounseal
readonly CHART="vault-autounseal/vault-autounseal"  # Chart do vault-autounseal
readonly VAULT_SERVICE="vault"             # Nome do serviço do Vault
readonly VAULT_PORT="8200"                 # Porta do Vault
readonly AUTOUNSEAL_KEYS_SECRET="vault-keys"       # Nome do secret para as chaves
readonly AUTOUNSEAL_ROOT_TOKEN_SECRET="vault-root-token"  # Nome do secret para o token root
readonly AUTOUNSEAL_SHARES=1               # Número de shares para auto-unseal
readonly AUTOUNSEAL_THRESHOLD=1            # Threshold para auto-unseal
readonly UNSEAL_FILE="vault-unseal.txt"    # Arquivo contendo as chaves do Vault

# --- Funções de Log ---
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*" >&2; }
warn()  { printf '\e[33m[WARN]\e[0m %s\n' "$*" >&2; }
err()   { printf '\e[31m[ERR ]\e[0m  %s\n' "$*" >&2; }

# --- Tratamento de Erros e Rollback ---
cleanup_and_exit() {
  local line_num=${1:-$LINENO}
  err "❌ Ocorreu um erro na linha $line_num"
  
  info "Status atual dos recursos do vault-autounseal:"
  kubectl get pods,svc -l app.kubernetes.io/name="$RELEASE" -n "$NS" 2>/dev/null || true
  
  warn "O script falhou. Verifique os logs acima para diagnosticar o problema."
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

# Verifica se o Vault existe e está acessível
check_vault() {
  info "Verificando se o Vault existe e está acessível..."
  
  # Verifica se o namespace existe
  if ! kubectl get namespace "$NS" &>/dev/null; then
    err "Namespace $NS não existe. Verifique se o Vault está instalado."
    return 1
  fi
  
  # Verifica se o serviço do Vault existe
  if ! kubectl get service "$VAULT_SERVICE" -n "$NS" &>/dev/null; then
    err "Serviço $VAULT_SERVICE não encontrado no namespace $NS."
    err "Verifique se o Vault está instalado corretamente."
    return 1
  fi
  
  # Verifica se há pelo menos um pod do Vault rodando
  if ! kubectl get pods -l app.kubernetes.io/name=vault -n "$NS" --no-headers | grep -q Running; then
    err "Nenhum pod do Vault encontrado em estado 'Running'."
    err "Verifique se o Vault está instalado e inicializado."
    return 1
  fi
  
  info "✅ Vault encontrado e parece estar acessível."
  return 0
}

# Verifica se o arquivo com as chaves do Vault existe ou tenta encontrá-las no Kubernetes
check_vault_keys() {
  info "Verificando chaves do Vault..."
  
  # Verifica se o arquivo de chaves existe
  if [[ -f "$UNSEAL_FILE" ]]; then
    info "Arquivo $UNSEAL_FILE encontrado."
    
    # Valida o formato do arquivo
    if ! grep -q ":" "$UNSEAL_FILE"; then
      err "O arquivo $UNSEAL_FILE não parece estar no formato correto."
      err "O formato esperado é: <unseal_key>:<root_token>"
      return 1
    fi
    
    return 0
  fi
  
  warn "Arquivo $UNSEAL_FILE não encontrado."
  
  # Verifica se já existem secrets para tentar recuperar as chaves
  if kubectl get secret "$AUTOUNSEAL_KEYS_SECRET" -n "$NS" &>/dev/null && \
     kubectl get secret "$AUTOUNSEAL_ROOT_TOKEN_SECRET" -n "$NS" &>/dev/null; then
    
    warn "Secrets existentes encontrados. Tentando recuperar as chaves..."
    
    local unseal_key
    local root_token
    
    # Tenta recuperar a chave de unseal
    unseal_key=$(kubectl get secret "$AUTOUNSEAL_KEYS_SECRET" -n "$NS" -o jsonpath="{.data.key1}" 2>/dev/null | base64 --decode)
    
    # Tenta recuperar o token root
    root_token=$(kubectl get secret "$AUTOUNSEAL_ROOT_TOKEN_SECRET" -n "$NS" -o jsonpath="{.data.token}" 2>/dev/null | base64 --decode)
    
    if [[ -n "$unseal_key" && -n "$root_token" ]]; then
      info "Chaves recuperadas dos secrets existentes."
      echo "${unseal_key}:${root_token}" > "$UNSEAL_FILE"
      info "Chaves salvas em '$UNSEAL_FILE'."
      return 0
    fi
  fi
  
  err "Não foi possível obter as chaves do Vault."
  err "Você precisa inicializar o Vault primeiro e ter o arquivo '$UNSEAL_FILE' disponível."
  err "O arquivo deve estar no formato: <unseal_key>:<root_token>"
  return 1
}

# Configura o ambiente para instalar o vault-autounseal
setup_environment() {
  info "Configurando ambiente para o vault-autounseal..."
  
  info "Adicionando repositório Helm do vault-autounseal..."
  helm repo add vault-autounseal https://pytoshka.github.io/vault-autounseal >/dev/null 2>&1 || true
  helm repo update >/dev/null
  
  info "✅ Ambiente configurado com sucesso."
}

# Cria os secrets do Kubernetes para o vault-autounseal
create_secrets() {
  info "Criando secrets para o vault-autounseal..."
  
  # Extrai as chaves do arquivo
  local unseal_key
  local root_token
  unseal_key=$(cut -d':' -f1 < "$UNSEAL_FILE")
  root_token=$(cut -d':' -f2 < "$UNSEAL_FILE")
  
  if [[ -z "$unseal_key" || -z "$root_token" ]]; then
    err "Não foi possível extrair as chaves do arquivo $UNSEAL_FILE."
    err "O arquivo deve estar no formato: <unseal_key>:<root_token>"
    return 1
  fi
  
  # Cria ou atualiza o secret para a chave de unseal
  info "Criando/atualizando secret $AUTOUNSEAL_KEYS_SECRET para armazenar chaves de unseal..."
  kubectl create secret generic "$AUTOUNSEAL_KEYS_SECRET" \
    --namespace "$NS" \
    --from-literal="key1=$unseal_key" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Cria ou atualiza o secret para o token root
  info "Criando/atualizando secret $AUTOUNSEAL_ROOT_TOKEN_SECRET para armazenar token root..."
  kubectl create secret generic "$AUTOUNSEAL_ROOT_TOKEN_SECRET" \
    --namespace "$NS" \
    --from-literal="token=$root_token" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  info "✅ Secrets criados/atualizados com sucesso."
}

# Instala o vault-autounseal usando Helm
install_autounseal() {
  info "Instalando/atualizando o vault-autounseal..."
  
  # Determina o URL do vault usando o serviço interno do Kubernetes
  local vault_url="http://${VAULT_SERVICE}.${NS}.svc.cluster.local:${VAULT_PORT}"
  info "URL do Vault configurado: $vault_url"
  
  # Configura valores para o chart do vault-autounseal
  local autounseal_values=(
    "--set" "settings.vault_url=$vault_url"
    "--set" "settings.namespace=$NS"
    "--set" "settings.vault_secret_shares=$AUTOUNSEAL_SHARES"
    "--set" "settings.vault_secret_threshold=$AUTOUNSEAL_THRESHOLD"
    "--set" "settings.vault_keys_secret=$AUTOUNSEAL_KEYS_SECRET"
    "--set" "settings.vault_root_token_secret=$AUTOUNSEAL_ROOT_TOKEN_SECRET"
    "--set" "serviceAccount.create=true"
    "--set" "serviceAccount.name=vault-autounseal"
    "--set" "rbac.create=true"
  )
  
  # Verifica se já existe uma instalação do vault-autounseal
  if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    info "Release existente do vault-autounseal encontrado. Executando upgrade..."
    helm upgrade "$RELEASE" "$CHART" "${autounseal_values[@]}" -n "$NS" --timeout 180s
  else
    info "Instalando novo release do vault-autounseal..."
    helm install "$RELEASE" "$CHART" "${autounseal_values[@]}" -n "$NS" --timeout 180s
  fi
  
  info "✅ vault-autounseal instalado/atualizado com sucesso."
}

# Verifica se o deployment do vault-autounseal está funcionando
verify_deployment() {
  info "Verificando deployment do vault-autounseal..."
  
  # Aguarda o deployment ficar pronto
  info "Aguardando pods do vault-autounseal ficarem prontos..."
  kubectl rollout status deployment/"$RELEASE" -n "$NS" --timeout=180s
  
  # Verifica se há pelo menos um pod rodando
  if ! kubectl get pods -l app.kubernetes.io/name=vault-autounseal -n "$NS" --no-headers | grep -q Running; then
    err "Nenhum pod do vault-autounseal encontrado em estado 'Running'."
    kubectl get pods -l app.kubernetes.io/name=vault-autounseal -n "$NS"
    return 1
  fi
  
  # Mostra os logs recentes para verificação
  info "Logs recentes do vault-autounseal:"
  kubectl logs -l app.kubernetes.io/name=vault-autounseal -n "$NS" --tail=20
  
  info "✅ vault-autounseal está rodando."
}

show_summary() {
  info "=================================================="
  info "✅ INSTALAÇÃO DO VAULT-AUTOUNSEAL CONCLUÍDA"
  info "=================================================="
  info ""
  info "🔐 O vault-autounseal está configurado e rodando."
  info "Os seguintes secrets foram criados/atualizados:"
  info "- Unseal Key: $AUTOUNSEAL_KEYS_SECRET"
  info "- Root Token: $AUTOUNSEAL_ROOT_TOKEN_SECRET"
  info ""
  info "Para verificar o status do auto-unseal, execute:"
  info "kubectl get pod -n $NS -l app.kubernetes.io/name=vault-autounseal"
  info "kubectl logs -n $NS -l app.kubernetes.io/name=vault-autounseal"
  info ""
  info "Na próxima reinicialização do Vault, o vault-autounseal"
  info "detectará automaticamente e realizará o unseal."
  info "--------------------------------------------------"
}

# --- Função Principal ---
main() {
  # Verifica dependências
  check_command kubectl helm
  
  # Verifica se o Vault existe
  check_vault
  
  # Verifica as chaves do Vault
  check_vault_keys
  
  # Configura o ambiente
  setup_environment
  
  # Cria os secrets
  create_secrets
  
  # Instala o vault-autounseal
  install_autounseal
  
  # Verifica se o deployment está funcionando
  verify_deployment
  
  # Mostra o resumo da instalação
  show_summary
}

# --- Ponto de Entrada ---
main "$@"
