#!/bin/bash

NAMESPACE="paladin"
DOMAIN=${DOMAIN:-cluster.eita.cloud}

echo "==== Besu Network Troubleshooting Tool ===="
echo "Checking resources in namespace: $NAMESPACE"
echo "Domain: $DOMAIN"

# Check DNS resolution
echo -e "\n==== DNS Resolution Check ===="
echo "Checking DNS for rpc-besu.$DOMAIN..."
nslookup rpc-besu.$DOMAIN || echo "DNS resolution failed!"

# Check ingress resources
echo -e "\n==== Ingress Resources Check ===="
echo "Checking IngressRoutes..."
kubectl get ingressroutes.traefik.io -n $NAMESPACE
echo -e "\nDetails for besu-rpc-route:"
kubectl describe ingressroutes.traefik.io besu-rpc-route -n $NAMESPACE

# Check traefik services
echo -e "\n==== TraefikServices Check ===="
echo "Listing TraefikServices..."
kubectl get traefikservices.traefik.io -n $NAMESPACE
echo -e "\nDetails for besu-rpc-lb:"
kubectl describe traefikservices.traefik.io besu-rpc-lb -n $NAMESPACE

# Check actual services
echo -e "\n==== Services Check ===="
echo "Listing services..."
kubectl get services -n $NAMESPACE | grep besu
echo -e "\nChecking endpoints..."
for i in $(kubectl get services -n $NAMESPACE | grep besu | awk '{print $1}'); do
  echo "Endpoints for $i:"
  kubectl get endpoints $i -n $NAMESPACE -o yaml | grep -A 5 subsets
done

# Check pods
echo -e "\n==== Pods Check ===="
echo "Checking Besu node pods..."
kubectl get pods -n $NAMESPACE | grep besu-node

# Check Traefik logs
echo -e "\n==== Traefik Logs Check ===="
echo "Checking recent Traefik logs for routing issues..."
TRAEFIK_POD=$(kubectl get pods -n kube-system -l app=traefik -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n kube-system $TRAEFIK_POD --tail=50 | grep -i "route\|error\|besu"

echo -e "\n==== Direct Service Access Test ===="
echo "Creating test pod to access services directly..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: curl-test
  namespace: $NAMESPACE
spec:
  containers:
  - name: curl
    image: curlimages/curl
    command: ["sleep", "600"]
  restartPolicy: Never
EOF

echo "Waiting for test pod to be ready..."
kubectl wait --for=condition=Ready pod/curl-test -n $NAMESPACE --timeout=30s

echo -e "\nTesting direct access to besu-node1-rpc service..."
kubectl exec -n $NAMESPACE curl-test -- curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://besu-node1-rpc:8545

echo -e "\n==== Recommendations ===="
echo "1. If DNS resolution failed, check your DNS configuration"
echo "2. If IngressRoutes are missing, redeploy using besu-lb-ingress-deploy.sh"
echo "3. If services are available but endpoints aren't, check if pods are running"
echo "4. If direct service access works but external doesn't, check Traefik configuration"

echo -e "\nDon't forget to clean up the test pod:"
echo "kubectl delete pod curl-test -n $NAMESPACE"
