#!/bin/bash

DOMAIN=${DOMAIN:-cluster.eita.cloud}

echo "===== Besu External Access Test Tool ====="
echo "Domain: $DOMAIN"
echo "Testing external access to Besu endpoints..."
echo ""

# Function to perform a test against an endpoint
test_endpoint() {
  local endpoint=$1
  local protocol=$2
  local url="${protocol}://${endpoint}.${DOMAIN}"
  
  echo "Testing connection to: $url"
  
  if [ "$protocol" = "ws" ]; then
    # For WebSocket endpoints
    echo "WebSocket test not implemented in this script. You can test with wscat tool separately."
  else
    # For HTTP endpoints, use curl with verbose output to see headers
    echo "HTTP Headers response:"
    curl -sS -D - -X OPTIONS "$url" -o /dev/null || echo "Failed to connect"
    echo ""
    
    echo "RPC request response:"
    curl -v -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' "$url"
    echo -e "\n"
  fi
}

# Test each endpoint
echo "======= Testing RPC Endpoint ======="
test_endpoint "rpc-besu" "http"

echo "======= Testing GraphQL Endpoint ======="
test_endpoint "graphql-besu" "http"

echo "======= Testing WebSocket Endpoint ======="
test_endpoint "ws-besu" "ws"

echo "======= DNS Resolution Check ======="
echo "Checking DNS resolution for endpoints..."
for endpoint in rpc-besu ws-besu graphql-besu; do
  echo -n "$endpoint.$DOMAIN resolves to: "
  host "$endpoint.$DOMAIN" || echo "DNS resolution failed!"
done

echo "======= Checking HTTPS Certificate ======="
echo "Verifying SSL certificate for endpoints..."
for endpoint in rpc-besu ws-besu graphql-besu; do
  echo "Certificate for $endpoint.$DOMAIN:"
  echo | openssl s_client -servername "$endpoint.$DOMAIN" -connect "$endpoint.$DOMAIN:443" 2>/dev/null | openssl x509 -noout -text | grep -E "Subject:|Not Before:|Not After :|DNS:" || echo "Could not verify certificate"
  echo ""
done

echo "======= Recommendations ======="
echo "1. If DNS resolution fails, ensure your domain is properly configured"
echo "2. If connections time out, check your firewall and ingress rules"
echo "3. If you get 404 errors, verify Traefik routes are properly set up" 
echo "4. If you get 502/503 errors, check that your Besu nodes are running correctly"
