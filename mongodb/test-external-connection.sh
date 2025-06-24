#!/bin/bash
# Script para testar conectividade externa do MongoDB
set -e

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

ROOT_PASS="${MONGODB_ROOT_PASSWORD:-drex123456}"

echo "🔐 Teste de Conectividade Externa MongoDB"
echo "=========================================="

# Verificar se mongosh está disponível
if ! command -v mongosh >/dev/null 2>&1; then
    error "mongosh não está instalado"
    info "Para instalar no macOS: brew install mongosh"
    exit 1
fi

# Verificar se a porta 27017 está ocupada
info "Verificando porta 27017..."
if command -v lsof >/dev/null 2>&1; then
    PORT_CHECK=$(lsof -i :27017 2>/dev/null | grep LISTEN || echo "")
    if [[ -n "$PORT_CHECK" ]]; then
        warn "Porta 27017 está ocupada:"
        echo "$PORT_CHECK"
        info "Isso pode ser um port-forward. Continuando teste..."
    else
        info "Porta 27017 está livre"
    fi
fi

# Teste 1: Conectividade simples
info "Teste 1: Conectividade simples (sem autenticação)..."
if timeout 5 mongosh --host localhost --port 27017 --eval 'quit()' >/dev/null 2>&1; then
    info "✅ Conectividade básica OK!"
else
    error "❌ Falha na conectividade básica"
    info "Pode haver um problema com hostNetwork ou conflito de porta"
    exit 1
fi

# Teste 2: Ping sem autenticação
info "Teste 2: Ping do banco (sem auth)..."
if mongosh --host localhost --port 27017 --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
    info "✅ MongoDB está respondendo!"
else
    warn "⚠️ MongoDB pode não estar respondendo adequadamente"
fi

# Teste 3: Autenticação com usuário root
info "Teste 3: Autenticação com usuário root..."
if mongosh --host localhost --port 27017 \
           --username root --password "$ROOT_PASS" \
           --authenticationDatabase admin \
           --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
    info "✅ Autenticação com root funcionando!"
else
    error "❌ Falha na autenticação com root"
    info "Verifique se a senha está correta: \$MONGODB_ROOT_PASSWORD"
fi

# Teste 4: Listar bancos de dados
info "Teste 4: Listando bancos de dados..."
if mongosh --host localhost --port 27017 \
           --username root --password "$ROOT_PASS" \
           --authenticationDatabase admin \
           --eval 'db.adminCommand("listDatabases")' 2>/dev/null | grep -q '"databases"'; then
    info "✅ Listagem de bancos funcionando!"
    
    # Mostrar bancos disponíveis
    info "Bancos disponíveis:"
    mongosh --quiet --host localhost --port 27017 \
            --username root --password "$ROOT_PASS" \
            --authenticationDatabase admin \
            --eval 'db.adminCommand("listDatabases").databases.forEach(db => print("  - " + db.name))' 2>/dev/null || true
else
    warn "⚠️ Não foi possível listar bancos"
fi

# Teste 5: Criar um documento de teste
info "Teste 5: Teste de escrita (documento de teste)..."
if mongosh --host localhost --port 27017 \
           --username root --password "$ROOT_PASS" \
           --authenticationDatabase admin \
           --eval 'use testdb; db.test.insertOne({message: "Hello from MongoDB!", timestamp: new Date()})' 2>/dev/null | grep -q 'acknowledged'; then
    info "✅ Escrita funcionando!"
    
    # Ler o documento de volta
    info "Lendo documento de teste..."
    mongosh --quiet --host localhost --port 27017 \
            --username root --password "$ROOT_PASS" \
            --authenticationDatabase admin \
            --eval 'use testdb; db.test.findOne()' 2>/dev/null | head -5 || true
else
    warn "⚠️ Falha no teste de escrita"
fi

echo ""
info "🎉 Teste de conectividade concluído!"
echo ""
info "📝 Comando para conectar manualmente:"
echo "mongosh --host localhost --port 27017 -u root -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase admin"
echo ""
info "🔗 String de conexão:"
echo "mongodb://root:\$MONGODB_ROOT_PASSWORD@localhost:27017/admin"
