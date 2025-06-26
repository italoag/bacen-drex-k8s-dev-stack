#!/usr/bin/env bash
# Deploy / upgrade cert-manager no ambiente Kubernetes para gerenciamento de certificados TLS
set -Eeuo pipefail

# --- Configurações Globais ---
readonly NS="cert-manager"              # Namespace a usar / criar
readonly RELEASE="cert-manager"         # Nome do Helm release
readonly CHART="jetstack/cert-manager"  # Chart do cert-manager
readonly CHART_VERSION="v1.17.1"        # Versão do chart
readonly TIMEOUT="600s"                 # Timeout para operações
readonly EMAIL=${EMAIL:-"admin@example.com"} # Email para Let's Encrypt (substituir se definido)
readonly LETSENCRYPT_URL="https://acme-v02.api.letsencrypt.org/directory"
readonly TEMP_CERT_DIR="/tmp/certs"
readonly CERT_SECRET_NAME="corporate-ca-certs"
readonly SKIP_CERT_CHECK=${SKIP_CERT_CHECK:-"false"} # Define como "true" para pular verificação de certificados corporativos
readonly FORCE_REINSTALL=${FORCE_REINSTALL:-"false"} # Define como "true" para forçar reinstalação completa

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
  
  # Verifica logs de pods com problemas para diagnóstico
  check_pod_logs
  
  warn "O script falhou. Verifique os logs acima para diagnosticar o problema."
  exit 1
}
trap 'cleanup_and_exit $LINENO' ERR

