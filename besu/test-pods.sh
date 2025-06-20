#!/bin/bash

NAMESPACE=${NAMESPACE:-paladin}

echo "==== Besu Internal Connectivity Test ===="

echo "Creating a test pod with curl..."
kubectl run curl-test --image=curlimages/curl -n $NAMESPACE -- sleep 3600

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=ready pod/curl-test -n $NAMESPACE --timeout=60s

echo "Testing direct access to besu-node1-rpc service..."
kubectl exec -n $NAMESPACE curl-test -- curl -v -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://besu-node1-rpc:8545

echo "Testing access to TraefikService endpoint (internal)..."
kubectl exec -n $NAMESPACE curl-test -- curl -v -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://besu-rpc-lb

echo ""
echo "Done with tests. Pod 'curl-test' is still running."
echo "You can manually run more tests with:"
echo "kubectl exec -it -n $NAMESPACE curl-test -- curl [options]"
echo ""
echo "To delete the test pod:"
echo "kubectl delete pod curl-test -n $NAMESPACE"
