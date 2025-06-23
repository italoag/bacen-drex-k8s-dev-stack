# Kafka Deployment com Strimzi

Este diretório contém os arquivos necessários para fazer o deploy do Apache Kafka usando o operador Strimzi no Kubernetes.

## Arquivos

- `deploy-kafka.sh` - Script principal de deploy
- `cleanup-kafka.sh` - Script para limpeza completa
- `check-kafka.sh` - Script para verificação de pré-requisitos e status
- `strimzi-values.yaml` - Configuração do cluster Kafka
- `README.md` - Este arquivo

## Pré-requisitos

1. Cluster Kubernetes rodando (k3s, minikube, etc.)
2. kubectl instalado e configurado
3. Pelo menos 4GB de RAM disponível no cluster
4. ClusterIssuer `selfsigned` (se usando TLS)

## Verificação do ambiente

Antes de fazer o deploy, execute o script de verificação:

```bash
cd kafka
./check-kafka.sh
```

Este script verifica:
- Conectividade com o cluster
- Status do operador Strimzi
- Status do cluster Kafka (se existir)
- Recursos disponíveis
- Conectividade de rede

## Como fazer o deploy

```bash
cd kafka
./deploy-kafka.sh
```

O script:
1. Verifica se o operador Strimzi está instalado
2. Se não estiver, instala via método manual (kubectl)
3. Aplica a configuração do cluster Kafka
4. Configura acesso externo via NodePort
5. Valida a conectividade

## Limpeza completa

Para remover tudo (cluster, operador, namespace):

```bash
cd kafka
./cleanup-kafka.sh
```

## Configuração

O cluster Kafka é configurado com:

- **1 réplica** (adequado para desenvolvimento)
- **KRaft habilitado** (sem ZooKeeper)
- **Listeners internos e externos**:
  - `plain`: porta 9092 (interno, sem TLS)
  - `tls`: porta 9093 (interno, com TLS)
  - `external`: porta 9094 → NodePort 31094 (bootstrap) / 31095 (broker) (externo, sem TLS)
  - `externaltls`: porta 9095 → NodePort 31096 (bootstrap) / 31097 (broker) (externo, com TLS)

## Acesso Externo vs Interno

### Via NodePort (Externo)

**Nota**: As portas NodePort podem estar bloqueadas pelo firewall em alguns ambientes k3s/k8s.

O Kafka fica acessível externamente através das portas NodePort:

```bash
# Descobrir o IP do node
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Conectar via kafka-console-producer/consumer (usando bootstrap)
kafka-console-producer.sh --bootstrap-server $NODE_IP:31094 --topic test
kafka-console-consumer.sh --bootstrap-server $NODE_IP:31094 --topic test --from-beginning

# Conectar via kcat
kcat -b $NODE_IP:31094 -L  # Listar metadados
kcat -b $NODE_IP:31094 -t test -P  # Producer
kcat -b $NODE_IP:31094 -t test -C  # Consumer

# Conectar diretamente ao broker (porta específica do broker)
kafka-console-producer.sh --bootstrap-server $NODE_IP:31095 --topic test
```

### Via Port-Forward (Alternativa recomendada)

Se as portas NodePort não estiverem acessíveis, use port-forward:

```bash
# Port-forward para o serviço bootstrap
kubectl -n kafka port-forward svc/cluster-kafka-bootstrap 9092:9092 &

# Usar localhost
kafka-console-producer.sh --bootstrap-server localhost:9092 --topic test
kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic test --from-beginning
```

### Via Pod Interno (Para testes)

Criar pods temporários dentro do cluster:

```bash
# Producer
kubectl -n kafka run kafka-producer -ti --image=quay.io/strimzi/kafka:0.46.0-kafka-4.0.0 --rm=true --restart=Never -- bin/kafka-console-producer.sh --bootstrap-server cluster-kafka-bootstrap:9092 --topic test

# Consumer (em outro terminal)
kubectl -n kafka run kafka-consumer -ti --image=quay.io/strimzi/kafka:0.46.0-kafka-4.0.0 --rm=true --restart=Never -- bin/kafka-console-consumer.sh --bootstrap-server cluster-kafka-bootstrap:9092 --topic test --from-beginning
```

### Via DNS (Opcional)

Adicione no `/etc/hosts`:
```
<NODE_IP>  kafka.localhost
```

## Verificação

```bash
# Status do cluster
kubectl -n kafka get kafka cluster

# Pods
kubectl -n kafka get pods

# Serviços
kubectl -n kafka get svc

# Tópicos
kubectl -n kafka get kafkatopic
```

## Comandos úteis

```bash
# Criar um tópico
kubectl -n kafka apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: my-topic
  labels:
    strimzi.io/cluster: cluster
spec:
  partitions: 3
  replicas: 1
EOF

# Listar tópicos via CLI
kafka-topics.sh --bootstrap-server $NODE_IP:31092 --list

# Testar produção/consumo
echo "Hello Kafka" | kafka-console-producer.sh --bootstrap-server $NODE_IP:31092 --topic my-topic
kafka-console-consumer.sh --bootstrap-server $NODE_IP:31092 --topic my-topic --from-beginning
```

## Troubleshooting

1. **Pods não inicializam**: Verifique recursos disponíveis
2. **NodePort não acessível**: Verifique firewall e rede do cluster
3. **TLS não funciona**: Verifique se o ClusterIssuer está funcionando

```bash
# Logs do operador
kubectl -n kafka logs deployment/strimzi-cluster-operator

# Logs do Kafka
kubectl -n kafka logs cluster-kafka-0

# Describe do cluster
kubectl -n kafka describe kafka cluster
```
