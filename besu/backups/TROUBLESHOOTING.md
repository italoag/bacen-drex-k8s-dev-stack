# Besu Load Balancer Troubleshooting Guide

## Common Issues and Solutions

### 404 Not Found When Accessing Endpoints

If you're receiving 404 errors when trying to access your endpoints (http://rpc-besu.cluster.eita.cloud, etc.), check the following:

1. **Verify DNS Resolution**:
   ```
   host rpc-besu.cluster.eita.cloud
   ```
   If DNS resolution fails, update your DNS records to point to your cluster's ingress IP.

2. **Check Traefik IngressRoute Configuration**:
   ```
   kubectl get ingressroute -n paladin
   kubectl describe ingressroute besu-rpc-route -n paladin
   ```
   Ensure the host rules match your domain exactly.

3. **Check if Traefik is Properly Routing**:
   ```
   kubectl logs -n kube-system -l app=traefik --tail=100
   ```
   Look for errors related to route configuration.

4. **Verify TraefikServices**:
   ```
   kubectl get traefikservices -n paladin
   kubectl describe traefikservice besu-rpc-lb -n paladin
   ```
   Ensure they are correctly configured to point to your Besu services.

5. **Test Connectivity from Inside the Cluster**:
   ```
   kubectl run -it --rm curl-test --restart=Never --image=curlimages/curl -- sh
   # Once inside the pod:
   curl -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' http://besu-node1-rpc.paladin:8545
   curl -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' http://besu-rpc-lb.paladin
   ```

### 502 Bad Gateway Errors

If you're seeing 502 errors, it usually means Traefik can't communicate with your backend Besu services:

1. **Check if Besu Pods are Running**:
   ```
   kubectl get pods -n paladin -l app=besu
   ```

2. **Check Endpoints**:
   ```
   kubectl get endpoints -n paladin | grep besu
   ```
   Verify that endpoints are properly registered.

3. **Check Besu Pod Logs**:
   ```
   kubectl logs -n paladin besu-node1-0
   ```
   Look for errors that might prevent the RPC API from working.

4. **Verify Network Policies**:
   Ensure no network policies are blocking communication between Traefik and Besu pods.

### WebSocket Connection Issues

If WebSocket connections are failing:

1. **Verify WebSocket Middleware**:
   ```
   kubectl describe middleware besu-ws-middleware -n paladin
   ```
   Ensure it's adding the required headers.

2. **Test WebSocket Connection**:
   ```
   # Using wscat (install with: npm install -g wscat)
   wscat -c ws://ws-besu.cluster.eita.cloud
   ```

## Advanced Troubleshooting

### Manual Connectivity Test

Run the external access testing script:
