#!/bin/bash

# Configurações
NAMESPACE="paladin"
LOG_FILE="besu-loadbalancer-deployment-$(date +%Y%m%d-%H%M%S).log"
RETRY_ATTEMPTS=3
RETRY_DELAY=5
BACKUP_DIR="k8s-backups/$(date +%Y%m%d-%H%M%S)"

# Arquivos de configuração
SERVICES_FILE="besu-services.yaml"
TRAEFIK_SERVICES_FILE="besu-traefik-services.yaml"
MIDDLEWARES_FILE="besu-middlewares.yaml"
INGRESSROUTES_FILE="besu-ingressroutes.yaml"

# Função para logging
log() {
  local level=$1
  local message=$2
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] [$level] $message" | tee -a $LOG_FILE
}

# Função para verificação de erros
check_error() {
  if [ $? -ne 0 ]; then
    log "ERROR" "$1"
    if [ "$2" == "exit" ]; then
      log "ERROR" "Script abortado."
      exit 1
    fi
    return 1
  fi
  return 0
}

# Função para backup de recursos existentes
backup_resources() {
  log "INFO" "Criando backup dos recursos existentes..."
  
  mkdir -p $BACKUP_DIR
  
  # Backup de serviços
  kubectl get services -n $NAMESPACE -o yaml > $BACKUP_DIR/services-backup.yaml 2>/dev/null || true
  
  # Backup de ingressroutes
  kubectl get ingressroutes.traefik.io -n $NAMESPACE -o yaml > $BACKUP_DIR/ingressroutes-backup.yaml 2>/dev/null || true
  
  # Backup de middlewares
  kubectl get middlewares.traefik.io -n $NAMESPACE -o yaml > $BACKUP_DIR/middlewares-backup.yaml 2>/dev/null || true
  
  # Backup de traefikservices
  kubectl get traefikservices.traefik.io -n $NAMESPACE -o yaml > $BACKUP_DIR/traefikservices-backup.yaml 2>/dev/null || true
  
  log "INFO" "Backup criado em $BACKUP_DIR"
}

# Função para rollback
rollback() {
  log "WARNING" "Iniciando rollback..."
  
  # Verificar se diretório de backup existe
  if [ ! -d "$BACKUP_DIR" ]; then
    log "ERROR" "Diretório de backup não encontrado. Rollback não é possível."
    return 1
  fi
  
  # Aplicar backups se existirem
  if [ -f "$BACKUP_DIR/services-backup.yaml" ]; then
    log "INFO" "Restaurando serviços..."
    kubectl apply -f $BACKUP_DIR/services-backup.yaml
  fi
  
  if [ -f "$BACKUP_DIR/ingressroutes-backup.yaml" ]; then
    log "INFO" "Restaurando ingressroutes..."
    kubectl apply -f $BACKUP_DIR/ingressroutes-backup.yaml
  fi
  
  if [ -f "$BACKUP_DIR/middlewares-backup.yaml" ]; then
    log "INFO" "Restaurando middlewares..."
    kubectl apply -f $BACKUP_DIR/middlewares-backup.yaml
  fi
  
  if [ -f "$BACKUP_DIR/traefikservices-backup.yaml" ]; then
    log "INFO" "Restaurando traefikservices..."
    kubectl apply -f $BACKUP_DIR/traefikservices-backup.yaml
  fi
  
  log "INFO" "Rollback concluído."
}

# Função para verificar a existência dos nós Besu
check_besu_nodes() {
  log "INFO" "Verificando a existência dos StatefulSets Besu..."
  
  for node in "besu-node1" "besu-node2" "besu-node3"; do
    kubectl get statefulset $node -n $NAMESPACE &>/dev/null
    if [ $? -ne 0 ]; then
      log "ERROR" "StatefulSet $node não encontrado no namespace $NAMESPACE."
      return 1
    fi
    
    # Verificar se o pod está em execução
    kubectl get pod $node-0 -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"
    if [ $? -ne 0 ]; then
      log "ERROR" "Pod $node-0 não está em execução."
      return 1
    fi
  done
  
  log "INFO" "Todos os nós Besu estão disponíveis."
  return 0
}

# Função para aplicar recursos com retry
apply_with_retry() {
  local file=$1
  local resource_type=$2
  local attempt=1
  
  while [ $attempt -le $RETRY_ATTEMPTS ]; do
    log "INFO" "Tentativa $attempt de $RETRY_ATTEMPTS para aplicar $resource_type..."
    kubectl apply -f $file
    
    if [ $? -eq 0 ]; then
      log "INFO" "$resource_type aplicado com sucesso."
      return 0
    else
      log "WARNING" "Falha ao aplicar $resource_type. Tentando novamente em $RETRY_DELAY segundos..."
      attempt=$((attempt + 1))
      sleep $RETRY_DELAY
    fi
  done
  
  log "ERROR" "Falha ao aplicar $resource_type após $RETRY_ATTEMPTS tentativas."
  return 1
}

# Função para verificar a existência dos arquivos de configuração
check_config_files() {
  for file in "$SERVICES_FILE" "$TRAEFIK_SERVICES_FILE" "$MIDDLEWARES_FILE" "$INGRESSROUTES_FILE"; do
    if [ ! -f "$file" ]; then
      log "ERROR" "Arquivo de configuração $file não encontrado."
      return 1
    fi
  done
  
  log "INFO" "Todos os arquivos de configuração estão disponíveis."
  return 0
}

