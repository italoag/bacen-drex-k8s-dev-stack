#!/bin/bash
# Script para criar acesso externo via NodePort
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

NS=database
SERVICE_NAME=mongodb-external

info "🌐 Configurando acesso externo ao MongoDB via NodePort"
echo "======================================================"

# Criar serviço NodePort
info "Criando serviço NodePort..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $NS
  labels:
    app: mongodb-external
spec:
  type: NodePort
  ports:
  - port: 27017
    targetPort: 27017
    nodePort: 30017
    protocol: TCP
    name: mongodb
  selector:
    app: mongodb-svc
EOF

# Verificar se o serviço foi criado
info "Verificando serviço criado..."
kubectl -n "$NS" get svc "$SERVICE_NAME"

# Obter a porta NodePort
NODE_PORT=$(kubectl -n "$NS" get svc "$SERVICE_NAME" -o jsonpath='{.spec.ports[0].nodePort}')
info "Serviço criado na porta: $NODE_PORT"

echo ""
info "🔗 Informações de acesso externo:"
echo "  Host: localhost:$NODE_PORT"
echo "  Usuário: root"
echo "  Senha: \$MONGODB_ROOT_PASSWORD"
echo "  Auth DB: admin"
echo ""
info "📝 Comando de teste:"
echo "mongosh --host localhost --port $NODE_PORT -u root -p \$MONGODB_ROOT_PASSWORD --authenticationDatabase admin"
echo ""
info "🔗 String de conexão:"
echo "mongodb://root:\$MONGODB_ROOT_PASSWORD@localhost:$NODE_PORT/admin"
