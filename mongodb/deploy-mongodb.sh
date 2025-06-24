#!/usr/bin/env bash
# Deploy / upgrade MongoDB stand-alone com acesso externo via NodePort (porta 30017)
set -Eeuo pipefail

info(){  printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){  printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }
warn(){ printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

################################################################################################
# VARIÁVEIS GLOBAIS                                                                            #
################################################################################################
RELEASE=mongodb
NS=database
VALUES=mongodb-values.yaml
TIMEOUT=180s           # tempo máximo de helm install/upgrade e kubernetes waits

# Detectar arquitetura do sistema
ARCH=$(uname -m)
NODE_ARCH=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "unknown")

################################################################################################
# FUNÇÕES UTILITÁRIAS                                                                         #
################################################################################################
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

rollback(){
  # Verificar se o namespace existe antes de tentar excluir
  if kubectl get ns "$NS" &>/dev/null; then
    # Verificar se o MongoDB Community existe
    if kubectl get mongodbcommunity "$RELEASE" -n "$NS" &>/dev/null; then
      kubectl delete mongodbcommunity "$RELEASE" -n "$NS" --wait=false || true
    fi
    
    # Verificar se o helm release existe
    if helm status mongodb-operator -n "$NS" &>/dev/null; then
      helm uninstall mongodb-operator -n "$NS" || true
    fi
    
    kubectl delete ns "$NS" --wait=false || true
  fi
}
trap 'err "Falha linha $LINENO"; rollback' ERR

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
  # Primeiro, obter a versão padrão do agent do chart
  local DEFAULT_AGENT_VERSION
  DEFAULT_AGENT_VERSION=$(helm show values "$CHART" | grep -A 2 "^agent:" | grep "version:" | sed 's/.*version: *//' | tr -d '"' | head -1)
  
  # Se não conseguiu obter do chart, usar versão padrão
  if [[ -z "$DEFAULT_AGENT_VERSION" ]]; then
    DEFAULT_AGENT_VERSION="108.0.6.8796-1"
    warn "Não foi possível obter versão do agent do chart, usando padrão: $DEFAULT_AGENT_VERSION"
  else
    info "Versão do agent obtida do chart: $DEFAULT_AGENT_VERSION"
  fi
  
  local AGENT_VERSION="$DEFAULT_AGENT_VERSION"
  if [[ "$ARCH" == "arm64" ]] || [[ "$NODE_ARCH" == "arm64" ]]; then
    info "Detectada arquitetura ARM64, adicionando sufixo -arm64..."
    # Verificar se já tem o sufixo -arm64
    if [[ "$AGENT_VERSION" != *"-arm64" ]]; then
      AGENT_VERSION="${AGENT_VERSION}-arm64"
    fi
  fi
  
  info "Versão final do agent: $AGENT_VERSION"

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

registry:
  agent: quay.io/mongodb
  pullPolicy: Always

community-operator-crds:
  enabled: true

# Configurações do MongoDB
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
    - name: admin
      db: admin
      passwordSecretRef:
        name: ${RELEASE}-admin-password
      roles:
        - name: clusterAdmin
          db: admin
        - name: userAdminAnyDatabase
          db: admin
        - name: readWriteAnyDatabase
          db: admin
        - name: dbAdminAnyDatabase
          db: admin
      scramCredentialsSecretName: ${RELEASE}-admin-scram
  additionalMongodConfig:
    storage.wiredTiger.engineConfig.journalCompressor: zlib
  statefulSet:
    spec:
      template:
        spec:
          containers:
            - name: mongod
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
              readinessProbe:
                exec:
                  command:
                    - mongosh
                    - --eval
                    - "db.runCommand('ping')"
                failureThreshold: 40
                initialDelaySeconds: 30
                periodSeconds: 10
                successThreshold: 1
                timeoutSeconds: 5
              livenessProbe:
                exec:
                  command:
                    - mongosh
                    - --eval
                    - "db.runCommand('ping')"
                failureThreshold: 3
                initialDelaySeconds: 60
                periodSeconds: 30
                successThreshold: 1
                timeoutSeconds: 10
            - name: mongodb-agent
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
                limits:
                  cpu: 200m
                  memory: 256Mi
              readinessProbe:
                exec:
                  command:
                    - /opt/scripts/readinessprobe
                failureThreshold: 40
                initialDelaySeconds: 5
                periodSeconds: 10
                successThreshold: 1
                timeoutSeconds: 5
      volumeClaimTemplates:
        - metadata:
            name: data-volume
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 8Gi
EOF

  # Criar serviço NodePort para acesso externo
  info "Criando serviço NodePort para acesso externo..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mongodb-external
  namespace: $NS
  labels:
    app: mongodb-external
