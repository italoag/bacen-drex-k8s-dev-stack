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

# Verificar se o namespace existe
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
  log "Criando namespace $NAMESPACE..."
  kubectl create namespace $NAMESPACE
fi

log "Gerando chaves e configurações para $NUM_VALIDATORS validadores QBFT usando K3s/Kubernetes..."

# Criar um pod temporário para gerar as chaves e o genesis
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
    command: ["sh", "-c", "mkdir -p /data && sleep 3600"]
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
log "Aguardando o pod besu-genesis-generator ficar pronto..."
kubectl wait --for=condition=Ready pod/besu-genesis-generator -n $NAMESPACE --timeout=60s

# Gerar as chaves para os validadores
log "Gerando chaves para validadores QBFT..."
for i in $(seq 1 $NUM_VALIDATORS); do
  kubectl exec besu-genesis-generator -n $NAMESPACE -- mkdir -p /data/validator$i
  kubectl exec besu-genesis-generator -n $NAMESPACE -- besu --data-path=/data/validator$i public-key export --to=/data/validator$i/key.pub
  log_success "Chaves geradas para o validador $i"
done

# Extrair as chaves públicas
log "Extraindo chaves públicas para o genesis..."
PUB_KEYS=""
for i in $(seq 1 $NUM_VALIDATORS); do
  KEY=$(kubectl exec besu-genesis-generator -n $NAMESPACE -- cat /data/validator$i/key.pub)
  PUB_KEYS="$PUB_KEYS\"$KEY\", "
done
PUB_KEYS=${PUB_KEYS%, }

# Gerar arquivo de configuração para o genesis
log "Gerando configuração para o genesis..."
cat <<EOF > $OUTPUT_DIR/genesis-config.json
{
  "genesis": {
    "config": {
      "chainId": $CHAIN_ID,
      "shanghaiTime": 0,
      "qbft": {
        "blockperiodseconds": 5,
        "epochlength": 30000,
        "requesttimeoutseconds": 60
      }
    },
    "nonce": "0x0",
    "timestamp": "0x0",
    "gasLimit": "0x1fffffffffffff",
    "difficulty": "0x1",
    "mixHash": "0x63746963616c2062797a616e74696e65206661756c7420746f6c6572616e6365",
    "coinbase": "0x0000000000000000000000000000000000000000",
    "alloc": {},
    "extraData": "0xf87aa00000000000000000000000000000000000000000000000000000000000000000f8549434c58c57bf65aa18e0c2b4a19bb92a6a58fd58f0943f8c302d3dee725e1a3c23057df51c334bf10594e12ad3d778604507b7495abeb0b5d8b4b69c30c94f94b66b80fdf32ef05501a2439ad1f2e5e8d2abbffa80c0"
  },
  "blockchain": {
    "nodes": {
      "generate": true,
      "count": $NUM_VALIDATORS
    }
  }
}
EOF

# Copiar a configuração para o pod
kubectl cp $OUTPUT_DIR/genesis-config.json $NAMESPACE/besu-genesis-generator:/data/genesis-config.json

# Remover diretório de saída se já existir
log "Removendo diretório de saída se existir..."
kubectl exec besu-genesis-generator -n $NAMESPACE -- rm -rf /data/networkFiles

# Gerar o genesis.json no pod
log "Gerando o genesis.json no pod..."
kubectl exec besu-genesis-generator -n $NAMESPACE -- besu operator generate-blockchain-config --config-file=/data/genesis-config.json --to=/data/networkFiles --private-key-file-name=key

# Verificar se o genesis foi gerado
if ! kubectl exec besu-genesis-generator -n $NAMESPACE -- ls -la /data/networkFiles/genesis.json; then
  log_error "Falha ao gerar o genesis.json"
  kubectl logs besu-genesis-generator -n $NAMESPACE
  exit 1
fi

# Listar os arquivos gerados para debug
log "Listando arquivos gerados no pod:"
kubectl exec besu-genesis-generator -n $NAMESPACE -- find /data -type f | sort

# Copiar o genesis.json para o diretório local
kubectl cp $NAMESPACE/besu-genesis-generator:/data/networkFiles/genesis.json $OUTPUT_DIR/genesis.json

# Criar ConfigMap com o genesis.json
log "Criando ConfigMap para o genesis..."
kubectl create configmap besu-genesis \
  --from-file=$OUTPUT_DIR/genesis.json \
  -n $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

