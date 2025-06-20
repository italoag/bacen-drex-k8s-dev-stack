#!/bin/bash

# Script para corrigir problemas comuns do Traefik no Kubernetes
NAMESPACE="paladin"
TRAEFIK_NS="kube-system"
DOMAIN=${DOMAIN:-cluster.eita.cloud}

# Função para logging
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" 
}

# Verificar pods do Traefik
log "ℹ️ INFO" "Verificando pods do Traefik..."
TRAEFIK_POD=$(kubectl get pods -n $TRAEFIK_NS -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || kubectl get pods -n $TRAEFIK_NS -l app=traefik -o jsonpath='{.items[0].metadata.name}')

if [ -z "$TRAEFIK_POD" ]; then
  log "❌ ERROR" "Nenhum pod do Traefik encontrado!"
  exit 1
else
  log "✅ OK" "Pod do Traefik encontrado: $TRAEFIK_POD"
fi

# 1. Excluir recursos com problemas
log "ℹ️ INFO" "Excluindo recursos do Traefik com problemas..."

# Excluir IngressRoutes
log "ℹ️ INFO" "Excluindo IngressRoutes existentes..."
kubectl delete ingressroute -n $NAMESPACE besu-rpc-route besu-ws-route besu-graphql-route 2>/dev/null || true

# Excluir TraefikServices
log "ℹ️ INFO" "Excluindo TraefikServices existentes..."
kubectl delete traefikservice -n $NAMESPACE besu-rpc-lb besu-ws-lb besu-graphql-lb 2>/dev/null || true

# Excluir Middlewares
log "ℹ️ INFO" "Excluindo Middlewares existentes..."
kubectl delete middleware -n $NAMESPACE besu-ws-middleware besu-retry-middleware 2>/dev/null || true

# Aguarde um momento para que as exclusões sejam processadas
log "ℹ️ INFO" "Aguardando processamento das exclusões..."
sleep 3

# 2. Criar novos recursos corrigidos

# Criar Middlewares
log "ℹ️ INFO" "Criando Middlewares corrigidos..."
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: besu-ws-middleware
  namespace: $NAMESPACE
spec:
  headers:
    customRequestHeaders:
      Connection: "Upgrade"
      Upgrade: "websocket"
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: besu-retry-middleware
  namespace: $NAMESPACE
spec:
  retry:
    attempts: 3
    initialInterval: "500ms"
EOF

# Aguardar um momento para garantir que os middlewares estejam criados
sleep 2

# Criar TraefikServices
log "ℹ️ INFO" "Criando TraefikServices corrigidos..."
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: besu-rpc-lb
  namespace: $NAMESPACE
spec:
  weighted:
    services:
      - name: besu-node1-rpc
        port: 8545
        weight: 1
      - name: besu-node2-rpc
        port: 8545
        weight: 1
      - name: besu-node3-rpc
        port: 8545
        weight: 1
---
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: besu-ws-lb
  namespace: $NAMESPACE
spec:
  weighted:
    services:
      - name: besu-node1-ws
        port: 8546
        weight: 1
      - name: besu-node2-ws
        port: 8546
        weight: 1
      - name: besu-node3-ws
        port: 8546
        weight: 1
---
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: besu-graphql-lb
  namespace: $NAMESPACE
spec:
  weighted:
    services:
      - name: besu-node1-graphql
        port: 8547
        weight: 1
      - name: besu-node2-graphql
        port: 8547
        weight: 1
      - name: besu-node3-graphql
        port: 8547
        weight: 1
EOF

# Aguardar um momento para garantir que os TraefikServices estejam criados
sleep 2

# Criar IngressRoutes - agora sem o sufixo @kubernetescrd e sem o certResolver
log "ℹ️ INFO" "Criando IngressRoutes corrigidos..."
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: besu-rpc-route
  namespace: $NAMESPACE
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(\`rpc-besu.$DOMAIN\`)
      kind: Rule
      services:
        - name: besu-rpc-lb
          kind: TraefikService
      middlewares:
        - name: besu-retry-middleware
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: besu-ws-route
  namespace: $NAMESPACE
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(\`ws-besu.$DOMAIN\`)
      kind: Rule
      services:
        - name: besu-ws-lb
          kind: TraefikService
      middlewares:
        - name: besu-ws-middleware
        - name: besu-retry-middleware
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: besu-graphql-route
  namespace: $NAMESPACE
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(\`graphql-besu.$DOMAIN\`)
      kind: Rule
      services:
        - name: besu-graphql-lb
          kind: TraefikService
      middlewares:
        - name: besu-retry-middleware
  tls: {}
EOF

# 3. Verificar se os recursos foram criados corretamente
log "ℹ️ INFO" "Verificando se os recursos foram criados corretamente..."

# Verificar Middlewares
log "ℹ️ INFO" "Verificando Middlewares..."
kubectl get middleware -n $NAMESPACE

# Verificar TraefikServices
log "ℹ️ INFO" "Verificando TraefikServices..."
kubectl get traefikservice -n $NAMESPACE

# Verificar IngressRoutes
log "ℹ️ INFO" "Verificando IngressRoutes..."
kubectl get ingressroute -n $NAMESPACE

# 4. Verificar se o Traefik está processando os recursos
log "ℹ️ INFO" "Verificando se o Traefik está processando os recursos..."

# Verificar rotas HTTP configuradas
log "ℹ️ INFO" "Rotas HTTP configuradas no Traefik:"
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik http routers | grep -i "besu" || echo "Nenhuma rota besu encontrada"

# Verificar serviços HTTP configurados
log "ℹ️ INFO" "Serviços HTTP configurados no Traefik:"
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik http services | grep -i "besu" || echo "Nenhum serviço besu encontrado"

# Verificar middlewares HTTP configurados
log "ℹ️ INFO" "Middlewares HTTP configurados no Traefik:"
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik http middlewares | grep -i "besu" || echo "Nenhum middleware besu encontrado"

log "✅ OK" "Correção concluída! Verifique se os endpoints estão respondendo agora."
