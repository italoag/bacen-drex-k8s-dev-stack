#!/usr/bin/env bash
# Script para limpeza completa do Kafka e Strimzi
set -Eeuo pipefail

NS=kafka
KAFKA_CLUSTER=cluster

log(){ printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){ printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }
warn(){ printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

echo "🧹 Limpeza completa do Kafka/Strimzi"
echo "Isso vai remover:"
echo "  - Cluster Kafka '$KAFKA_CLUSTER'"
echo "  - Todos os recursos Strimzi"
echo "  - Operador Strimzi"
echo "  - Namespace '$NS'"
echo ""
read -rp "Continuar? [y/N]: " confirm
[[ $confirm =~ ^[Yy]$ ]] || { echo "Cancelado."; exit 0; }

### 1 ─ Remove Kafka cluster e recursos Strimzi
log "Removendo cluster Kafka e recursos Strimzi..."
kubectl -n "$NS" delete $(kubectl get strimzi -o name -n "$NS" 2>/dev/null) || true

### 2 ─ Remove PVCs
log "Removendo Persistent Volume Claims..."
kubectl delete pvc -l strimzi.io/name="$KAFKA_CLUSTER"-kafka -n "$NS" || true

### 3 ─ Remove operador Strimzi
log "Removendo operador Strimzi..."
kubectl -n "$NS" delete -f "https://strimzi.io/install/latest?namespace=$NS" || true

# Se operador estiver em namespace diferente, tentar remover globalmente
if kubectl get deployment strimzi-cluster-operator -A >/dev/null 2>&1; then
  OPERATOR_NS=$(kubectl get deployment strimzi-cluster-operator -A -o jsonpath='{.items[0].metadata.namespace}')
  warn "Operador ainda existe em namespace: $OPERATOR_NS"
  read -rp "Remover operador do namespace $OPERATOR_NS? [y/N]: " remove_operator
  if [[ $remove_operator =~ ^[Yy]$ ]]; then
    kubectl -n "$OPERATOR_NS" delete -f "https://strimzi.io/install/latest?namespace=$OPERATOR_NS" || true
  fi
fi

### 4 ─ Remove namespace
log "Removendo namespace $NS..."
kubectl delete namespace "$NS" || true

log "✅ Limpeza concluída!"
log "Para reinstalar, execute: ./deploy-kafka.sh"
