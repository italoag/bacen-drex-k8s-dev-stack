#!/usr/bin/env bash
# Script para inicializar um Vault já implantado mas que precisa de unseal
set -Eeuo pipefail

# Variáveis
NS=${VAULT_NAMESPACE:-vault}
RELEASE=${VAULT_RELEASE:-vault}
VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}

# Cores e formatação
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Funções de utilidade
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  INICIALIZAÇÃO DE VAULT EXISTENTE      ${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# Obter o pod do Vault
pod_name=$(kubectl get pods -l app.kubernetes.io/name=vault -n "$NS" -o custom-columns=":metadata.name" --no-headers 2>/dev/null || echo "")

if [ -z "$pod_name" ]; then
  error "Não foi possível encontrar o pod do Vault."
  exit 1
fi

info "Encontrado pod: $pod_name"

# Verificar status atual
info "Verificando status atual do Vault..."
vault_status=$(kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault status" 2>/dev/null || echo "")

if [ -n "$vault_status" ]; then
  echo "$vault_status"
  echo ""
  
  # Verificar se está inicializado
  if echo "$vault_status" | grep -q "Initialized.*true"; then
    info "✅ Vault está inicializado."
    
    # Verificar se está selado
    if echo "$vault_status" | grep -q "Sealed.*true"; then
      warn "⚠️  Vault está selado. Você precisa de uma chave de unseal para deselá-lo."
      warn ""
      warn "Se você tem a chave de unseal, execute:"
      warn "  ./unseal-vault.sh <sua-chave-de-unseal>"
      warn ""
      warn "Se você perdeu a chave de unseal, será necessário:"
      warn "  1. Fazer backup dos dados importantes"
      warn "  2. Remover o Vault completamente"
      warn "  3. Reinstalar e reinicializar"
      exit 1
    else
      success "✅ Vault está funcionando normalmente (não selado)."
    fi
  else
    info "Vault não está inicializado. Tentando inicializar agora..."
    
    # Tentar inicializar
    init_output=$(kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault operator init -key-shares=1 -key-threshold=1 -format=json" 2>/dev/null)
    
    if [ -n "$init_output" ] && echo "$init_output" | grep -q "root_token"; then
      success "✅ Vault inicializado com sucesso!"
      
      # Extrair chaves
      unseal_key=$(echo "$init_output" | grep -o '"keys":\[[^]]*' | grep -o '"[^"]*"' | sed 's/"//g' | head -1 || echo "")
      root_token=$(echo "$init_output" | grep -o '"root_token":"[^"]*' | cut -d'"' -f4 || echo "")
      
      if [ -n "$unseal_key" ] && [ -n "$root_token" ]; then
        echo ""
        success "⚠️  IMPORTANTE: Guarde estas informações em local seguro!"
        echo -e "${BOLD}🔑 Unseal Key: $unseal_key${NC}"
        echo -e "${BOLD}🔒 Root Token: $root_token${NC}"
        echo ""
        
        # Tentar fazer unseal automaticamente
        info "Realizando unseal automático..."
        if kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault operator unseal $unseal_key" &>/dev/null; then
          success "✅ Vault unsealed com sucesso!"
          
          # Verificar status final
          info "Status final do Vault:"
          kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault status" || true
        else
          warn "⚠️ Falha ao fazer unseal automático. Execute manualmente:"
          warn "  ./unseal-vault.sh $unseal_key"
        fi
      else
        error "❌ Falha ao extrair as chaves de inicialização."
        exit 1
      fi
    else
      error "❌ Falha ao inicializar o Vault."
      exit 1
    fi
  fi
else
  error "❌ Não foi possível obter o status do Vault."
  exit 1
fi

# Obter informações de acesso
node_port=$(kubectl get service "$RELEASE"-ui -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30820")
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")

echo ""
success "========================================="
success "           ACESSO AO VAULT"
success "========================================="
echo -e "${BOLD}🌐 URL do UI: http://${node_ip}:${node_port}/ui/${NC}"
echo -e "${BOLD}🌐 URL da API: http://${node_ip}:${node_port}/v1/${NC}"
echo ""
info "Para verificar o status:"
info "  kubectl exec $pod_name -n $NS -- sh -c \"VAULT_ADDR=$VAULT_ADDR vault status\""
echo ""
