#!/bin/bash
# Script robusto para deploy automatizado do Besu com Helm Charts
# Gera genesis/config, cria ConfigMaps/Secrets, monta values.yaml e faz deploy Helm

set -e

WORKDIR="$(dirname "$0")"
NAMESPACE="blockchain"
NODE_COUNT=${NODE_COUNT:-4}
JWT_SECRET=${JWT_SECRET:-"$(openssl rand -hex 32)"}
CHART_PATH="$WORKDIR/ethereum-helm-charts/charts/besu"
VALUES_TEMPLATE="$WORKDIR/besu-genesis-values.yaml"
VALUES_FILE="$WORKDIR/tmp/besu-genesis-values.yaml"
HELM_VALUES_FILE="$WORKDIR/besu-values.yaml"
OUTPUT_DIR="$WORKDIR/genesis-artifacts/besu"
CONFIGS_DIR="$WORKDIR/configs"
TMP_DIR="$WORKDIR/tmp"

ROLLBACK=false
RETRY=false

for arg in "$@"; do
  case $arg in
    --rollback)
      ROLLBACK=true
      ;;
    --retry)
      RETRY=true
      ;;
  esac
  shift
done

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log_success() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] \033[0;32m$1\033[0m"
}

log_error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] \033[0;31m$1\033[0m"
}

log_warning() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] \033[0;33m$1\033[0m"
}

if [ "$ROLLBACK" = true ]; then
  log "Executando rollback de todos os recursos do Besu..."
  helm uninstall besu -n "$NAMESPACE" || true
  kubectl delete configmap besu-config -n "$NAMESPACE" --ignore-not-found
  kubectl delete secret besu-jwt -n "$NAMESPACE" --ignore-not-found
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  rm -rf "$TMP_DIR" "$OUTPUT_DIR" "$CONFIGS_DIR" "$HELM_VALUES_FILE"
  log "Rollback concluído."
  exit 0
fi

mkdir -p "$TMP_DIR" "$OUTPUT_DIR" "$CONFIGS_DIR"

# Garantir que a namespace existe
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# Função para pegar o subdiretório datado mais recente após gerar os artefatos
encontrar_artefatos_besu() {
  local latest_dir
  latest_dir=$(ls -td "$OUTPUT_DIR"/*/ 2>/dev/null | head -1)
  if [ -z "$latest_dir" ]; then
    log_error "Nenhum diretório de artefatos encontrado em $OUTPUT_DIR"
    return 1
  fi
  
  if [ -d "$latest_dir/besu" ]; then
    echo "$latest_dir/besu"
  else
    echo "$latest_dir"
  fi
}

# 1. Gerar YAML dinâmico para quorum-genesis-tool
export NODE_COUNT
export CONSENSUS=qbft
export CHAIN_ID=2025
export BLOCK_PERIOD=5
export EPOCH_LENGTH=30000
export REQUEST_TIMEOUT=20
export DIFFICULTY=1
export GAS_LIMIT='0x1fffffffffffff'
export COINBASE='0x0000000000000000000000000000000000000000'
export VALIDATORS=$NODE_COUNT
export MEMBERS=0
export BOOTNODES=1
export QUICKSTART_DEV_ACCOUNTS=true
export SHANGHAI_TIME=0
export CANCUN_TIME=0

log "Gerando arquivo de valores dinâmico para o genesis..."
envsubst < "$VALUES_TEMPLATE" > "$VALUES_FILE"

# 2. Gerar artefatos (genesis.json, static-nodes.json, etc)
log "Gerando artefatos do genesis com quorum-genesis-tool..."
npx quorum-genesis-tool \
  --consensus "$CONSENSUS" \
  --chainID "$CHAIN_ID" \
  --blockperiod "$BLOCK_PERIOD" \
  --epochLength "$EPOCH_LENGTH" \
  --requestTimeout "$REQUEST_TIMEOUT" \
  --difficulty "$DIFFICULTY" \
  --gasLimit "$GAS_LIMIT" \
  --coinbase "$COINBASE" \
  --validators "$VALIDATORS" \
  --bootnodes "$BOOTNODES" \
  --outputPath "$OUTPUT_DIR" \
  --quickstartDevAccounts "$QUICKSTART_DEV_ACCOUNTS" \
  --shanghaiTime "$SHANGHAI_TIME" \
  --cancunTime "$CANCUN_TIME" \
  --constantinopleBlock 0 \
  --byzantiumBlock 0 \
  --homesteadBlock 0

log_success "Artefatos do genesis gerados com sucesso!"

# 3. Gerar config.toml para cada nó
for i in $(seq 0 $((NODE_COUNT-1))); do
  NODE_NAME="besu-$i"
  DATA_PATH="/data/$NODE_NAME"
  GENESIS_PATH="/config/genesis.json"
  CONFIG_FILE="$CONFIGS_DIR/config$i.toml"
  cat > "$CONFIG_FILE" <<EOF
data-path="$DATA_PATH"
genesis-file="$GENESIS_PATH"
data-storage-format="FOREST"
profile="ENTERPRISE"
revert-reason-enabled=true
logging="INFO"
nat-method="NONE"
min-gas-price=0
tx-pool="sequenced"
tx-pool-retention-hours=1
tx-pool-limit-by-account-percentage=1
tx-pool-max-size=2500
p2p-enabled=true
discovery-enabled=true
p2p-port=30303
max-peers=25
remote-connections-limit-enabled=false
host-allowlist=["*"]
rpc-http-apis=["DEBUG", "ETH", "ADMIN", "WEB3", "QBFT", "NET", "PERM", "TXPOOL", "PLUGINS", "MINER", "TRACE"]
consensus-protocol="QBFT"
miner-enabled=true
miner-coinbase="0x0000000000000000000000000000000000000000"
engine-rpc-enabled=false
network="dev"
rpc-http-cors-origins=["*"]
rpc-http-enabled=true
rpc-http-max-active-connections=2000
graphql-http-enabled=true
graphql-http-host="0.0.0.0"
graphql-http-port=8547
graphql-http-cors-origins=["*"]
rpc-ws-enabled=false
rpc-ws-host="0.0.0.0"
rpc-ws-port=8546
rpc-ws-apis=["DEBUG", "ETH", "ADMIN", "WEB3", "QBFT", "NET", "PERM", "TXPOOL", "PLUGINS", "MINER", "TRACE"]
rpc-ws-authentication-enabled=false
metrics-enabled=false
metrics-host="0.0.0.0"
metrics-port=9545
permissions-nodes-contract-enabled=true
permissions-nodes-contract-address="0x0000000000000000000000000000000000009999"
permissions-nodes-contract-version=2
permissions-accounts-contract-enabled=true
permissions-accounts-contract-address="0x359e4Ac15c34db530DC61C93D3E646103A569a0A"
EOF
done

# 4. Criar ConfigMap único para genesis/configs
log "Localizando artefatos do genesis..."
ARTEFATOS_BESU_DIR=$(encontrar_artefatos_besu)

if [ ! -d "$ARTEFATOS_BESU_DIR" ]; then
  log_error "Diretório de artefatos não encontrado: $ARTEFATOS_BESU_DIR"
  exit 1
fi

log_success "Artefatos do genesis encontrados em: $ARTEFATOS_BESU_DIR"

# Verificar se os arquivos necessários existem
if [ ! -f "$ARTEFATOS_BESU_DIR/genesis.json" ]; then
  log_error "Arquivo genesis.json não encontrado em $ARTEFATOS_BESU_DIR"
  ls -la "$ARTEFATOS_BESU_DIR"
  exit 1
fi

# Gerar static-nodes.json para cada nó
STATIC_NODES_JSON="$ARTEFATOS_BESU_DIR/static-nodes.json"
if [ -f "$STATIC_NODES_JSON" ]; then
  for j in $(seq 0 $((NODE_COUNT-1))); do
    OUT_FILE="$ARTEFATOS_BESU_DIR/static-nodes-$j.json"
    # Copiar o arquivo original
    cp "$STATIC_NODES_JSON" "$OUT_FILE.tmp"
    
    # Substituir <HOST> pelo DNS do pod
    if [ "$(uname)" = "Darwin" ]; then
      # macOS
      sed -i '' "s/@<HOST>:/@besu-$j.besu-headless.$NAMESPACE.svc.cluster.local:/g" "$OUT_FILE.tmp"
      sed -i '' 's/\(:[0-9][0-9]*\)"/\1?discport=0"/g' "$OUT_FILE.tmp"
    else
      # Linux
      sed -i "s/@<HOST>:/@besu-$j.besu-headless.$NAMESPACE.svc.cluster.local:/g" "$OUT_FILE.tmp"
      sed -i 's/\(:[0-9][0-9]*\)"/\1?discport=0"/g' "$OUT_FILE.tmp"
    fi
    
    # Remover o próprio nó usando jq
    jq "del(.[$j])" "$OUT_FILE.tmp" > "$OUT_FILE"
    
    # Limpar arquivos temporários
    rm -f "$OUT_FILE.tmp"
  done
fi

log "Criando ConfigMap 'besu-config' com genesis, static-nodes e configs individuais..."

# Construir o comando corretamente
CONFIGMAP_CMD="kubectl create configmap besu-config \
  --from-file=genesis.json=\"$ARTEFATOS_BESU_DIR/genesis.json\" \
"

# Adicionar static-nodes-*.json
for j in $(seq 0 $((NODE_COUNT-1))); do
  if [ -f "$ARTEFATOS_BESU_DIR/static-nodes-$j.json" ]; then
    CONFIGMAP_CMD="$CONFIGMAP_CMD  --from-file=static-nodes-$j.json=\"$ARTEFATOS_BESU_DIR/static-nodes-$j.json\" \
"
  fi
done

# Adicionar configs
for i in $(seq 0 $((NODE_COUNT-1))); do
  CONFIGMAP_CMD="$CONFIGMAP_CMD  --from-file=config$i.toml=$CONFIGS_DIR/config$i.toml \
"
done

# Finalizar comando
CONFIGMAP_CMD="$CONFIGMAP_CMD  -n $NAMESPACE --dry-run=client -o yaml"

# Executar comando
eval "$CONFIGMAP_CMD" | kubectl apply -f -

# 5. Gerar besu-values.yaml para Helm
log "Gerando arquivo besu-values.yaml para Helm..."
echo "replicas: $NODE_COUNT" > "$HELM_VALUES_FILE"
cat <<EOF >> "$HELM_VALUES_FILE"
extraVolumes:
  - name: besu-config
    configMap:
      name: besu-config
extraVolumeMounts:
  - name: besu-config
    mountPath: /config
command:
  - /bin/sh
  - -c
args:
  - |
    BESU_NODE_INDEX=${HOSTNAME##*-}
    # Ensure critical parameters are explicitly set to override any from config file
    exec /opt/besu/bin/besu \
      --genesis-file=/config/genesis.json \
      --config-file=/config/config${BESU_NODE_INDEX}.toml \
      --static-nodes-file=/config/static-nodes-${BESU_NODE_INDEX}.json \
      --discovery-enabled=true \
      --rpc-http-enabled=true \
      --rpc-http-api=ETH,NET,QBFT,ADMIN,DEBUG,WEB3,TXPOOL \
      --rpc-http-host=0.0.0.0 \
      --rpc-http-port=8545 \
      --rpc-http-cors-origins="*" \
      --host-allowlist="*" \
      --sync-mode=FULL \
      --data-storage-format=FOREST \
      --network=dev \
      --engine-rpc-enabled=false \
      --miner-enabled=true \
      --miner-coinbase=0x0000000000000000000000000000000000000000 \
      --consensus-protocol=QBFT
jwt: $JWT_SECRET
EOF

log "Arquivo besu-values.yaml gerado. Pronto para deploy Helm."

# 7. Deploy via Helm
# Remover Secret antigo se existir (para evitar conflito de ownership com Helm)
kubectl delete secret besu-jwt -n "$NAMESPACE" --ignore-not-found

log "Executando deploy/upgrade do Helm Chart..."
helm upgrade --install besu "$CHART_PATH" -f "$HELM_VALUES_FILE" -n "$NAMESPACE" --create-namespace

log_success "Deploy de Besu concluído!"

# Verificar status dos pods
log "Verificando status dos pods..."
sleep 5
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=besu

log "Para visualizar os logs de um nó específico, execute:"
log_success "kubectl logs -f besu-0 -n $NAMESPACE"

log "Para verificar se os nós estão sincronizando corretamente, execute:"
log_success "kubectl exec -it besu-0 -n $NAMESPACE -- curl -X POST --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_syncing\",\"params\":[],\"id\":1}' localhost:8545"

log "Deploy Helm finalizado com sucesso!"
