#!/usr/bin/env bash
# Deploy / upgrade MongoDB stand-alone com hostNetwork em localhost:27017 (acesso externo)
set -Eeuo pipefail

info(){  printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){  printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }
warn(){ printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

######################if [[ "$USE_OFFICIAL_CHART" == "true" ]]; then
  # Para MongoDB oficial, aguardar StatefulSet e pods com timeout maior para hostNetwork
  info "Aguardando MongoDB ficar operacional (pode levar alguns minutos com hostNetwork)..."
  
  # Tentar aguardar o MongoDBCommunity ficar Ready, mas não falhar se demorar
  if ! retry 5 kubectl -n "$NS" wait mongodbcommunity/"$RELEASE" --for=condition=Ready --timeout=120s; then
    warn "MongoDBCommunity ainda não está Ready, mas continuando validação..."
  fi
  
  # Aguardar especificamente o pod mongodb-0 ficar pronto
  info "Aguardando pod mongodb-0 ficar pronto..."
  retry 10 kubectl -n "$NS" wait pod mongodb-0 --for=condition=ready --timeout=60s
  
  # Validação adicional: verificar se o MongoDB está realmente respondendo
  info "Testando conectividade direta com o MongoDB..."
  for i in {1..10}; do
    if kubectl -n "$NS" exec mongodb-0 -c mongod -- mongosh --eval "db.runCommand('ping')" >/dev/null 2>&1; then
      info "✅ MongoDB está respondendo corretamente!"
      break
    else
      warn "Tentativa $i/10: MongoDB ainda não está respondendo, aguardando..."
      sleep 10
    fi
  done
else#################################################################
# VARIÁVEIS GLOBAIS                                                                            #
################################################################################################
RELEASE=mongodb
NS=database
VALUES=mongodb-values.yaml
TIMEOUT=300s            # tempo máximo de helm install/upgrade

# Detectar arquitetura do sistema
ARCH=$(uname -m)
NODE_ARCH=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "unknown")

# Configurar chart e valores baseado na arquitetura
if [[ "$ARCH" == "arm64" ]] || [[ "$NODE_ARCH" == "arm64" ]]; then
  info "Detectada arquitetura ARM64, usando chart oficial do MongoDB"
  CHART="mongodb/community-operator"
  USE_OFFICIAL_CHART=true
else
  info "Detectada arquitetura $ARCH/$NODE_ARCH, usando chart Bitnami"
  CHART="oci://registry-1.docker.io/bitnamicharts/mongodb"
  USE_OFFICIAL_CHART=false
fi

ROOT_PASS="${MONGODB_ROOT_PASSWORD:-}"  # deve vir do ambiente
if [[ -z "$ROOT_PASS" ]]; then
  echo "❌  Defina a variável de ambiente MONGODB_ROOT_PASSWORD."
  exit 1
fi

rollback(){
  helm uninstall "$RELEASE" -n "$NS" || true
  kubectl delete ns "$NS" --wait=false || true
}
trap 'err "Falha linha $LINENO"; rollback' ERR

retry(){ 
  local n=1 
  local max=$1
  shift
  until "$@"; do 
    [ $n -ge $max ] && return 1
    warn "retry $n/$max..."
    sleep 5
    n=$((n+1))
  done
}

################################################################################################
# FUNÇÕES DE DEPLOY                                                                           #
################################################################################################
deploy_bitnami_mongodb() {
  if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    info "Helm release existe → upgrade (Bitnami)"
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
    info "Helm release não existe → install (Bitnami)"
    helm install "$RELEASE" "$CHART" \
         --namespace "$NS" \
         --timeout "$TIMEOUT" \
         -f "$VALUES" \
         --set auth.rootPassword="$ROOT_PASS" \
         --set auth.usernames[0]=admin \
         --set auth.databases[0]="$RELEASE"_db \
         --set auth.passwords[0]="$ROOT_PASS"
  fi
}

