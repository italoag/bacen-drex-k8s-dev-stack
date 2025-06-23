#!/usr/bin/env bash
# Script para verificar pré-requisitos e status do Kafka
set -Eeuo pipefail

NS=kafka
KAFKA_CLUSTER=cluster

log(){ printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){ printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }
warn(){ printf '\e[33m[WARN]\e[0m %s\n' "$*"; }
ok(){ printf '\e[32m[OK  ]\e[0m  %s\n' "$*"; }

echo "🔍 Verificação do ambiente Kafka/Strimzi"
echo "========================================"

### 1 ─ Verificar kubectl
log "Verificando kubectl..."
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL_VERSION=$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion' 2>/dev/null || kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo "unknown")
  ok "kubectl encontrado: $KUBECTL_VERSION"
else
  err "kubectl não encontrado!"
fi

### 2 ─ Verificar conexão com cluster
log "Verificando conexão com cluster Kubernetes..."
if kubectl cluster-info >/dev/null 2>&1; then
  CLUSTER_INFO=$(kubectl cluster-info | head -1 | sed 's/.*running at //' | sed 's/\x1b\[[0-9;]*m//g')
  ok "Conectado ao cluster: $CLUSTER_INFO"
else
  err "Não foi possível conectar ao cluster Kubernetes!"
  exit 1
fi

### 3 ─ Verificar namespace
log "Verificando namespace $NS..."
if kubectl get ns "$NS" >/dev/null 2>&1; then
  ok "Namespace $NS existe"
else
  warn "Namespace $NS não existe"
fi

### 4 ─ Verificar operador Strimzi
log "Verificando operador Strimzi..."
if kubectl get deployment strimzi-cluster-operator -n "$NS" >/dev/null 2>&1; then
  STATUS=$(kubectl get deployment strimzi-cluster-operator -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
  if [[ "$STATUS" == "True" ]]; then
    ok "Operador Strimzi está rodando no namespace $NS"
  else
    warn "Operador Strimzi existe mas não está disponível no namespace $NS"
  fi
elif kubectl get deployment strimzi-cluster-operator -A >/dev/null 2>&1; then
  OPERATOR_NS=$(kubectl get deployment strimzi-cluster-operator -A -o jsonpath='{.items[0].metadata.namespace}')
  warn "Operador Strimzi encontrado em namespace diferente: $OPERATOR_NS"
else
  err "Operador Strimzi não encontrado!"
fi

### 5 ─ Verificar cluster Kafka
log "Verificando cluster Kafka..."
if kubectl get kafka "$KAFKA_CLUSTER" -n "$NS" >/dev/null 2>&1; then
  STATUS=$(kubectl get kafka "$KAFKA_CLUSTER" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$STATUS" == "True" ]]; then
    ok "Cluster Kafka '$KAFKA_CLUSTER' está pronto"
  else
    warn "Cluster Kafka '$KAFKA_CLUSTER' existe mas não está pronto (Status: $STATUS)"
  fi
else
  warn "Cluster Kafka '$KAFKA_CLUSTER' não encontrado"
fi

### 6 ─ Verificar pods
log "Verificando pods..."
echo "Pods no namespace $NS:"
kubectl get pods -n "$NS" 2>/dev/null || echo "Nenhum pod encontrado"

### 7 ─ Verificar serviços
log "Verificando serviços..."
echo "Serviços no namespace $NS:"
kubectl get svc -n "$NS" 2>/dev/null || echo "Nenhum serviço encontrado"

### 8 ─ Verificar NodePorts
log "Verificando NodePorts..."
if kubectl get svc -n "$NS" -l strimzi.io/cluster="$KAFKA_CLUSTER" 2>/dev/null | grep -q NodePort; then
  echo "Serviços NodePort encontrados:"
  kubectl get svc -n "$NS" -l strimzi.io/cluster="$KAFKA_CLUSTER" -o wide 2>/dev/null | grep NodePort || true
else
  warn "Nenhum serviço NodePort encontrado para o cluster $KAFKA_CLUSTER"
fi

### 9 ─ Verificar conectividade externa
log "Verificando conectividade externa..."
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
if [[ -n "$NODE_IP" ]]; then
  ok "IP do node: $NODE_IP"
  
  # Verificar portas NodePort específicas
  for PORT in 31094 31095 31096 31097; do
    if nc -z -w 2 "$NODE_IP" "$PORT" 2>/dev/null; then
      ok "Porta $PORT está acessível"
    else
      warn "Porta $PORT não está acessível"
    fi
  done
else
  err "Não foi possível obter IP do node"
fi

### 10 ─ Verificar recursos computacionais
log "Verificando recursos do cluster..."
echo "Nodes:"
kubectl get nodes -o wide 2>/dev/null || echo "Erro ao obter nodes"

echo ""
echo "Uso de recursos:"
kubectl top nodes 2>/dev/null || echo "Metrics server não disponível"

### 11 ─ Logs recentes
log "Logs recentes do operador (últimas 10 linhas)..."
if kubectl get deployment strimzi-cluster-operator -n "$NS" >/dev/null 2>&1; then
  kubectl logs deployment/strimzi-cluster-operator -n "$NS" --tail=10 2>/dev/null || echo "Erro ao obter logs"
elif kubectl get deployment strimzi-cluster-operator -A >/dev/null 2>&1; then
  OPERATOR_NS=$(kubectl get deployment strimzi-cluster-operator -A -o jsonpath='{.items[0].metadata.namespace}')
  kubectl logs deployment/strimzi-cluster-operator -n "$OPERATOR_NS" --tail=10 2>/dev/null || echo "Erro ao obter logs"
else
  echo "Operador não encontrado"
fi

echo ""
echo "🔍 Verificação concluída!"
echo "Para deploy: ./deploy-kafka.sh"
echo "Para limpeza: ./cleanup-kafka.sh"
