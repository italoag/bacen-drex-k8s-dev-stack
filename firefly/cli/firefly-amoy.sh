#!/bin/bash
firefly init ethereum amoy 1 \
    --multiparty=false \
    -n remote-rpc \
    --remote-node-url https://polygon-amoy.g.alchemy.com/v2/0hjEysojfCudnrbZCIQLq \
    --chain-id 80002 \
    --firefly-base-port 5005 \
    --connector-config ./polygon.yml
