#!/bin/bash

# Script to create Besu ingress using the Kubernetes Ingress API
# Based on the successful Paladin configuration

NAMESPACE="paladin"
DOMAIN=${DOMAIN:-cluster.eita.cloud}

# Function for logging
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" 
}

# Check if namespace exists
kubectl get namespace $NAMESPACE &>/dev/null
if [ $? -ne 0 ]; then
  log "❌ ERROR" "Namespace $NAMESPACE does not exist."
  exit 1
fi

# Check if Besu services exist
for i in 1 2 3; do
  for type in rpc ws graphql; do
    kubectl get svc -n $NAMESPACE besu-node${i}-${type} &>/dev/null
    if [ $? -ne 0 ]; then
      log "❌ ERROR" "Service besu-node${i}-${type} does not exist."
      exit 1
    fi
  done
done

log "✅ OK" "All required Besu services exist."

# First, create middleware if it doesn't exist yet
log "ℹ️ INFO" "Creating/updating Besu middlewares..."

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

# Check if cert-manager is installed
CERT_MANAGER_INSTALLED=false
kubectl get deployment -A | grep cert-manager &>/dev/null
if [ $? -eq 0 ]; then
  CERT_MANAGER_INSTALLED=true
  log "ℹ️ INFO" "cert-manager detected. Will configure TLS with cert-manager."
else
  log "ℹ️ INFO" "cert-manager not detected. Will use simple TLS configuration."
fi

# Create Kubernetes Ingress resources for each Besu endpoint
log "ℹ️ INFO" "Creating Kubernetes Ingress resources for Besu endpoints..."

# Create Ingress for RPC endpoints
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: besu-rpc-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: "traefik"
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/load-balancer-method: "roundrobin"
spec:
  rules:
  - host: rpc-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node1-rpc
            port:
              number: 8545
  - host: rpc-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node2-rpc
            port:
              number: 8545
  - host: rpc-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node3-rpc
            port:
              number: 8545
EOF

# Create Ingress for WS endpoints
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: besu-ws-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: "traefik"
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/load-balancer-method: "roundrobin"
    traefik.ingress.kubernetes.io/websocket: "true"
spec:
  rules:
  - host: ws-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node1-ws
            port:
              number: 8546
  - host: ws-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node2-ws
            port:
              number: 8546
  - host: ws-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node3-ws
            port:
              number: 8546
EOF

# Create Ingress for GraphQL endpoints
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: besu-graphql-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: "traefik"
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/load-balancer-method: "roundrobin"
spec:
  rules:
  - host: graphql-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node1-graphql
            port:
              number: 8547
  - host: graphql-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node2-graphql
            port:
              number: 8547
  - host: graphql-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-node3-graphql
            port:
              number: 8547
EOF

# Create a service to do load balancing for Besu RPC endpoints
log "ℹ️ INFO" "Creating load balancer service for Besu endpoints..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: besu-rpc-lb
  namespace: $NAMESPACE
spec:
  type: ClusterIP
  ports:
    - name: rpc
      port: 8545
      targetPort: 8545
      protocol: TCP
  selector: {}
---
apiVersion: v1
kind: Endpoints
metadata:
  name: besu-rpc-lb
  namespace: $NAMESPACE
subsets:
  - addresses:
    - ip: $(kubectl get pod -n $NAMESPACE besu-node1-0 -o jsonpath='{.status.podIP}')
    - ip: $(kubectl get pod -n $NAMESPACE besu-node2-0 -o jsonpath='{.status.podIP}')
    - ip: $(kubectl get pod -n $NAMESPACE besu-node3-0 -o jsonpath='{.status.podIP}')
    ports:
    - name: rpc
      port: 8545
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: besu-ws-lb
  namespace: $NAMESPACE
spec:
  type: ClusterIP
  ports:
    - name: ws
      port: 8546
      targetPort: 8546
      protocol: TCP
  selector: {}
---
apiVersion: v1
kind: Endpoints
metadata:
  name: besu-ws-lb
  namespace: $NAMESPACE
subsets:
  - addresses:
    - ip: $(kubectl get pod -n $NAMESPACE besu-node1-0 -o jsonpath='{.status.podIP}')
    - ip: $(kubectl get pod -n $NAMESPACE besu-node2-0 -o jsonpath='{.status.podIP}')
    - ip: $(kubectl get pod -n $NAMESPACE besu-node3-0 -o jsonpath='{.status.podIP}')
    ports:
    - name: ws
      port: 8546
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: besu-graphql-lb
  namespace: $NAMESPACE
spec:
  type: ClusterIP
  ports:
    - name: graphql
      port: 8547
      targetPort: 8547
      protocol: TCP
  selector: {}
---
apiVersion: v1
kind: Endpoints
metadata:
  name: besu-graphql-lb
  namespace: $NAMESPACE
subsets:
  - addresses:
    - ip: $(kubectl get pod -n $NAMESPACE besu-node1-0 -o jsonpath='{.status.podIP}')
    - ip: $(kubectl get pod -n $NAMESPACE besu-node2-0 -o jsonpath='{.status.podIP}')
    - ip: $(kubectl get pod -n $NAMESPACE besu-node3-0 -o jsonpath='{.status.podIP}')
    ports:
    - name: graphql
      port: 8547
      protocol: TCP
EOF

# Wait a bit for the resources to be created
sleep 5

log "ℹ️ INFO" "Checking if the Ingress resources were created successfully..."
kubectl get ingress -n $NAMESPACE | grep besu

log "ℹ️ INFO" "Checking if the load balancer Services and Endpoints were created successfully..."
kubectl get svc -n $NAMESPACE | grep besu-.*-lb
kubectl get endpoints -n $NAMESPACE | grep besu-.*-lb

# Test connectivity directly to one of the services
log "ℹ️ INFO" "Testing direct access to besu-node1-rpc..."
kubectl port-forward -n $NAMESPACE svc/besu-node1-rpc 8545:8545 &
PF_PID=$!
sleep 2

RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://localhost:8545 || echo "Failed to connect")

kill $PF_PID 2>/dev/null
wait $PF_PID 2>/dev/null || true

if [[ "$RESPONSE" == *"jsonrpc"* ]]; then
  log "✅ OK" "Successfully connected to besu-node1-rpc. Response: $RESPONSE"
else
  log "⚠️ WARNING" "Could not connect to besu-node1-rpc. Response: $RESPONSE"
fi

log "✅ OK" "Besu ingress resources have been created following the Paladin configuration pattern."
log "ℹ️ INFO" "You can now access your Besu endpoints at:"
log "ℹ️ INFO" "  - RPC: http://rpc-besu.$DOMAIN"
log "ℹ️ INFO" "  - WebSocket: ws://ws-besu.$DOMAIN"
log "ℹ️ INFO" "  - GraphQL: http://graphql-besu.$DOMAIN"