spec:
  type: NodePort
  ports:
  - port: 27017
    targetPort: 27017
    nodePort: 30017
    protocol: TCP
    name: mongodb
  selector:
    app: mongodb-svc
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
# 3 ─ Patch hostNetwork + dnsPolicy + Recreate (apenas para Bitnami/AMD64)                  #
################################################################################################
# hostNetwork removido para MongoDB Community Operator (ARM64) para evitar problemas com readiness probe
if [[ "$USE_OFFICIAL_CHART" == "false" ]]; then
  info "Aplicando patch para hostNetwork e dnsPolicy (Bitnami)…"
  kubectl patch deployment "$RELEASE" -n "$NS" --type='json' -p='[
    {"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true},
    {"op": "add", "path": "/spec/template/spec/dnsPolicy", "value": "ClusterFirstWithHostNet"}
  ]'
  info "Aplicando patch para estratégia Recreate…"
  kubectl patch deployment "$RELEASE" -n "$NS" --type='json' -p='[
    {"op": "replace", "path": "/spec/strategy", "value": {"type": "Recreate"}}
  ]'

  info "Reiniciando rollout para aplicar patch…"
  kubectl rollout restart deployment/"$RELEASE" -n "$NS"
fi

################################################################################################
# 4 ─ Rollout e espera de ready                                                                #
################################################################################################
info "Aguardando pod ficar Ready…"

