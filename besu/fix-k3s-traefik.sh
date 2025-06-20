#!/bin/bash

NAMESPACE=${NAMESPACE:-paladin}
DOMAIN=${DOMAIN:-cluster.eita.cloud}

echo "==== K3s Traefik Configuration Troubleshooter ===="

# Detect Traefik namespace and deployment
echo "Identifying Traefik installation..."
TRAEFIK_NS=$(kubectl get pods --all-namespaces | grep -i traefik | awk '{print $1}' | head -1)

if [ -z "$TRAEFIK_NS" ]; then
  echo "❌ ERROR: Traefik not found in the cluster. Is K3s using a different ingress?"
  exit 1
else
  echo "✅ Traefik found in namespace: $TRAEFIK_NS"
fi

# Get Traefik pod name
TRAEFIK_POD=$(kubectl get pods -n $TRAEFIK_NS -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || kubectl get pods -n $TRAEFIK_NS -l app=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$TRAEFIK_POD" ]; then
  echo "❌ ERROR: Traefik pod not found!"
  exit 1
else
  echo "✅ Traefik pod found: $TRAEFIK_POD"
fi

# Check if IngressRoutes are being properly tracked
echo "Checking if Traefik is processing IngressRoutes..."
kubectl get ingressroutes.traefik.io -n $NAMESPACE
echo ""

echo "Checking Traefik logs for routing information..."
kubectl logs -n $TRAEFIK_NS $TRAEFIK_POD --tail=50 | grep -i "route\|ingress\|404\|error"

# Check entrypoints configuration which is critical
echo "Checking Traefik EntryPoints configuration..."
kubectl get -n $TRAEFIK_NS configmap traefik -o jsonpath='{.data.traefik\.yaml}' 2>/dev/null | grep -A 10 "entryPoints:" || echo "No entryPoints found in ConfigMap"

# Check if CRD provider is enabled
echo "Checking if Traefik CRD provider is enabled..."
kubectl get -n $TRAEFIK_NS configmap traefik -o jsonpath='{.data.traefik\.yaml}' 2>/dev/null | grep -A 10 "providers:" | grep -A 5 "kubernetesIngress\|kubernetescrd" || echo "kubernetescrd provider not found!"

# Let's fix common issues with K3s Traefik IngressRoutes
echo "Applying fixes for common K3s Traefik issues..."

# 1. Fix: Make sure each IngressRoute service specifies kind: TraefikService
echo "Checking IngressRoute services have kind: TraefikService..."
for ir in besu-rpc-route besu-ws-route besu-graphql-route; do
  HAS_KIND=$(kubectl get ingressroute.traefik.io $ir -n $NAMESPACE -o jsonpath='{.spec.routes[0].services[0].kind}' 2>/dev/null)
  if [ "$HAS_KIND" != "TraefikService" ]; then
    echo "Adding kind: TraefikService to $ir"
    kubectl get ingressroute.traefik.io $ir -n $NAMESPACE -o yaml > /tmp/$ir.yaml
    sed -i 's/services:/services:\n        - kind: TraefikService/' /tmp/$ir.yaml
    kubectl apply -f /tmp/$ir.yaml
  else
    echo "✅ $ir already has kind: TraefikService"
  fi
done

# 2. Fix: Check for Traefik version and update syntax if needed
TRAEFIK_VERSION=$(kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik version 2>/dev/null | grep -i version || echo "unknown")
echo "Traefik version: $TRAEFIK_VERSION"

# 3. Fix: Create direct Service resources if needed
echo "Creating direct services that point to the Besu nodes..."
for i in 1 2 3; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: besu-direct-rpc-$i
  namespace: $NAMESPACE
spec:
  selector:
    statefulset.kubernetes.io/pod-name: besu-node$i-0
  ports:
  - name: http
    port: 8545
    targetPort: 8545
  type: ClusterIP
EOF
done

# 4. Fix: Create a direct IngressRoute that doesn't use TraefikService for testing
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: besu-direct-route
  namespace: $NAMESPACE
spec:
  entryPoints:
  - web
  routes:
  - match: Host(\`direct-besu.$DOMAIN\`)
    kind: Rule
    services:
    - name: besu-direct-rpc-1
      port: 8545
EOF

echo ""
echo "==== Testing Direct Access ===="
echo "Try accessing: http://direct-besu.$DOMAIN"
echo "This should bypass the TraefikService and connect directly to a Besu node."
echo ""

echo "==== Troubleshooting Recommendations ===="
echo "1. If direct access works but TraefikService doesn't, check your TraefikService configuration"
echo "2. If neither work, check your ingress-controller configuration in K3s"
echo "3. Try restarting the Traefik pod: kubectl delete pod -n $TRAEFIK_NS $TRAEFIK_POD"
echo "4. Check the domain DNS is correctly pointed to your K3s node's IP"
echo "5. Try 'curl -v http://direct-besu.$DOMAIN' to see detailed connection information"
echo "6. Ensure Traefik is listening on the ports you expect with: netstat -tuln | grep '80\\|443'"

# Output the external cluster IP for DNS configuration
echo ""
echo "External access information:"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
if [ -z "$NODE_IP" ]; then
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
fi
echo "Make sure your DNS records for *.$DOMAIN point to: $NODE_IP"
