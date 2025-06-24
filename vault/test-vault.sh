#!/usr/bin/env bash
# Teste de conectividade com o Vault
set -Eeuo pipefail

# Variáveis
NS=vault
RELEASE=vault

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

# Verificar se o vault está instalado
if ! kubectl get pod -l app.kubernetes.io/name=vault -n "$NS" &>/dev/null; then
  error "O Vault não parece estar instalado. Execute deploy-vault.sh primeiro."
  exit 1
fi

# Obter o pod do Vault
pod_name=$(kubectl get pod -l app.kubernetes.io/name=vault -n "$NS" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
if [ -z "$pod_name" ]; then
  error "Não foi possível encontrar o pod do Vault."
  exit 1
fi

info "Encontrado pod: $pod_name"
kubectl get pod "$pod_name" -n "$NS"

# Verificar o status atual do Vault
info "Verificando status do Vault..."
if ! status=$(kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status" 2>/dev/null); then
  warn "Não foi possível obter status do Vault. Pode estar selado ou não inicializado."
  
  # Tentar obter mais informações
  info "Tentando obter mais informações do Vault..."
  kubectl exec "$pod_name" -n "$NS" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json" 2>/dev/null || echo "Falha"
fi

# Verificar serviços
info "Verificando serviços do Vault..."
kubectl get svc -l app.kubernetes.io/instance="$RELEASE" -n "$NS"

# Obter porta do UI
node_port=$(kubectl get service "$RELEASE"-ui -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")

info "Verificando conectividade com UI do Vault..."
if command -v curl &>/dev/null && [ "$node_port" != "N/A" ]; then
  http_code=$(curl -s --connect-timeout 3 -o /dev/null -w "%{http_code}" "http://${node_ip}:${node_port}/ui/" 2>/dev/null || echo "failed")
  if [[ "$http_code" =~ ^(200|307|302|401|403)$ ]]; then
    success "UI do Vault acessível em http://${node_ip}:${node_port}/ui/ (status: $http_code)"
  else
    warn "UI do Vault não parece estar acessível: http://${node_ip}:${node_port}/ui/ (status: $http_code)"
  fi
else
  info "URL do UI do Vault: http://${node_ip}:${node_port}/ui/ (não testado)"
fi

# Mostrar informações do pod
info "Informações do pod:"
kubectl describe pod "$pod_name" -n "$NS" | grep -A5 "State:" || true

# Mostrar últimas linhas de log
info "Últimas linhas de log:"
kubectl logs "$pod_name" -n "$NS" --tail=10

# Informações finais
echo ""
success "Teste concluído!"
echo -e "${YELLOW}=============================ATENÇÃO=============================${NC}"
echo -e "Se o Vault está selado, você pode deselá-lo com:"
echo -e "${BOLD}  ./unseal-vault.sh <sua-chave-de-unseal>${NC}"
echo -e ""
echo -e "Para conectar ao Vault usando CLI dentro do pod:"
echo -e "${BOLD}  kubectl exec -it $pod_name -n $NS -- sh${NC}"
echo -e "${BOLD}  export VAULT_ADDR=http://127.0.0.1:8200${NC}"
echo -e "${BOLD}  vault status${NC}"
echo -e ""
