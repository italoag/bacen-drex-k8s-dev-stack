#!/usr/bin/env bash
# Deploy / upgrade MongoDB stand-alone com hostNetwork em localhost:27017
set -Eeuo pipefail

################################################################################################
# VARIÁVEIS GLOBAIS                                                                            #
################################################################################################
RELEASE=mongodb
NS=database
VALUES=mongodb-values.yaml
CHART=oci://registry-1.docker.io/bitnamicharts/mongodb
TIMEOUT=300s            # tempo máximo de helm install/upgrade

ROOT_PASS="${MONGODB_ROOT_PASSWORD:-}"  # deve vir do ambiente
if [[ -z "$ROOT_PASS" ]]; then
  echo "❌  Defina a variável de ambiente MONGODB_ROOT_PASSWORD."
  exit 1
fi

log(){  printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){  printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }
warn(){ printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

rollback(){
  helm uninstall "$RELEASE" -n "$NS" || true
  kubectl delete ns "$NS" --wait=false || true
}
trap 'err "Falha linha $LINENO"; rollback' ERR

retry(){ local n=1 max=$1; shift
         until "$@"; do (( n++>max )) && return 1
         warn "retry $n/$max…"; sleep 5; done; }

################################################################################################
# 1 ─ Helm repo / ns                                                                           #
################################################################################################
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

################################################################################################
# 2 ─ Install / upgrade                                                                        #
################################################################################################
log "Deploying/Upgrading MongoDB…"

if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  log "Helm release existe → upgrade"
  helm upgrade "$RELEASE" "$CHART" \
       --namespace "$NS" \
       --timeout "$TIMEOUT" \
       -f "$VALUES" \
       --set auth.rootPassword="$ROOT_PASS" \
       --set auth.usernames[0]=admin \
       --set auth.databases[0]="$RELEASE"_db \
       --set auth.passwords[0]="$ROOT_PASS" \
       --reuse-values
else
  log "Helm release não existe → install"
  helm install "$RELEASE" "$CHART" \
       --namespace "$NS" \
       --timeout "$TIMEOUT" \
       -f "$VALUES" \
       --set auth.rootPassword="$ROOT_PASS" \
       --set auth.usernames[0]=admin \
       --set auth.databases[0]="$RELEASE"_db \
       --set auth.passwords[0]="$ROOT_PASS"
fi

################################################################################################
# 3 ─ Patch hostNetwork + dnsPolicy + Recreate                                                 #
################################################################################################
log "Aplicando patch para hostNetwork e dnsPolicy…"
kubectl patch deployment "$RELEASE" -n "$NS" --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true},
  {"op": "add", "path": "/spec/template/spec/dnsPolicy", "value": "ClusterFirstWithHostNet"}
]'

log "Aplicando patch para estratégia Recreate…"
kubectl patch deployment "$RELEASE" -n "$NS" --type='json' -p='[
  {"op": "replace", "path": "/spec/strategy", "value": {"type": "Recreate"}}
]'

################################################################################################
# 4 ─ Rollout e espera de ready                                                                #
################################################################################################
log "Reiniciando rollout para aplicar patch…"
kubectl rollout restart deployment/"$RELEASE" -n "$NS"

log "Aguardando pod ficar Ready…"
retry 20 kubectl -n "$NS" rollout status deployment/"$RELEASE"
retry 20 kubectl -n "$NS" wait pod -l app.kubernetes.io/instance="$RELEASE" \
               --for=condition=ready --timeout="$TIMEOUT"

################################################################################################
# 5 ─ Teste rápido de autenticação                                                             #
################################################################################################
if command -v mongo >/dev/null 2>&1; then
  log "Testando conexão local em localhost:27017 com usuário root…"
  if mongo --quiet --host localhost --port 27017 \
           -u root -p "$ROOT_PASS" --authenticationDatabase admin \
           --eval 'db.runCommand({ping:1})' | grep -q '"ok" : 1'; then
    log "✅  Conexão com usuário root OK!"
  else
    warn "❌  Falhou ping ao MongoDB com usuário root"
  fi

  log "Testando conexão local em localhost:27017 com usuário admin…"
  if mongo --quiet --host localhost --port 27017 \
           -u admin -p "$ROOT_PASS" --authenticationDatabase "${RELEASE}_db" \
           --eval 'db.runCommand({ping:1})' | grep -q '"ok" : 1'; then
    log "✅  Conexão com usuário admin OK!"
  else
    warn "❌  Falhou ping ao MongoDB com usuário admin"
  fi
else
  log "Comando 'mongo' não encontrado. Pulando testes de conexão."
  log "Deploy completo! Verifique a conexão manualmente usando os exemplos abaixo."
fi

################################################################################################
# 6 ─ Resumo final                                                                             #
################################################################################################
cat <<EOF

🎉  MongoDB disponível em localhost:27017

Usuários:
- Usuário root : root
  Senha        : (variável MONGODB_ROOT_PASSWORD)
  Auth DB      : admin

- Usuário admin: admin
  Senha        : (variável MONGODB_ROOT_PASSWORD)
  Auth DB      : ${RELEASE}_db

Exemplos:

  # Usando root
  mongo --host localhost --port 27017 -u root -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase admin
  export MONGODB_ROOT_URI="mongodb://root:\$MONGODB_ROOT_PASSWORD@localhost:27017/admin"
  
  # Usando admin
  mongo --host localhost --port 27017 -u admin -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase ${RELEASE}_db
  export MONGODB_URI="mongodb://admin:\$MONGODB_ROOT_PASSWORD@localhost:27017/${RELEASE}_db"

EOF
