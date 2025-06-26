#!/usr/bin/env bash
# Script para diagnosticar e corrigir problemas de certificados em redes corporativas
set -Eeuo pipefail

# --- Configurações Globais ---
readonly NS="cert-manager"
readonly RELEASE="cert-manager"
readonly CERT_SECRET_NAME="corporate-ca-certs"
readonly TEMP_CERT_DIR="/tmp/certs"
readonly LETSENCRYPT_URL="https://acme-v02.api.letsencrypt.org/directory"

# --- Funções de Log ---
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*" >&2; }
warn()  { printf '\e[33m[WARN]\e[0m %s\n' "$*" >&2; }
err()   { printf '\e[31m[ERR ]\e[0m  %s\n' "$*" >&2; }

# Verifica comandos necessários
check_commands() {
  for cmd in kubectl openssl curl; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Comando '$cmd' não encontrado. Por favor, instale-o e tente novamente."
      exit 1
    fi
  done
}

# Testa conexão com Let's Encrypt 
test_letsencrypt_connection() {
  info "Testando conexão com Let's Encrypt..."
  local domain
  domain=$(echo "$LETSENCRYPT_URL" | sed -E 's|^https://([^/]+)/.*|\1|')

  # Testa conexão básica
  if ! curl --connect-timeout 10 -sI "$LETSENCRYPT_URL" >/dev/null; then
    err "Não foi possível conectar a $LETSENCRYPT_URL"
    warn "Verificando se há problemas de rede ou proxy..."
    
    # Tenta obter mais informações
    curl -v --connect-timeout 10 "$LETSENCRYPT_URL" 2>&1 | grep -E '^[<>*]' >&2
    return 1
  fi

  info "✅ Conexão com Let's Encrypt bem-sucedida!"
  return 0
}

# Diagnostica e extrai certificados
diagnose_certificates() {
  info "Diagnosticando certificados ao conectar com Let's Encrypt..."
  local domain
  domain=$(echo "$LETSENCRYPT_URL" | sed -E 's|^https://([^/]+)/.*|\1|')
  
  # Cria diretório temporário
  mkdir -p "$TEMP_CERT_DIR"
  
  # Obtém e exibe informações detalhadas do certificado
  info "Obtendo informações do certificado para $domain..."
  openssl s_client -showcerts -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null \
    | tee "$TEMP_CERT_DIR/full_output.txt" \
    | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ {print}' \
    > "$TEMP_CERT_DIR/cert_chain.pem"

  # Exibe informações do certificado raiz
  info "Informações do primeiro certificado na cadeia:"
  openssl x509 -in "$TEMP_CERT_DIR/cert_chain.pem" -noout -subject -issuer -dates

  # Verifica se há interceptação de proxy
  local subject_cn
  local issuer_cn
  subject_cn=$(openssl x509 -in "$TEMP_CERT_DIR/cert_chain.pem" -noout -subject | grep -o "CN = [^,]*" | sed 's/CN = //')
  issuer_cn=$(openssl x509 -in "$TEMP_CERT_DIR/cert_chain.pem" -noout -issuer | grep -o "CN = [^,]*" | sed 's/CN = //')
  
  if echo "$issuer_cn" | grep -i -E '(netskope|zscaler|proxy|gateway|firewall|security|corporate|enterprise)' >/dev/null; then
    warn "⚠️  Detectado certificado de proxy corporativo: $issuer_cn"
    warn "O certificado de $domain foi emitido por uma autoridade corporativa"
    warn "Isso pode causar problemas com o cert-manager se os certificados não forem confiáveis"
  elif echo "$subject_cn" | grep -i "$domain" >/dev/null && \
       echo "$issuer_cn" | grep -i -E '(let'"'"'?s encrypt|lets encrypt|isrg|r3)' >/dev/null; then
    info "✅ Certificado parece legítimo do Let's Encrypt: $issuer_cn"
  else
    warn "⚠️  Certificado não corresponde ao esperado:"
    warn "Domínio: $domain"
    warn "Subject: $subject_cn"
    warn "Issuer: $issuer_cn"
  fi

  # Extrai todos os certificados da cadeia
  info "Extraindo certificados da cadeia..."
  grep -n "BEGIN CERTIFICATE" "$TEMP_CERT_DIR/full_output.txt" | while read -r line; do
    line_num=$(echo "$line" | cut -d: -f1)
    cert_num=$(echo "$line" | cut -d: -f2 | awk '{print NR}')
    
    # Extrai o certificado
    awk "NR >= $line_num" "$TEMP_CERT_DIR/full_output.txt" | 
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ {print}' > "$TEMP_CERT_DIR/cert$cert_num.pem"
    
    # Exibe informações
    info "Certificado $cert_num:"
    openssl x509 -in "$TEMP_CERT_DIR/cert$cert_num.pem" -noout -subject -issuer | sed 's/^/  /'
  done
}

