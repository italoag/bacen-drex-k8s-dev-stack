#!/bin/bash
# Script de teste para MongoDB - Compatível com macOS
set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Configurações
NS=database
RELEASE=mongodb
ROOT_PASS="${MONGODB_ROOT_PASSWORD:-drex123456}"

echo "🧪 Teste de Conectividade MongoDB"
echo "=================================="

# 1. Teste do status dos pods
info "1. Verificando status dos pods..."
kubectl -n "$NS" get pods | grep mongodb

# 2. Teste do status do MongoDBCommunity
info "2. Verificando status do MongoDBCommunity..."
kubectl -n "$NS" get mongodbcommunity

# 3. Teste de conectividade direta (via kubectl exec)
info "3. Testando conectividade direta via kubectl exec..."
if kubectl -n "$NS" exec mongodb-0 -c mongod -- mongosh --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
    info "✅ Conexão direta OK!"
else
    error "❌ Falhou conexão direta"
fi

# 4. Verificar se a porta 27017 está sendo usada
info "4. Verificando porta 27017..."
if command -v lsof >/dev/null 2>&1; then
    PORT_INFO=$(lsof -i :27017 2>/dev/null || echo "Porta livre")
    echo "$PORT_INFO"
else
    warn "Comando lsof não disponível no macOS (pode precisar instalar)"
fi

# 5. Teste de conectividade externa (se mongosh estiver disponível)
info "5. Testando conectividade externa..."
if command -v mongosh >/dev/null 2>&1; then
    info "Comando mongosh encontrado, testando conexão..."
    
    # Teste simples de conectividade (timeout de 5 segundos)
    if timeout 5 mongosh --host localhost --port 27017 --eval 'quit()' >/dev/null 2>&1; then
        info "✅ Conectividade externa OK!"
        
        # Teste com autenticação
        info "Testando autenticação..."
        if mongosh --host localhost --port 27017 \
                   --username root --password "$ROOT_PASS" \
                   --authenticationDatabase admin \
                   --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
            info "✅ Autenticação com usuário root OK!"
        else
            warn "⚠️ Falhou autenticação (mas conectividade funciona)"
        fi
    else
        warn "⚠️ Não foi possível conectar externamente"
        info "Isso pode acontecer se:"
        info "  - A porta 27017 estiver ocupada por outro processo"
        info "  - Houver um port-forward ativo"
        info "  - O hostNetwork não estiver funcionando corretamente"
    fi
else
    warn "Comando mongosh não encontrado"
    info "Para instalar mongosh no macOS:"
    info "  brew install mongosh"
    info "Ou baixe de: https://www.mongodb.com/try/download/shell"
fi

# 6. Informações de conexão
info "6. Informações de conexão:"
echo ""
echo "🔗 Conexão interna (dentro do cluster):"
echo "   Host: mongodb-svc.database.svc.cluster.local:27017"
echo ""
echo "🔗 Conexão externa (hostNetwork):"
echo "   Host: localhost:27017"
echo ""
echo "👤 Credenciais:"
echo "   Usuário root: root"
echo "   Senha: \$MONGODB_ROOT_PASSWORD"
echo "   Auth DB: admin"
echo ""
echo "🧪 Teste manual:"
echo "   mongosh --host localhost --port 27017 -u root -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase admin"
echo ""

# 7. Verificar se há conflitos de porta
info "7. Verificando possíveis conflitos..."
if command -v netstat >/dev/null 2>&1; then
    info "Processos escutando na porta 27017:"
    netstat -an | grep :27017 || echo "Nenhum processo encontrado"
else
    warn "Comando netstat não disponível"
fi

echo ""
info "✅ Teste concluído!"
