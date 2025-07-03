#!/bin/bash

# Script para testar e verificar a configuração do Traefik

# Configurações
NAMESPACE="paladin"
TRAEFIK_NS="kube-system"

echo "🔍 Verificando configuração do Traefik..."

# Verificar pods do Traefik
echo "1️⃣ Verificando pods do Traefik..."
TRAEFIK_POD=$(kubectl get pods -n $TRAEFIK_NS -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || kubectl get pods -n $TRAEFIK_NS -l app=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$TRAEFIK_POD" ]; then
  echo "❌ ERROR: Nenhum pod do Traefik encontrado!"
  exit 1
else
  echo "✅ Pod do Traefik encontrado: $TRAEFIK_POD"
fi

# Verificar configuração dinâmica do Traefik
echo "2️⃣ Verificando configuração dinâmica do Traefik..."
echo "🔹 Rotas HTTP configuradas:"
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik http routers | grep -i "besu"

echo "🔹 Serviços HTTP configurados:"
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik http services | grep -i "besu"

echo "🔹 Middlewares HTTP configurados:"
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik http middlewares | grep -i "besu"

# Verificar se os provedores CRD estão ativos
echo "3️⃣ Verificando se o provedor CRD está ativo..."
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik providers

# Verificar entrypoints
echo "4️⃣ Verificando entrypoints configurados:"
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik entrypoints

# Verificar resolvedores de certificados
echo "5️⃣ Verificando resolvedores de certificados:"
kubectl exec -n $TRAEFIK_NS $TRAEFIK_POD -- traefik cert list || echo "❓ Nenhum resolvedor de certificado configurado ou comando não suportado"

# Verificar os recursos personalizados do Traefik
echo "6️⃣ Verificando recursos personalizados do Traefik no namespace $NAMESPACE:"
echo "🔹 IngressRoutes:"
kubectl get ingressroute -n $NAMESPACE -o wide

echo "🔹 TraefikServices:"
kubectl get traefikservice -n $NAMESPACE -o wide

echo "🔹 Middlewares:"
kubectl get middleware -n $NAMESPACE -o wide

# Verificar se há erros nos logs
echo "7️⃣ Verificando logs do Traefik por erros relacionados ao Besu:"
kubectl logs -n $TRAEFIK_NS $TRAEFIK_POD --tail=30 | grep -i "besu\|error\|warning" || echo "Nenhum erro encontrado nos logs recentes"

# Teste de conectividade direta aos serviços
echo "8️⃣ Testando acesso direto aos serviços via port-forward:"

# Lista de serviços para testar
SERVICES=("besu-node1-rpc:8545" "besu-node1-ws:8546" "besu-node1-graphql:8547")

for SVC_PORT in "${SERVICES[@]}"; do
  SVC=${SVC_PORT%:*}
  PORT=${SVC_PORT#*:}
  
  echo "🔹 Testando acesso ao serviço $SVC na porta $PORT..."
  
  # Use nohup para evitar que o port-forward seja interrompido
  nohup kubectl port-forward -n $NAMESPACE svc/$SVC $PORT:$PORT > /dev/null 2>&1 &
  PF_PID=$!
  
  # Aguarde um momento para o port-forward iniciar
  sleep 2
  
  # Para serviços RPC, tente uma solicitação JSON-RPC
  if [[ $SVC == *-rpc ]]; then
    echo "  Enviando solicitação JSON-RPC net_version..."
    curl -s -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
      http://localhost:$PORT
    echo  # Nova linha após a resposta
  elif [[ $SVC == *-ws ]]; then
    echo "  Verificando apenas se a porta está respondendo (WebSocket)..."
    curl -s --no-buffer -I http://localhost:$PORT
  else
    echo "  Verificando apenas se a porta está respondendo..."
    curl -s --no-buffer -I http://localhost:$PORT
  fi
  
  # Encerrar o port-forward
  kill $PF_PID 2>/dev/null
  wait $PF_PID 2>/dev/null || true
  
  echo "  Teste para $SVC concluído."
  echo
done

echo "✨ Verificação de configuração do Traefik concluída!"
