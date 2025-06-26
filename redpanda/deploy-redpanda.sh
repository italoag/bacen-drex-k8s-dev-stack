#!/usr/bin/env bash
# Deploy / upgrade Redpanda e validar endpoints
set -Eeuo pipefail

RELEASE=redpanda
NS=redpanda
VALUES=redpanda-values.yaml
CHART=redpanda/redpanda
TIMEOUT=600s # Aumentado para dar mais tempo para o deploy

ISSUER=selfsigned          # ClusterIssuer
DOMAIN=redpanda.rd          # host público
BROKER_PLAIN=31094         # Porta NodePort para PLAINTEXT (atualizada)
BROKER_TLS=31095           # Porta NodePort para TLS (atualizada)
LOCAL_IP=127.0.0.1

log(){ printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
err(){ printf '\e[31m[ERR ]\e[0m  %s\n' "$*"; }
warn(){ printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

rollback(){ helm uninstall "$RELEASE" -n "$NS" || true; kubectl delete ns "$NS" --wait=false || true; }
trap 'err "Falha linha $LINENO"; read -rp "Rollback? [y/N]: " a && [[ $a =~ ^[Yy]$ ]] && rollback' ERR

retry(){ local n=1 max=$1; shift; until "$@"; do (( n++>max )) && return 1; warn "retry $n/$max…"; sleep 10; done; }

### 1 ─ Pré-check Issuer
kubectl get clusterissuer "$ISSUER" >/dev/null || { err "ClusterIssuer $ISSUER não existe"; exit 1; }

### 2 ─ Helm repo & namespace
helm repo add redpanda https://charts.redpanda.com >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

### 3 ─ Install / upgrade
log "Iniciando deploy/upgrade do Redpanda..."
if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  log "Helm release $RELEASE encontrado, fazendo upgrade..."
  helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$VALUES" --timeout "$TIMEOUT"
else
  log "Instalando $RELEASE pela primeira vez..."
  helm install "$RELEASE" "$CHART" -n "$NS" -f "$VALUES" --timeout "$TIMEOUT"
fi

### 4 ─ Wait pods
log "Aguardando pods ficarem prontos..."
retry 20 kubectl -n "$NS" rollout status sts/redpanda
retry 20 kubectl -n "$NS" wait pod -l app.kubernetes.io/name=console --for=condition=ready --timeout="$TIMEOUT"

### 5 ─ Descobre IP público e NodePort
log "Obtendo informações para conexão..."
# Usa ExternalIP em vez de InternalIP para acessibilidade externa
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
# Fallback para InternalIP se ExternalIP não estiver disponível
if [ -z "$NODE_IP" ]; then
  NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  log "Nenhum IP externo encontrado, usando IP interno: $NODE_IP"
fi
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

# Teste rpk se instalado
if command -v rpk >/dev/null; then
  log "rpk encontrado, testando conexão..."
  
  # Lista todos os secrets disponíveis para debug
  log "Procurando certificados disponíveis:"
  kubectl -n "$NS" get secrets | grep -E 'cert|certificate'
  
  # Verificando diferentes nomes de secrets possíveis
  CERT_SECRETS=("${RELEASE}-external-cert" 
                "${RELEASE}-external-root-certificate"
                "redpanda-external-cert" 
                "redpanda-external-root-certificate")
  
  SECRET_FOUND=false
  for SECRET_NAME in "${CERT_SECRETS[@]}"; do
    if kubectl -n "$NS" get secret "$SECRET_NAME" &>/dev/null; then
      log "Certificado encontrado: $SECRET_NAME"
      kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > /tmp/ca.crt || \
      kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > /tmp/ca.crt
      
      if [ -s /tmp/ca.crt ]; then
        SECRET_FOUND=true
        log "Certificado exportado para /tmp/ca.crt"
        break
      else
        rm -f /tmp/ca.crt
      fi
    fi
  done
  
  # Primeiro tentar conexão usando hostname com TLS (o certificado é válido para o hostname)
  log "Tentando conexão com TLS usando hostname..."
  if $SECRET_FOUND && rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER" --tls-enabled --tls-truststore /tmp/ca.crt; then
    log "✅ rpk TLS info via hostname OK"
  else
    # Em caso de falha, tentar sem TLS usando IP
    warn "Não conseguiu conectar via TLS com hostname, tentando sem TLS usando IP..."
    if rpk cluster info --brokers "$NODE_IP:$NODEPORT_BROKER"; then
      log "✅ rpk info OK (sem TLS)"
    else
      warn "❌ rpk não conseguiu conectar sem TLS por IP"
      
      # Como último recurso, tentar sem TLS usando hostname
      warn "Tentando sem TLS usando hostname..."
      if rpk cluster info --brokers "$DOMAIN:$NODEPORT_BROKER"; then
        log "✅ rpk info OK (sem TLS via hostname)"
      else
        warn "❌ rpk não conseguiu conectar (pode ignorar em dev)"
      fi
    fi
  fi
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
cat <<EOF

🎉  Deploy concluído.

Verifique:
1. Resolução DNS: $DOMAIN deve apontar para $NODE_IP
2. Adicione no /etc/hosts se necessário:
   $NODE_IP  $DOMAIN redpanda-0.$DOMAIN

Endpoints:
Console    → http://$DOMAIN
Kafka (NodePort) → $NODE_IP:$NODEPORT_BROKER

Para verificação adicional, execute:
kubectl -n $NS get all
kubectl -n $NS get ingress
kubectl -n $NS describe pod -l app.kubernetes.io/name=console
kubectl -n $NS logs -l app.kubernetes.io/name=console

Para conectar ao Kafka:
rpk cluster info --brokers $NODE_IP:$NODEPORT_BROKER
EOF

# Verifica porta do console
log "Tentando executar curl no console para verificar acesso..."
if curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$DOMAIN" 2>/dev/null; then
  log "✅ Console acessível via http://$DOMAIN"
else
  warn "❌ Console não parece estar acessível. Verifique a configuração do Ingress e DNS"
  
  # Informações adicionais sobre o ingress
  log "Detalhes do ingress:"
  kubectl -n "$NS" describe ingress
  
  # Obter o IP do Ingress e sugerir um acesso alternativo
  INGRESS_IP=$(kubectl -n "$NS" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
  if [ -n "$INGRESS_IP" ]; then
    log "Tente acessar o console através do IP do Ingress: http://$INGRESS_IP"
  fi
fi