#!/usr/bin/env bash
# Deploy / upgrade Redis stand-alone em localhost:6379 (hostNetwork)
set -Eeuo pipefail

############################
# PARÂMETROS PERSONALIZÁVEIS
############################
RELEASE=redis                 # nome do Helm release
NS=database                   # namespace a usar / criar
VALUES=redis-values.yaml      # arquivo de valores
CHART=oci://registry-1.docker.io/bitnamicharts/redis
TIMEOUT=600s                  # timeout helm install/upgrade

# Senha do Redis (NÃO versionar!). Exporte antes de rodar o script:
#   export REDIS_PASSWORD='minhaSenha!'
PASS="${REDIS_PASSWORD:-}"
if [[ -z "$PASS" ]]; then
  echo "❌  Defina a variável de ambiente REDIS_PASSWORD antes de executar."
  exit 1
fi

#########
# LOG UI
#########
log()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }
err()  { printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }

rollback(){
  helm uninstall "$RELEASE" -n "$NS" || true
  kubectl delete ns "$NS" --wait=false || true
}
trap 'err "Falha na linha $LINENO"; rollback' ERR

retry(){ local n=1 max=$1; shift
         until "$@"; do (( n++>max )) && return 1
         warn "retry $n/$max…"; sleep 5; done; }

############################
# 1 ─ REPOS / NAMESPACE
############################
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

############################
# 2 ─ INSTALL / UPGRADE
############################
log "Instalando / atualizando Redis…"
if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  log "Release existe → upgrade."
  helm upgrade "$RELEASE" "$CHART" \
      --namespace "$NS" \
      --timeout "$TIMEOUT" \
      -f "$VALUES" \
      --set architecture=standalone \
      --set auth.enabled=true \
      --set auth.password="$PASS" \
      --reuse-values
else
  log "Release não existe → install."
  helm install "$RELEASE" "$CHART" \
      --namespace "$NS" \
      --timeout "$TIMEOUT" \
      -f "$VALUES" \
      --set architecture=standalone \
      --set auth.enabled=true \
      --set auth.password="$PASS"
fi

###########################################
# 3 ─ PATCH hostNetwork + dnsPolicy
###########################################
# O chart em modo stand-alone cria um StatefulSet <release>-master
STS_NAME="$(kubectl get sts -l app.kubernetes.io/instance=$RELEASE -n $NS -o jsonpath='{.items[0].metadata.name}')"

log "Aplicando patch hostNetwork/dnsPolicy no StatefulSet ${STS_NAME}…"
kubectl patch statefulset "$STS_NAME" -n "$NS" --type='merge' -p '{
  "spec": {
    "template": {
      "spec": {
        "hostNetwork": true,
        "dnsPolicy": "ClusterFirstWithHostNet"
      }
    },
    "updateStrategy": { "type": "RollingUpdate" }
  }
}'

# Reinicia o StatefulSet (força recriação do pod com hostNetwork)
log "Reiniciando rollout…"
kubectl rollout restart statefulset/"$STS_NAME" -n "$NS"

###########################################
# 4 ─ ESPERA DE READINESS
###########################################
log "Aguardando pod ficar Ready…"
retry 20 kubectl -n "$NS" rollout status statefulset/"$STS_NAME"
retry 20 kubectl -n "$NS" wait pod -l app.kubernetes.io/instance="$RELEASE" \
               --for=condition=ready --timeout="$TIMEOUT"

###########################################
# 5 ─ TESTE DE CONEXÃO
###########################################
if command -v redis-cli >/dev/null; then
  log "Testando conexão em localhost:6379 …"
  if redis-cli -h localhost -p 6379 -a "$PASS" ping | grep -q PONG; then
    log "✅  Redis responde PONG!"
  else
    warn "❌  Não foi possível autenticar no Redis."
  fi
else
  warn "redis-cli não encontrado; pulei teste de ping."
fi

###########################################
# 6 ─ RESUMO
###########################################
cat <<EOF

🎉  Redis disponível em localhost:6379

Senha          : \$REDIS_PASSWORD
Variável de env: export REDIS_URI="redis://default:\$REDIS_PASSWORD@localhost:6379"

Exemplo de teste:
  redis-cli -h localhost -p 6379 -a \$REDIS_PASSWORD ping

EOF