# Instala certificados manualmente
install_certificates() {
  info "Instalando certificados corporativos para cert-manager..."
  
  # Verifica se há certificados extraídos
  if ! ls "$TEMP_CERT_DIR"/cert*.pem >/dev/null 2>&1; then
    err "Nenhum certificado encontrado para instalar."
    err "Execute primeiro o diagnóstico de certificados."
    return 1
  fi
  
  # Combina todos os certificados
  cat "$TEMP_CERT_DIR"/cert*.pem > "$TEMP_CERT_DIR/combined.pem"
  
  # Cria ou atualiza secret
  kubectl -n "$NS" create secret generic "$CERT_SECRET_NAME" \
    --from-file=ca.crt="$TEMP_CERT_DIR/combined.pem" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  info "✅ Secret '$CERT_SECRET_NAME' criado/atualizado no namespace '$NS'."
  info "Agora você precisa reconfigurar o cert-manager para usar estes certificados."
  info "Execute o script deploy-cert-manager.sh novamente para aplicar as alterações."
}

# Verifica se o cert-manager está configurado para usar certificados corporativos
check_cert_manager_config() {
  info "Verificando configuração do cert-manager..."
  
  # Verifica se o secret existe
  if ! kubectl -n "$NS" get secret "$CERT_SECRET_NAME" >/dev/null 2>&1; then
    warn "Secret '$CERT_SECRET_NAME' não encontrado no namespace '$NS'."
    warn "Certificados corporativos não estão configurados."
    return 1
  fi
  
  # Verifica se o cert-manager está configurado para usar o secret
  local volume_mounts
  volume_mounts=$(kubectl -n "$NS" get deployment "$RELEASE"-controller -o jsonpath='{.spec.template.spec.containers[0].volumeMounts}' 2>/dev/null)
  
  if ! echo "$volume_mounts" | grep -q "$CERT_SECRET_NAME"; then
    warn "O cert-manager não está configurado para usar os certificados corporativos."
    warn "Execute o script deploy-cert-manager.sh novamente para aplicar a configuração correta."
    return 1
  fi
  
  info "✅ O cert-manager está configurado para usar certificados corporativos."
  return 0
}

# Função principal
main() {
  check_commands
  
  info "=================================================="
  info "DIAGNÓSTICO DE CERTIFICADOS CORPORATIVOS"
  info "=================================================="
  
  test_letsencrypt_connection
  diagnose_certificates
  
  # Menu de ações
  echo ""
  echo "Escolha uma opção:"
  echo "1. Instalar certificados corporativos no cert-manager"
  echo "2. Verificar configuração atual do cert-manager"
  echo "3. Sair sem fazer alterações"
  read -rp "Opção (1-3): " option
  
  case "$option" in
    1)
      install_certificates
      ;;
    2)
      check_cert_manager_config
      ;;
    *)
      info "Nenhuma alteração foi feita."
      ;;
  esac
  
  # Limpa certificados temporários
  info "Limpando arquivos temporários..."
  [[ -d "$TEMP_CERT_DIR" ]] && rm -rf "$TEMP_CERT_DIR"
  
  info "✅ Diagnóstico concluído."
}

main "$@"
