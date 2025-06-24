#!/usr/bin/env bash
# Script para verificar o status atual do HashiCorp Vault
set -Eeuo pipefail

NS=${VAULT_NAMESPACE:-vault}
RELEASE=${VAULT_RELEASE:-vault}
VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}

log(){ printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){ printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }

# Verifica se o pod do Vault está rodando
POD_NAME=$(kubectl get pods -l app.kubernetes.io/name=vault -n "$NS" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")

if [[ -z "$POD_NAME" ]]; then
  err "❌ Não foi possível encontrar o pod do Vault. Verifique se o deployment está ativo."
  exit 1
fi

# Verifica o status do Vault
log "Verificando status do Vault no pod $POD_NAME..."
if ! kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault status"; then
  log "⚠️  Não foi possível obter o status do Vault via CLI."
  
  # Tentar obter o status em formato JSON (pode ser mais tolerante a erros)
  log "Tentando obter status em formato JSON..."
  if ! kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault status -format=json" 2>/dev/null; then
    log "⚠️ O Vault não está respondendo. Verificando o pod..."
  fi
  
  log "📊 Detalhes do pod:"
  kubectl describe pod "$POD_NAME" -n "$NS" | grep -A10 "Conditions:" || true
  
  log "🔍 Logs do container:"
  kubectl logs "$POD_NAME" -n "$NS" --tail=20 || true
  
  log "🔄 Estado das readiness/liveness probes:"
  kubectl get pod "$POD_NAME" -n "$NS" -o jsonpath='{.status.conditions}' | jq . 2>/dev/null || echo "Não foi possível obter detalhes das probes"
  
  # Não sai com erro, apenas mostra diagnóstico
fi

# Verificar se o pod está em estado Running
POD_STATUS=$(kubectl get pod "$POD_NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [[ "$POD_STATUS" != "Running" ]]; then
  log "⚠️ O pod não está em estado Running. Estado atual: $POD_STATUS"
fi

# Mostra informações de acesso
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")
NODE_PORT=$(kubectl get service "$RELEASE"-ui -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30820")

# Verifica se serviços estão expostos
log "📡 Verificando serviços do Vault..."
kubectl get svc -l app.kubernetes.io/instance="$RELEASE" -n "$NS" || true

# Verifica conectividade externa
log "🔌 Testando conectividade externa..."
if command -v curl &>/dev/null; then
  HTTP_CODE=$(curl -s --connect-timeout 3 -o /dev/null -w "%{http_code}" "http://${NODE_IP}:${NODE_PORT}/ui/" 2>/dev/null || echo "falhou")
  if [[ "$HTTP_CODE" =~ ^(200|307|302|401|403)$ ]]; then
    log "✅ UI do Vault acessível em http://${NODE_IP}:${NODE_PORT}/ui/ (status: $HTTP_CODE)"
  else
    log "⚠️  UI do Vault não parece estar acessível: http://${NODE_IP}:${NODE_PORT}/ui/ (status: $HTTP_CODE)"
  fi
fi

# Verifica recursos do Vault
log "🔍 Recursos alocados pelo Vault:"
kubectl get statefulset,deployment,pods,svc,pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NS" || true

log ""
log "🌐 URL do Vault UI: http://${NODE_IP}:${NODE_PORT}/ui/"
log "🌐 URL da API: http://${NODE_IP}:${NODE_PORT}/v1/"
log ""
log "✨ Para fazer login, você precisará do token root que foi gerado durante a inicialização."
log "💡 Se o Vault estiver selado, use o comando: ./unseal-vault.sh <sua-chave-de-unseal>"
log "🛠️  Para mais diagnósticos, você pode executar: kubectl exec -it $POD_NAME -n $NS -- sh"
