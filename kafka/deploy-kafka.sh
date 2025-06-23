#!/usr/bin/env bash
# Deploy / upgrade Kafka usando Strimzi (instalação manual) e validar endpoints
set -Eeuo pipefail

KAFKA_CLUSTER=cluster
NS=kafka
VALUES=strimzi-values.yaml
TIMEOUT=600s # Tempo suficiente para o Kafka inicializar

ISSUER=selfsigned          # ClusterIssuer (se necessário para TLS)
DOMAIN=kafka.localhost     # host público
KAFKA_PLAIN=31094          # Porta NodePort para PLAINTEXT
KAFKA_TLS=31096            # Porta NodePort para TLS

log(){ printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){ printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }
warn(){ printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

rollback(){ 
  kubectl delete kafka "$KAFKA_CLUSTER" -n "$NS" --wait=false || true
  kubectl delete kafkanodepool kafka -n "$NS" --wait=false || true
}
trap 'err "Falha linha $LINENO"; read -rp "Rollback? [y/N]: " a && [[ $a =~ ^[Yy]$ ]] && rollback' ERR

retry(){ local n=1 max=$1; shift; until "$@"; do [ $n -ge $max ] && return 1; warn "retry $n/$max…"; sleep 10; n=$((n+1)); done; }

### 1 ─ Verificar namespace
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

### 2 ─ Verificar se operador Strimzi existe
log "Verificando se operador Strimzi está instalado..."
if kubectl get deployment strimzi-cluster-operator -n "$NS" >/dev/null 2>&1; then
  log "✅ Operador Strimzi encontrado no namespace $NS"
elif kubectl get deployment strimzi-cluster-operator -A >/dev/null 2>&1; then
  OPERATOR_NS=$(kubectl get deployment strimzi-cluster-operator -A -o jsonpath='{.items[0].metadata.namespace}')
  log "✅ Operador Strimzi encontrado no namespace $OPERATOR_NS"
  log "⚠️  Operador está em namespace diferente, mas pode funcionar"
else
  log "❌ Operador Strimzi não encontrado. Instalando via método manual..."
  log "Aplicando instalação manual do Strimzi..."
  kubectl create -f "https://strimzi.io/install/latest?namespace=$NS" -n "$NS"
fi

### 3 ─ Wait for operator
log "Aguardando operator ficar pronto..."
# Tentar primeiro no namespace kafka, depois globalmente
if kubectl get deployment strimzi-cluster-operator -n "$NS" >/dev/null 2>&1; then
  retry 20 kubectl -n "$NS" wait deployment/strimzi-cluster-operator --for=condition=available --timeout="$TIMEOUT"
else
  log "Procurando operador em outros namespaces..."
  OPERATOR_NS=$(kubectl get deployment strimzi-cluster-operator -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
  if [[ -n "$OPERATOR_NS" ]]; then
    log "Operador encontrado em namespace: $OPERATOR_NS"
    retry 20 kubectl -n "$OPERATOR_NS" wait deployment/strimzi-cluster-operator --for=condition=available --timeout="$TIMEOUT"
  else
    err "Operador Strimzi não encontrado em nenhum namespace"
    exit 1
  fi
fi

### 4 ─ Deploy Kafka Cluster
log "Aplicando configuração do Kafka Cluster..."
kubectl apply -f "$VALUES" -n "$NS"

### 5 ─ Wait for Kafka cluster
log "Aguardando cluster Kafka ficar pronto..."
retry 30 kubectl -n "$NS" wait kafka/"$KAFKA_CLUSTER" --for=condition=Ready --timeout="$TIMEOUT"

### 6 ─ Wait for external services
log "Aguardando serviços externos ficarem prontos..."
retry 20 kubectl -n "$NS" get svc/"$KAFKA_CLUSTER"-kafka-external-bootstrap || log "Serviço externo pode não estar pronto ainda"

### 7 ─ Create Ingress for Kafka (optional)
log "Criando Ingress para Kafka..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kafka-ingress
  namespace: $NS
  annotations:
    kubernetes.io/ingress.class: traefik
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
    - host: $DOMAIN
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${KAFKA_CLUSTER}-kafka-external-bootstrap
                port:
                  number: 9094
EOF

### 8 ─ Descobre IP público e informações de conectividade
log "Obtendo informações para conexão..."
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Obter informações dos serviços externos
log "Verificando serviços externos criados pelo Strimzi..."
kubectl -n "$NS" get svc -l strimzi.io/cluster="$KAFKA_CLUSTER" -l strimzi.io/kind=Kafka

# Descobrir NodePorts reais dos serviços externos
EXTERNAL_BOOTSTRAP_NODEPORT=$(kubectl -n "$NS" get svc "$KAFKA_CLUSTER"-kafka-external-bootstrap -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
log "NodePort do bootstrap externo: $EXTERNAL_BOOTSTRAP_NODEPORT"

# Usar as portas configuradas ou descobrir dinamicamente
if [[ "$EXTERNAL_BOOTSTRAP_NODEPORT" != "N/A" ]]; then
  KAFKA_PLAIN="$EXTERNAL_BOOTSTRAP_NODEPORT"
fi

log "Usando endereço $NODE_IP e NodePort $KAFKA_PLAIN para validação"

### 9 ─ Validações básicas
# Teste porta NodePort externa
log "Testando conexão no NodePort $KAFKA_PLAIN..."
if nc -z -w 5 "$NODE_IP" "$KAFKA_PLAIN" 2>/dev/null; then
  log "✅ Porta $KAFKA_PLAIN está respondendo!"
else
  warn "❌ Porta $KAFKA_PLAIN não está respondendo ainda. Continuando anyway..."
fi

# Teste com kafka CLI se disponível
if command -v kafka-console-producer.sh >/dev/null; then
  log "Kafka CLI encontrada, testando conexão..."
  if timeout 10 kafka-topics.sh --bootstrap-server "$NODE_IP:$KAFKA_PLAIN" --list >/dev/null 2>&1; then
    log "✅ Kafka CLI conectou com sucesso!"
  else
    warn "❌ Kafka CLI não conseguiu conectar (pode ignorar em ambiente de desenvolvimento)"
  fi
fi

# Teste com kcat se disponível
if command -v kcat >/dev/null; then
  log "kcat encontrado, testando conexão..."
  if timeout 10 kcat -b "$NODE_IP:$KAFKA_PLAIN" -L >/dev/null 2>&1; then
    log "✅ kcat conectou com sucesso!"
  else
    warn "❌ kcat não conseguiu conectar (pode ignorar em ambiente de desenvolvimento)"
  fi
fi

### 10 ─ Verifica DNS
log "Verificando resolução de DNS para $DOMAIN..."
if ping -c1 "$DOMAIN" &>/dev/null; then
  log "DNS para $DOMAIN está OK!"
else
  warn "DNS para $DOMAIN não está resolvendo. Verifique sua configuração do dnsmasq."
  log "Adicione no /etc/hosts: $NODE_IP $DOMAIN"
fi

### 11 ─ Info final
cat <<EOF

🎉  Deploy do Kafka concluído.

Verifique:
1. Resolução DNS: $DOMAIN deve apontar para $NODE_IP
2. Adicione no /etc/hosts se necessário:
   $NODE_IP  $DOMAIN

Endpoints:
Kafka PLAINTEXT (NodePort) → $NODE_IP:$KAFKA_PLAIN
Kafka TLS (NodePort)       → $NODE_IP:$KAFKA_TLS
Kafka Interno PLAINTEXT    → $KAFKA_CLUSTER-kafka-bootstrap.$NS.svc.cluster.local:9092
Kafka Interno TLS          → $KAFKA_CLUSTER-kafka-bootstrap.$NS.svc.cluster.local:9093

Para verificação adicional, execute:
kubectl -n $NS get all
kubectl -n $NS get kafka
kubectl -n $NS get kafkanodepool
kubectl -n $NS describe kafka/$KAFKA_CLUSTER

Para conectar ao Kafka externamente:
kafka-console-producer.sh --bootstrap-server $NODE_IP:$KAFKA_PLAIN --topic test
kafka-console-consumer.sh --bootstrap-server $NODE_IP:$KAFKA_PLAIN --topic test --from-beginning

Para conectar com kcat:
kcat -b $NODE_IP:$KAFKA_PLAIN -L
kcat -b $NODE_IP:$KAFKA_PLAIN -t test -P  # Producer
kcat -b $NODE_IP:$KAFKA_PLAIN -t test -C  # Consumer

EOF

# Listar tópicos disponíveis
log "Listando tópicos disponíveis..."
kubectl -n "$NS" get kafkatopic || log "Nenhum tópico personalizado encontrado ainda"

# Mostrar logs do cluster para debug se necessário
log "Status do cluster Kafka:"
kubectl -n "$NS" get kafka "$KAFKA_CLUSTER" -o wide

log "✅ Deploy concluído com sucesso!"