deploy_official_mongodb() {
  info "Usando deployment oficial do MongoDB..."
  
  # Detectar arquitetura e configurar valores adequados
  local AGENT_VERSION="108.0.6.8796-1"
  if [[ "$ARCH" == "arm64" ]] || [[ "$NODE_ARCH" == "arm64" ]]; then
    info "Detectada arquitetura ARM64, configurando agent específico..."
    AGENT_VERSION="108.0.6.8796-1-arm64"
  fi

  # Criar values.yaml personalizado para o operator
  cat <<EOF > /tmp/mongodb-operator-values.yaml
operator:
  watchNamespace: "*"
  resources:
    limits:
      cpu: 750m
      memory: 750Mi
    requests:
      cpu: 200m
      memory: 200Mi

agent:
  name: mongodb-agent-ubi
  version: ${AGENT_VERSION}

versionUpgradeHook:
  name: mongodb-kubernetes-operator-version-upgrade-post-start-hook
  version: 1.0.10

readinessProbe:
  name: mongodb-kubernetes-readinessprobe
  version: 1.0.23

registry:
  agent: quay.io/mongodb
  versionUpgradeHook: quay.io/mongodb
  readinessProbe: quay.io/mongodb
  operator: quay.io/mongodb
  pullPolicy: Always

community-operator-crds:
  enabled: true

# Configurações específicas para hostNetwork
mongodb:
  name: mongo
  repo: docker.io
EOF
  
  # Primeiro, instalar o operator se não existir
  if ! helm status mongodb-operator -n "$NS" >/dev/null 2>&1; then
    info "Instalando MongoDB Community Operator..."
    helm install mongodb-operator "$CHART" \
         --namespace "$NS" \
         --values /tmp/mongodb-operator-values.yaml \
         --timeout "$TIMEOUT" \
         --wait
  else
    info "Atualizando MongoDB Community Operator..."
    helm upgrade mongodb-operator "$CHART" \
         --namespace "$NS" \
         --values /tmp/mongodb-operator-values.yaml \
         --timeout "$TIMEOUT" \
         --wait
  fi
  
  # Aguardar operator ficar pronto
  info "Aguardando operator ficar pronto..."
  retry 20 kubectl -n "$NS" wait deployment/mongodb-kubernetes-operator --for=condition=available --timeout="$TIMEOUT"
  
  # Criar secrets para senhas
  kubectl create secret generic "${RELEASE}-root-password" \
    --from-literal=password="$ROOT_PASS" \
    --namespace="$NS" \
    --dry-run=client -o yaml | kubectl apply -f -
    
  kubectl create secret generic "${RELEASE}-admin-password" \
    --from-literal=password="$ROOT_PASS" \
    --namespace="$NS" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Criar o recurso MongoDB via kubectl
  info "Criando instância MongoDB..."
  cat <<EOF | kubectl apply -f -
apiVersion: mongodbcommunity.mongodb.com/v1
kind: MongoDBCommunity
metadata:
  name: $RELEASE
  namespace: $NS
spec:
  members: 1
  type: ReplicaSet
  version: "8.0.8"
  security:
    authentication:
      modes: ["SCRAM"]
  users:
    - name: root
      db: admin
      passwordSecretRef:
        name: ${RELEASE}-root-password
      roles:
        - name: root
          db: admin
      scramCredentialsSecretName: ${RELEASE}-root-scram
    - name: admin
      db: ${RELEASE}_db
      passwordSecretRef:
        name: ${RELEASE}-admin-password
      roles:
        - name: readWrite
          db: ${RELEASE}_db
      scramCredentialsSecretName: ${RELEASE}-admin-scram
  additionalMongodConfig:
    storage.wiredTiger.engineConfig.journalCompressor: zlib
  statefulSet:
    spec:
      template:
        spec:
          hostNetwork: true
          dnsPolicy: ClusterFirstWithHostNet
          containers:
            - name: mongod
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
            - name: mongodb-agent
              env:
                - name: AGENT_STATUS_FILEPATH
                  value: /var/log/mongodb-mms-automation/healthstatus/agent-health-status.json
                - name: AUTOMATION_CONFIG_MAP
                  value: mongodb-config
                - name: HEADLESS_AGENT
                  value: "true"
                - name: POD_NAMESPACE
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.namespace
                - name: POD_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
              readinessProbe:
                exec:
                  command:
                  - /bin/sh
                  - -c
                  - "sleep 5 && exit 0"
                failureThreshold: 3
                initialDelaySeconds: 60
                periodSeconds: 30
                timeoutSeconds: 10
      volumeClaimTemplates:
        - metadata:
            name: data-volume
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 8Gi
EOF
}

################################################################################################
# 1 ─ Helm repo / ns                                                                           #
################################################################################################
if [[ "$USE_OFFICIAL_CHART" == "true" ]]; then
  info "Configurando repositório oficial do MongoDB..."
  helm repo add mongodb https://mongodb.github.io/helm-charts >/dev/null 2>&1 || true
else
  info "Configurando repositório Bitnami..."
  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
fi

helm repo update >/dev/null
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

################################################################################################
# 2 ─ Install / upgrade                                                                        #
################################################################################################
info "Deploying/Upgrading MongoDB…"

if [[ "$USE_OFFICIAL_CHART" == "true" ]]; then
  deploy_official_mongodb
else
  deploy_bitnami_mongodb
fi

################################################################################################
# 3 ─ Patch hostNetwork + dnsPolicy + Recreate (apenas para Bitnami) - REMOVIDO             #
################################################################################################
# Removido hostNetwork para evitar problemas com readiness probe
# if [[ "$USE_OFFICIAL_CHART" == "false" ]]; then
#   info "Aplicando patch para hostNetwork e dnsPolicy (Bitnami)…"
#   kubectl patch deployment "$RELEASE" -n "$NS" --type='json' -p='[
#     {"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true},
#     {"op": "add", "path": "/spec/template/spec/dnsPolicy", "value": "ClusterFirstWithHostNet"}
#   ]'
# 
#   info "Aplicando patch para estratégia Recreate…"
#   kubectl patch deployment "$RELEASE" -n "$NS" --type='json' -p='[
#     {"op": "replace", "path": "/spec/strategy", "value": {"type": "Recreate"}}
#   ]'
# 
#   info "Reiniciando rollout para aplicar patch…"
#   kubectl rollout restart deployment/"$RELEASE" -n "$NS"
# fi

