#!/usr/bin/env bash
# Deploy / upgrade cert-manager no ambiente Kubernetes para gerenciamento de certificados TLS
set -Eeuo pipefail

# --- Configurações Globais ---
readonly NS="cert-manager"              # Namespace a usar / criar
readonly RELEASE="cert-manager"         # Nome do Helm release
readonly CHART="jetstack/cert-manager"  # Chart do cert-manager
readonly CHART_VERSION="v1.17.1"        # Versão do chart
readonly TIMEOUT="300s"                 # Timeout para operações
readonly EMAIL=${EMAIL:-"admin@example.com"} # Email para Let's Encrypt (substituir se definido)
readonly LETSENCRYPT_URL="https://acme-v02.api.letsencrypt.org/directory"
readonly TEMP_CERT_DIR="/tmp/certs"
readonly CERT_SECRET_NAME="corporate-ca-certs"
readonly SKIP_CERT_CHECK=${SKIP_CERT_CHECK:-"false"} # Define como "true" para pular verificação de certificados corporativos

# --- Funções de Log ---
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*" >&2; }
warn()  { printf '\e[33m[WARN]\e[0m %s\n' "$*" >&2; }
err()   { printf '\e[31m[ERR ]\e[0m  %s\n' "$*" >&2; }

# --- Tratamento de Erros e Rollback ---
cleanup_and_exit() {
  local line_num=${1:-$LINENO}
  err "❌ Ocorreu um erro na linha $line_num"
  
  info "Status atual dos recursos do cert-manager:"
  kubectl get pods,svc -l app.kubernetes.io/instance="$RELEASE" -n "$NS" 2>/dev/null || true
  
  warn "O script falhou. Verifique os logs acima para diagnosticar o problema."
  exit 1
}
trap 'cleanup_and_exit $LINENO' ERR

# --- Funções Utilitárias ---
check_command() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Comando '$cmd' não encontrado. Por favor, instale-o e tente novamente."
      exit 1
    fi
  done
}

# Verifica se estamos em uma rede corporativa com proxies SSL que interceptam tráfego
check_corporate_network() {
  info "Verificando se estamos em uma rede corporativa com interceptação SSL..."
  
  # Cria diretório temporário para armazenar certificados
  mkdir -p "$TEMP_CERT_DIR"
  
  # Tenta obter o certificado do servidor Let's Encrypt usando OpenSSL
  info "Recuperando certificado de $LETSENCRYPT_URL"
  local domain
  domain=$(echo "$LETSENCRYPT_URL" | sed -E 's|^https://([^/]+)/.*|\1|')
  info "Domínio extraído: $domain"
  
  # Tenta diversos métodos para obter o certificado
  if ! openssl s_client -showcerts -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null | 
       awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ {print}' > "$TEMP_CERT_DIR/cert_chain.pem"; then
    warn "Não foi possível conectar a $domain usando OpenSSL. Tentando método alternativo..."
    
    # Método alternativo usando curl se disponível
    if command -v curl &>/dev/null; then
      warn "Tentando obter informações com curl..."
      curl -v --connect-timeout 10 "https://$domain" 2>&1 | grep -i "issuer\|subject\|certificate" >&2
    fi
    
    warn "Não foi possível obter certificados. Continuando sem verificações adicionais."
    return 1
  fi
  
  # Verifica se conseguimos obter um certificado válido
  if ! openssl x509 -in "$TEMP_CERT_DIR/cert_chain.pem" -noout &>/dev/null; then
    warn "O arquivo obtido não parece ser um certificado X509 válido."
    return 1
  fi
  
  # Obtém informações sobre o certificado
  local subject_cn
  local issuer_cn
  local issuer_org
  local is_corporate=false
  
  # Extrai CN do subject e issuer
  subject_cn=$(openssl x509 -in "$TEMP_CERT_DIR/cert_chain.pem" -noout -subject 2>/dev/null | 
               grep -o "CN *= *[^,/\"]*" | sed 's/CN *= *//')
  
  issuer_cn=$(openssl x509 -in "$TEMP_CERT_DIR/cert_chain.pem" -noout -issuer 2>/dev/null | 
              grep -o "CN *= *[^,/\"]*" | sed 's/CN *= *//')
  
  issuer_org=$(openssl x509 -in "$TEMP_CERT_DIR/cert_chain.pem" -noout -issuer 2>/dev/null | 
               grep -o "O *= *[^,/\"]*" | sed 's/O *= *//')
  
  info "Certificado para $domain:"
  info "  Subject: $subject_cn"
  info "  Emissor: $issuer_cn"
  info "  Organização: $issuer_org"
  
  # Lógica de verificação mais abrangente
  # 1. Verifica se o certificado foi emitido por serviços conhecidos
  if echo "$issuer_cn $issuer_org" | grep -i -E '(netskope|zscaler|proxy|gateway|firewall|security|corporate|enterprise|walled garden|forefront|fortinet|checkpoint|palo alto|blue coat|mcafee|sophos|cisco|watchguard)' >/dev/null; then
    info "Detectado certificado de solução de segurança corporativa: $issuer_cn / $issuer_org"
    is_corporate=true
  # 2. Verifica se o subject contém o domínio esperado
  elif ! echo "$subject_cn" | grep -i "$domain" >/dev/null; then
    warn "O subject ($subject_cn) não corresponde ao domínio esperado ($domain)"
    is_corporate=true
  # 3. Verifica se o emissor é quem deveria ser para Let's Encrypt
  elif ! echo "$issuer_cn $issuer_org" | grep -i -E "(let's encrypt|letsencrypt|isrg|r3|digital signature trust co|internet security research group)" >/dev/null; then
    warn "Emissor ($issuer_cn / $issuer_org) não parece ser da Let's Encrypt"
    is_corporate=true
  fi
  
  # Em redes corporativas, extrai e salva todos os certificados da cadeia
  if [[ "$is_corporate" == "true" ]]; then
    info "🔒 Detectada rede corporativa com intercepção SSL!"
    extract_corporate_certificates "$domain"
    return 0
  else
    info "✅ Certificado parece ser autêntico do Let's Encrypt. Nenhuma ação necessária."
    rm -rf "$TEMP_CERT_DIR"
    return 1
  fi
}

