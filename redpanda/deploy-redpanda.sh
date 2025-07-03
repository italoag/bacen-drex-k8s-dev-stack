#!/usr/bin/env bash
# Deploy / upgrade Redpanda e validar endpoints
set -Eeuo pipefail

# Variáveis padrão
RELEASE=redpanda
NS=redpanda
VALUES=redpanda-values.yaml
MONITORING_VALUES=redpanda-values-monitoring.yaml
CHART=redpanda/redpanda
TIMEOUT=600s # Aumentado para dar mais tempo para o deploy

ISSUER=selfsigned          # ClusterIssuer
DOMAIN=redpanda.rd          # host público padrão
BROKER_PLAIN=31094         # Porta NodePort para PLAINTEXT
BROKER_TLS=31095           # Porta NodePort para TLS
LOCAL_IP=127.0.0.1
ENABLE_TLS=true            # Habilitar TLS por padrão
ENABLE_MONITORING=false    # Monitoramento desabilitado por padrão

log(){ printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){ printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }
warn(){ printf '\e[33m[WARN]\e[0m %s\n' "$*"; }
header(){ printf '\n\e[1m%s\e[0m\n%s\n' "$*" "========================================"; }

# Função para exibir ajuda
show_help() {
  cat <<EOF
Uso: $0 [OPÇÕES]

Opções:
  --domain DOMAIN     Define o domínio para acesso externo (ex: kafka.exemplo.com.br)
  --tls               Habilita TLS para as conexões Kafka (padrão: habilitado)
  --no-tls            Desabilita TLS para as conexões Kafka
  --monitoring        Habilita recursos de monitoramento (Prometheus, Grafana)
  --help              Exibe esta mensagem de ajuda

Exemplo:
  $0 --domain kafka.meudominio.com.br --tls --monitoring
EOF
  exit 0
}

# Parse dos argumentos da linha de comando
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --tls)
      ENABLE_TLS=true
      shift
      ;;
    --no-tls)
      ENABLE_TLS=false
      shift
      ;;
    --monitoring)
      ENABLE_MONITORING=true
      shift
      ;;
    --help)
      show_help
      ;;
    *)
      warn "Opção desconhecida: $key"
      show_help
      ;;
  esac
done

rollback(){ helm uninstall "$RELEASE" -n "$NS" || true; kubectl delete ns "$NS" --wait=false || true; }
trap 'err "Falha linha $LINENO"; read -rp "Rollback? [y/N]: " a && [[ $a =~ ^[Yy]$ ]] && rollback' ERR

retry(){ local n=1 max=$1; shift; until "$@"; do (( n++>max )) && return 1; warn "retry $n/$max…"; sleep 10; done; }

# Inicia com um cabeçalho
header "INICIANDO DEPLOYMENT DO REDPANDA"

### 1 ─ Pré-check Issuer
kubectl get clusterissuer "$ISSUER" >/dev/null || { err "ClusterIssuer $ISSUER não existe"; exit 1; }

### 2 ─ Helm repo & namespace
helm repo add redpanda https://charts.redpanda.com >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

### 3 ─ Install / upgrade
header "CONFIGURANDO O REDPANDA"
log "Iniciando deploy/upgrade do Redpanda..."

# Usa ExternalIP em vez de InternalIP para acessibilidade externa
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
# Fallback para InternalIP se ExternalIP não estiver disponível
if [ -z "$NODE_IP" ]; then
  NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  log "Nenhum IP externo encontrado, usando IP interno: $NODE_IP"
else
  log "Usando IP externo do nó: $NODE_IP"
fi

log "Usando valores dinâmicos: DOMAIN=$DOMAIN, NODE_IP=$NODE_IP"

# Comandos Helm com parâmetros dinâmicos usando --set
HELM_ARGS=(
  "--set" "external.domain=$DOMAIN"
  "--set" "tls.certs.external.ipAddresses[0]=$NODE_IP"
  "--set" "listeners.kafka.external.default.advertisedAddresses[0]=$DOMAIN"
  "--set" "console.ingress.hosts[0].host=$DOMAIN"
  "--set" "console.ingress.hosts[0].paths[0].path=/"
  "--set" "console.ingress.hosts[0].paths[0].pathType=Prefix"
)

