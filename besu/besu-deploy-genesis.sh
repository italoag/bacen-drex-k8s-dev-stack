#!/bin/bash
# Script para gerar o Genesis file para a rede QBFT Besu utilizando K3s/Kubernetes
set -e

# Cores para a saída
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Função de log
log() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_success() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}$1${NC}"
}

log_warning() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}$1${NC}"
}

log_error() {
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}$1${NC}"
}

# Configurações
NAMESPACE="blockchain" 
NUM_VALIDATORS=4  # Para ambiente de teste, 4 validadores é suficiente (mínimo para QBFT é 4)
BESU_VERSION="24.12.2"
CHAIN_ID=22012022
# Diretório temporário para os arquivos gerados
OUTPUT_DIR="besu-genesis-temp"
mkdir -p $OUTPUT_DIR

# Verificar se o namespace existe (agora verificado pelo namespace-script.sh, mas mantemos a lógica defensiva)
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
  log_warning "Namespace $NAMESPACE não encontrado. Certifique-se de executar o namespace-script.sh primeiro."
  log "Tentando criar namespace $NAMESPACE..."
  kubectl create namespace $NAMESPACE
fi

log "Gerando chaves e configurações para $NUM_VALIDATORS validadores QBFT usando K3s/Kubernetes no namespace '$NAMESPACE'..."

# Criar um pod temporário para gerar as chaves e o genesis
# <<< ATUALIZADO o namespace no metadata
cat <<EOF > $OUTPUT_DIR/besu-genesis-generator.yaml
apiVersion: v1
kind: Pod
metadata:
  name: besu-genesis-generator
  namespace: $NAMESPACE
spec:
  containers:
  - name: besu
    image: hyperledger/besu:$BESU_VERSION
    command: ["tail", "-f", "/dev/null"] 
    volumeMounts:
    - name: genesis-data
      mountPath: /data
  volumes:
  - name: genesis-data
    emptyDir: {}
  restartPolicy: Never
EOF

# Aplicar a configuração do pod
kubectl apply -f $OUTPUT_DIR/besu-genesis-generator.yaml

# Aguardar até que o pod esteja pronto
log "Aguardando o pod besu-genesis-generator ficar pronto no namespace $NAMESPACE..."
kubectl wait --for=condition=Ready pod/besu-genesis-generator -n $NAMESPACE --timeout=120s

# Gerar as chaves para os validadores DENTRO do pod
log "Gerando chaves para validadores QBFT dentro do pod..."
ALL_KEYS_JSON="{\"keys\":[]}"
VALIDATOR_ADDRESSES=""

# Verificar a versão do Besu (para propósitos de diagnóstico)
kubectl exec besu-genesis-generator -n $NAMESPACE -- besu --version