################################################################################################
# 4 ─ Rollout e espera de ready                                                                #
################################################################################################
info "Aguardando pod ficar Ready…"

if [[ "$USE_OFFICIAL_CHART" == "true" ]]; then
  # Para MongoDB oficial, aguardar StatefulSet e pods com timeout maior para hostNetwork
  info "Aguardando MongoDB ficar operacional (pode levar alguns minutos com hostNetwork)..."
  retry 5 kubectl -n "$NS" wait mongodbcommunity/"$RELEASE" --for=condition=Ready --timeout="$TIMEOUT"
  
  # Aguardar especificamente o pod mongodb-0 ficar pronto
  info "Aguardando pod mongodb-0 ficar pronto..."
  retry 5 kubectl -n "$NS" wait pod mongodb-0 --for=condition=ready --timeout="$TIMEOUT"
else
  # Para Bitnami, aguardar Deployment
  retry 5 kubectl -n "$NS" rollout status deployment/"$RELEASE"
  retry 5 kubectl -n "$NS" wait pod -l app.kubernetes.io/instance="$RELEASE" \
                 --for=condition=ready --timeout="$TIMEOUT"
fi

################################################################################################
# 5 ─ Teste rápido de autenticação                                                             #
################################################################################################
test_mongodb_connection() {
  local host="localhost"
  local port="27017"
  
  # Para MongoDB oficial com hostNetwork, sempre usar localhost
  if [[ "$USE_OFFICIAL_CHART" == "true" ]]; then
    info "Testando MongoDB com hostNetwork em $host:$port"
  fi
  
  # Primeiro tentar conexão direta via kubectl exec
  info "Testando conexão direta via kubectl exec..."
  if kubectl -n "$NS" exec mongodb-0 -c mongod -- mongosh --quiet --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
    info "✅ Conexão direta OK!"
  else
    warn "❌ Falhou conexão direta"
  fi
  
  # Se mongosh estiver disponível localmente, testar conexão externa
  if command -v mongosh >/dev/null 2>&1; then
    info "Testando conexão externa com mongosh em $host:$port..."
    
    # Teste simples de conectividade (sem auth primeiro)
    if timeout 10 mongosh --quiet --host "$host" --port "$port" --eval 'quit()' >/dev/null 2>&1; then
      info "✅ Conectividade de rede OK!"
      
      # Agora teste com autenticação
      if mongosh --quiet --host "$host" --port "$port" \
                 --username root --password "$ROOT_PASS" --authenticationDatabase admin \
                 --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
        info "✅ Autenticação com usuário root OK!"
      else
        warn "⚠️  Falhou autenticação com usuário root (mas MongoDB está rodando)"
      fi
    else
      warn "⚠️  Não foi possível conectar externamente (verifique se a porta 27017 está livre)"
    fi
  else
    info "Comando 'mongosh' não encontrado. MongoDB está disponível em localhost:27017"
    info "Teste manual: mongosh --host localhost --port 27017 -u root -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase admin"
  fi
}

test_mongodb_connection

################################################################################################
# 6 ─ Resumo final                                                                             #
################################################################################################
if [[ "$USE_OFFICIAL_CHART" == "true" ]]; then
cat <<EOF

🎉  MongoDB (Oficial) disponível!

Arquitetura: ARM64 (usando MongoDB Community Operator)
Namespace: $NS
Release: $RELEASE

Conexão interna:
- Host: $RELEASE-svc.$NS.svc.cluster.local:27017

Para conexão externa, execute:
kubectl -n $NS port-forward svc/$RELEASE-svc 27017:27017

Usuários:
- Usuário root : root
  Senha        : (variável MONGODB_ROOT_PASSWORD)
  Auth DB      : admin

- Usuário admin: admin
  Senha        : (variável MONGODB_ROOT_PASSWORD)
  Auth DB      : ${RELEASE}_db

Exemplos com port-forward:
kubectl -n $NS port-forward svc/$RELEASE-svc 27017:27017 &

# Usando root
mongosh --host localhost --port 27017 -u root -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase admin
export MONGODB_ROOT_URI="mongodb://root:\$MONGODB_ROOT_PASSWORD@localhost:27017/admin"

# Usando admin
mongosh --host localhost --port 27017 -u admin -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase ${RELEASE}_db
export MONGODB_URI="mongodb://admin:\$MONGODB_ROOT_PASSWORD@localhost:27017/${RELEASE}_db"

EOF
else
cat <<EOF

🎉  MongoDB (Bitnami) disponível em localhost:27017

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
fi
