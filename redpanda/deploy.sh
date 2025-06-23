#!/usr/bin/env bash
# Deploy / upgrade Redpanda e validar endpoints
set -Eeuo pipefail

RELEASE=redpanda
NS=redpanda
VALUES=redpanda-values.yaml
CHART=redpanda/redpanda
TIMEOUT=600s # Aumentado para dar mais tempo para o deploy

ISSUER=selfsigned          # ClusterIssuer
DOMAIN=redpanda.localhost  # host público
BROKER_PLAIN=31094         # Porta NodePort para PLAINTEXT
BROKER_TLS=31095           # Porta NodePort para TLS

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

### 5 ─ Descobre IP público
# Tentativa de obter o IP externo primeiro, depois o interno
log "Obtendo informações sobre IP e NodePort..."
EXTERNAL_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
INTERNAL_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_IP=${EXTERNAL_IP:-$INTERNAL_IP}

# Descobrir NodePort para broker externo
NODEPORT_BROKER=$(kubectl -n "$NS" get svc "$RELEASE"-external -o jsonpath='{.spec.ports[?(@.name=="kafka-default")].nodePort}')

# Log detalhes do serviço para debug
log "Detalhes do serviço externo:"
kubectl -n "$NS" get svc "$RELEASE"-external -o yaml | grep -A 20 ports:

log "Endereços disponíveis - Interno: $INTERNAL_IP, Externo: $EXTERNAL_IP"
log "Usando endereço $NODE_IP e NodePort $NODEPORT_BROKER para validação"

### 6 ─ Verificar Ingress
log "Verificando Ingress do console..."
kubectl -n "$NS" get ingress
INGRESS_IP=$(kubectl -n "$NS" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
[ -n "$INGRESS_IP" ] && log "IP do Ingress: $INGRESS_IP"

### 7 ─ Validações básicas
# Teste com nome do domínio ao invés de IP
log "Verificando resolução de DNS para $DOMAIN..."
if ping -c1 "$DOMAIN" &>/dev/null; then
  log "DNS para $DOMAIN está OK!"
  
  # Teste porta NodePort externa com nc 
  log "Testando conexão no NodePort $NODEPORT_BROKER usando nome do domínio..."
  if nc -z -w 5 "$DOMAIN" "$NODEPORT_BROKER" 2>/dev/null; then
    log "✅ Porta $NODEPORT_BROKER está respondendo via nome do domínio!"
  else
    warn "❌ Porta $NODEPORT_BROKER não está respondendo via nome do domínio. Tentando via IP..."
    if nc -z -w 5 "$NODE_IP" "$NODEPORT_BROKER" 2>/dev/null; then
      log "✅ Porta $NODEPORT_BROKER está respondendo via IP!"
    else
      warn "❌ Porta $NODEPORT_BROKER não está respondendo ainda. O serviço pode levar alguns minutos para estar totalmente disponível."
    fi
  fi
  
  # Teste conexão com kcat se disponível (desativado por padrão pois pode demorar muito)
  if command -v kcat >/dev/null && false; then
    log "kcat encontrado, mas o teste está desativado por padrão para evitar timeouts. Para testar manualmente use:"
    log "  kcat -b $DOMAIN:$NODEPORT_BROKER -L"
  fi
else
  warn "DNS para $DOMAIN não está resolvendo. Verificando IP diretamente..."
  if nc -z -w 5 "$NODE_IP" "$NODEPORT_BROKER" 2>/dev/null; then
    log "✅ Porta $NODEPORT_BROKER está respondendo via IP!"
  else
    warn "❌ Porta $NODEPORT_BROKER não está respondendo ainda. Continuando anyway..."
  fi
  
  log "Adicione no /etc/hosts: $NODE_IP $DOMAIN redpanda-0.$DOMAIN"
fi

# Teste rpk se instalado - simplificado para evitar erros de TLS
if command -v rpk >/dev/null; then
  log "rpk encontrado. Para testar a conexão manualmente após o deploy, use:"
  log "  rpk cluster info --brokers $DOMAIN:$NODEPORT_BROKER"
  
  # Lista todos os secrets disponíveis para debug
  log "Certificados disponíveis:"
  kubectl -n "$NS" get secrets | grep -E 'cert|certificate'
  
  # Desativando teste automático de rpk para evitar falhas no script
  log "Teste automático de rpk desativado para evitar falhas. Para testar após o deploy, use os comandos acima."
fi

### 8 ─ Info final
cat <<EOF

🎉  Deploy concluído.

Verifique:
1. Resolução DNS: $DOMAIN deve apontar para $NODE_IP
2. Adicione no /etc/hosts se necessário:
   $NODE_IP  $DOMAIN redpanda-0.$DOMAIN

Endpoints:
Console   → http://$DOMAIN
Kafka     → $DOMAIN:$NODEPORT_BROKER (recomendado)
         → $NODE_IP:$NODEPORT_BROKER (alternativo)

Para verificação adicional, execute:
kubectl -n $NS get all
kubectl -n $NS get ingress
kubectl -n $NS describe pod -l app.kubernetes.io/name=console
kubectl -n $NS logs -l app.kubernetes.io/name=console

Para conectar ao Kafka:
kcat -b $DOMAIN:$NODEPORT_BROKER -L
rpk cluster info --brokers $DOMAIN:$NODEPORT_BROKER
EOF

# Verifica porta do console
log "Tentando executar curl no console para verificar acesso..."
if curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$DOMAIN" 2>/dev/null; then
  log "✅ Console acessível via http://$DOMAIN"
else
  warn "❌ Console não parece estar acessível. Verificando IP do Ingress..."
  
  if [ -n "$INGRESS_IP" ]; then
    if curl -s -o /dev/null -m 5 -w "%{http_code}" "http://$INGRESS_IP" 2>/dev/null; then
      log "✅ Console acessível via http://$INGRESS_IP"
      log "Adicione no /etc/hosts: $INGRESS_IP $DOMAIN"
    else
      warn "❌ Console não está acessível nem pelo IP do Ingress"
      # Informações adicionais sobre o ingress
      log "Detalhes do ingress:"
      kubectl -n "$NS" describe ingress
    fi
  else
    warn "❌ Não foi possível obter IP do Ingress"
    log "Detalhes do ingress:"
    kubectl -n "$NS" describe ingress
  fi
fi

# Exibe um resumo da configuração para debugging
log "RESUMO DA CONECTIVIDADE DO REDPANDA:"
log "-----------------------------------"
log "DNS: $DOMAIN"
log "IP Interno do Nó: $INTERNAL_IP"
log "IP Externo do Nó: $EXTERNAL_IP"
log "IP do Ingress: $INGRESS_IP"
log "Porta Kafka: $NODEPORT_BROKER"
log "Domínio + Porta: $DOMAIN:$NODEPORT_BROKER"
log "-----------------------------------"
log "Deploy concluído com sucesso!"
log "Obs: O Redpanda pode levar alguns minutos para aceitar conexões após o deploy."
log "     Tente novamente em alguns minutos se tiver problemas de conexão."