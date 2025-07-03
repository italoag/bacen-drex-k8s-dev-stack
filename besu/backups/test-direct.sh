#!/bin/bash

# Configuration
DOMAIN=${DOMAIN:-cluster.eita.cloud}
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || 
          kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "==== Direct Connectivity Test ===="
echo "Using domain: $DOMAIN"
echo "Node IP detected as: $NODE_IP"

# Test direct IP access
echo ""
echo "Testing direct IP access to port 80..."
curl -v -m 5 "http://$NODE_IP" || echo "Failed to connect to port 80"
echo ""

echo "Testing direct IP access to port 443..."  
curl -v -m 5 -k "https://$NODE_IP" || echo "Failed to connect to port 443"
echo ""

# Test domain resolution
echo "Testing DNS resolution..."
for endpoint in rpc-besu ws-besu graphql-besu direct-besu; do
  echo -n "$endpoint.$DOMAIN resolves to: "
  getent hosts "$endpoint.$DOMAIN" || echo "DNS resolution failed"
done
echo ""

# Test Besu endpoints
echo "Testing Besu RPC endpoint..."
curl -v -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  "http://rpc-besu.$DOMAIN"
echo ""

echo "Testing direct-besu endpoint..."
curl -v -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  "http://direct-besu.$DOMAIN"
echo ""

echo "==== Recommendations ===="
echo "If DNS resolution fails:"
echo "  - Add entries to your /etc/hosts file: $NODE_IP rpc-besu.$DOMAIN ws-besu.$DOMAIN graphql-besu.$DOMAIN direct-besu.$DOMAIN"
echo "If connection times out:"
echo "  - Check firewall rules on your K3s server"
echo "  - Verify the ports 80/443 are open and Traefik is listening"
echo "If you get 404 errors:"
echo "  - Run the fix-k3s-traefik.sh script to troubleshoot routing issues"
echo "  - Check the Traefik logs for any routing errors"
