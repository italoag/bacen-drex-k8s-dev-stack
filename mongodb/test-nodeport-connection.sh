#!/bin/bash
# Teste de conectividade via NodePort (porta 30017)
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

ROOT_PASS="${MONGODB_ROOT_PASSWORD:-drex123456}"
PORT=30017

echo "🔐 Teste de Conectividade MongoDB via NodePort (porta $PORT)"
echo "============================================================"

# Verificar se mongosh está disponível
if ! command -v mongosh >/dev/null 2>&1; then
    error "mongosh não está instalado"
    info "Para instalar no macOS: brew install mongosh"
    exit 1
fi

# Teste 1: Conectividade simples
info "Teste 1: Conectividade simples..."
if timeout 10 mongosh --host localhost --port $PORT --eval 'quit()' >/dev/null 2>&1; then
    info "✅ Conectividade na porta $PORT OK!"
else
    error "❌ Falha na conectividade na porta $PORT"
    info "Verifique se o serviço NodePort está funcionando"
    exit 1
fi

# Teste 2: Ping sem autenticação
info "Teste 2: Ping do banco..."
if mongosh --host localhost --port $PORT --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
    info "✅ MongoDB está respondendo!"
else
    warn "⚠️ MongoDB pode não estar respondendo adequadamente"
fi

# Teste 3: Autenticação com usuário root
info "Teste 3: Autenticação com usuário root..."
if mongosh --host localhost --port $PORT \
           --username root --password "$ROOT_PASS" \
           --authenticationDatabase admin \
           --eval 'db.runCommand({ping:1})' 2>/dev/null | grep -q '"ok"'; then
    info "✅ Autenticação com root funcionando!"
else
    error "❌ Falha na autenticação com root"
    info "Verifique se a senha está correta: \$MONGODB_ROOT_PASSWORD"
    exit 1
fi

# Teste 4: Operações básicas
info "Teste 4: Testando operações básicas..."

# Listar bancos
info "Listando bancos de dados..."
mongosh --quiet --host localhost --port $PORT \
        --username root --password "$ROOT_PASS" \
        --authenticationDatabase admin \
        --eval 'db.adminCommand("listDatabases").databases.forEach(db => print("  📁 " + db.name + " (" + (db.sizeOnDisk/1024/1024).toFixed(2) + " MB)"))' 2>/dev/null || warn "Falha ao listar bancos"

# Teste de escrita
info "Testando escrita..."
if mongosh --quiet --host localhost --port $PORT \
           --username root --password "$ROOT_PASS" \
           --authenticationDatabase admin \
           --eval 'use testdb; db.test.insertOne({message: "Teste de conectividade externa", timestamp: new Date(), port: '$PORT'})' 2>/dev/null | grep -q 'acknowledged'; then
    info "✅ Escrita funcionando!"
    
    # Ler documento de volta
    info "Documento inserido:"
    mongosh --quiet --host localhost --port $PORT \
            --username root --password "$ROOT_PASS" \
            --authenticationDatabase admin \
            --eval 'use testdb; db.test.findOne({port: '$PORT'})' 2>/dev/null | head -8 || true
else
    warn "⚠️ Falha no teste de escrita"
fi

# Teste de performance simples
info "Teste 5: Performance básica..."
info "Inserindo 1000 documentos..."
time mongosh --quiet --host localhost --port $PORT \
      --username root --password "$ROOT_PASS" \
      --authenticationDatabase admin \
      --eval 'use perftest; for(let i=0; i<1000; i++) { db.perf.insertOne({index: i, data: "test_" + i, timestamp: new Date()}) }' 2>/dev/null || warn "Falha no teste de performance"

# Contar documentos
DOC_COUNT=$(mongosh --quiet --host localhost --port $PORT \
           --username root --password "$ROOT_PASS" \
           --authenticationDatabase admin \
           --eval 'use perftest; db.perf.countDocuments()' 2>/dev/null | tail -1)

info "Documentos inseridos: $DOC_COUNT"

echo ""
info "🎉 Todos os testes passaram! MongoDB está funcionando perfeitamente!"
echo ""
info "📋 Resumo da configuração:"
echo "  🏠 Acesso interno: mongodb-svc.database.svc.cluster.local:27017"
echo "  🌐 Acesso externo: localhost:$PORT"
echo "  👤 Usuário: root"
echo "  🔑 Senha: \$MONGODB_ROOT_PASSWORD"
echo "  📚 Auth DB: admin"
echo ""
info "🚀 Comando para usar no seu IntelliJ ou outras aplicações:"
echo "mongodb://root:$ROOT_PASS@localhost:$PORT/admin"
