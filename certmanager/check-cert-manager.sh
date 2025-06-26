#!/usr/bin/env bash
# Script para verificar a instalação e funcionamento do cert-manager
set -Eeuo pipefail

# --- Configurações Globais ---
readonly NS="cert-manager"

# --- Funções de Log ---
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*" >&2; }
warn()  { printf '\e[33m[WARN]\e[0m %s\n' "$*" >&2; }
err()   { printf '\e[31m[ERR ]\e[0m  %s\n' "$*" >&2; }

# --- Verificações ---
check_components() {
  info "Verificando componentes do cert-manager..."
  kubectl get pods -n "$NS" -o wide
  
  info "Verificando serviços..."
  kubectl get svc -n "$NS"
  
  info "Verificando APIServices..."
  kubectl get apiservice | grep cert-manager
}

check_crds() {
  info "Verificando CRDs do cert-manager..."
  kubectl get crd | grep cert-manager.io
}

check_issuers() {
  info "Verificando ClusterIssuers..."
  kubectl get clusterissuers
  
  info "Detalhes do ClusterIssuer principal..."
  kubectl describe clusterissuer letsencrypt-certmanager
}

check_certificates() {
  info "Verificando certificados em todos os namespaces..."
  kubectl get certificates --all-namespaces
  
  info "Verificando solicitações de certificados..."
  kubectl get certificaterequests --all-namespaces
}

check_events() {
  info "Verificando eventos relacionados a certificados..."
  kubectl get events --field-selector involvedObject.kind=Certificate --all-namespaces
  kubectl get events --field-selector involvedObject.kind=CertificateRequest --all-namespaces
  kubectl get events --field-selector involvedObject.kind=Challenge --all-namespaces
}

test_certificate() {
  local test_ns="cert-manager-test"
  local domain=${1:-"example.local"}
  
  info "Criando namespace de teste..."
  kubectl create ns "$test_ns" --dry-run=client -o yaml | kubectl apply -f -
  
  info "Criando serviço e ingress de teste..."
  cat <<EOF | kubectl apply -n "$test_ns" -f -
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: nginx
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx
        ports:
        - containerPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-certmanager"
    kubernetes.io/tls-acme: "true"
    kubernetes.io/ingress.class: traefik
spec:
  tls:
  - hosts:
    - ${domain}
    secretName: test-tls
  rules:
  - host: ${domain}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              number: 80
EOF

  info "Certificado de teste solicitado. Verificando status..."
  sleep 5
  kubectl get certificate -n "$test_ns"
  kubectl describe certificate test-tls -n "$test_ns"
  
  info "Verificando eventos de certificado..."
  kubectl get events -n "$test_ns" --field-selector involvedObject.kind=Certificate
  
  info "Para limpar o teste, execute: kubectl delete ns $test_ns"
}

# --- Função Principal ---
main() {
  check_components
  check_crds
  check_issuers
  check_certificates
  check_events
  
  # Descomente para testar um certificado (especifique um domínio real)
  # test_certificate "seu-dominio.exemplo.com"
  
  info "✅ Verificação concluída."
}

# --- Ponto de Entrada ---
main "$@"
