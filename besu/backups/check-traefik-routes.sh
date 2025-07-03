#!/bin/bash

DOMAIN=${DOMAIN:-cluster.eita.cloud}
NAMESPACE=${NAMESPACE:-paladin}

echo "==== Besu Traefik Routing Check ===="
echo "Checking Traefik routes for Besu endpoints..."

# Get Traefik pod
TRAEFIK_POD=$(kubectl get pods -n kube-system -l app=traefik -o jsonpath='{.items[0].metadata.name}')
if [ -z "$TRAEFIK_POD" ]; then
  echo "❌ ERROR: Traefik pod not found!"
  exit 1
fi

echo "Found Traefik pod: $TRAEFIK_POD"

# Check if Traefik API is enabled
echo "Checking if Traefik API is enabled..."
kubectl get configmap -n kube-system traefik -o yaml | grep "api:"
API_ENABLED=$?

if [ $API_ENABLED -eq 0 ]; then
  echo "Traefik API appears to be enabled. Setting up port forward..."
  # Setup port-forward in background
  kubectl port-forward -n kube-system $TRAEFIK_POD 9000:9000 &
  PF_PID=$!
  
  # Give it a moment to establish
  sleep 2
  
  echo "Fetching routes from Traefik API..."
  curl -s http://localhost:9000/api/http/routers | grep -i besu

  echo "Fetching services from Traefik API..."
  curl -s http://localhost:9000/api/http/services | grep -i besu
  
  # Kill port-forward
  kill $PF_PID
else
  echo "Traefik API not enabled. Using logs to diagnose..."
fi

# Check Traefik logs for routing information
echo "Checking Traefik logs for routing information..."
kubectl logs -n kube-system $TRAEFIK_POD --tail=100 | grep -i "route\|besu\|404\|error"

# Check IngressRoute resources
echo "Checking IngressRoute resources..."
kubectl get ingressroutes.traefik.io -n $NAMESPACE
echo ""

for route in besu-rpc-route besu-ws-route besu-graphql-route; do
  echo "Details for $route:"
  kubectl describe ingressroutes.traefik.io $route -n $NAMESPACE
  echo ""
done

# Check TraefikService resources
echo "Checking TraefikService resources..."
kubectl get traefikservices.traefik.io -n $NAMESPACE
echo ""

for service in besu-rpc-lb besu-ws-lb besu-graphql-lb; do
  echo "Details for $service:"
  kubectl describe traefikservices.traefik.io $service -n $NAMESPACE
  echo ""
done

# Test external DNS resolution
echo "Testing DNS resolution for endpoints..."
for endpoint in rpc-besu ws-besu graphql-besu; do
  fqdn="${endpoint}.${DOMAIN}"
  echo "Resolving $fqdn..."
  host $fqdn || nslookup $fqdn || dig $fqdn || echo "Failed to resolve $fqdn"
  echo ""
done

echo "==== Recommendations ===="
echo "1. If IngressRoutes look correct but endpoints return 404, verify DNS is pointing to your Traefik ingress IP"
echo "2. If Traefik logs show routing errors, check the configuration of your IngressRoutes"
echo "3. If TraefikServices can't find backends, verify that the service names and ports are correct"
echo ""

echo "You can try accessing the endpoints externally with:"
echo "curl -v -X POST -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"net_version\",\"params\":[],\"id\":1}' http://rpc-besu.${DOMAIN}"
