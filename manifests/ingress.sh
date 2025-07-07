#!/bin/bash
set -euo pipefail

NAMESPACE=kube-system
DASHBOARD_HOST="traefik.cluster.eita.cloud"
BASIC_AUTH_SECRET="my-basic-auth-secret"
TLS_SECRET="traefik-tls"
MIDDLEWARE_NAME="my-basic-auth"

# 1. Verifica e cria o Secret TLS se não existir
if ! kubectl get secret ${TLS_SECRET} -n ${NAMESPACE} >/dev/null 2>&1; then
  echo "Secret ${TLS_SECRET} não encontrado em ${NAMESPACE}. Criando certificado autoassinado..."
  # Cria certificado autoassinado para testes (válido por 365 dias)
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
    -keyout tls.key -out tls.crt \
    -subj "/CN=${DASHBOARD_HOST}" -days 365
  kubectl create secret tls ${TLS_SECRET} \
    --cert=tls.crt --key=tls.key -n ${NAMESPACE}
  rm tls.key tls.crt
  echo "Secret ${TLS_SECRET} criado."
else
  echo "Secret ${TLS_SECRET} já existe em ${NAMESPACE}."
fi

# 2. Verifica e copia o Secret de autenticação básica se necessário
# Se o secret de autenticação estiver no namespace default, copie para kube-system
if ! kubectl get secret ${BASIC_AUTH_SECRET} -n ${NAMESPACE} >/dev/null 2>&1; then
  echo "Secret ${BASIC_AUTH_SECRET} não encontrado em ${NAMESPACE}. Verificando no namespace default..."
  if kubectl get secret ${BASIC_AUTH_SECRET} -n default >/dev/null 2>&1; then
    echo "Copiando ${BASIC_AUTH_SECRET} de default para ${NAMESPACE}..."
    kubectl get secret ${BASIC_AUTH_SECRET} -n default -o yaml | \
      sed "s/namespace: default/namespace: ${NAMESPACE}/" | kubectl apply -f -
    echo "Secret ${BASIC_AUTH_SECRET} copiado para ${NAMESPACE}."
  else
    echo "Secret ${BASIC_AUTH_SECRET} não existe no namespace default. Crie-o antes de prosseguir."
    exit 1
  fi
else
  echo "Secret ${BASIC_AUTH_SECRET} já existe em ${NAMESPACE}."
fi

# 3. Cria o Middleware my-basic-auth no namespace kube-system
if ! kubectl get middleware ${MIDDLEWARE_NAME} -n ${NAMESPACE} >/dev/null 2>&1; then
  echo "Criando Middleware ${MIDDLEWARE_NAME} no namespace ${NAMESPACE}..."
  cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ${MIDDLEWARE_NAME}
  namespace: ${NAMESPACE}
spec:
  basicAuth:
    secret: ${BASIC_AUTH_SECRET}
EOF
  echo "Middleware ${MIDDLEWARE_NAME} criado."
else
  echo "Middleware ${MIDDLEWARE_NAME} já existe em ${NAMESPACE}."
fi

echo "Verifique se o IngressRoute do dashboard (no namespace ${NAMESPACE}) está apontando para o secret TLS e o middleware corretos."