# Extrai certificados corporativos para uso no cluster
extract_corporate_certificates() {
  local domain=$1
  info "Extraindo certificados corporativos para domínio $domain..."
  
  # Limpa diretório
  rm -f "$TEMP_CERT_DIR"/*.pem
  
  # Método 1: Tenta usar OpenSSL com showcerts para obter a cadeia completa
  info "Tentando extrair certificados com OpenSSL..."
  openssl s_client -showcerts -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null | 
  awk 'BEGIN {c=0} 
       /BEGIN CERTIFICATE/{c++; print > "'$TEMP_CERT_DIR'/cert" c ".pem"} 
       /Certificate chain/{flag=1; next} 
       /END CERTIFICATE/{print > "'$TEMP_CERT_DIR'/cert" c ".pem"}'
  
  # Verifica se conseguimos extrair certificados
  local cert_count
  cert_count=$(find "$TEMP_CERT_DIR" -name "cert*.pem" | wc -l)
  
  # Se não conseguiu extrair certificados, tenta outro método
  if [[ "$cert_count" -eq 0 ]]; then
    warn "Não foi possível extrair certificados com o primeiro método. Tentando alternativa..."
    # Método alternativo, extrai pelo menos o certificado do servidor
    openssl s_client -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null | 
    sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > "$TEMP_CERT_DIR/cert1.pem"
    
    # Verifica novamente
    cert_count=$(find "$TEMP_CERT_DIR" -name "cert*.pem" -a -size +0 | wc -l)
  fi
  
  if [[ "$cert_count" -eq 0 ]]; then
    warn "⚠️ Não foi possível extrair nenhum certificado. Isso pode causar problemas."
    return 1
  fi
  
  info "✅ Extraídos $cert_count certificados da cadeia."
  
  # Mostra informações sobre os certificados encontrados
  for cert in "$TEMP_CERT_DIR"/cert*.pem; do
    if [[ -f "$cert" ]] && [[ -s "$cert" ]]; then  # Verifica se arquivo existe e não está vazio
      local subject
      local issuer
      local dates
      subject=$(openssl x509 -noout -subject -in "$cert" 2>/dev/null | sed 's/subject=//')
      issuer=$(openssl x509 -noout -issuer -in "$cert" 2>/dev/null | sed 's/issuer=//')
      dates=$(openssl x509 -noout -dates -in "$cert" 2>/dev/null | tr '\n' ' ')
      info "Certificado $(basename "$cert"):"
      info "  - Subject: $subject"
      info "  - Issuer: $issuer"
      info "  - $dates"
    fi
  done
  
  return 0
}

# Cria ConfigMap/Secret com certificados corporativos para cert-manager
create_cert_config() {
  info "Criando Secret com certificados CA corporativos para cert-manager..."
  
  # Verifica se o namespace existe (pode ter sido criado na função setup_environment)
  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    info "Namespace $NS não existe. Criando..."
    kubectl create ns "$NS"
  fi
  
  # Verifica se há certificados extraídos
  local cert_count
  cert_count=$(find "$TEMP_CERT_DIR" -name "cert*.pem" | wc -l)
  
  if [[ "$cert_count" -eq 0 ]]; then
    warn "Nenhum certificado encontrado para adicionar."
    return 0
  fi
  
  # Combina todos os certificados em um único arquivo
  cat "$TEMP_CERT_DIR"/cert*.pem > "$TEMP_CERT_DIR/combined.pem"
  
  # Verifica se o secret já existe
  if kubectl -n "$NS" get secret "$CERT_SECRET_NAME" >/dev/null 2>&1; then
    info "Secret '$CERT_SECRET_NAME' já existe. Atualizando..."
    kubectl -n "$NS" create secret generic "$CERT_SECRET_NAME" \
      --from-file=ca.crt="$TEMP_CERT_DIR/combined.pem" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    info "Criando novo Secret '$CERT_SECRET_NAME'..."
    kubectl -n "$NS" create secret generic "$CERT_SECRET_NAME" \
      --from-file=ca.crt="$TEMP_CERT_DIR/combined.pem"
  fi
  
  info "✅ Secret '$CERT_SECRET_NAME' criado/atualizado no namespace $NS"
}

retry() {
  local n=1
  local max=$1
  shift
  
  until "$@"; do
    if [[ $n -ge $max ]]; then
      err "Falha após $n tentativas."
      return 1
    fi
    warn "Tentativa $n/$max falhou. Tentando novamente em 5 segundos..."
    sleep 5
    n=$((n+1))
  done
}

rollback() {
  warn "Executando rollback..."
  
  if helm status "$RELEASE" -n "$NS" &>/dev/null; then
    warn "Desinstalando release Helm '$RELEASE'..."
    helm uninstall "$RELEASE" -n "$NS" || true
  fi
  
  warn "Removendo CRDs do cert-manager..."
  kubectl delete crd -l app.kubernetes.io/name=cert-manager 2>/dev/null || true
  
  warn "Removendo namespace se vazio..."
  if [[ $(kubectl get all -n "$NS" 2>/dev/null | wc -l) -le 1 ]]; then
    kubectl delete ns "$NS" --wait=false 2>/dev/null || true
  fi
  
  warn "Rollback concluído."
}

wait_for_pods() {
  info "Aguardando os pods do cert-manager ficarem prontos..."
  retry 30 kubectl -n "$NS" wait pods --all --for=condition=Ready --timeout=10s

  # Verifica se todos os pods estão rodando
  local ready_pods
  local total_pods
  ready_pods=$(kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | wc -w)
  total_pods=$(kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{.items[*].metadata.name}' | wc -w)
  
  if [[ "$ready_pods" -ne "$total_pods" ]]; then
    err "Nem todos os pods estão no estado 'Running'. ($ready_pods/$total_pods)"
    kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE"
    return 1
  fi
  
  info "✅ Todos os pods do cert-manager estão rodando."
}

# --- Funções de Deploy ---
setup_environment() {
  info "Configurando ambiente..."
  
  info "Adicionando repositório Helm do jetstack..."
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm repo update >/dev/null
  
  info "Verificando namespace..."
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
}

install_cert_manager() {
  info "Instalando/atualizando o cert-manager via Helm..."
  
  # Configura valores adicionais para certificados corporativos (verifica flag global)
  local extra_values=""
  local has_corporate_certs=false
  
  # Verifica se o secret existe (foi criado anteriormente na função create_cert_config)
  if [[ -d "$TEMP_CERT_DIR" ]] && [[ -f "$TEMP_CERT_DIR/combined.pem" ]]; then
    has_corporate_certs=true
    info "Detectado arquivo de certificados corporativos, configurando extraCA"
  elif kubectl -n "$NS" get secret "$CERT_SECRET_NAME" >/dev/null 2>&1; then
    has_corporate_certs=true
    info "Detectado Secret existente com certificados corporativos, configurando extraCA"
  fi
  
  # Define os valores extras para o Helm apenas se tiver certificados
  if [[ "$has_corporate_certs" == "true" ]]; then
    extra_values="--set extraArgs={--trusted-ca=/etc/ssl/certs/ca-certificates.crt} --set volumeMounts[0].name=ca-certs --set volumeMounts[0].mountPath=/etc/ssl/certs/ca-certificates.crt --set volumeMounts[0].subPath=ca.crt --set volumes[0].name=ca-certs --set volumes[0].secret.secretName=$CERT_SECRET_NAME"
  fi
  
  if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    info "Release existente encontrado. Executando upgrade..."
    if [[ -n "$extra_values" ]]; then
      helm upgrade "$RELEASE" "$CHART" \
        --namespace "$NS" \
        --version "$CHART_VERSION" \
        --set crds.enabled=true \
        ${extra_values} \
        --timeout "$TIMEOUT" \
        --wait
    else
      helm upgrade "$RELEASE" "$CHART" \
        --namespace "$NS" \
        --version "$CHART_VERSION" \
        --set crds.enabled=true \
        --timeout "$TIMEOUT" \
        --wait
    fi
  else
    info "Nenhum release existente. Executando instalação..."
    if [[ -n "$extra_values" ]]; then
      helm install "$RELEASE" "$CHART" \
        --namespace "$NS" \
        --create-namespace \
        --version "$CHART_VERSION" \
        --set crds.enabled=true \
        ${extra_values} \
        --timeout "$TIMEOUT" \
        --wait
    else
      helm install "$RELEASE" "$CHART" \
        --namespace "$NS" \
        --create-namespace \
        --version "$CHART_VERSION" \
        --set crds.enabled=true \
        --timeout "$TIMEOUT" \
        --wait
    fi
  fi
  
  info "✅ Deploy/Upgrade do Helm concluído."
}

verify_crds() {
  info "Verificando instalação dos CRDs do cert-manager..."
  local crds=("certificates.cert-manager.io" "issuers.cert-manager.io" "clusterissuers.cert-manager.io" "challenges.acme.cert-manager.io")
  
  for crd in "${crds[@]}"; do
    if ! kubectl get crd "$crd" &>/dev/null; then
      warn "CRD $crd não encontrado. Tentando aplicar CRDs manualmente..."
      kubectl apply --validate=false -f "https://github.com/jetstack/cert-manager/releases/$CHART_VERSION/cert-manager.crds.yaml"
      break
    fi
  done
  
  info "✅ CRDs verificados."
}

create_cluster_issuer() {
  info "Criando ClusterIssuer para Let's Encrypt..."
  
  # Criar arquivo temporário com a configuração do ClusterIssuer
  cat > "letsencrypt-certmanager.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-certmanager
  namespace: cert-manager
spec:
  acme:
    email: ${EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-certmanager
    solvers:
    - http01:
        ingress:
          class: traefik
EOF
  
  # Aplicar configuração
  info "Aplicando configuração do ClusterIssuer..."
  retry 5 kubectl apply -f letsencrypt-certmanager.yaml
  
  info "✅ ClusterIssuer criado."
}

verify_installation() {
  info "Verificando instalação do cert-manager..."
  
  # Verificar se os pods estão rodando
  kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE"
  
  # Verificar se o ClusterIssuer está pronto
  local issuer_status
  issuer_status=$(kubectl get clusterissuer letsencrypt-certmanager -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "NotFound")
  
  if [[ "$issuer_status" == "Ready" ]]; then
    info "✅ ClusterIssuer está pronto."
  else
    warn "ClusterIssuer ainda não está pronto. Status: $issuer_status"
    kubectl describe clusterissuer letsencrypt-certmanager
  fi
}

show_summary() {
  info "=================================================="
  info "✅ DEPLOYMENT DO CERT-MANAGER CONCLUÍDO"
  info "=================================================="
  
  info "Versão instalada: $CHART_VERSION"
  info "Namespace: $NS"
  info "Email registrado para Let's Encrypt: $EMAIL"
  
  # Verifica se estamos usando certificados corporativos
  if kubectl -n "$NS" get secret "$CERT_SECRET_NAME" >/dev/null 2>&1; then
    info "🔒 Certificados CA corporativos foram adicionados ao cert-manager."
    info "Secret com certificados: $CERT_SECRET_NAME"
  fi
  
  info "Para verificar o status do cert-manager a qualquer momento, execute:"
  info "kubectl get pods -n $NS"
  info ""
  info "Para verificar o ClusterIssuer, execute:"
  info "kubectl describe clusterissuer letsencrypt-certmanager"
  info ""
  info "Para criar um certificado usando este ClusterIssuer, adicione estas anotações ao seu Ingress:"
  info "  annotations:"
  info "    cert-manager.io/cluster-issuer: \"letsencrypt-certmanager\""
  info "    kubernetes.io/tls-acme: \"true\""
  info "=================================================="
}

# --- Função Principal ---
main() {
  check_command kubectl helm openssl
  
  # Primeiro configuramos o ambiente básico (namespace, repos)
  setup_environment
  
  # Agora verificamos se estamos em uma rede corporativa com proxy SSL
  if [[ "$SKIP_CERT_CHECK" != "true" ]]; then
    if check_corporate_network; then
      info "Detectada rede corporativa com interceptação SSL."
      create_cert_config
    else
      info "Rede não parece ter interceptação SSL, continuando normalmente."
    fi
  else
    info "Verificação de certificados corporativos foi desativada (SKIP_CERT_CHECK=true)."
  fi
  
  # Agora instalamos o cert-manager (já com o namespace e certificados preparados)
  install_cert_manager
  wait_for_pods
  verify_crds
  create_cluster_issuer
  verify_installation
  show_summary
  
  # Limpa certificados temporários
  [[ -d "$TEMP_CERT_DIR" ]] && rm -rf "$TEMP_CERT_DIR"
}

# --- Ponto de Entrada ---
main "$@"
