#!/usr/bin/env bash
# Deploy / upgrade PostgreSQL stand-alone em localhost:5432 (hostNetwork)
set -Eeuo pipefail

############################
# PARÂMETROS PERSONALIZÁVEIS
############################
RELEASE=postgres                # nome do Helm release
NS=database                     # namespace a usar / criar
VALUES=postgresql-values.yaml   # arquivo de valores
CHART=oci://registry-1.docker.io/bitnamicharts/postgresql
TIMEOUT=600s                    # timeout helm install/upgrade

# Senha do super-user Postgres.  NÃO versionar!
# Exporte antes de rodar:   export POSTGRES_PASSWORD='SenhaForte'
PASS="${POSTGRES_PASSWORD:-}"
if [[ -z "$PASS" ]]; then
  echo "❌ Defina a variável de ambiente POSTGRES_PASSWORD antes de executar."
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
# 1 ─ REPO / NAMESPACE
############################
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

############################
# 2 ─ INSTALL / UPGRADE
############################
log "Instalando / atualizando PostgreSQL…"
if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  log "Release existe → upgrade."
  helm upgrade "$RELEASE" "$CHART" \
      --namespace "$NS" \
      --timeout "$TIMEOUT" \
      -f "$VALUES" \
      --set auth.postgresPassword="$PASS" \
      --reuse-values
else
  log "Release não existe → install."
  helm install "$RELEASE" "$CHART" \
      --namespace "$NS" \
      --timeout "$TIMEOUT" \
      -f "$VALUES" \
      --set auth.postgresPassword="$PASS"
fi

###########################################
# 3 ─ PATCH hostNetwork + dnsPolicy
###########################################
# StatefulSet gerado → <release>-postgresql
STS_NAME="$(kubectl get sts -l app.kubernetes.io/instance=$RELEASE -n $NS -o jsonpath='{.items[0].metadata.name}')"

log "Aplicando patch hostNetwork/dnsPolicy e updateStrategy no StatefulSet ${STS_NAME}…"
# Aplicar patches usando kubectl patch com type=merge é mais simples e confiável
kubectl patch statefulset "$STS_NAME" -n "$NS" --type='merge' -p '{
  "spec": {
    "template": {
      "spec": {
        "hostNetwork": true,
        "dnsPolicy": "ClusterFirstWithHostNet"
      }
    }
  }
}'

# The updateStrategy needs to be set in a separate step
kubectl patch statefulset "$STS_NAME" -n "$NS" --type='json' -p '[
  {"op": "replace", "path": "/spec/updateStrategy", "value": {"type": "OnDelete"}}
]'

# Para garantir que os pods sejam recriados com hostNetwork habilitado
log "Deletando pod para forçar recriação com hostNetwork habilitado..."
kubectl delete pod -n "$NS" -l app.kubernetes.io/instance="$RELEASE" --wait=true

log "Reiniciando rollout…"
kubectl rollout restart statefulset/"$STS_NAME" -n "$NS"

###########################################
# 4 ─ ESPERA DE READINESS
###########################################
log "Aguardando pod ficar Ready…"
# Não usa rollout status para OnDelete strategy
log "Aguardando até o pod estar pronto..."
retry 20 kubectl -n "$NS" wait pod -l app.kubernetes.io/instance="$RELEASE" \
               --for=condition=ready --timeout="$TIMEOUT"

###########################################
# 5 ─ TESTE DE CONEXÃO
###########################################
if command -v psql >/dev/null; then
  log "Testando conexão em localhost:5432 …"
  if PGPASSWORD="$PASS" psql -h localhost -p 5432 -U postgres -d postgres -c '\q' >/dev/null 2>&1; then
    log "✅ PostgreSQL aceita conexão!"
  else
    warn "❌ Falha ao conectar no PostgreSQL."
  fi
else
  warn "psql não encontrado; pulei teste de conexão."
fi

###########################################
# 6 ─ RESUMO
###########################################
cat <<EOF

🎉  PostgreSQL disponível em localhost:5432

Usuário super-user : postgres
Senha               : \$POSTGRES_PASSWORD

String de conexão:
  export JDBC_URL="jdbc:postgresql://localhost:5432/postgres"
  export PGPASSWORD="\$POSTGRES_PASSWORD"
  psql -h localhost -U postgres -d postgres

EOF
