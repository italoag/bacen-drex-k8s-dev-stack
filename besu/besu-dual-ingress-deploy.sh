#!/bin/bash

# Script to create Besu ingress using both Kubernetes Ingress API and Traefik IngressRoute
# Based on the successful Paladin configuration pattern

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

# Check if required resources exist
log "ℹ️ INFO" "Checking required resources..."

# Check if my-basic-auth middleware exists
kubectl get middleware -n $NAMESPACE my-basic-auth &>/dev/null
if [ $? -ne 0 ]; then
  log "ℹ️ INFO" "Creating basic auth middleware..."
  
  # Generate credentials
  USER=${BESU_USER:-admin}
  PASS=${BESU_PASS:-$(openssl rand -base64 12)}
  
  log "ℹ️ INFO" "Creating credentials for basic auth: $USER / $PASS"
  
  # Create secret for basic auth
  kubectl create secret generic -n $NAMESPACE besu-basic-auth-secret \
    --from-literal=users="$USER:$(htpasswd -nb $USER $PASS | cut -d ":" -f 2)"
  
  # Create middleware
  cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: besu-basic-auth
  namespace: $NAMESPACE
spec:
  basicAuth:
    secret: besu-basic-auth-secret
EOF
else
  log "ℹ️ INFO" "Using existing basic auth middleware."
fi

# First, create other required middlewares
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

# Create services if they don't exist
log "ℹ️ INFO" "Creating/updating Besu services..."

for i in 1 2 3; do
  kubectl get statefulset -n $NAMESPACE besu-node$i &>/dev/null
  if [ $? -ne 0 ]; then
    log "⚠️ WARNING" "StatefulSet besu-node$i not found. Skipping."
    continue
  fi
  
  # Create RPC, WS, and GraphQL services for each node
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: besu-node${i}-rpc
  namespace: $NAMESPACE
spec:
  selector:
    statefulset.kubernetes.io/pod-name: besu-node${i}-0
  ports:
    - name: rpc-http
      port: 8545
      targetPort: 8545
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: besu-node${i}-ws
  namespace: $NAMESPACE
spec:
  selector:
    statefulset.kubernetes.io/pod-name: besu-node${i}-0
  ports:
    - name: rpc-ws
      port: 8546
      targetPort: 8546
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: besu-node${i}-graphql
  namespace: $NAMESPACE
spec:
  selector:
    statefulset.kubernetes.io/pod-name: besu-node${i}-0
  ports:
    - name: graphql
      port: 8547
      targetPort: 8547
      protocol: TCP
EOF
done

# Create load balancer services
log "ℹ️ INFO" "Creating load balancer services..."

# Create RPC LoadBalancer Service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: besu-rpc-lb
  namespace: $NAMESPACE
spec:
  ports:
    - name: rpc-http
      port: 8545
      targetPort: 8545
      protocol: TCP
  selector: {}
EOF

# Create RPC Endpoints to manually specify targets
ENDPOINTS=""
for i in 1 2 3; do
  IP=$(kubectl get pod -n $NAMESPACE besu-node${i}-0 -o jsonpath='{.status.podIP}' 2>/dev/null)
  if [ -n "$IP" ]; then
    if [ -n "$ENDPOINTS" ]; then
      ENDPOINTS+=","
    fi
    ENDPOINTS+="{ \"ip\": \"$IP\" }"
  fi
done

if [ -n "$ENDPOINTS" ]; then
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Endpoints
metadata:
  name: besu-rpc-lb
  namespace: $NAMESPACE
subsets:
  - addresses:
$(echo $ENDPOINTS | jq -r '.[] | "    - ip: \(.ip)"')
    ports:
    - name: rpc-http
      port: 8545
      protocol: TCP
EOF
fi

# Do the same for WS
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: besu-ws-lb
  namespace: $NAMESPACE
spec:
  ports:
    - name: rpc-ws
      port: 8546
      targetPort: 8546
      protocol: TCP
  selector: {}
EOF

# Create WS Endpoints
ENDPOINTS=""
for i in 1 2 3; do
  IP=$(kubectl get pod -n $NAMESPACE besu-node${i}-0 -o jsonpath='{.status.podIP}' 2>/dev/null)
  if [ -n "$IP" ]; then
    if [ -n "$ENDPOINTS" ]; then
      ENDPOINTS+=","
    fi
    ENDPOINTS+="{ \"ip\": \"$IP\" }"
  fi
done

if [ -n "$ENDPOINTS" ]; then
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Endpoints
metadata:
  name: besu-ws-lb
  namespace: $NAMESPACE