# Adicionar configurações de TLS se habilitado
if [ "$ENABLE_TLS" = "true" ]; then
  log "TLS habilitado para conexões Kafka"
  HELM_ARGS+=(
    "--set" "tls.enabled=true"
    "--set" "tls.certs.external.caEnabled=true"
    "--set" "tls.certs.external.issuerRef.name=$ISSUER"
    "--set" "tls.certs.external.issuerRef.kind=ClusterIssuer"
  )
else
  log "TLS desabilitado para conexões Kafka"
  HELM_ARGS+=(
    "--set" "tls.enabled=false"
  )
fi

# Escolher arquivo de valores com base na opção de monitoramento
VALUES_FILE="$VALUES"
if [ "$ENABLE_MONITORING" = "true" ]; then
  log "Recursos de monitoramento habilitados"
  if [ -f "$MONITORING_VALUES" ]; then
    VALUES_FILE="$MONITORING_VALUES"
    log "Usando arquivo de valores para monitoramento: $MONITORING_VALUES"
  else
    warn "Arquivo de valores para monitoramento não encontrado. Usando configuração padrão."
  fi
fi

if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  log "Helm release $RELEASE encontrado, fazendo upgrade..."
  helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$VALUES_FILE" "${HELM_ARGS[@]}" --timeout "$TIMEOUT"
else
  log "Instalando $RELEASE pela primeira vez..."
  helm install "$RELEASE" "$CHART" -n "$NS" -f "$VALUES_FILE" "${HELM_ARGS[@]}" --timeout "$TIMEOUT"
fi

### 4 ─ Wait pods
log "Aguardando pods ficarem prontos..."
retry 20 kubectl -n "$NS" rollout status sts/redpanda
retry 20 kubectl -n "$NS" wait pod -l app.kubernetes.io/name=console --for=condition=ready --timeout="$TIMEOUT"

### 5 ─ Obtém NodePort
log "Obtendo informações para conexão..."
# Descobrir NodePort para broker externo
NODEPORT_BROKER=$(kubectl -n "$NS" get svc "$RELEASE"-external -o jsonpath='{.spec.ports[?(@.name=="kafka-default")].nodePort}')

# Log detalhes do serviço para debug
log "Detalhes do serviço externo:"
kubectl -n "$NS" get svc "$RELEASE"-external -o yaml | grep -A 20 ports:

log "Usando endereço $NODE_IP e NodePort $NODEPORT_BROKER para validação"

### 6 ─ Verificar Ingress
log "Verificando Ingress do console..."
kubectl -n "$NS" get ingress

### 7 ─ Validações básicas
# Teste porta NodePort externa com nc padrão (sem timeout)
log "Testando conexão no NodePort $NODEPORT_BROKER..."
if nc -z -w 5 "$NODE_IP" "$NODEPORT_BROKER" 2>/dev/null; then
  log "✅ Porta $NODEPORT_BROKER está respondendo!"
else
  warn "❌ Porta $NODEPORT_BROKER não está respondendo ainda. Continuando anyway..."
fi

header "VERIFICANDO CONECTIVIDADE REDPANDA"

