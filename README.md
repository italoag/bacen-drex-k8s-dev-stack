# Kubernetes Dev Stack

Este repositório contém scripts, manifests e instruções para deploy e validação de múltiplos componentes em um ambiente Kubernetes para desenvolvimento e testes. Cada pasta representa um componente independente do stack. Siga as instruções de cada seção para realizar o deployment e validação.

## Pré-requisitos

- Kubernetes (k3s, minikube, kind, ou cluster compatível)
- kubectl configurado
- Helm instalado
- Acesso administrativo ao cluster
- Bash/zsh

## Componentes

Cada pasta abaixo representa um componente. Siga a ordem sugerida para evitar dependências não resolvidas.

---

## 1. **besu**

### Descrição

Scripts e manifests para deploy do Besu (Ethereum Client) com suporte a ingress, middlewares e serviços.

### Deployment

```sh
cd besu
./besu-install-script.sh
```

- Para customizar valores, edite `besu-install-values.yaml`.
- Para deploy do genesis, use `./besu-genesis-deploy.sh`.
- Para troubleshooting, consulte `BESU_INGRESS_TROUBLESHOOTING.md` e scripts de diagnose.

### Validação

- Execute `./test-direct.sh` para testar acesso direto.
- Execute `./test-external-access.sh` para validar acesso externo.
- Use `./diagnose-besu-404.sh` para investigar problemas de ingress.

---

## 2. **kafka**

### Descrição

Deploy do Apache Kafka usando Strimzi Operator.

### Deployment

```sh
cd kafka
./deploy-kafka.sh
```

- Edite `strimzi-values.yaml` para customizações.
- O operador está em `strimzi-kafka-operator/`.

### Validação

- Execute `./check-kafka.sh` para validar o cluster.
- Use `./cleanup-kafka.sh` para remover recursos.

---

## 3. **mongodb**

### Descrição

Deploy do MongoDB com suporte a operador e acesso externo.

### Deployment

```sh
cd mongodb
./deploy-mongodb.sh
```

- Edite `mongodb-values.yaml` para customizações.
- O operador está em `helm/`.

### Validação

- Execute `./test-mongodb.sh` para validar o deployment.
- Use `./test-external-connection.sh` para testar acesso externo.
- Scripts adicionais para debug: `debug-mongodb.sh`, `test-nodeport-connection.sh`.

---

## 4. **paladin**

### Descrição

Manifests de ingress, middlewares e valores para o serviço Paladin.

### Deployment

- Aplique os arquivos YAML conforme necessário:

  ```sh
  kubectl apply -f paladin/paladin1-ingress.yaml
  kubectl apply -f paladin/paladin2-ingress.yaml
  kubectl apply -f paladin/paladin3-ingress.yaml
  # E demais arquivos conforme o ambiente
  ```

- Edite `paladin-values.yaml` para customizações.

### Validação

- Verifique os ingressroutes e middlewares aplicados:

  ```sh
  kubectl get ingressroutes
  kubectl get middleware
  ```

---

## 5. **postgres**

### Descrição

Scripts e valores para deploy do PostgreSQL.

### Deployment

```sh
cd postgres
./postgresql-deploy.sh
```

- Edite `postgresql-values.yaml` para customizações.

### Validação

- Verifique os pods e serviços:

  ```sh
  kubectl get pods -n <namespace>
  kubectl get svc -n <namespace>
  ```

---

## 6. **redis**

### Descrição

Deploy do Redis via script e valores customizáveis.

### Deployment

```sh
cd redis
./deploy-redis.sh
```

- Edite `redis-values.yaml` para customizações.

### Validação

- Verifique os pods e serviços:

  ```sh
  kubectl get pods -n <namespace>
  kubectl get svc -n <namespace>
  ```

---

## 7. **redpanda**

### Descrição

Deploy do Redpanda (streaming platform) com suporte a TLS.

### Deployment

```sh
cd redpanda
./deploy-redpanda.sh
```

- Edite `redpanda-values.yaml` ou `redpanda-values-monitoring.yaml` para customizações.

### Validação

- Verifique os pods e serviços:

  ```sh
  kubectl get pods -n <namespace>
  kubectl get svc -n <namespace>
  ```

---

## 8. **vault**

### Descrição

Deploy e inicialização do HashiCorp Vault.

### Deployment

```sh
cd vault
./deploy-vault.sh
./init-vault.sh
```

- Edite `vault-values.yaml` para customizações.
- Siga as instruções de unseal em `vault-unseal.txt`.

### Validação

- Execute `./test-vault.sh` para validar o funcionamento.
- Use `./check-vault.sh` para status.

---

## 9. **firefly**

### Descrição

Scripts e arquivos de configuração para o Firefly.

### Deployment

- Siga as instruções do arquivo `bash.txt` ou scripts presentes na pasta.

### Validação

- Consulte logs e status dos pods:

  ```sh
  kubectl get pods -n <namespace>
  kubectl logs <pod>
  ```

---

## 10. **Scripts Gerais**

- `install.sh`: Instalação geral do stack.
- `cleanup_history.sh`: Limpeza de histórico de deploys.

---

## Observações Gerais

- Sempre verifique os namespaces utilizados em cada componente.
- Consulte os arquivos README.md específicos de cada subdiretório, se existirem, para detalhes adicionais.
- Para troubleshooting, utilize os scripts de diagnose presentes em cada pasta.

---

## Contato

Dúvidas ou problemas? Abra uma issue ou entre em contato com o mantenedor do repositório.
