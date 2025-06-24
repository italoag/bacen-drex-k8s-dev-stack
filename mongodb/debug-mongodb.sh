#!/bin/bash
# Script de diagnóstico detalhado para MongoDB
set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

NS=database

echo "🔍 Diagnóstico Detalhado MongoDB"
echo "================================"

# 1. Status detalhado do pod
info "1. Status detalhado do pod mongodb-0:"
kubectl -n "$NS" describe pod mongodb-0 | tail -20

echo ""

# 2. Logs do container mongod
info "2. Logs recentes do container mongod:"
kubectl -n "$NS" logs mongodb-0 -c mongod --tail=10

echo ""

# 3. Logs do container mongodb-agent
info "3. Logs recentes do container mongodb-agent:"
kubectl -n "$NS" logs mongodb-0 -c mongodb-agent --tail=10

echo ""

# 4. Teste de execução de comando simples
info "4. Testando execução de comando simples:"
if kubectl -n "$NS" exec mongodb-0 -c mongod -- echo "Container accessible" 2>/dev/null; then
    info "✅ Container é acessível"
else
    error "❌ Container não é acessível"
fi

echo ""

# 5. Verificar se mongosh existe no container
info "5. Verificando se mongosh existe no container:"
if kubectl -n "$NS" exec mongodb-0 -c mongod -- which mongosh 2>/dev/null; then
    info "✅ mongosh encontrado"
else
    warn "⚠️ mongosh não encontrado, tentando mongo..."
    if kubectl -n "$NS" exec mongodb-0 -c mongod -- which mongo 2>/dev/null; then
        info "✅ mongo encontrado"
    else
        error "❌ Nem mongosh nem mongo encontrados"
    fi
fi

echo ""

# 6. Teste de conectividade MongoDB sem autenticação
info "6. Testando conectividade MongoDB (sem auth):"
if kubectl -n "$NS" exec mongodb-0 -c mongod -- mongosh --eval 'db.runCommand({ping:1})' 2>/dev/null; then
    info "✅ MongoDB respondendo"
else
    error "❌ MongoDB não está respondendo"
    info "Tentando com mongo legacy..."
    if kubectl -n "$NS" exec mongodb-0 -c mongod -- mongo --eval 'db.runCommand({ping:1})' 2>/dev/null; then
        info "✅ MongoDB respondendo (via mongo legacy)"
    else
        error "❌ MongoDB não está respondendo nem via mongo legacy"
    fi
fi

echo ""

# 7. Status do MongoDBCommunity detalhado
info "7. Status detalhado do MongoDBCommunity:"
kubectl -n "$NS" describe mongodbcommunity mongodb | grep -A 20 "Status:"

echo ""

# 8. Verificar se o processo MongoDB está rodando
info "8. Verificando processos MongoDB no container:"
kubectl -n "$NS" exec mongodb-0 -c mongod -- ps aux | grep mongod || echo "Nenhum processo mongod encontrado"

echo ""

info "✅ Diagnóstico concluído!"