# Copiar as chaves dos validadores para ConfigMaps
log "Criando ConfigMaps para as chaves dos validadores..."
for i in $(seq 1 $NUM_VALIDATORS); do
  # Verificar onde estão as chaves no pod
  log "Verificando arquivos para o validador $i..."
  
  # Copiar chave pública (já sabemos que existe)
  kubectl cp $NAMESPACE/besu-genesis-generator:/data/validator$i/key.pub $OUTPUT_DIR/validator$i-key.pub
  
  # Verificar onde está a chave privada
  KEY_LOCATIONS=(
    "/data/networkFiles/keys/validator$i/key"
    "/data/networkFiles/validator$i/key"
    "/data/validator$i/key"
  )
  
  KEY_FOUND=false
  for loc in "${KEY_LOCATIONS[@]}"; do
    if kubectl exec besu-genesis-generator -n $NAMESPACE -- test -f "$loc" 2>/dev/null; then
      log_success "Chave privada encontrada em $loc"
      kubectl cp $NAMESPACE/besu-genesis-generator:$loc $OUTPUT_DIR/validator$i-key
      KEY_FOUND=true
      break
    fi
  done
  
  if [ "$KEY_FOUND" != "true" ]; then
    # Última tentativa: procurar a chave em qualquer lugar
    KEY_PATH=$(kubectl exec besu-genesis-generator -n $NAMESPACE -- find /data -name key -type f 2>/dev/null | grep -v "key.pub" | head -1)
    if [ -n "$KEY_PATH" ]; then
      log_warning "Chave encontrada em caminho alternativo: $KEY_PATH"
      kubectl cp $NAMESPACE/besu-genesis-generator:$KEY_PATH $OUTPUT_DIR/validator$i-key
      KEY_FOUND=true
    else
      log_error "Não foi possível encontrar a chave privada para o validador $i"
      # Gerar uma chave manualmente como último recurso
      log_warning "Gerando uma nova chave privada para o validador $i"
      kubectl exec besu-genesis-generator -n $NAMESPACE -- besu --data-path=/data/new-validator$i public-key export --to=/data/new-validator$i/key.pub
      kubectl cp $NAMESPACE/besu-genesis-generator:/data/new-validator$i/key $OUTPUT_DIR/validator$i-key
      KEY_FOUND=true
    fi
  fi
  
  if [ "$KEY_FOUND" = "true" ]; then
    # Criar ConfigMap para as chaves
    kubectl create configmap besu-validator$i-keys \
      --from-file=key.pub=$OUTPUT_DIR/validator$i-key.pub \
      --from-file=key=$OUTPUT_DIR/validator$i-key \
      -n $NAMESPACE \
      --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "ConfigMap 'besu-validator$i-keys' criado com sucesso"
  else
    log_error "Não foi possível criar o ConfigMap para o validador $i"
  fi
done

# Excluir o pod temporário
log "Limpando recursos temporários..."
kubectl delete pod besu-genesis-generator -n $NAMESPACE

# Atualizar o arquivo besu-install-values.yaml para usar os ConfigMaps de chaves
log "Configurando besu-install-values.yaml para usar os ConfigMaps de chaves..."
if [ -f "besu-install-values.yaml" ]; then
  # Fazer backup do arquivo original
  cp besu-install-values.yaml besu-install-values.yaml.bak
  
  # Atualizar o número de validadores - usando abordagem compatível com BSD e GNU sed
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS (BSD sed)
    sed -i '' "s/numValidators:[ ]*[0-9]*/numValidators: $NUM_VALIDATORS/" besu-install-values.yaml
  else
    # Linux (GNU sed)
    sed -i "s/numValidators:[ ]*[0-9]*/numValidators: $NUM_VALIDATORS/" besu-install-values.yaml
  fi
  
  # Adicionar configuração para usar os ConfigMaps de chaves
  # Primeiro, verificar se a seção validators já existe
  if grep -q "validators:" besu-install-values.yaml; then
    log_warning "Seção 'validators' já existe em besu-install-values.yaml. Pulando adição automática."
  else
    cat <<EOF >> besu-install-values.yaml

# Configuração para usar ConfigMaps de chaves para os validadores
validators:
EOF

    for i in $(seq 1 $NUM_VALIDATORS); do
      cat <<EOF >> besu-install-values.yaml
  validator$i:
    keysConfigMap:
      name: besu-validator$i-keys
EOF
    done
    
    log_success "Arquivo besu-install-values.yaml atualizado para usar os ConfigMaps de chaves"
  fi
else
  log_warning "Arquivo besu-install-values.yaml não encontrado. Você precisará configurar manualmente os validadores."
fi

log_success "Genesis e chaves gerados com sucesso!"
log "ConfigMap 'besu-genesis' criado com sucesso no namespace '$NAMESPACE'"
log "ConfigMaps para as chaves dos $NUM_VALIDATORS validadores criados com sucesso"
log "Você pode prosseguir com a instalação do Besu usando o script install-besu.sh"

# Manter os arquivos para referência
log "Os arquivos gerados estão disponíveis em $OUTPUT_DIR para referência"