# Teste rpk se instalado
if command -v rpk >/dev/null; then
  log "rpk encontrado, testando conexão..."
  
  CERT_PATH="./ca.crt"
  SECRET_FOUND=false
  
  if [ "$ENABLE_TLS" = "true" ]; then
    # Verificar se o certificado CA já foi gerado
    log "Procurando certificados disponíveis..."
    
    # Verificando diferentes nomes de secrets possíveis
    CERT_SECRETS=(
      "redpanda-external-ca"        # Nome atual
      "${RELEASE}-external-ca"      # Nome alternativo usando variável release
      "${RELEASE}-external-cert"    # Variações antigas
      "${RELEASE}-external-root-certificate"
      "redpanda-external-cert" 
      "redpanda-external-root-certificate"
    )
    
    for SECRET_NAME in "${CERT_SECRETS[@]}"; do
      if kubectl -n "$NS" get secret "$SECRET_NAME" &>/dev/null; then
        log "Certificado encontrado: $SECRET_NAME"
        
        # Tentar diferentes caminhos para o certificado
        if kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$CERT_PATH"; then
          if [ -s "$CERT_PATH" ]; then
            SECRET_FOUND=true
            log "Certificado CA exportado para $CERT_PATH"
            break
          fi
        elif kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$CERT_PATH"; then
          if [ -s "$CERT_PATH" ]; then
            SECRET_FOUND=true
            log "Certificado TLS exportado para $CERT_PATH"
            break
          fi
        fi
        
        # Se chegou aqui, o secret existe mas não conseguimos extrair o certificado
        log "Secret encontrado mas não conseguimos extrair o certificado válido"
      fi
    done
    
    if ! $SECRET_FOUND; then
      warn "Nenhum certificado CA encontrado, TLS pode não funcionar corretamente"
    fi
  else
    log "TLS está desativado, ignorando verificação de certificados"
  fi
  
  # Executar sequência de testes de conectividade
  CONNECTED=false
  
  # Teste 1: Com TLS usando hostname (se TLS habilitado)
  if [ "$ENABLE_TLS" = "true" ] && $SECRET_FOUND; then
    log "Teste 1: Tentando conexão com TLS usando hostname..."
    if rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER" --tls-enabled --tls-truststore "$CERT_PATH" &>/dev/null; then
      log "✅ Conexão com TLS via hostname: SUCESSO"
      rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER" --tls-enabled --tls-truststore "$CERT_PATH"
      CONNECTED=true
    else
      warn "❌ Conexão com TLS via hostname: FALHOU"
    fi
  else
    [ "$ENABLE_TLS" = "true" ] && warn "Pulando teste com TLS (certificado não encontrado)"
  fi
  
  # Teste 2: Sem TLS usando IP (sempre tenta este teste)
  if ! $CONNECTED; then
    log "Teste 2: Tentando conexão sem TLS usando IP..."
    if rpk cluster info --brokers "$NODE_IP:$NODEPORT_BROKER" &>/dev/null; then
      log "✅ Conexão sem TLS via IP: SUCESSO"
      rpk cluster info --brokers "$NODE_IP:$NODEPORT_BROKER"
      CONNECTED=true
    else
      warn "❌ Conexão sem TLS via IP: FALHOU"
    fi
  fi
  
  # Teste 3: Sem TLS usando hostname (último recurso)
  if ! $CONNECTED; then
    log "Teste 3: Tentando conexão sem TLS usando hostname..."
    if rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER" &>/dev/null; then
      log "✅ Conexão sem TLS via hostname: SUCESSO"
      rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER"
      CONNECTED=true
    else
      warn "❌ Conexão sem TLS via hostname: FALHOU"
    fi
  fi
  
  if ! $CONNECTED; then
    warn "❌ Não foi possível estabelecer conexão com o Redpanda"
    warn "Verifique se os pods estão funcionando corretamente e tente novamente em alguns minutos"
  fi
else
  warn "Comando rpk não encontrado, pulando teste de conectividade"
  warn "Para testar manualmente, instale rpk: https://docs.redpanda.com/docs/install-upgrade/rpk-install/"
fi

### 8 ─ Verifica DNS
log "Verificando resolução de DNS para $DOMAIN..."
DNS_CHECK=$(ping -c1 "$DOMAIN" 2>/dev/null || echo "Failed")
if [[ "$DNS_CHECK" != "Failed" ]]; then
  RESOLVED_IP=$(ping -c1 "$DOMAIN" | grep PING | awk -F '[()]' '{print $2}')
  log "DNS para $DOMAIN está OK! (Resolving to $RESOLVED_IP)"
  
  if [[ "$RESOLVED_IP" != "$NODE_IP" ]]; then
    warn "DNS está resolvendo para $RESOLVED_IP, mas os testes estão usando $NODE_IP"
    warn "Isto pode causar falhas de conexão se os IPs não forem acessíveis entre si"
  fi
