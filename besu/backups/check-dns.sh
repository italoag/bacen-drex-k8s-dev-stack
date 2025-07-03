#!/bin/bash

echo "Checking DNS resolution for rpc-besu.cluster.eita.cloud..."
nslookup rpc-besu.cluster.eita.cloud
dig rpc-besu.cluster.eita.cloud

echo "Checking if Traefik is handling the domain..."
kubectl get ingressroute -n paladin besu-rpc-route -o yaml