for i in $(seq 1 $NUM_VALIDATORS); do
  log "Gerando chaves para validador $i..."
  
  # Remover diretório anterior se existir
  kubectl exec besu-genesis-generator -n $NAMESPACE -- rm -rf /data/validator$i
  
  # Criar arquivo de configuração compatível com Besu 24.12.2
  cat <<EOF > $OUTPUT_DIR/config-$i.json
{
  "genesis": {
    "config": {
      "chainId": $CHAIN_ID,
      "berlinBlock": 0,
      "pragueBlock": 0,
      "londonBlock": 0,
      "shanghaiTime": 0,
      "cancunTime": 0,
      "qbft": {
        "blockperiodseconds": 5,
        "epochlength": 30000,
        "requesttimeoutseconds": 20
      }
    }
  },
  "blockchain": {
    "nodes": {
      "generate": true,
      "count": 1
    }
  }
}
EOF
  
  # Copiar config para o pod e gerar a chave
  kubectl cp $OUTPUT_DIR/config-$i.json $NAMESPACE/besu-genesis-generator:/data/config-$i.json
  kubectl exec besu-genesis-generator -n $NAMESPACE -- bash -c "besu operator generate-blockchain-config --config-file=/data/config-$i.json --to=/data/validator$i"
  
  # Encontrar o arquivo de chave e extrair para um local conhecido
  KEY_FILE=$(kubectl exec besu-genesis-generator -n $NAMESPACE -- find /data/validator$i -name "key.priv" | head -1)
  
  if [ -n "$KEY_FILE" ]; then
    # Copiar chave privada para local conhecido
    kubectl exec besu-genesis-generator -n $NAMESPACE -- cp "$KEY_FILE" "/data/key-$i"
    
    # Encontrar o diretório onde está a chave (para obter o endereço do validador)
    KEY_DIR=$(dirname "$KEY_FILE")
    ADDRESS=$(basename $(dirname "$KEY_FILE"))
    
    # Copiar a chave pública já existente (não precisamos gerar novamente)
    PUB_KEY_FILE="$KEY_DIR/key.pub"
    kubectl exec besu-genesis-generator -n $NAMESPACE -- cp "$PUB_KEY_FILE" "/data/key-$i.pub"
    
    # Salvar o endereço em um arquivo
    kubectl exec besu-genesis-generator -n $NAMESPACE -- bash -c "echo '$ADDRESS' > /data/address-$i.txt"
    
    # Ler a chave pública
    PUBLIC_KEY=$(kubectl exec besu-genesis-generator -n $NAMESPACE -- cat /data/key-$i.pub)
    
    # Adicionar à lista de endereços (sem "0x" no início para comando rlp encode)
    ADDRESS_WITHOUT_PREFIX=${ADDRESS#0x}
    VALIDATOR_ADDRESSES+="$ADDRESS\n"
    ALL_KEYS_JSON=$(echo $ALL_KEYS_JSON | jq --argjson i "$i" --arg pubkey "$PUBLIC_KEY" --arg address "$ADDRESS" '.keys += [{"index": $i, "publicKey": $pubkey, "address": $address}]')
    log_success "Chaves geradas para o validador $i (Endereço: $ADDRESS)"
  else
    log_error "Não foi possível encontrar o arquivo de chave para o validador $i"
    kubectl exec besu-genesis-generator -n $NAMESPACE -- find /data/validator$i -ls
    exit 1
  fi
done

# Remover nova linha final da lista de endereços e tratar formato para uso posterior
VALIDATOR_ADDRESSES=$(echo -e "$VALIDATOR_ADDRESSES" | sed '/^$/d')

# Extrair os ENDEREÇOS dos validadores para o genesis (QBFT usa endereços)
log "Extraindo endereços dos validadores para o genesis..."

# Gerar arquivo de configuração para o genesis
log "Gerando configuração para o genesis (genesis-config.json)..."

# Criar string de alocação manualmente
ALLOC_JSON="{"
for ADDR in $VALIDATOR_ADDRESSES; do
  ALLOC_JSON+="\"$ADDR\": { \"balance\": \"1000000000000000000000\" },"
done
# Remover a última vírgula
ALLOC_JSON=${ALLOC_JSON%,}
ALLOC_JSON+="}"

# Criar lista de validadores para RLP encode (formato CSV)
VALIDATOR_LIST_CMD=$(echo "$VALIDATOR_ADDRESSES" | tr '\n' ',' | sed 's/,$//')

cat <<EOF > $OUTPUT_DIR/genesis-config.json
{
  "config": {
    "chainId": $CHAIN_ID,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "muirGlacierBlock": 0,
    "berlinBlock": 0,
    "arrowGlacierBlock": 0,
    "grayGlacierBlock": 0,
    "mergeNetSplitBlock": 0,
    "londonBlock": 0,
    "pragueTime": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "qbft": {
      "epochLength": 30000,
      "blockPeriodSeconds": 5,
      "requestTimeoutSeconds": 20,
      "policy": "qbft"
    }
  },
  "nonce": "0x0",
  "timestamp": "0x0",
  "extraData": "0x",
  "gasLimit": "0x1fffffffffffff",
  "difficulty": "0x1",
  "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "coinbase": "0x0000000000000000000000000000000000000000",
  "alloc": $ALLOC_JSON,
  "number": "0x0",
  "gasUsed": "0x0",
  "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "baseFeePerGas": "0x3b9aca00"
}
EOF

# Copiar a configuração para o pod
kubectl cp $OUTPUT_DIR/genesis-config.json $NAMESPACE/besu-genesis-generator:/data/genesis-config.json

# Gerar o genesis.json no pod usando a configuração e os validadores
log "Gerando o genesis.json no pod..."
# Criar arquivo com lista de validadores (um por linha) no pod
kubectl exec besu-genesis-generator -n $NAMESPACE -- bash -c "rm -f /data/validators.txt"
for ADDR in $VALIDATOR_ADDRESSES; do
  kubectl exec besu-genesis-generator -n $NAMESPACE -- bash -c "echo '$ADDR' >> /data/validators.txt"
done

# Versão 24.12.2 do Besu: Permitir que o Besu gere o extraData automaticamente
# Em vez de definir manualmente o extraData, vamos usar o Besu para gerar o genesis completo
log "Gerando o genesis.json com o Besu para configurar corretamente o extraData para QBFT"

# Criar um arquivo de configuração do QBFT que inclui os validadores
VALIDATORS_JSON="["
for ADDR in $VALIDATOR_ADDRESSES; do
  VALIDATORS_JSON+="\"$ADDR\","
done
# Remover a última vírgula
VALIDATORS_JSON=${VALIDATORS_JSON%,}
VALIDATORS_JSON+="]"

# Criar arquivo de configuração QBFT completo
cat <<EOF > $OUTPUT_DIR/qbft-config.json
{
  "genesis": {
    "config": {
      "chainId": $CHAIN_ID,
      "shanghaiTime": 0,
      "cancunTime": 0,
      "qbft": {
        "epochLength": 30000,
        "blockPeriodSeconds": 5,
        "requestTimeoutSeconds": 20
      }
    },
    "nonce": "0x0",
    "timestamp": "0x0",
    "gasLimit": "0x1fffffffffffff",
    "difficulty": "0x1",
    "mixHash": "0x63746963616c2062797a616e74696e65206661756c7420746f6c6572616e6365",
    "coinbase": "0x0000000000000000000000000000000000000000",
    "alloc": $ALLOC_JSON
  },
  "blockchain": {
    "nodes": {
      "generate": true,
      "count": 4
    }
  },
  "qbft": {
    "validators": $VALIDATORS_JSON,
    "blockperiodseconds": 5,
    "epochlength": 30000,
    "requesttimeoutseconds": 20
  }
}
EOF

# Copiar a configuração para o pod
kubectl cp $OUTPUT_DIR/qbft-config.json $NAMESPACE/besu-genesis-generator:/data/qbft-config.json

# Usar o Besu para gerar o genesis.json correto com o extraData adequado para QBFT
kubectl exec besu-genesis-generator -n $NAMESPACE -- bash -c "besu operator generate-blockchain-config --config-file=/data/qbft-config.json --to=/data/genesis-output"

# Verificar se o genesis foi gerado corretamente
GENESIS_PATH=$(kubectl exec besu-genesis-generator -n $NAMESPACE -- find /data/genesis-output -name "genesis.json" | head -1)
if [ -z "$GENESIS_PATH" ]; then
  log_error "Falha ao gerar genesis.json com Besu."
  kubectl logs besu-genesis-generator -n $NAMESPACE --tail=20
  exit 1
fi

# Copiar o genesis.json gerado pelo Besu para o local correto
kubectl exec besu-genesis-generator -n $NAMESPACE -- cp "$GENESIS_PATH" /data/genesis.json

# Verificar se o genesis foi gerado
if ! kubectl exec besu-genesis-generator -n $NAMESPACE -- test -f /data/genesis.json; then
  log_error "Falha ao gerar genesis.json no pod."
  kubectl logs besu-genesis-generator -n $NAMESPACE --tail=20
  exit 1
fi
log_success "Arquivo genesis.json gerado com sucesso no pod."

# Listar os arquivos gerados para debug
log "Listando arquivos gerados no pod (/data):"
kubectl exec besu-genesis-generator -n $NAMESPACE -- find /data -ls

# Copiar o genesis.json para o diretório local
log "Copiando genesis.json do pod para $OUTPUT_DIR/genesis.json..."
kubectl cp $NAMESPACE/besu-genesis-generator:/data/genesis.json $OUTPUT_DIR/genesis.json
if [ ! -f "$OUTPUT_DIR/genesis.json" ]; then
    log_error "Falha ao copiar genesis.json do pod."
    exit 1
fi
log_success "genesis.json copiado para o diretório local."


# Criar ConfigMap com o genesis.json
log "Criando ConfigMap 'besu-genesis' no namespace '$NAMESPACE'..."
kubectl create configmap besu-genesis --from-file=$OUTPUT_DIR/genesis.json -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
log_success "ConfigMap 'besu-genesis' criado."

# Copiar as chaves dos validadores para ConfigMaps
log "Criando ConfigMaps para as chaves dos validadores no namespace '$NAMESPACE'..."
for i in $(seq 1 $NUM_VALIDATORS); do
  # Copiar chave privada, pública e endereço do pod para o diretório local temporário
  kubectl cp $NAMESPACE/besu-genesis-generator:/data/key-$i $OUTPUT_DIR/key-$i
  kubectl cp $NAMESPACE/besu-genesis-generator:/data/key-$i.pub $OUTPUT_DIR/key-$i.pub
  kubectl cp $NAMESPACE/besu-genesis-generator:/data/address-$i.txt $OUTPUT_DIR/address-$i.txt

  # Verificar se os arquivos foram copiados
  if [ ! -f "$OUTPUT_DIR/key-$i" ] || [ ! -f "$OUTPUT_DIR/key-$i.pub" ] || [ ! -f "$OUTPUT_DIR/address-$i.txt" ]; then
      log_error "Falha ao copiar arquivos de chave/endereço do pod para o validador $i."
      exit 1
  fi

  # Criar ConfigMap para o validador i
  CONFIGMAP_NAME="besu-validator$i-keys"
  kubectl create configmap $CONFIGMAP_NAME \
    --from-file=key=$OUTPUT_DIR/key-$i \
    --from-file=key.pub=$OUTPUT_DIR/key-$i.pub \
    --from-file=address=$OUTPUT_DIR/address-$i.txt \
    -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

  log_success "ConfigMap '$CONFIGMAP_NAME' criado."

  # Limpar arquivos locais temporários
  rm $OUTPUT_DIR/key-$i $OUTPUT_DIR/key-$i.pub $OUTPUT_DIR/address-$i.txt
done

# Limpar o pod gerador
log "Limpando o pod besu-genesis-generator..."
kubectl delete pod besu-genesis-generator -n $NAMESPACE --ignore-not-found=true

# Limpar diretório temporário local (opcional)
# rm -rf $OUTPUT_DIR

log_success "Geração do Genesis e chaves dos validadores concluída com sucesso!"