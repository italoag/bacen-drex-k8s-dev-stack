# Besu Ingress Troubleshooting Guide

## Background

The error you're experiencing with the Besu endpoints returning 404 errors is related to how the Traefik ingress resources are configured in your Kubernetes cluster. There are a few key differences between your working Paladin configuration and the Besu configuration that was causing issues.

## Issue Summary

The main issues with the original Besu ingress configuration were:

1. **Incorrect TraefikService references**: The IngressRoute CRD was referencing services with `@kubernetescrd` suffix which wasn't correct
2. **Non-existent certResolver**: Using `certResolver: default` when no such resolver is configured in Traefik
3. **Command not found errors**: The troubleshooting command `traefik http` isn't available in your Traefik installation

## Solution Approaches

We've provided three alternative solutions to address these issues:

1. **fix-traefik-routes.sh**: Tries to fix the existing TraefikService and IngressRoute approach, but some commands don't work in your Traefik installation
2. **besu-k8s-ingress.sh**: Uses standard Kubernetes Ingress resources for improved compatibility
3. **besu-dual-ingress-deploy.sh**: Uses a dual approach like your working Paladin configuration (both Kubernetes Ingress and Traefik IngressRoute)

## Recommended Solution

The recommended solution is to use the **besu-dual-ingress-deploy.sh** script, as it follows the same pattern you already have working with your Paladin services.

## How to Apply the Fix

Run the dual ingress deployment script:

```bash
cd /Users/italo/Projects/lab/k3s/bacen-drex-kubernetes-dev-stack/besu
./besu-dual-ingress-deploy.sh
```

This script will:

1. Create required Kubernetes services for each Besu node
2. Create load balancer services to distribute traffic across nodes
3. Create both Kubernetes Ingress and Traefik IngressRoute resources
4. Apply the necessary middlewares for WebSocket support and retries

## Key Differences from Original Configuration

1. **No @kubernetescrd suffix**: References services directly by name (e.g., `besu-rpc-lb` instead of `besu-rpc-lb@kubernetescrd`)
2. **Empty TLS Configuration**: Uses `tls: {}` instead of `certResolver: default`
3. **Dual Approach**: Uses both Kubernetes Ingress and Traefik IngressRoute resources for better compatibility

## Verifying the Fix

After applying the fix, you can test if the endpoints are working properly by:

1. Testing internal access:
   ```bash
   kubectl port-forward -n paladin svc/besu-rpc-lb 8545:8545 &
   curl -X POST -H "Content-Type: application/json" \
     --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
     http://localhost:8545
   ```

2. Testing external access (replace with your actual domain):
   ```bash
   curl -X POST -H "Content-Type: application/json" \
     --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
     http://rpc-besu.cluster.eita.cloud
   ```

## If Problems Persist

If you're still experiencing issues after applying the fix:

1. Check if DNS is resolving correctly:
   ```bash
   nslookup rpc-besu.cluster.eita.cloud
   ```

2. Verify Traefik is handling the routes properly:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=traefik | grep rpc-besu
   ```

3. Check for any errors in the endpoints:
   ```bash
   kubectl get endpoints -n paladin | grep besu
   ```