else
  warn "DNS para $DOMAIN não está resolvendo. Verifique sua configuração do dnsmasq."
  log "Adicione no /etc/hosts: $NODE_IP $DOMAIN redpanda-0.$DOMAIN"
fi

### 9 ─ Info final
header "DEPLOYMENT CONCLUÍDO"

# Verifica porta do console
CONSOLE_PROTOCOL="http"
if [ "$ENABLE_TLS" = "true" ]; then
  CONSOLE_PROTOCOL="https"
fi

log "Verificando acesso ao console web..."
if curl -s -o /dev/null -m 5 -w "%{http_code}" -k "${CONSOLE_PROTOCOL}://$DOMAIN" 2>/dev/null; then
  STATUS_CODE=$(curl -s -o /dev/null -m 5 -w "%{http_code}" -k "${CONSOLE_PROTOCOL}://$DOMAIN" 2>/dev/null)
  if [ "$STATUS_CODE" = "200" ] || [ "$STATUS_CODE" = "302" ]; then
    log "✅ Console acessível via ${CONSOLE_PROTOCOL}://$DOMAIN (status $STATUS_CODE)"
  else
    warn "⚠️ Console responde com status $STATUS_CODE em ${CONSOLE_PROTOCOL}://$DOMAIN"
  fi
else
  warn "❌ Console não parece estar acessível. Verifique a configuração do Ingress e DNS"
  
  # Informações adicionais sobre o ingress
  log "Detalhes do ingress:"
  kubectl -n "$NS" describe ingress
  
  # Obter o IP do Ingress e sugerir um acesso alternativo
  INGRESS_IP=$(kubectl -n "$NS" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "$INGRESS_IP" ]; then
    log "Tente acessar o console através do IP do Ingress: ${CONSOLE_PROTOCOL}://$INGRESS_IP"
  fi
fi

# Mensagem de resumo final com informações coloridas
echo ""
echo -e "\e[1;32m🎉  REDPANDA DEPLOYMENT CONCLUÍDO\e[0m"
echo ""
echo -e "\e[1mVerifique:\e[0m"
echo "1. Resolução DNS: $DOMAIN deve apontar para $NODE_IP"
echo "2. Adicione no /etc/hosts se necessário:"
echo "   $NODE_IP  $DOMAIN redpanda-0.$DOMAIN"
echo ""
echo -e "\e[1mEndpoints:\e[0m"
echo -e "Console Web     → ${CONSOLE_PROTOCOL}://$DOMAIN"
echo -e "Kafka (NodePort) → $NODE_IP:$NODEPORT_BROKER"
echo ""
echo -e "\e[1mVerificação adicional:\e[0m"
echo "kubectl -n $NS get all"
echo "kubectl -n $NS get ingress"
echo "kubectl -n $NS describe pod -l app.kubernetes.io/name=console"
echo "kubectl -n $NS logs -l app.kubernetes.io/name=console"
echo ""
echo -e "\e[1mPara conectar ao Kafka:\e[0m"

echo -e "\e[32m# Via IP sem TLS:\e[0m"
echo "rpk cluster info --brokers $NODE_IP:$NODEPORT_BROKER"
echo ""

if [ "$ENABLE_TLS" = "true" ] && [ -f "$CERT_PATH" ]; then
  echo -e "\e[32m# Via hostname com TLS (recomendado para produção):\e[0m"
  echo "rpk cluster info --brokers $DOMAIN:$NODEPORT_BROKER --tls-enabled --tls-truststore $CERT_PATH"
  echo ""
fi

echo -e "\e[32m# Via hostname sem TLS:\e[0m"
echo "rpk cluster info --brokers $DOMAIN:$NODEPORT_BROKER"
echo ""

echo -e "\e[1mPara diagnosticar problemas de conectividade:\e[0m"
echo "./test-redpanda-connectivity.sh"
echo ""

# Garantir que o script de teste de conectividade seja executável
if [ -f "./test-redpanda-connectivity.sh" ]; then
  chmod +x ./test-redpanda-connectivity.sh 2>/dev/null || true
fi