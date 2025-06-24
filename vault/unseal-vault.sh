#!/usr/bin/env bash
# Script para realizar unseal do HashiCorp Vault
set -Eeuo pipefail

NS=${VAULT_NAMESPACE:-vault}
RELEASE=${VAULT_RELEASE:-vault}
VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}

log(){ printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){ printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }

# Verifica se chave de unseal foi fornecida
if [[ $# -lt 1 ]]; then
  err "❌ Uso: $0 <unseal-key>"
  log "Exemplo: $0 abcDefGhiJklMnoPqRsTuVwXyZ0123456789ABCDEFG="
  exit 1
fi

UNSEAL_KEY="$1"

# Verifica se o pod do Vault está rodando
POD_NAME=$(kubectl get pods -l app.kubernetes.io/name=vault -n "$NS" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")

if [[ -z "$POD_NAME" ]]; then
  err "❌ Não foi possível encontrar o pod do Vault. Verifique se o deployment está ativo."
  exit 1
fi

# Verifica o status atual
log "Verificando status atual do Vault..."
VAULT_STATUS=$(kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault status -format=json 2>/dev/null" || echo '{"sealed": true}')

if ! echo "$VAULT_STATUS" | grep -q '"sealed": true'; then
  log "✅ O Vault já está unsealed. Não é necessário fazer unseal."
  exit 0
fi

# Realiza o unseal
log "Realizando unseal do Vault usando a chave fornecida..."
# Tentar até 3 vezes
for i in {1..3}; do
  log "Tentativa $i de realizar unseal..."
  if kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault operator unseal $UNSEAL_KEY"; then
  log "✅ Vault unsealed com sucesso!"
  
    # Verifica novamente para confirmar
    VAULT_STATUS=$(kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault status -format=json 2>/dev/null" || echo '{"sealed": true}')
    if echo "$VAULT_STATUS" | grep -q '"sealed": false'; then
      log "✅ Confirmado: Vault está em estado unsealed."
      
      # Mostra o status completo
      log "Status atual do Vault:"
      kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault status"
      
      # Verifica se o UI está acessível
      NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")
      NODE_PORT=$(kubectl get service "$RELEASE"-ui -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30800")
      log "🌐 O UI do Vault deve estar acessível em: http://${NODE_IP}:${NODE_PORT}/ui/"
      exit 0
    else
      if [ $i -lt 3 ]; then
        log "Unseal aplicado, mas o Vault ainda está selado. Tentando novamente em 3 segundos..."
        sleep 3
      else
        err "⚠️  O unseal parece não ter funcionado completamente mesmo após várias tentativas."
        log "Status atual do Vault:"
        kubectl exec "$POD_NAME" -n "$NS" -- sh -c "VAULT_ADDR=$VAULT_ADDR vault status" || true
        exit 1
      fi
    fi
  else
    if [ $i -lt 3 ]; then
      err "❌ Falha ao aplicar unseal na tentativa $i. Tentando novamente em 3 segundos..."
      sleep 3
    else
      err "❌ Falha ao fazer unseal do Vault após 3 tentativas. Verificando problemas..."
      log "Status do pod:"
      kubectl describe pod "$POD_NAME" -n "$NS" | grep -A10 "State:" || true
      log "Logs recentes:"
      kubectl logs "$POD_NAME" -n "$NS" --tail=20 || true
      exit 1
    fi
  fi
done

# Se chegarmos aqui, significa que todas as tentativas falharam
err "❌ Falha ao fazer unseal após todas as tentativas."
exit 1