subsets:
  - addresses:
$(echo $ENDPOINTS | jq -r '.[] | "    - ip: \(.ip)"')
    ports:
    - name: rpc-ws
      port: 8546
      protocol: TCP
EOF
fi

# And for GraphQL
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: besu-graphql-lb
  namespace: $NAMESPACE
spec:
  ports:
    - name: graphql
      port: 8547
      targetPort: 8547
      protocol: TCP
  selector: {}
EOF

# Create GraphQL Endpoints
ENDPOINTS=""
for i in 1 2 3; do
  IP=$(kubectl get pod -n $NAMESPACE besu-node${i}-0 -o jsonpath='{.status.podIP}' 2>/dev/null)
  if [ -n "$IP" ]; then
    if [ -n "$ENDPOINTS" ]; then
      ENDPOINTS+=","
    fi
    ENDPOINTS+="{ \"ip\": \"$IP\" }"
  fi
done

if [ -n "$ENDPOINTS" ]; then
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Endpoints
metadata:
  name: besu-graphql-lb
  namespace: $NAMESPACE
subsets:
  - addresses:
$(echo $ENDPOINTS | jq -r '.[] | "    - ip: \(.ip)"')
    ports:
    - name: graphql
      port: 8547
      protocol: TCP
EOF
fi

# Create dual ingress resources (Kubernetes Ingress + Traefik IngressRoute)
log "ℹ️ INFO" "Creating dual ingress resources..."

# First, create Kubernetes Ingress resources
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: besu-rpc-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: "traefik"
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
spec:
  rules:
  - host: rpc-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-rpc-lb
            port:
              number: 8545
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: besu-ws-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: "traefik"
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
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
            name: besu-ws-lb
            port:
              number: 8546
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: besu-graphql-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: "traefik"
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
spec:
  rules:
  - host: graphql-besu.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: besu-graphql-lb
            port:
              number: 8547
EOF

# Then create Traefik IngressRoutes with middleware
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: besu-rpc-route-secure
  namespace: $NAMESPACE
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`rpc-besu.$DOMAIN\`)
      kind: Rule
      middlewares:
        - name: besu-retry-middleware
      services:
        - name: besu-rpc-lb
          port: 8545
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: besu-ws-route-secure
  namespace: $NAMESPACE
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`ws-besu.$DOMAIN\`)
      kind: Rule
      middlewares:
        - name: besu-ws-middleware
        - name: besu-retry-middleware
      services:
        - name: besu-ws-lb
          port: 8546
  tls: {}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: besu-graphql-route-secure
  namespace: $NAMESPACE
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`graphql-besu.$DOMAIN\`)
      kind: Rule
      middlewares:
        - name: besu-retry-middleware
      services:
        - name: besu-graphql-lb
          port: 8547
  tls: {}
EOF

# Wait a bit for the resources to be created
sleep 5

# Check created resources
log "ℹ️ INFO" "Checking created resources..."

log "ℹ️ INFO" "Kubernetes Ingress resources:"
kubectl get ingress -n $NAMESPACE | grep besu

log "ℹ️ INFO" "Traefik IngressRoute resources:"
kubectl get ingressroute -n $NAMESPACE | grep besu

log "ℹ️ INFO" "Load balancer services and endpoints:"
kubectl get svc -n $NAMESPACE | grep besu-.*-lb
kubectl get endpoints -n $NAMESPACE | grep besu-.*-lb

# Test connectivity
log "ℹ️ INFO" "Testing direct access to besu-rpc-lb..."
kubectl port-forward -n $NAMESPACE svc/besu-rpc-lb 8545:8545 &
PF_PID=$!
sleep 2

RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://localhost:8545 || echo "Failed to connect")

kill $PF_PID 2>/dev/null
wait $PF_PID 2>/dev/null || true

if [[ "$RESPONSE" == *"jsonrpc"* ]]; then
  log "✅ OK" "Successfully connected to besu-rpc-lb. Response: $RESPONSE"
else
  log "⚠️ WARNING" "Could not connect to besu-rpc-lb. Response: $RESPONSE"
fi

log "✅ OK" "Besu ingress resources have been created following the Paladin dual-approach pattern."
log "ℹ️ INFO" "You can now access your Besu endpoints at:"
log "ℹ️ INFO" "  - RPC: http://rpc-besu.$DOMAIN"
log "ℹ️ INFO" "  - WebSocket: ws://ws-besu.$DOMAIN"
log "ℹ️ INFO" "  - GraphQL: http://graphql-besu.$DOMAIN"
