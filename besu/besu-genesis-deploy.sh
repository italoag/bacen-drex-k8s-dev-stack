#!/bin/bash
# Script para gerar genesis.json e chaves para os nodes Besu usando quorum-genesis-tool via npx
# Requer: Node.js, npx e yq instalados

set -e

WORKDIR="$(dirname "$0")"
VALUES_TEMPLATE="$WORKDIR/besu-genesis-values.yaml"
VALUES_FILE="$WORKDIR/tmp/besu-genesis-values.yaml"
OUTPUT_DIR="$WORKDIR/genesis-artifacts"
LOG_FILE="besu-genesis-deploy-$(date +%Y%m%d-%H%M%S).log"

# Função para logging
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a $LOG_FILE
}

# Verifica dependências
command -v npx >/dev/null 2>&1 || { echo >&2 "npx não encontrado. Instale Node.js."; exit 1; }
command -v yq >/dev/null 2>&1 || { echo >&2 "yq não encontrado. Instale yq para parsear YAML."; exit 1; }

# Lê parâmetros do YAML
CONSENSUS=$(yq '.consensus' "$VALUES_FILE")
CHAIN_ID=$(yq '.chainId' "$VALUES_FILE")
BLOCK_PERIOD=$(yq '.blockPeriod' "$VALUES_FILE")
EPOCH_LENGTH=$(yq '.epochLength' "$VALUES_FILE")
DIFFICULTY=$(yq '.difficulty' "$VALUES_FILE")
GAS_LIMIT=$(yq '.gasLimit' "$VALUES_FILE")
COINBASE=$(yq '.coinbase' "$VALUES_FILE")
VALIDATORS_COUNT=$(yq '.validators' "$VALUES_FILE")
MEMBERS_COUNT=$(yq '.members' "$VALUES_FILE")
BOOTNODES_COUNT=$(yq '.bootnodes' "$VALUES_FILE")
QUICKSTART_DEV_ACCOUNTS=$(yq '.quickstartDevAccounts' "$VALUES_FILE")


# Parametrização dinâmica
NODE_COUNT=${NODE_COUNT:-6}
CONSENSUS=${CONSENSUS:-qbft}
CHAIN_ID=${CHAIN_ID:-2025}
BLOCK_PERIOD=${BLOCK_PERIOD:-5}
EPOCH_LENGTH=${EPOCH_LENGTH:-30000}
REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-10}
DIFFICULTY=${DIFFICULTY:-1}
GAS_LIMIT=${GAS_LIMIT:-'0x1fffffffffffff'}
COINBASE=${COINBASE:-'0x0000000000000000000000000000000000000000'}
VALIDATORS=${VALIDATORS:-$NODE_COUNT}
MEMBERS=${MEMBERS:-1}
BOOTNODES=${BOOTNODES:-1}
QUICKSTART_DEV_ACCOUNTS=${QUICKSTART_DEV_ACCOUNTS:-false}

# Gerar YAML dinâmico
log "ℹ️ INFO" "Gerando arquivo de valores dinâmico para o genesis..."
export CONSENSUS CHAIN_ID BLOCK_PERIOD EPOCH_LENGTH REQUEST_TIMEOUT DIFFICULTY GAS_LIMIT COINBASE VALIDATORS MEMBERS BOOTNODES QUICKSTART_DEV_ACCOUNTS NODE_NAME
envsubst < "$VALUES_TEMPLATE" > "$VALUES_FILE"

# Criar diretório de saída
log "ℹ️ INFO" "Criando diretório de saída..."
mkdir -p "$OUTPUT_DIR"

# Executa quorum-genesis-tool via npx
log "ℹ️ INFO" "Executando quorum-genesis-tool..."
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
  --members "$MEMBERS" \
  --bootnodes "$BOOTNODES" \
  --outputPath "$OUTPUT_DIR" \
  --quickstartDevAccounts "$QUICKSTART_DEV_ACCOUNTS"

if [ $? -eq 0 ]; then
  log "ℹ️ INFO" "Genesis e chaves gerados em $OUTPUT_DIR."
else
  log "❌ ERROR" "Erro ao gerar genesis.json e chaves."
  exit 1
fi

# Gerar config.toml para cada nó
CONFIGS_DIR="$WORKDIR/configs"
mkdir -p "$CONFIGS_DIR"
for i in $(seq 1 $NODE_COUNT); do
  NODE_NAME="besu-node$i"
  DATA_PATH="/data/$NODE_NAME"
  GENESIS_PATH="$OUTPUT_DIR/besu/genesis.json"
  STATIC_NODES_PATH="$OUTPUT_DIR/besu/static-nodes.json"
  CONFIG_FILE="$CONFIGS_DIR/$NODE_NAME-config.toml"
  log "ℹ️ INFO" "Gerando $CONFIG_FILE ..."
  cat > "$CONFIG_FILE" <<EOF
data-path="$DATA_PATH"
genesis-file="$GENESIS_PATH"
revert-reason-enabled=true
logging="INFO"
nat-method="NONE"
min-gas-price=0
tx-pool="sequenced"
tx-pool-retention-hours=1
tx-pool-limit-by-account-percentage=1
tx-pool-max-size=2500
p2p-enabled=true
discovery-enabled=false
static-nodes-file="$STATIC_NODES_PATH"
p2p-port=30303
max-peers=25
remote-connections-limit-enabled=false
host-allowlist=["*"]
rpc-http-api=["DEBUG", "ETH", "ADMIN", "WEB3", "QBFT", "NET", "PERM", "TXPOOL", "PLUGINS", "MINER", "TRACE"]
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
rpc-ws-api=["DEBUG", "ETH", "ADMIN", "WEB3", "QBFT", "NET", "PERM", "TXPOOL", "PLUGINS", "MINER", "TRACE"]
rpc-ws-authentication-enabled=false
metrics-enabled=false
metrics-host="0.0.0.0"
metrics-port=9545
EOF
done
log "ℹ️ INFO" "Arquivos config.toml gerados para todos os nós em $CONFIGS_DIR."

# (Opcional) Criar ConfigMap/Secret no Kubernetes
# kubectl create configmap besu-genesis --from-file=$OUTPUT_DIR/besu/genesis.json -n <namespace>
