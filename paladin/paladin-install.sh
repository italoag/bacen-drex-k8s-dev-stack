#!/bin/bash
# paladin-install.sh
# Script para instalar o Paladin Operator e opcionalmente configurar ingressos, ingressroutes de UI e middlewares

set -e

WITH_INGRESS=false

for arg in "$@"; do
  case $arg in
    --with-ingress)
      WITH_INGRESS=true
      shift
      ;;
  esac
done

# Função para checar status de pods em um namespace
check_pods_ready() {
  local ns=$1
  local label=$2
  echo "Verificando pods em $ns com label $label..."
  kubectl wait --for=condition=Ready pods -l $label -n $ns --timeout=180s
}

# Step 1: Instalar CRDs do Paladin
helm repo add paladin https://LF-Decentralized-Trust-labs.github.io/paladin --force-update
helm upgrade --install paladin-crds paladin/paladin-operator-crd

# Step 2: Instalar cert-manager (se não existir)
if ! kubectl get ns cert-manager &>/dev/null; then
  echo "Instalando cert-manager..."
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm install cert-manager --namespace cert-manager --version v1.16.1 jetstack/cert-manager --create-namespace --set crds.enabled=true
else
  echo "cert-manager já instalado."
fi

# Verificar se o cert-manager está funcionando
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s

# Step 3: Instalar Paladin Operator
helm upgrade --install paladin paladin/paladin-operator -n paladin --create-namespace

# Verificar se o Paladin Operator está pronto
check_pods_ready "paladin" "app.kubernetes.io/name=paladin-operator"

if $WITH_INGRESS; then
  echo "Aplicando ingressos, ingressroutes de UI e middlewares do Paladin..."
  kubectl apply -f paladin/paladin1-ingress.yaml
  kubectl apply -f paladin/paladin1-ui-ingressroute.yaml
  kubectl apply -f paladin/paladin2-ingress.yaml
  kubectl apply -f paladin/paladin2-ui-ingressroute.yaml
  kubectl apply -f paladin/paladin3-ingress.yaml
  kubectl apply -f paladin/paladin3-ui-ingressroute.yaml
  kubectl apply -f paladin/paladin-basic-auth-middleware.yaml
  echo "Ingressos e middlewares aplicados."
else
  echo "Instalando Paladin em modo hostNetwork (sem ingressos)."
  # Exemplo: adicionar --set hostNetwork=true se o chart suportar
  helm upgrade --install paladin paladin/paladin-operator -n paladin --set hostNetwork=true --create-namespace
fi

echo "Instalação do Paladin finalizada."
