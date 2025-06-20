#!/bin/bash

# Este script testa o acesso direto aos serviços Besu através de port-forward

NAMESPACE="paladin"

# Função para testar um serviço
test_service() {
  local service=$1
  local port=$2
  local method=$3
  
  echo "🔄 Testando acesso ao serviço $service na porta $port..."
  
  # Iniciar port-forward em background
  kubectl port-forward -n $NAMESPACE svc/$service $port:$port &
  local pf_pid=$!
  
  # Aguardar um momento para o port-forward iniciar
  sleep 2
  
  # Fazer requisição dependendo do método
  local response
  if [ "$method" = "rpc" ]; then
    echo "📤 Enviando requisição JSON-RPC (net_version)..."
    response=$(curl -s -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
      http://localhost:$port)
    echo "📥 Resposta: $response"
  elif [ "$method" = "ws" ]; then
    echo "📤 Verificando cabeçalhos WebSocket..."
    response=$(curl -s -I http://localhost:$port)
    echo "📥 Resposta: "
    echo "$response"
  else
    echo "📤 Verificando cabeçalhos HTTP..."
    response=$(curl -s -I http://localhost:$port)
    echo "📥 Resposta: "
    echo "$response"
  fi
  
  # Encerrar o port-forward
  kill $pf_pid 2>/dev/null
  wait $pf_pid 2>/dev/null || true
  echo
}

# Testar todos os serviços para o primeiro nó
echo "== Testando serviços RPC para Besu =="
test_service "besu-node1-rpc" 8545 "rpc"
test_service "besu-node1-ws" 8546 "ws"
test_service "besu-node1-graphql" 8547 "graphql"

echo "✅ Teste direto aos serviços Besu concluído!"
