#!/bin/bash
firefly init ethereum polygon 1 \
    --multiparty=false \
    -n remote-rpc \
    --remote-node-url https://polygon-mainnet.g.alchemy.com/v2/0hjEysojfCudnrbZCIQLq \
    --chain-id 80001 \
    --firefly-base-port 5005 \
    --node-name polygon-node \
    --org-name polygon \
    --connector-config ./polygon.yml
