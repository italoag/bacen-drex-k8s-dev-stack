#!/bin/bash

NAMESPACE=${NAMESPACE:-paladin}
DOMAIN=${DOMAIN:-cluster.eita.cloud}

echo "==== Besu 404 Error Diagnostic Tool ===="
echo "This tool will diagnose 404 errors for Besu endpoints without making any changes"
echo "Namespace: $NAMESPACE"
echo "Domain: $DOMAIN"
echo ""

# Find ingress controller
echo "===== Discovering Ingress Controller ====="
INGRESS_NS=$(kubectl get pods --all-namespaces | grep -E 'traefik|ingress-nginx|haproxy|ambassador' | awk '{print $1}' | head -1)
INGRESS_POD=$(kubectl get pods -n $INGRESS_NS -l app.kubernetes.io/name=traefik -o name 2>/dev/null || kubectl get pods -n $INGRESS_NS -l app=traefik -o name 2>/dev/null || kubectl get pods -n $INGRESS_NS | grep -E 'traefik|ingress-nginx|haproxy|ambassador' | awk '{print $1}' | head -1)

if [ -z "$INGRESS_NS" ] || [ -z "$INGRESS_POD" ]; then
  echo "⚠️ WARNING: Could not automatically detect ingress controller. Will continue with limited diagnostics."
else
  echo "✅ Ingress controller found in namespace: $INGRESS_NS"
  echo "   Pod: $INGRESS_POD"
fi

# Check Besu resources
echo ""
echo "===== Checking Besu Resources ====="

# Check Besu pods
echo "Checking Besu pods..."
kubectl get pods -n $NAMESPACE -l app=besu -o wide || echo "No pods with label app=besu found"
echo ""

# Check Kubernetes services
echo "Checking Besu services..."
kubectl get services -n $NAMESPACE | grep 'besu' || echo "No Besu services found"
echo ""

# Check TraefikServices
echo "Checking TraefikServices..."
kubectl get traefikservices.traefik.io -n $NAMESPACE || echo "No TraefikServices found"
echo ""

# Check IngressRoutes
echo "Checking IngressRoutes..."
kubectl get ingressroutes.traefik.io -n $NAMESPACE || echo "No IngressRoutes found"
echo ""

# External access details
echo "===== External Access Details ====="
EXTERNAL_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
INTERNAL_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_IP=${EXTERNAL_IP:-$INTERNAL_IP}

echo "Node IP appears to be: $NODE_IP"
echo "DNS entries for Besu should point to this IP."
echo ""

# Check DNS entries
echo "Checking DNS resolution..."
for endpoint in rpc-besu ws-besu graphql-besu; do
  echo -n "$endpoint.$DOMAIN resolves to: "
  getent hosts "$endpoint.$DOMAIN" 2>/dev/null || echo "Unable to resolve - DNS may not be configured"
done
echo ""

# Check routing in detail
echo "===== Detailed Route Analysis ====="

echo "Checking RPC Route details..."
kubectl describe ingressroute.traefik.io besu-rpc-route -n $NAMESPACE 2>/dev/null || echo "Could not find RPC route"
echo ""

echo "Checking TraefikService for RPC..."
kubectl describe traefikservice.traefik.io besu-rpc-lb -n $NAMESPACE 2>/dev/null || echo "Could not find RPC TraefikService"
echo ""

# Check if the middleware exists and is correctly configured
echo "Checking middleware configuration..."
kubectl describe middleware.traefik.io besu-retry-middleware -n $NAMESPACE 2>/dev/null || echo "Could not find retry middleware"
echo ""

echo "===== Test with Port Forward ====="
echo "Attempting direct connection to Besu with port-forward..."

# Create a port-forward to test direct connection
NODE_NUMBER=1
kubectl port-forward -n $NAMESPACE svc/besu-node${NODE_NUMBER}-rpc 8545:8545 &
PF_PID=$!

# Wait for port-forward to establish
sleep 2

# Test the service directly
echo "Testing direct connection to Besu node ${NODE_NUMBER} via port-forward..."
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://localhost:8545 || echo "Failed to connect to Besu directly"

# Clean up port-forward
kill $PF_PID 2>/dev/null

echo ""
echo "===== Recommendations ====="

# Check for common k3s issues
if kubectl describe configmap -n $INGRESS_NS traefik 2>/dev/null | grep -q "allowExternalNameServices"; then
  EXTERNAL_NAME=$(kubectl get configmap -n $INGRESS_NS traefik -o yaml | grep -c "allowExternalNameServices: true")
  if [ "$EXTERNAL_NAME" -eq 0 ]; then
    echo "⚠️ K3s Traefik configuration might need 'allowExternalNameServices: true' for TraefikServices to work."
    echo "   This is a common issue with K3s Traefik deployments."
  fi
fi

echo ""
echo "Common reasons for 404 errors:"
echo "1. DNS not resolving to correct IP address"
echo "   - Add entries to /etc/hosts: $NODE_IP rpc-besu.$DOMAIN ws-besu.$DOMAIN graphql-besu.$DOMAIN"
echo ""
echo "2. IngressRoute not properly configured"
echo "   - Ensure Host rules match exactly: Host(\`rpc-besu.${DOMAIN}\`)"
echo "   - For TraefikService references, syntax should be: name@kubernetescrd"
echo ""
echo "3. TraefikService not routing correctly"
echo "   - Verify service port numbers match the actual Besu services (8545/8546/8547)"
echo ""
echo "4. Besu nodes not exposing APIs"
echo "   - Verify RPC/WS/GraphQL APIs are enabled on the Besu nodes"
echo "   - Common Besu flags to check: --rpc-http-enabled --rpc-ws-enabled --graphql-http-enabled"
echo ""
echo "5. Network/Firewall issues"
echo "   - Ensure ports 80/443 are open and accessible"
echo ""
echo "Try creating a test pod to debug from inside the cluster:"
echo "kubectl run curl-test --image=curlimages/curl -n $NAMESPACE -- sleep 3600"
echo "kubectl exec -it curl-test -n $NAMESPACE -- curl http://besu-node1-rpc:8545"

exit 0
