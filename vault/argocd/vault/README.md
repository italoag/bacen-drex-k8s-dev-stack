# Vault ArgoCD Deployment

Esta configuração implementa um deployment completo do HashiCorp Vault usando ArgoCD com o padrão "App of Apps" para garantir a ordem correta de execução.

## Estrutura

- `vault-dev.yaml` - Application "pai" (App of Apps)
- `vault-application-dev.yaml` - Application do Vault (Helm Chart)
- `rbac-application.yaml` - Application do RBAC necessário para o Job
- `init-unseal-job-application.yaml` - Application do Job de unseal
- `rbac.yaml` - Recursos RBAC (ServiceAccount, Role, RoleBinding)
- `init-unseal-job.yaml` - Job que inicializa e faz unseal do Vault

## Ordem de Execução

1. **Vault (sync-wave: 1)** - Instala o Vault via Helm Chart
2. **RBAC (sync-wave: 2)** - Cria recursos RBAC necessários para o Job
3. **Init Unseal (sync-wave: 3)** - Executa o Job que inicializa e faz unseal do Vault

## Como Usar

### Pré-requisitos

1. ArgoCD instalado e configurado
2. Adicionar o repositório Helm da HashiCorp:
   ```bash
   argocd repo add https://helm.releases.hashicorp.com --type helm --name hashicorp
   ```

### Deploy

Para fazer o deploy completo, basta aplicar o Application "pai":

```bash
kubectl apply -f https://raw.githubusercontent.com/eitatech/deployments/main/argocd/apps/vault/vault-dev.yaml
```

Ou se você clonou o repositório:

```bash
kubectl apply -f argocd/apps/vault/vault-dev.yaml
```

### Verificação

1. Verifique os Applications criados:
   ```bash
   kubectl get applications -n argocd
   ```

2. Acompanhe o status das aplicações:
   ```bash
   argocd app list
   ```

3. Verifique se o Vault foi inicializado:
   ```bash
   kubectl get secret vault-keys -n vault
   ```

## Funcionalidades

- **Automated Sync**: Todas as aplicações são sincronizadas automaticamente
- **Self Heal**: ArgoCD corrige automaticamente qualquer drift
- **Auto Prune**: Remove recursos que não estão mais definidos nos manifests
- **Dependency Management**: Garante ordem correta de execução via sync-waves e dependências
- **Namespace Creation**: Cria automaticamente o namespace `vault`
- **Vault Initialization**: Inicializa e faz unseal automaticamente do Vault
- **Secret Management**: Armazena chaves de unseal e root token em um Secret do Kubernetes

## Estrutura de Arquivos Necessária

Certifique-se que os seguintes arquivos estejam no path `argocd/apps/vault/` do seu repositório:

```
argocd/apps/vault/
├── vault-dev.yaml                      # App of Apps (arquivo principal)
├── vault-application-dev.yaml          # Application do Vault
├── rbac-application.yaml               # Application do RBAC  
├── init-unseal-job-application.yaml    # Application do Job
├── rbac.yaml                          # Recursos RBAC
├── init-unseal-job.yaml               # Job de inicialização
└── values/
    ├── base.yaml                      # Values base do Helm
    └── dev.yaml                       # Values específicos do dev
```
