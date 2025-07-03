#!/bin/bash
# paladin-install.sh
# Script para instalar o Paladin Operator e opcionalmente configurar ingressos, ingressroutes de UI e middlewares

set -e

# --- Configurações Globais ---
readonly CERT_MANAGER_NS="cert-manager"
readonly CERT_MANAGER_SCRIPT="../certmanager/deploy-cert-manager.sh"

# --- Funções de Log ---
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[33m[WARN]\e[0m  %s\n' "$*"; }
error() { printf '\e[31m[ERRO]\e[0m  %s\n' "$*"; }

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
  info "Verificando pods em $ns com label $label..."
  kubectl wait --for=condition=Ready pods -l $label -n $ns --timeout=180s
}

# Função para verificar se o cert-manager está instalado e funcionando
check_cert_manager() {
  info "Verificando se o cert-manager está instalado..."
  
  # Verifica se o namespace do cert-manager existe
  if ! kubectl get namespace "$CERT_MANAGER_NS" &>/dev/null; then
    error "O namespace $CERT_MANAGER_NS não existe."
    return 1
  fi

  # Verifica se os deployments do cert-manager existem
  if ! kubectl get deployment cert-manager -n "$CERT_MANAGER_NS" &>/dev/null; then
    error "O deployment cert-manager não foi encontrado."
    return 1
  fi

  if ! kubectl get deployment cert-manager-webhook -n "$CERT_MANAGER_NS" &>/dev/null; then
    error "O deployment cert-manager-webhook não foi encontrado."
    return 1
  fi

  if ! kubectl get deployment cert-manager-cainjector -n "$CERT_MANAGER_NS" &>/dev/null; then
    error "O deployment cert-manager-cainjector não foi encontrado."
    return 1
  fi

  # Verifica os CRDs necessários do cert-manager
  if ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
    error "CRD certificates.cert-manager.io não encontrado."
    return 1
  fi

  if ! kubectl get crd issuers.cert-manager.io &>/dev/null; then
    error "CRD issuers.cert-manager.io não encontrado."
    return 1
  fi

  info "✅ O cert-manager está instalado e parece estar configurado corretamente."
  return 0
}

# Verifica se o cert-manager está instalado
if ! check_cert_manager; then
  error "O cert-manager não está instalado ou não está configurado corretamente."
  error "O cert-manager é um pré-requisito para o Paladin."
  error "Por favor, instale o cert-manager primeiro usando: ../certmanager/deploy-cert-manager.sh"
  
  # Verifica se o script de instalação do cert-manager existe
  if [[ -f "$CERT_MANAGER_SCRIPT" ]]; then
    warn "O script de instalação do cert-manager foi encontrado em: $CERT_MANAGER_SCRIPT"
    read -p "Deseja instalar o cert-manager agora? (s/n): " install_choice
    if [[ "$install_choice" == "s" ]]; then
      info "Instalando cert-manager..."
      bash "$CERT_MANAGER_SCRIPT" || {
        error "Falha ao instalar o cert-manager. Por favor, tente instalar manualmente."
        exit 1
      }
    else
      error "Instalação cancelada. Por favor, instale o cert-manager antes de continuar."
      exit 1
    fi
  else
    error "Script de instalação do cert-manager não encontrado."
    error "Certifique-se de estar executando este script do diretório correto."
    exit 1
  fi
fi

# Verificar status dos componentes do cert-manager
info "Verificando se o cert-manager está funcionando corretamente..."
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s || {
  error "Problemas com o deployment cert-manager. Verifique o status."
  exit 1
}
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s || {
  error "Problemas com o deployment cert-manager-webhook. Verifique o status."
  exit 1
}
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s || {
  error "Problemas com o deployment cert-manager-cainjector. Verifique o status."
  exit 1
}

# Step 1: Instalar CRDs do Paladin
info "Adicionando repositório Helm do Paladin..."
helm repo add paladin https://LF-Decentralized-Trust-labs.github.io/paladin --force-update
info "Instalando CRDs do Paladin..."
helm upgrade --install paladin-crds paladin/paladin-operator-crd

# Step 2: Instalar Paladin Operator
info "Instalando Paladin Operator..."
helm upgrade --install paladin paladin/paladin-operator -n paladin --create-namespace

# Verificar se o Paladin Operator está pronto
info "Verificando se o Paladin Operator está pronto..."
check_pods_ready "paladin" "app.kubernetes.io/name=paladin-operator"

if $WITH_INGRESS; then
  info "Aplicando ingressos, ingressroutes de UI e middlewares do Paladin..."
  kubectl apply -f paladin1-ingress.yaml
  kubectl apply -f paladin1-ui-ingressroute.yaml
  kubectl apply -f paladin2-ingress.yaml
  kubectl apply -f paladin2-ui-ingressroute.yaml
  kubectl apply -f paladin3-ingress.yaml
  kubectl apply -f paladin3-ui-ingressroute.yaml
  kubectl apply -f paladin-basic-auth-middleware.yaml
  info "Ingressos e middlewares aplicados."
else
  info "Instalando Paladin em modo hostNetwork (sem ingressos)."
  # Exemplo: adicionar --set hostNetwork=true se o chart suportar
  helm upgrade --install paladin paladin/paladin-operator -n paladin --set hostNetwork=true --create-namespace
fi

info "✅ Instalação do Paladin finalizada com sucesso."
