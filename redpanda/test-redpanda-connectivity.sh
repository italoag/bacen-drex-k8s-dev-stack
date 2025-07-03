#!/bin/bash

set -e

# Funções para saída colorida
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

log() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

header() {
  echo -e "\n${BOLD}$1${NC}"
  echo "========================================"
}

# Verifica se rpk está instalado
if ! command -v rpk &> /dev/null; then
  error "rpk não está instalado. Por favor, instale o Redpanda Tools primeiro."
  echo "Instruções: https://docs.redpanda.com/docs/install-upgrade/rpk-install/"
  exit 1
fi

# Obtém informações do cluster Redpanda
header "VERIFICANDO DEPLOYMENT DO REDPANDA"

# Verifica se o namespace redpanda existe
if ! kubectl get namespace redpanda &> /dev/null; then
  error "Namespace redpanda não encontrado. O Redpanda está instalado?"
  exit 1
fi

log "Namespace redpanda encontrado"

# Verifica se o StatefulSet está em execução
EXPECTED_REPLICAS=$(kubectl -n redpanda get statefulset redpanda -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
READY_REPLICAS=$(kubectl -n redpanda get statefulset redpanda -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [ "$EXPECTED_REPLICAS" = "0" ]; then
  error "StatefulSet redpanda não encontrado"
  exit 1
elif [ "$READY_REPLICAS" != "$EXPECTED_REPLICAS" ]; then
  warn "StatefulSet redpanda: $READY_REPLICAS/$EXPECTED_REPLICAS réplicas prontas"
else
  log "StatefulSet redpanda: $READY_REPLICAS/$EXPECTED_REPLICAS réplicas prontas ✅"
fi

# Obtém o IP do nó
header "VERIFICANDO CONECTIVIDADE"
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
if [ -z "$NODE_IP" ]; then
  NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  warn "IP externo não encontrado, usando IP interno: $NODE_IP"
else
  log "IP externo encontrado: $NODE_IP"
fi

# Obtém portas NodePort
NODEPORT_BROKER=$(kubectl -n redpanda get svc redpanda-external -o jsonpath='{.spec.ports[?(@.name=="kafka-default")].nodePort}')
NODEPORT_ADMIN=$(kubectl -n redpanda get svc redpanda-external -o jsonpath='{.spec.ports[?(@.name=="admin-default")].nodePort}')
NODEPORT_SCHEMA=$(kubectl -n redpanda get svc redpanda-external -o jsonpath='{.spec.ports[?(@.name=="schema-default")].nodePort}')

if [ -z "$NODEPORT_BROKER" ]; then
  error "Não foi possível encontrar NodePort para o broker Kafka"
  exit 1
else
  log "NodePort para Kafka: $NODEPORT_BROKER"
fi

# Verificar se o certificado CA existe
SECRET_FOUND=false
CERT_PATH="/tmp/ca.crt"

# Verificando diferentes nomes de secrets possíveis
CERT_SECRETS=(
  "redpanda-external-ca"        # Nome atual 
  "redpanda-external-cert"      # Variações antigas
  "redpanda-external-root-certificate"
)

for SECRET_NAME in "${CERT_SECRETS[@]}"; do
  if kubectl -n redpanda get secret "$SECRET_NAME" &>/dev/null; then
    log "Certificado encontrado: $SECRET_NAME"
    
    # Tentar extrair o certificado
    if kubectl -n redpanda get secret "$SECRET_NAME" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$CERT_PATH" && [ -s "$CERT_PATH" ]; then
      SECRET_FOUND=true
      log "Certificado CA extraído com sucesso para $CERT_PATH"
      break
    elif kubectl -n redpanda get secret "$SECRET_NAME" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$CERT_PATH" && [ -s "$CERT_PATH" ]; then
      SECRET_FOUND=true
      log "Certificado TLS extraído com sucesso para $CERT_PATH"
      break
    fi
  fi
done

if ! $SECRET_FOUND; then
  warn "Certificado CA não encontrado, o TLS pode não estar configurado"
fi

# Tentar obter o hostname configurado de várias maneiras
DOMAIN=""

# Método 1: Obter do configmap
if [ -z "$DOMAIN" ]; then
  DOMAIN=$(kubectl -n redpanda get cm redpanda -o jsonpath='{.data.redpanda\.yaml}' 2>/dev/null | grep -o "advertised_kafka_addr:.*" | awk '{print $2}' | head -1 || echo "")
  [ -n "$DOMAIN" ] && log "Domínio obtido do ConfigMap redpanda: $DOMAIN"
fi

# Método 2: Obter do ingress
if [ -z "$DOMAIN" ]; then
  DOMAIN=$(kubectl -n redpanda get ingress redpanda-console -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
  [ -n "$DOMAIN" ] && log "Domínio obtido do Ingress do console: $DOMAIN"
fi

# Método 3: Usar o valor do nodeport ou node IP como último recurso
if [ -z "$DOMAIN" ]; then
  warn "Não foi possível determinar o domínio configurado, usando IP do nó"
  DOMAIN="$NODE_IP"
fi

if [ -n "$DOMAIN" ]; then
  log "Domínio configurado: $DOMAIN"

  # Verifica resolução DNS
  log "Verificando resolução DNS para $DOMAIN..."
  if host "$DOMAIN" &> /dev/null; then
    IP_RESOLVED=$(host "$DOMAIN" | grep "has address" | head -1 | awk '{print $4}')
    log "Domínio $DOMAIN resolve para $IP_RESOLVED ✅"
  else
    warn "Domínio $DOMAIN não resolve para um IP"
    
    # Verifica se o domínio está no /etc/hosts
    if grep -q "$DOMAIN" /etc/hosts; then
      IP_IN_HOSTS=$(grep "$DOMAIN" /etc/hosts | awk '{print $1}')
      log "Domínio $DOMAIN encontrado em /etc/hosts apontando para $IP_IN_HOSTS"
    else
      warn "Domínio $DOMAIN não encontrado em /etc/hosts."
      warn "Considere adicionar: $NODE_IP $DOMAIN"
    fi
  fi
else
  warn "Não foi possível determinar o domínio configurado"
  DOMAIN="$NODE_IP"
fi

# Testar conectividade
header "TESTANDO CONEXÕES AO REDPANDA"

log "1. Tentando conexão com TLS usando hostname (se disponível)..."
if [ "$SECRET_FOUND" = "true" ] && [ "$DOMAIN" != "$NODE_IP" ]; then
  if rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER" --tls-enabled --tls-truststore /tmp/ca.crt &> /dev/null; then
    log "✅ Conexão com TLS usando hostname: SUCESSO"
    rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER" --tls-enabled --tls-truststore /tmp/ca.crt
  else
    warn "❌ Conexão com TLS usando hostname: FALHOU"
  fi
else
  warn "Pulando teste de TLS com hostname (certificado não encontrado ou domínio não configurado)"
fi

log "2. Tentando conexão sem TLS usando IP..."
if rpk cluster info --brokers "$NODE_IP:$NODEPORT_BROKER" &> /dev/null; then
  log "✅ Conexão sem TLS usando IP: SUCESSO"
  rpk cluster info --brokers "$NODE_IP:$NODEPORT_BROKER"
else
  warn "❌ Conexão sem TLS usando IP: FALHOU"
fi

log "3. Tentando conexão sem TLS usando hostname (se disponível)..."
if [ "$DOMAIN" != "$NODE_IP" ]; then
  if rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER" &> /dev/null; then
    log "✅ Conexão sem TLS usando hostname: SUCESSO"
    rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER"
  else
    warn "❌ Conexão sem TLS usando hostname: FALHOU"
  fi
else
  warn "Pulando teste sem TLS usando hostname (domínio não configurado)"
fi

# Interface do console
header "VERIFICANDO ACESSO AO CONSOLE"
CONSOLE_URL="https://$DOMAIN"
INGRESS_HOST=$(kubectl -n redpanda get ingress redpanda-console -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")

if [ -n "$INGRESS_HOST" ]; then
  log "Console configurado em: https://$INGRESS_HOST"
  
  if [ "$INGRESS_HOST" != "$DOMAIN" ]; then
    warn "O hostname do ingress ($INGRESS_HOST) é diferente do domínio do Kafka ($DOMAIN)"
  fi

  # Testar se o endpoint responde
  if curl -s -k -o /dev/null -w "%{http_code}" "https://$INGRESS_HOST" &> /dev/null; then
    STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" "https://$INGRESS_HOST")
    if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ]; then
      log "✅ Console acessível em https://$INGRESS_HOST (status $STATUS)"
    else
      warn "⚠️ Console responde com status $STATUS em https://$INGRESS_HOST"
    fi
  else
    warn "❌ Console não está respondendo em https://$INGRESS_HOST"
  fi
else
  warn "Ingress do console não encontrado"
fi

# Limpar arquivo temporário
rm -f /tmp/ca.crt &> /dev/null || true

header "RESUMO DE CONECTIVIDADE"
echo "Para se conectar ao cluster Redpanda, use um dos seguintes comandos:"
echo ""
echo -e "${GREEN}# Via IP sem TLS:${NC}"
echo "rpk cluster info --brokers $NODE_IP:$NODEPORT_BROKER"
echo ""

if [ "$SECRET_FOUND" = "true" ]; then
  echo -e "${GREEN}# Via hostname com TLS (recomendado para produção):${NC}"
  echo "kubectl -n redpanda get secret redpanda-external-ca -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/ca.crt"
  echo "rpk cluster info --brokers $DOMAIN:$NODEPORT_BROKER --tls-enabled --tls-truststore /tmp/ca.crt"
  echo ""
fi

if [ "$DOMAIN" != "$NODE_IP" ]; then
  echo -e "${GREEN}# Via hostname sem TLS:${NC}"
  echo "rpk cluster info --brokers $DOMAIN:$NODEPORT_BROKER"
  echo ""
fi

if [ -n "$INGRESS_HOST" ]; then
  echo -e "${GREEN}# Console web:${NC}"
  echo "https://$INGRESS_HOST"
  echo ""
fi