# Função para verificar acesso ao cluster
check_cluster_access() {
  log "INFO" "Verificando acesso ao cluster Kubernetes..."
  
  kubectl get nodes &>/dev/null
  if [ $? -ne 0 ]; then
    log "ERROR" "Não foi possível acessar o cluster Kubernetes."
    return 1
  fi
  
  # Verificar acesso ao namespace
  kubectl get namespace $NAMESPACE &>/dev/null
  if [ $? -ne 0 ]; then
    log "ERROR" "Namespace $NAMESPACE não encontrado ou sem acesso."
    return 1
  fi
  
  log "INFO" "Acesso ao cluster e namespace $NAMESPACE confirmado."
  return 0
}

# Função para verificar o deployment
verify_deployment() {
  local success=true
  
  # Verificar serviços
  log "INFO" "Verificando serviços..."
  for svc in "besu-node1-rpc" "besu-node2-rpc" "besu-node3-rpc" "besu-node1-ws" "besu-node2-ws" "besu-node3-ws" "besu-node1-graphql" "besu-node2-graphql" "besu-node3-graphql"; do
    kubectl get service $svc -n $NAMESPACE &>/dev/null
    if [ $? -ne 0 ]; then
      log "ERROR" "Serviço $svc não encontrado."
      success=false
    fi
  done
  
  # Verificar TraefikServices
  log "INFO" "Verificando TraefikServices..."
  for ts in "besu-rpc-lb" "besu-ws-lb" "besu-graphql-lb"; do
    kubectl get traefikservices.traefik.io $ts -n $NAMESPACE &>/dev/null
    if [ $? -ne 0 ]; then
      log "ERROR" "TraefikService $ts não encontrado."
      success=false
    fi
  done
  
  # Verificar Middlewares
  log "INFO" "Verificando Middlewares..."
  for mw in "besu-ws-middleware" "besu-retry-middleware"; do
    kubectl get middlewares.traefik.io $mw -n $NAMESPACE &>/dev/null
    if [ $? -ne 0 ]; then
      log "ERROR" "Middleware $mw não encontrado."
      success=false
    fi
  done
  
  # Verificar IngressRoutes
  log "INFO" "Verificando IngressRoutes..."
  for ir in "besu-rpc-route" "besu-ws-route" "besu-graphql-route"; do
    kubectl get ingressroutes.traefik.io $ir -n $NAMESPACE &>/dev/null
    if [ $? -ne 0 ]; then
      log "ERROR" "IngressRoute $ir não encontrado."
      success=false
    fi
  done
  
  if [ "$success" = true ]; then
    log "INFO" "Todos os recursos foram implantados com sucesso!"
    return 0
  else
    log "ERROR" "Alguns recursos não foram implantados corretamente."
    return 1
  fi
}

# Início do script
log "INFO" "Iniciando implantação do balanceador de carga para Besu..."

# Verificar acesso ao cluster
check_cluster_access
if [ $? -ne 0 ]; then
  log "ERROR" "Não foi possível acessar o cluster. Encerrando script."
  exit 1
fi

# Verificar a existência dos nós Besu
check_besu_nodes
if [ $? -ne 0 ]; then
  log "ERROR" "Verificação dos nós Besu falhou. Encerrando script."
  exit 1
fi

# Verificar arquivos de configuração
check_config_files
if [ $? -ne 0 ]; then
  log "ERROR" "Verificação dos arquivos de configuração falhou. Encerrando script."
  exit 1
fi

# Backup dos recursos existentes
backup_resources

# Aplicar recursos
log "INFO" "Aplicando serviços..."
apply_with_retry $SERVICES_FILE "Serviços"
if [ $? -ne 0 ]; then
  log "ERROR" "Falha ao aplicar serviços. Iniciando rollback..."
  rollback
  exit 1
fi

log "INFO" "Aplicando Middlewares..."
apply_with_retry $MIDDLEWARES_FILE "Middlewares"
if [ $? -ne 0 ]; then
  log "ERROR" "Falha ao aplicar middlewares. Iniciando rollback..."
  rollback
  exit 1
fi

log "INFO" "Aplicando TraefikServices..."
apply_with_retry $TRAEFIK_SERVICES_FILE "TraefikServices"
if [ $? -ne 0 ]; then
  log "ERROR" "Falha ao aplicar TraefikServices. Iniciando rollback..."
  rollback
  exit 1
fi

log "INFO" "Aplicando IngressRoutes..."
apply_with_retry $INGRESSROUTES_FILE "IngressRoutes"
if [ $? -ne 0 ]; then
  log "ERROR" "Falha ao aplicar IngressRoutes. Iniciando rollback..."
  rollback
  exit 1
fi

# Verificar implantação
log "INFO" "Verificando implantação..."
verify_deployment
if [ $? -ne 0 ]; then
  log "WARNING" "Alguns recursos não foram verificados corretamente. Verificando novamente em 10 segundos..."
  sleep 10
  
  verify_deployment
  if [ $? -ne 0 ]; then
    log "ERROR" "A verificação da implantação falhou novamente. Iniciando rollback..."
    rollback
    exit 1
  fi
fi

log "SUCCESS" "Balanceador de carga para Besu implantado com sucesso!"
log "INFO" "Os seguintes endpoints estão disponíveis:"
log "INFO" "- RPC HTTP: http://rpc-besu.cluster.eita.cloud"
log "INFO" "- RPC WebSocket: ws://ws-besu.cluster.eita.cloud"
log "INFO" "- GraphQL: http://graphql-besu.cluster.eita.cloud"

exit 0