# --- Funções Utilitárias ---
check_command() {
  local missing_cmds=()
  
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done
  
  if [[ ${#missing_cmds[@]} -gt 0 ]]; then
    err "Comandos necessários não encontrados: ${missing_cmds[*]}"
    err "Por favor, instale as ferramentas acima e tente novamente."
    return 1
  fi
  
  return 0
}

# Verifica logs de pods em crash para auxiliar no diagnóstico
check_pod_logs() {
  info "Verificando logs de pods problemáticos..."
  
  # Verifica se o namespace existe antes de tentar obter logs
  if ! kubectl get ns "$NS" &>/dev/null; then
    info "Namespace $NS não existe. Não há pods para verificar."
    return 0
  fi
  
  # Verifica se existem pods do cert-manager
  if ! kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" --no-headers &>/dev/null; then
    info "Não foram encontrados pods do cert-manager no namespace $NS."
    return 0
  fi
  
  # Primeiro vamos verificar se existem pods em CrashLoopBackOff
  local crashloop_pods
  crashloop_pods=$(kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" --no-headers | grep -E 'CrashLoopBackOff|Error|Failed|ImagePullBackOff' | awk '{print $1}' || echo "")
  
  if [[ -n "$crashloop_pods" ]]; then
    warn "Detectados pods em estado de falha (CrashLoopBackOff/Error):"
    echo "$crashloop_pods" | tr ' ' '\n'
    
    # Verifica logs específicos para cada pod em falha
    echo "$crashloop_pods" | tr ' ' '\n' | while read -r pod; do
      warn "===== Detalhes do pod em falha: $pod ====="
      
      # Verifica o status do container para entender o tipo de falha
      warn "Estado do container:"
      kubectl get pod -n "$NS" "$pod" -o jsonpath='{.status.containerStatuses[0].state}' | jq . || true
      
      # Verifica últimos logs
      warn "Últimos logs do pod $pod:"
      kubectl -n "$NS" logs "$pod" --tail=30 2>&1 || true
      
      # Verifica logs do container anterior (se estiver em crash loop)
      warn "Logs do container anterior (se disponível):"
      kubectl -n "$NS" logs "$pod" --previous --tail=20 2>&1 || true
      
      # Verifica erros de certificado nos logs
      warn "Verificando erros de certificado nos logs:"
      kubectl -n "$NS" logs "$pod" 2>&1 | grep -E 'certificate|SSL|x509|TLS|CA' || echo "Nenhum erro de certificado encontrado"
      
      warn "Descrição detalhada do pod:"
      kubectl -n "$NS" describe pod "$pod" | grep -A 20 -E 'Events:|State:|Containers:|Last State:' || true
      
      echo "-------------------------------------"
    done
    
    return 1
  fi
  
  # Obtém lista de pods que não estão em estado "Running" ou não estão "Ready"
  local non_ready_pods
  local all_pods
  
  # Obtém todos os pods
  all_pods=$(kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
  non_ready_pods=""
  
  # Para cada pod, verifica se está em estado não-pronto
  for pod in $all_pods; do
    local pod_status
    local ready_status
    
    pod_status=$(kubectl get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    ready_status=$(kubectl get pod -n "$NS" "$pod" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)
    
    if [[ "$pod_status" != "Running" ]] || [[ "$ready_status" != "True" ]]; then
      non_ready_pods="$non_ready_pods $pod"
    fi
  done
  
  if [[ -n "$non_ready_pods" ]]; then
    for pod in $non_ready_pods; do
      warn "Verificando pod não-pronto: $pod"
      warn "Status do pod:"
      kubectl get pod -n "$NS" "$pod" -o wide
      
      warn "Logs recentes do pod:"
      kubectl -n "$NS" logs "$pod" --tail=20 2>&1 || true
      
      # Verifica se há problemas de rede ou certificado
      warn "Verificando problemas de rede ou certificado:"
      kubectl -n "$NS" logs "$pod" 2>&1 | grep -E 'certificate|SSL|x509|TLS|CA|network|connection|timeout|dial' || echo "Nenhum erro óbvio encontrado"
      
      # Também mostra os eventos relacionados ao pod
      warn "Eventos do pod:"
      kubectl -n "$NS" get events --field-selector involvedObject.name="$pod" --sort-by='.lastTimestamp' 2>&1 || true
    done
  else
    info "Todos os pods estão em estado 'Running' e 'Ready'."
  fi
  
  # Verifica se os pods têm access ao CA cert bundle
  info "Verificando acesso ao CA cert bundle em um pod..."
  local sample_pod
  sample_pod=$(kubectl get pod -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o name | head -1)
  
  if [[ -n "$sample_pod" ]]; then
    kubectl -n "$NS" exec $sample_pod -- ls -la /etc/ssl/certs/ | grep -i "ca\|cert" || true
  fi
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
  
  # Limpa e prepara diretório
  mkdir -p "$TEMP_CERT_DIR"
  rm -f "$TEMP_CERT_DIR"/*.pem "$TEMP_CERT_DIR"/*.txt
  
  info "Tentando extrair certificados com OpenSSL..."
  
  # Tentativa 1: Método mais completo para obter todos os certificados
  local temp_output="$TEMP_CERT_DIR/openssl_output.txt"
  local timeout_cmd=""
  
  # Verifica se o timeout está disponível (evita travamentos)
  if command -v timeout &>/dev/null; then
    timeout_cmd="timeout 30"
  fi
  
  # Tenta obter os certificados (com timeout se possível)
  if ! $timeout_cmd openssl s_client -showcerts -connect "$domain:443" -servername "$domain" </dev/null >$temp_output 2>&1; then
    warn "Erro ao conectar usando OpenSSL. Verificando conteúdo obtido mesmo assim..."
  fi
  
  # Verifica se obteve algum erro no conteúdo
  if grep -q "error\|invalid\|unable\|fail" "$temp_output"; then
    warn "Detectados erros na saída do OpenSSL:"
    grep -i "error\|invalid\|unable\|fail" "$temp_output"
  fi
  
  # Extrai os certificados usando um método mais robusto
  local cert_count=0
  local in_cert=false
  local current_cert=""
  
  # Abordagem 1: Processa linha por linha identificando certificados
  while IFS= read -r line || [ -n "$line" ]; do
    # Remove espaços em branco extras no início e fim da linha
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [[ "$line" == *"BEGIN CERTIFICATE"* ]]; then
      cert_count=$((cert_count + 1))
      current_cert="$TEMP_CERT_DIR/cert${cert_count}.pem"
      in_cert=true
      echo "-----BEGIN CERTIFICATE-----" > "$current_cert"
    elif [[ "$line" == *"END CERTIFICATE"* ]]; then
      echo "-----END CERTIFICATE-----" >> "$current_cert"
      in_cert=false
      
      # Validação: Verifica se o arquivo criado é um certificado X509 válido
      if ! openssl x509 -noout -in "$current_cert" &>/dev/null; then
        warn "Certificado inválido detectado: $current_cert"
        rm -f "$current_cert"  # Remove certificado inválido
        cert_count=$((cert_count - 1))
      fi
    elif [[ "$in_cert" == "true" && -n "$line" ]]; then
      # Apenas adiciona linhas não vazias ao certificado
      echo "$line" >> "$current_cert"
    fi
  done < "$temp_output"
  
  # Verifica se conseguimos extrair certificados
  local valid_certs=0
  valid_certs=$(find "$TEMP_CERT_DIR" -name "cert*.pem" -a -size +0 | wc -l | tr -d ' ')
  
  # Se não conseguiu extrair certificados, tenta métodos alternativos
  if [[ "$valid_certs" -eq 0 ]]; then
    warn "Nenhum certificado extraído com o primeiro método. Tentando métodos alternativos..."
    
    # Método 2: Abordagem simplificada - extrai qualquer bloco que pareça com certificado
    info "Usando método alternativo 1 para extração..."
    $timeout_cmd openssl s_client -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null | 
      sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > "$TEMP_CERT_DIR/cert1.pem"
    
    if ! openssl x509 -noout -in "$TEMP_CERT_DIR/cert1.pem" &>/dev/null; then
      warn "Certificado extraído com método alternativo 1 é inválido. Tentando método 2..."
      
      # Método 3: Usando curl para obter cabeçalhos e usar outra estratégia
      if command -v curl &>/dev/null; then
        info "Tentando extrair certificados via curl..."
        curl --insecure -v "https://$domain" >/dev/null 2>"$TEMP_CERT_DIR/curl_output.txt"
        
        # Tenta extrair informações úteis para diagnóstico
        grep -i "SSL connection\|certificate\|issuer\|subject" "$TEMP_CERT_DIR/curl_output.txt" || true
      fi
      
      # Método 4: Tentativa com flag -CApath
      info "Tentando método alternativo com CApath..."
      openssl s_client -showcerts -CApath /etc/ssl/certs -connect "$domain:443" </dev/null 2>/dev/null |
        sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > "$TEMP_CERT_DIR/cert2.pem"
    fi
    
    # Verifica novamente
    valid_certs=$(find "$TEMP_CERT_DIR" -name "cert*.pem" -a -size +0 | wc -l | tr -d ' ')
  fi
  
  # Valida todos os certificados extraídos
  for cert_file in "$TEMP_CERT_DIR"/cert*.pem; do
    if [[ -f "$cert_file" ]] && [[ -s "$cert_file" ]]; then
      if ! openssl x509 -noout -in "$cert_file" &>/dev/null; then
        warn "Certificado inválido detectado: $cert_file"
        rm -f "$cert_file"
        valid_certs=$((valid_certs - 1))
      fi
    fi
  done
  
  # Contagem final de certificados válidos
  valid_certs=$(find "$TEMP_CERT_DIR" -name "cert*.pem" -a -size +0 | wc -l | tr -d ' ')
  
  if [[ "$valid_certs" -eq 0 ]]; then
    warn "⚠️ Não foi possível extrair nenhum certificado válido."
    
    # Último recurso: Procurar certificados no sistema
    warn "Procurando certificados CA do sistema como último recurso..."
    if [[ -f "/etc/ssl/certs/ca-certificates.crt" ]]; then
      info "Encontrado arquivo de certificados do sistema. Copiando..."
      cp "/etc/ssl/certs/ca-certificates.crt" "$TEMP_CERT_DIR/system_ca.pem"
      valid_certs=1
    else
      warn "Nenhum certificado CA do sistema encontrado."
      return 1
    fi
  fi
  
  info "✅ Processados $valid_certs certificados válidos."
  
  # Mostra informações sobre os certificados encontrados
  for cert in "$TEMP_CERT_DIR"/*.pem; do
    if [[ -f "$cert" ]] && [[ -s "$cert" ]] && openssl x509 -noout -in "$cert" &>/dev/null; then
      local subject
      local issuer
      local dates
      subject=$(openssl x509 -noout -subject -in "$cert" 2>/dev/null | sed 's/subject=//')
      issuer=$(openssl x509 -noout -issuer -in "$cert" 2>/dev/null | sed 's/issuer=//')
      dates=$(openssl x509 -noout -dates -in "$cert" 2>/dev/null | tr '\n' ' ')
      fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert" 2>/dev/null | sed 's/SHA256 Fingerprint=//')
      
      info "Certificado $(basename "$cert"):"
      info "  - Subject: $subject"
      info "  - Issuer: $issuer"
      info "  - $dates"
      info "  - Fingerprint: $fingerprint"
    else
      # Se o arquivo existe mas não é um certificado válido, remove-o
      if [[ -f "$cert" ]]; then
        warn "Removendo arquivo de certificado inválido: $(basename "$cert")"
        rm -f "$cert"
      fi
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
    if ! kubectl create ns "$NS"; then
      err "Falha ao criar namespace $NS"
      return 1
    fi
  fi
  
  # Verifica se há certificados extraídos
  local cert_count=0
  
  # Primeiro, vamos verificar certificados .pem normais
  if ls "$TEMP_CERT_DIR"/*.pem &>/dev/null; then
    cert_count=$(find "$TEMP_CERT_DIR" -name "*.pem" -a -size +0 | wc -l | tr -d ' ')
  fi
  
  if [[ "$cert_count" -eq 0 ]]; then
    warn "Nenhum certificado .pem encontrado no diretório $TEMP_CERT_DIR."
    
    # Se temos o certificado do sistema como último recurso, usamos ele
    if [[ -f "/etc/ssl/certs/ca-certificates.crt" ]]; then
      warn "Usando certificados CA do sistema como alternativa..."
      cp "/etc/ssl/certs/ca-certificates.crt" "$TEMP_CERT_DIR/system_ca.pem"
      cert_count=1
    else
      warn "Nenhuma fonte de certificados confiáveis encontrada."
      return 1
    fi
  fi
  
  info "Encontrados $cert_count arquivos de certificado para processar."
  
  # Validação adicional: garante que todos os certificados são válidos antes de combinar
  local valid_certs=0
  for cert in "$TEMP_CERT_DIR"/*.pem; do
    if [[ -f "$cert" ]] && [[ -s "$cert" ]]; then
      if openssl x509 -noout -in "$cert" &>/dev/null; then
        valid_certs=$((valid_certs + 1))
      else
        warn "Removendo certificado inválido: $cert"
        rm -f "$cert"
      fi
    fi
  done
  
  if [[ "$valid_certs" -eq 0 ]]; then
    err "Nenhum certificado válido encontrado após validação."
    return 1
  fi
  
  # Combina todos os certificados em um único arquivo
  info "Combinando $valid_certs certificados válidos..."
  cat "$TEMP_CERT_DIR"/*.pem > "$TEMP_CERT_DIR/combined.pem"
  
  # Validação final do arquivo combinado
  if ! openssl x509 -noout -in "$TEMP_CERT_DIR/combined.pem" &>/dev/null; then
    err "O arquivo combinado não contém um certificado X509 válido."
    # Tenta diagnosticar o problema
    warn "Conteúdo do arquivo combinado (primeiras 10 linhas):"
    head -10 "$TEMP_CERT_DIR/combined.pem"
    return 1
  fi
  
  # Cria ou atualiza o secret
  info "Criando/atualizando Secret com os certificados..."
  
  # Verifica se o secret já existe
  if kubectl -n "$NS" get secret "$CERT_SECRET_NAME" >/dev/null 2>&1; then
    info "Secret '$CERT_SECRET_NAME' já existe. Atualizando..."
    if ! kubectl -n "$NS" create secret generic "$CERT_SECRET_NAME" \
          --from-file=ca.crt="$TEMP_CERT_DIR/combined.pem" \
          --dry-run=client -o yaml | kubectl apply -f -; then
      err "Falha ao atualizar o Secret '$CERT_SECRET_NAME'"
      return 1
    fi
  else
    info "Criando novo Secret '$CERT_SECRET_NAME'..."
    if ! kubectl -n "$NS" create secret generic "$CERT_SECRET_NAME" \
          --from-file=ca.crt="$TEMP_CERT_DIR/combined.pem"; then
      err "Falha ao criar o Secret '$CERT_SECRET_NAME'"
      return 1
    fi
  fi
  
  # Verifica se o secret foi criado corretamente
  if kubectl -n "$NS" get secret "$CERT_SECRET_NAME" >/dev/null 2>&1; then
    info "✅ Secret '$CERT_SECRET_NAME' criado/atualizado com sucesso no namespace $NS"
    return 0
  else
    err "❌ Falha ao verificar a existência do Secret '$CERT_SECRET_NAME'"
    return 1
  fi
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

# Limpa recursos problemáticos antes de tentar novamente
cleanup_crashing_pods() {
  info "Verificando e removendo pods em CrashLoopBackOff..."
  
  # Verifica se o namespace existe antes de tentar obter pods
  if ! kubectl get ns "$NS" &>/dev/null; then
    info "Namespace $NS não existe. Não há pods para verificar."
    return 0
  fi
  
  # Verifica se existem pods do cert-manager no namespace
  # Usamos uma abordagem mais segura para consultar pods
  if ! kubectl get pods -n "$NS" &>/dev/null; then
    info "Não foi possível listar pods no namespace $NS."
    return 0
  fi
  
  # Verifica se há algum pod do cert-manager
  local pod_count
  pod_count=$(kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" --no-headers 2>/dev/null | wc -l)
  
  if [[ "$pod_count" -eq 0 ]]; then
    info "Não foram encontrados pods do cert-manager no namespace $NS."
    return 0
  fi
  
  # Agora que confirmamos que há pods, podemos verificar se algum está em CrashLoopBackOff
  # Usamos uma consulta mais segura
  local crash_pods
  crash_pods=$(kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,REASON:.status.containerStatuses[0].state.waiting.reason --no-headers 2>/dev/null | grep -i "CrashLoopBackOff" | awk '{print $1}')
  
  if [[ -n "$crash_pods" ]]; then
    warn "Encontrados pods em CrashLoopBackOff. Tentando remover para nova implantação."
    
    # Tenta deletar os pods com crash para forçar recriação 
    for pod in $crash_pods; do
      info "Removendo pod com problemas: $pod"
      kubectl delete pod -n "$NS" "$pod" --grace-period=0 --force
    done
    
    # Aguarda um momento para garantir que foram removidos
    sleep 5
  else
    info "Nenhum pod em CrashLoopBackOff encontrado."
  fi
}

wait_for_pods() {
  info "Aguardando os pods do cert-manager ficarem prontos..."
  
  # Primeiro verificamos se o namespace existe
  if ! kubectl get ns "$NS" &>/dev/null; then
    info "Namespace $NS não existe. Não há pods para verificar."
    return 0
  fi

  # Espera inicial para dar tempo dos pods serem criados
  sleep 10
  
  local max_attempts=30
  local attempt=0
  local all_ready=false
  
  # Componentes esperados e contagem total
  local expected_components=("controller" "webhook" "cainjector")
  local total_expected=${#expected_components[@]}  # Esperamos 3 pods por padrão
  
  while [ $attempt -lt $max_attempts ] && [ "$all_ready" != "true" ]; do
    attempt=$((attempt+1))
    info "Verificando status dos pods (tentativa $attempt/$max_attempts)..."
    
    # Verifica se os deployments existem primeiro
    local deployments
    deployments=$(kubectl get deployments -n "$NS" -l app.kubernetes.io/instance="$RELEASE" 2>/dev/null)
    local deployment_count
    deployment_count=$(echo "$deployments" | grep -c "$RELEASE" 2>/dev/null || echo "0")
    
    if [[ "$deployment_count" -eq 0 ]]; then
      warn "Nenhum deployment do cert-manager encontrado. Verificando se o Helm Release existe..."
      if ! helm status "$RELEASE" -n "$NS" &>/dev/null; then
        err "O release do Helm '$RELEASE' não existe no namespace '$NS'."
        warn "A instalação pode ter falhado completamente. Verifique os logs do Helm."
        return 1
      fi
      sleep 5
      continue
    fi
    
    # Obtém todos os pods no namespace
    local pod_status
    pod_status=$(kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" 2>/dev/null || echo "")
    
    # Verifica pods com problemas - crash loop, init container, etc
    local crashing_pods
    crashing_pods=$(echo "$pod_status" | grep -E 'CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull' || echo "")
    if [[ -n "$crashing_pods" ]]; then
      err "Detectados pods com problemas:"
      echo "$crashing_pods"
      warn "Verificando logs dos pods com problemas..."
      echo "$crashing_pods" | awk '{print $1}' | while read -r pod; do
        warn "=== Logs do pod $pod ==="
        kubectl logs -n "$NS" "$pod" --tail=50 || true
        warn "=== Descrição do pod $pod ==="
        kubectl describe pod -n "$NS" "$pod" | grep -A 10 -E 'Events:|State:|Last State:' || true
      done
      
      # Se ainda estamos nas primeiras tentativas, damos mais tempo
      if [ "$attempt" -lt 10 ]; then
        warn "Aguardando recuperação dos pods..."
        sleep 20
        continue
      else
        err "Pods continuam em estado de falha após várias tentativas."
        return 1
      fi
    fi
    
    # Verifica quantos pods estão prontos vs. total
    local ready_pods
    local total_pods
    
    # Conta total de pods do cert-manager
    total_pods=$(echo "$pod_status" | grep -c "$RELEASE" || echo "0")
    
    if [[ "$total_pods" -eq 0 ]]; then
      warn "Nenhum pod do cert-manager encontrado ainda. Aguardando criação..."
      kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -5
      sleep 10
      continue
    fi
    
    # Verifica se todos os componentes esperados estão presentes
    local missing_components=()
    for comp in "${expected_components[@]}"; do
      if ! echo "$pod_status" | grep -q "$comp"; then
        missing_components+=("$comp")
      fi
    done
    
    if [[ ${#missing_components[@]} -gt 0 ]]; then
      warn "Componentes ausentes: ${missing_components[*]}"
      warn "Verificando se os deployments estão corretos..."
      kubectl get deployments -n "$NS" -l app.kubernetes.io/instance="$RELEASE"
    fi
    
    # Conta pods que estão prontos (Running e Ready)
    ready_pods=$(kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{range .items[*]}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null | grep -c "Running.*True" || echo "0")
    
    if [[ "$ready_pods" -eq "$total_pods" ]] && [[ "$ready_pods" -ge "$total_expected" ]]; then
      all_ready=true
      info "✅ Todos os pods ($ready_pods/$total_pods) estão prontos!"
      break
    else
      info "Pods prontos: $ready_pods/$total_pods (esperamos pelo menos $total_expected)"
      echo "$pod_status"
    fi
    
    # Verificações extras em intervalos específicos
    if [ "$attempt" -eq 10 ] || [ "$attempt" -eq 20 ]; then
      warn "Pods estão demorando para ficar prontos. Verificando eventos recentes..."
      kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -10
      
      warn "Verificando detalhes dos pods pendentes..."
      echo "$pod_status" | grep -v "Running.*1/1" | while read -r line; do
        pod_name=$(echo "$line" | awk '{print $1}')
        kubectl describe pod -n "$NS" "$pod_name" | grep -A 15 -E 'Events:|State:|Last State:|Conditions:' || true
      done
    fi
    
    sleep 15
  done
  
  if [[ "$all_ready" != "true" ]]; then
    if [[ "$total_pods" -eq 0 ]]; then
      err "Nenhum pod do cert-manager foi criado após $max_attempts tentativas."
      kubectl describe deployments -n "$NS" -l app.kubernetes.io/instance="$RELEASE"
      return 1
    else
      err "Timeout aguardando pods ficarem prontos após $max_attempts tentativas."
      return 1
    fi
  fi
  
  info "✅ Todos os pods do cert-manager estão rodando e prontos."
  kubectl get pods -n "$NS" -l app.kubernetes.io/instance="$RELEASE"
  return 0
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
    info "Detectado arquivo de certificados corporativos, configurando certificados CA"
  elif kubectl -n "$NS" get secret "$CERT_SECRET_NAME" >/dev/null 2>&1; then
    has_corporate_certs=true
    info "Detectado Secret existente com certificados corporativos, configurando certificados CA"
  fi
  
  # Define os valores para o Helm, independente de ter certificados corporativos ou não
  local base_values=(
    "--set" "installCRDs=true"
  )
  
  # Valores para certificados corporativos
  if [[ "$has_corporate_certs" == "true" ]]; then
    info "Configurando montagem de certificados corporativos..."
    extra_values=(
      # Configurações para controller
      "--set" "volumeMounts[0].name=ca-certs"
      "--set" "volumeMounts[0].mountPath=/etc/ssl/certs/ca-certificates.crt"
      "--set" "volumeMounts[0].subPath=ca.crt"
      "--set" "volumes[0].name=ca-certs"
      "--set" "volumes[0].secret.secretName=$CERT_SECRET_NAME"
      # Configurações para webhook
      "--set" "webhook.volumeMounts[0].name=ca-certs"
      "--set" "webhook.volumeMounts[0].mountPath=/etc/ssl/certs/ca-certificates.crt"
      "--set" "webhook.volumeMounts[0].subPath=ca.crt"
      "--set" "webhook.volumes[0].name=ca-certs"
      "--set" "webhook.volumes[0].secret.secretName=$CERT_SECRET_NAME"
      # Configurações para cainjector
      "--set" "cainjector.volumeMounts[0].name=ca-certs"
      "--set" "cainjector.volumeMounts[0].mountPath=/etc/ssl/certs/ca-certificates.crt"
      "--set" "cainjector.volumeMounts[0].subPath=ca.crt"
      "--set" "cainjector.volumes[0].name=ca-certs"
      "--set" "cainjector.volumes[0].secret.secretName=$CERT_SECRET_NAME"
    )
  else
    extra_values=()
  fi
  
  # Combinando os arrays de valores
  local all_values=("${base_values[@]}" "${extra_values[@]}")
  
  # Força desinstalação completa se FORCE_REINSTALL estiver ativado
  if [[ "$FORCE_REINSTALL" == "true" ]] && helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    info "FORCE_REINSTALL ativado. Desinstalando cert-manager existente..."
    helm uninstall "$RELEASE" -n "$NS" || true
    
    # Aguarda um pouco para garantir que tudo foi limpo
    info "Aguardando limpeza completa..."
    sleep 10
    
    # Verifica se CRDs precisam ser removidos manualmente
    kubectl get crd -l app.kubernetes.io/name=cert-manager 2>/dev/null | grep -q "cert-manager" && {
      info "Removendo CRDs do cert-manager manualmente..."
      kubectl delete crd -l app.kubernetes.io/name=cert-manager
      sleep 5
    }
  fi
  
  # Cria arquivo temporário com valores YAML para evitar problemas de escape na linha de comando
  local values_file
  values_file=$(mktemp -t cert-manager-values-XXXXX.yaml)
  
  cat > "$values_file" <<EOF
# Valores padrão
installCRDs: true
EOF

  # Adiciona configurações para certificados corporativos se necessário
  if [[ "$has_corporate_certs" == "true" ]]; then
    cat >> "$values_file" <<EOF
# Configurações para montar certificados corporativos
volumes:
- name: ca-certs
  secret:
    secretName: $CERT_SECRET_NAME
volumeMounts:
- name: ca-certs
  mountPath: /etc/ssl/certs/ca-certificates.crt
  subPath: ca.crt

# Configurações para webhook
webhook:
  volumes:
  - name: ca-certs
    secret:
      secretName: $CERT_SECRET_NAME
  volumeMounts:
  - name: ca-certs
    mountPath: /etc/ssl/certs/ca-certificates.crt
    subPath: ca.crt

# Configurações para cainjector
cainjector:
  volumes:
  - name: ca-certs
    secret:
      secretName: $CERT_SECRET_NAME
  volumeMounts:
  - name: ca-certs
    mountPath: /etc/ssl/certs/ca-certificates.crt
    subPath: ca.crt
EOF
  fi
  
  info "Valores para instalação configurados em $values_file"
  
  # Executa o comando Helm
  local result=0
  if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    info "Release existente encontrado. Executando upgrade..."
    helm upgrade "$RELEASE" "$CHART" \
      --namespace "$NS" \
      --version "$CHART_VERSION" \
      --values "$values_file" \
      --timeout "$TIMEOUT" \
      --wait || result=$?
  else
    info "Nenhum release existente. Executando instalação..."
    helm install "$RELEASE" "$CHART" \
      --namespace "$NS" \
      --create-namespace \
      --version "$CHART_VERSION" \
      --values "$values_file" \
      --timeout "$TIMEOUT" \
      --wait || result=$?
  fi
  
  # Remove o arquivo temporário
  rm -f "$values_file"
  
  if [ "$result" -eq 0 ]; then
    info "✅ Deploy/Upgrade do Helm concluído com sucesso!"
    return 0
  else
    err "❌ Deploy/Upgrade do Helm falhou com código $result."
    # Exibe recursos criados para diagnóstico
    kubectl get all -n "$NS"
    return 1
  fi
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
  info ""
  info "SOLUÇÃO DE PROBLEMAS:"
  info "- Se os pods continuarem com falhas, execute com FORCE_REINSTALL=true:"
  info "  FORCE_REINSTALL=true ./deploy-cert-manager.sh"
  info "- Para diagnosticar problemas com certificados:"
  info "  ./diagnose-certificates.sh"
  info "=================================================="
}

# --- Funções de Diagnóstico ---
show_diagnostics() {
  info "=== INICIANDO DIAGNÓSTICO DE PROBLEMAS ==="
  
  # Verifica status da conexão com o cluster
  info "Verificando conexão com o cluster Kubernetes:"
  kubectl cluster-info 2>&1 | head -2 || true
  
  # Verifica estado do namespace
  info "Verificando estado do namespace $NS:"
  kubectl get ns "$NS" -o yaml 2>/dev/null || echo "Namespace não existe"
  
  # Verifica CRDs do cert-manager
  info "Verificando CRDs do cert-manager:"
  kubectl get crd | grep -E 'cert-manager|certmanager' || echo "Nenhum CRD do cert-manager encontrado"
  
  # Verifica pods no namespace
  info "Verificando recursos no namespace $NS:"
  kubectl get all -n "$NS" || echo "Nenhum recurso encontrado ou namespace não existe"
  
  # Verifica eventos recentes no namespace
  info "Eventos recentes no namespace $NS:"
  kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -10 || true
  
  # Verifica versões de Helm e charts utilizados
  info "Versão do Helm:"
  helm version --short || true
  
  info "Repositórios Helm configurados:"
  helm repo list | grep jetstack || echo "Repositório jetstack não encontrado"
  
  info "Verificando release do cert-manager:"
  helm list -n "$NS" || echo "Nenhum release encontrado"
  
  # Verifica recursos específicos do cert-manager
  info "Verificando certificados e issuers:"
  kubectl get certificates,issuers,clusterissuers --all-namespaces 2>/dev/null || true
  
  # Verifica configuração de rede para o Let's Encrypt
  info "Verificando acesso a servidores ACME do Let's Encrypt:"
  timeout 5 curl -s -o /dev/null -w "%{http_code}" "$LETSENCRYPT_URL" || echo "Não foi possível conectar ao Let's Encrypt"
  
  info "=== FIM DO DIAGNÓSTICO ==="
}

# --- Função Principal ---
main() {
  local status=0
  
  # Verifica requisitos de ferramentas antes de começar
  info "Verificando dependências de ferramentas..."
  if ! check_command kubectl helm openssl; then
    err "Ferramentas necessárias não encontradas. Abortando."
    exit 1
  fi
  
  info "Verificando conexão com o cluster Kubernetes..."
  if ! kubectl cluster-info &>/dev/null; then
    err "Não foi possível conectar ao cluster Kubernetes. Verifique sua configuração kubeconfig."
    exit 1
  fi
  
  # Quando FORCE_REINSTALL é true, primeiro fazemos uma limpeza completa
  if [[ "$FORCE_REINSTALL" == "true" ]]; then
    info "Modo FORCE_REINSTALL ativado: Realizando limpeza completa primeiro..."
    
    # Verifica se o namespace existe e o limpa completamente
    if kubectl get ns "$NS" &>/dev/null; then
      warn "Desinstalando qualquer release existente do cert-manager..."
      if helm list -n "$NS" | grep -q "$RELEASE"; then
        info "Release $RELEASE encontrado, desinstalando..."
        helm uninstall "$RELEASE" -n "$NS" || {
          warn "Erro ao desinstalar helm release. Tentando prosseguir mesmo assim."
        }
      else
        info "Nenhum release helm encontrado no namespace $NS."
      fi
      
      # Remove CRDs relacionados ao cert-manager para evitar "recursos órfãos"
      warn "Removendo CRDs do cert-manager..."
      kubectl delete crd -l app.kubernetes.io/name=cert-manager 2>/dev/null || true
      sleep 3
      kubectl delete crd -l app.kubernetes.io/instance=cert-manager 2>/dev/null || true
      
      # Agora remove o namespace depois que os CRDs e releases foram removidos
      warn "Removendo namespace $NS para reinstalação limpa..."
      kubectl delete ns "$NS" --wait=false
      
      # Espera até que o namespace seja totalmente removido
      local timeout=60  # 60 segundos de timeout
      local start_time=$(date +%s)
      while kubectl get ns "$NS" &>/dev/null; do
        local current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
          warn "Timeout aguardando remoção do namespace. Continuando mesmo assim..."
          break
        fi
        info "Aguardando remoção do namespace $NS..."
        sleep 5
      done
    else
      # Remove CRDs mesmo se o namespace não existir
      warn "Removendo CRDs do cert-manager..."
      kubectl delete crd -l app.kubernetes.io/name=cert-manager 2>/dev/null || true
      sleep 2
      kubectl delete crd -l app.kubernetes.io/instance=cert-manager 2>/dev/null || true
    fi
    
    # Pausa adicional para garantir que tudo foi limpo
    info "Aguardando para garantir que a limpeza foi concluída..."
    sleep 5
  fi
  
  # Primeiro configuramos o ambiente básico (namespace, repos)
  info "Configurando ambiente básico..."
  if ! setup_environment; then
    err "Falha ao configurar o ambiente básico."
    exit 1
  fi
  
  # Agora verificamos se estamos em uma rede corporativa com proxy SSL
  info "Verificando configuração de rede..."
  if [[ "$SKIP_CERT_CHECK" != "true" ]]; then
    if check_corporate_network; then
      info "Detectada rede corporativa com interceptação SSL."
      if ! create_cert_config; then
        warn "Falha ao extrair certificados corporativos. Continuando mesmo assim, mas pode haver problemas de conexão SSL."
      else
        info "Configuração de certificados corporativos concluída com sucesso."
      fi
    else
      info "Rede não parece ter interceptação SSL, continuando normalmente."
    fi
  else
    info "Verificação de certificados corporativos foi desativada (SKIP_CERT_CHECK=true)."
  fi
  
  # Removemos pods em crash antes de tentar uma nova instalação
  info "Limpando pods em estado de falha (se houver)..."
  cleanup_crashing_pods
  
  # Agora instalamos o cert-manager (já com o namespace e certificados preparados)
  info "Iniciando a instalação do cert-manager..."
  
  # Se estamos em um modo de reinstalação, adicionamos uma pausa extra
  if [[ "$FORCE_REINSTALL" == "true" ]]; then
    info "Garantindo que o ambiente está pronto após limpeza..."
    sleep 5
  fi
  
  # Tenta a instalação com retries em caso de falha
  local max_attempts=3
  local attempt=1
  local install_success=false
  
  # Loop de tentativas de instalação
  while [[ "$attempt" -le "$max_attempts" && "$install_success" != "true" ]]; do
    info "Tentativa $attempt/$max_attempts de instalar o cert-manager..."
    
    if install_cert_manager; then
      install_success=true
      info "Instalação do cert-manager concluída com sucesso!"
    else
      warn "Falha na instalação (tentativa $attempt/$max_attempts)"
      
      # Se não for a última tentativa, tenta diagnosticar e corrigir problemas
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        warn "Diagnosticando falha e tentando corrigir problemas..."
        
        # Verifica se há problemas com secrets
        kubectl get secrets -n "$NS" | grep -q "$CERT_SECRET_NAME" && {
          warn "Secret $CERT_SECRET_NAME já existe. Tentando recriar..."
          kubectl delete secret "$CERT_SECRET_NAME" -n "$NS" || true
          
          # Recria os certificados se necessário
          if [[ "$SKIP_CERT_CHECK" != "true" ]] && check_corporate_network; then
            create_cert_config
          fi
        }
        
        warn "Aguardando antes da próxima tentativa..."
        sleep 10
      fi
      
      attempt=$((attempt + 1))
    fi
  done
  
  # Verificação final após todas as tentativas
  if [[ "$install_success" != "true" ]]; then
    err "❌ Falha na instalação do cert-manager após $max_attempts tentativas."
    show_diagnostics
    exit 1
  fi
  
  # Agora que a instalação foi bem-sucedida, configura o resto
  info "Verificando pods do cert-manager..."
  if ! wait_for_pods; then
    err "❌ Falha ao aguardar pods do cert-manager."
    status=1
  else
    info "✅ Todos os pods do cert-manager estão rodando corretamente."
  fi
  
  info "Verificando CRDs do cert-manager..."
  if ! verify_crds; then
    err "❌ Falha ao verificar CRDs do cert-manager."
    status=1
  else
    info "✅ CRDs do cert-manager verificados com sucesso."
  fi
  
  info "Criando ClusterIssuer..."
  if ! create_cluster_issuer; then
    err "❌ Falha ao criar ClusterIssuer."
    status=1
  else
    info "✅ ClusterIssuer criado com sucesso."
  fi
  
  info "Verificando instalação completa..."
  if ! verify_installation; then
    err "❌ Falha ao verificar instalação."
    status=1
  else
    info "✅ Verificação de instalação concluída com sucesso."
  fi
  
  # Mostra resumo final
  show_summary
  
  # Limpa certificados temporários
  [[ -d "$TEMP_CERT_DIR" ]] && rm -rf "$TEMP_CERT_DIR"
  
  if [[ "$status" -eq 0 ]]; then
    info "🎉 Instalação do cert-manager concluída com sucesso!"
    return 0
  else
    warn "⚠️ Instalação do cert-manager concluída com alguns avisos ou erros."
    return 1
  fi
}

# --- Ponto de Entrada ---
main "$@"
