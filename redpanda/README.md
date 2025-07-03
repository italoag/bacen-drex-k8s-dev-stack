# Redpanda Kafka no Kubernetes

Este diretório contém os scripts e configurações necessários para implantar o Redpanda Kafka em um cluster Kubernetes.

## Requisitos

- Cluster Kubernetes configurado (K3s, K8s, etc.)
- Helm v3 instalado
- `kubectl` configurado para acessar seu cluster
- [Redpanda tools (rpk)](https://docs.redpanda.com/docs/install-upgrade/rpk-install/) instaladas para testes (opcional)

## Arquivos Principais

- `deploy-redpanda.sh`: Script principal para implantar o Redpanda
- `redpanda-values.yaml`: Arquivo de valores Helm para a configuração do Redpanda
- `test-redpanda-connectivity.sh`: Script para testar conectividade após a implantação
- `ca.crt`: Certificado CA (gerado durante a implantação com TLS)

## Implantação

Para implantar o Redpanda no cluster Kubernetes:

```bash
./deploy-redpanda.sh
```

O script suporta os seguintes parâmetros opcionais:

- `--domain example.com`: Define um domínio personalizado para o Redpanda
- `--tls`: Habilita TLS para as conexões Kafka (recomendado)
- `--monitoring`: Instala recursos de monitoramento adicionais (Prometheus, Grafana)

Exemplo com todos os parâmetros:

```bash
./deploy-redpanda.sh --domain kafka.meudominio.com.br --tls --monitoring
```

## Testando a Conectividade

Após a implantação, você pode testar a conectividade com o script:

```bash
./test-redpanda-connectivity.sh
```

Este script verifica:
- Se o StatefulSet está em execução
- Se as portas NodePort estão acessíveis
- Se o TLS está configurado corretamente
- Se o domínio resolve para o IP correto
- Se o Console Web está acessível

## Conectando ao Redpanda

### Usando o cliente rpk (Redpanda CLI)

1. Sem TLS (usando IP):
```bash
rpk cluster info --brokers <IP_DO_NODE>:<NODEPORT>
```

2. Com TLS (usando hostname):
```bash
# Primeiro, obtenha o certificado CA
kubectl -n redpanda get secret redpanda-external-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt

# Em seguida, conecte usando o certificado
rpk cluster info --brokers <DOMÍNIO>:<NODEPORT> --tls-enabled --tls-truststore /tmp/ca.crt
```

### Usando aplicativos Kafka

Para aplicações Kafka padrão, configure o bootstrap server:

1. Sem TLS:
```
<IP_DO_NODE>:<NODEPORT>
```

2. Com TLS:
```
<DOMÍNIO>:<NODEPORT>
```

Lembre-se de configurar as propriedades de TLS apropriadas e importar o certificado CA.

## Acessando o Console Web

O Console Web pode ser acessado via:

```
https://<DOMÍNIO>
```

## Solução de Problemas

Se você encontrar problemas durante a implantação ou ao conectar-se ao Redpanda:

1. Verifique se os pods estão em execução:
```bash
kubectl -n redpanda get pods
```

2. Verifique os logs dos pods:
```bash
kubectl -n redpanda logs -l app.kubernetes.io/name=redpanda
```

3. Verifique se as portas NodePort estão expostas:
```bash
kubectl -n redpanda get svc redpanda-external
```

4. Para problemas de TLS, verifique se o domínio resolve para o IP correto:
```bash
host <DOMÍNIO>
```

5. Adicione uma entrada no arquivo hosts se necessário:
```bash
echo "<IP_DO_NODE> <DOMÍNIO>" | sudo tee -a /etc/hosts
```

## Desinstalação

Para desinstalar o Redpanda:

```bash
helm uninstall redpanda -n redpanda
kubectl delete namespace redpanda
```