if [[ "$USE_OFFICIAL_CHART" == "true" ]]; then
  # Para MongoDB oficial, aguardar o pod ficar pronto
  info "Aguardando MongoDB ficar operacional (pode levar alguns minutos)..."
  
  # Esperar o pod ser criado primeiro (pode demorar um pouco)
  sleep 10
  
  # Verificar se o pod existe antes de tentar wait
  info "Verificando se o pod ${RELEASE}-0 foi criado..."
  for i in {1..10}; do
    if kubectl get pod ${RELEASE}-0 -n "$NS" &>/dev/null; then
      info "Pod ${RELEASE}-0 criado, aguardando ficar ready..."
      break
    fi
    
    if [ "$i" -eq 10 ]; then
      warn "Pod ${RELEASE}-0 não foi criado após 50 segundos. Continuando mesmo assim..."
    else
      info "Aguardando pod ser criado (tentativa $i/10)..."
      sleep 5
    fi
  done
  
  # Aguardar pod ficar ready com timeout maior
  info "Aguardando pod ${RELEASE}-0 ficar pronto..."
  if kubectl get pod ${RELEASE}-0 -n "$NS" &>/dev/null; then
    kubectl -n "$NS" wait pod ${RELEASE}-0 --for=condition=ready --timeout=180s || true
  fi
  
  # Verificar o campo "phase" do MongoDBCommunity
  info "Verificando status do MongoDB Community..."
  ATTEMPTS=0
  MAX_ATTEMPTS=12
  INTERVAL=10
  while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    PHASE=$(kubectl get mongodbcommunity ${RELEASE} -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [[ "$PHASE" == "Running" ]]; then
      info "✅ MongoDB Community está em estado Running!"
      break
    else
      ATTEMPTS=$((ATTEMPTS+1))
      if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
        warn "MongoDB Community ainda não está em estado Running (status: ${PHASE:-Pending})"
        warn "Continuando mesmo assim, mas pode haver problemas de conexão..."
      else
        info "MongoDB Community status: ${PHASE:-Pending} (tentativa $ATTEMPTS/$MAX_ATTEMPTS, verificando novamente em ${INTERVAL}s)..."
        sleep $INTERVAL
      fi
    fi
  done
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
  
  # Para MongoDB Bitnami com hostNetwork, usar localhost
  if [[ "$USE_OFFICIAL_CHART" == "false" ]]; then
    info "Testando MongoDB com hostNetwork em $host:$port"
  else
    info "Testando MongoDB via NodePort ou port-forward"
  fi
  
  # Primeiro tentar conexão direta via kubectl exec
  info "Testando conexão direta via kubectl exec..."
  if kubectl -n "$NS" exec ${RELEASE}-0 -c mongod -- mongosh --quiet --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
    info "✅ Conexão direta OK!"
  else
    warn "❌ Falhou conexão direta"
  fi
  
  # Se mongosh estiver disponível localmente, testar conexão externa
  if command -v mongosh >/dev/null 2>&1; then
    info "Testando conectividade externa com mongosh..."
    
    # Verificar se a porta está disponível localmente
    if lsof -i :$port >/dev/null 2>&1; then
      info "Porta $port está em uso (pode ser MongoDB ou port-forward)"
      
      # Tentar conectar (pode ser MongoDB direto ou via port-forward)
      if timeout 10 mongosh --quiet --host "$host" --port "$port" --eval 'quit()' >/dev/null 2>&1; then
        info "✅ Conectividade de rede OK!"
        
        # Tentar autenticação
        if mongosh --quiet --host "$host" --port "$port" \
                   --username admin --password "$ROOT_PASS" --authenticationDatabase admin \
                   --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
          info "✅ Autenticação com usuário admin OK!"
        else
          info "⚠️  Conectividade OK, mas autenticação pode não estar configurada ainda"
        fi
      else
        info "⚠️  Porta em uso mas não é MongoDB (pode ser outro serviço)"
      fi
    else
      info "⚠️  Porta $port não está em uso no host"
      if [[ "$USE_OFFICIAL_CHART" == "false" ]]; then
        info "Mesmo com hostNetwork ativado, pode haver conflitos de porta"
      else
        info "Isso é normal se não estiver usando hostNetwork ou se houver conflitos de porta"
      fi
    fi
  else
    info "Comando 'mongosh' não encontrado. MongoDB está disponível via kubectl exec"
    info "Teste manual: kubectl -n $NS exec ${RELEASE}-0 -c mongod -- mongosh"
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

Conexão externa:
- Host: localhost:30017 (via NodePort)

Para port-forward alternativo:
kubectl -n $NS port-forward svc/$RELEASE-svc 27017:27017 &

Usuários:
- Usuário admin: admin
  Senha        : (variável MONGODB_ROOT_PASSWORD)
  Auth DB      : admin

Exemplos com port-forward:
kubectl -n $NS port-forward svc/$RELEASE-svc 27017:27017 &

# Usando admin
mongosh --host localhost --port 27017 -u admin -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase admin
export MONGODB_URI="mongodb://admin:\$MONGODB_ROOT_PASSWORD@localhost:27017/admin"

EOF
else
cat <<EOF

🎉  MongoDB (Bitnami) disponível!

Arquitetura: x64 (usando Bitnami Chart com hostNetwork)
Namespace: $NS
Release: $RELEASE

Conexão externa:
- Host: localhost:27017 (via hostNetwork)

Usuários:
- Usuário admin: admin
  Senha        : (variável MONGODB_ROOT_PASSWORD)
  Auth DB      : ${RELEASE}_db

Exemplos:

  # Usando admin
  mongo --host localhost --port 27017 -u admin -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase ${RELEASE}_db
  export MONGODB_URI="mongodb://admin:\$MONGODB_ROOT_PASSWORD@localhost:27017/${RELEASE}_db"

EOF
fi
