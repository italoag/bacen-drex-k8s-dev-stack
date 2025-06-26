# HashiCorp Vault com Auto-Unseal

Este diretório contém scripts para instalar e gerenciar o HashiCorp Vault e o componente vault-autounseal no Kubernetes.

## Arquivos disponíveis

- **deploy-vault.sh**: Script principal para instalar/configurar o Vault com suporte integrado para auto-unseal.
- **install-vault-autounseal.sh**: Script independente para instalar apenas o componente vault-autounseal em um Vault existente.
- **vault-values.yaml**: Valores de configuração para o Helm chart do Vault.

## Sobre o componente Auto-Unseal

O vault-autounseal é um componente que permite que o Vault seja automaticamente "unsealed" após reinicializações, utilizando segredos armazenados no Kubernetes.

### Instalação do Auto-Unseal em um Vault existente

Se você já tem um Vault instalado e inicializado, pode adicionar o componente de auto-unseal usando o script `install-vault-autounseal.sh`:

```bash
./install-vault-autounseal.sh
```

#### Pré-requisitos para o script

- Um cluster Kubernetes com acesso via `kubectl`
- Vault já instalado e inicializado no namespace `vault`
- Arquivo `vault-unseal.txt` contendo as chaves do Vault no formato `unseal_key:root_token`

#### Configuração

O script usa as seguintes configurações padrão:

- **Namespace**: vault
- **Nome do release**: vault-autounseal
- **Nome do serviço do Vault**: vault
- **Porta do Vault**: 8200
- **Secret para chaves**: vault-keys
- **Secret para token root**: vault-root-token
- **Key shares/threshold**: 1/1

## Uso do Auto-Unseal

Após a instalação, o vault-autounseal detecta automaticamente quando o Vault está "sealed" e realiza o "unseal" usando as chaves armazenadas nos segredos do Kubernetes.

Para verificar o status do auto-unseal:

```bash
kubectl get pods -n vault -l app.kubernetes.io/name=vault-autounseal
kubectl logs -n vault -l app.kubernetes.io/name=vault-autounseal
```

## Segurança

As chaves são armazenadas em segredos do Kubernetes. Recomenda-se utilizar mecanismos adicionais de segurança em ambientes de produção, como:

- Kubernetes Secret Encryption
- Vault Enterprise com KMS para auto-unseal
