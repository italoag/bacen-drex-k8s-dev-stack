# Deployment do Paladin com ArgoCD

Este diretório contém as configurações do ArgoCD para o deployment do componente Paladin no cluster Kubernetes.

## Estrutura do Diretório

A estrutura segue o padrão de organização de aplicações do ArgoCD, separando as definições de `Application` dos Helm Charts:

```
paladin/argocd/
├── apps/
│   └── paladin-dev.yaml
└── paladin/
    ├── Chart.yaml
    ├── values.yaml
    ├── environments/
    │   ├── values-dev.yaml
    │   └── values-prod.yaml
    └── templates/
        ├── crds.yaml
        ├── operator.yaml
        └── ingress.yaml
```

### `apps/`

Contém as definições de `Application` do ArgoCD. Cada arquivo YAML neste diretório representa uma instância do Paladin para um ambiente específico.

-   `paladin-dev.yaml`: Define a aplicação ArgoCD para o ambiente de desenvolvimento. Ele aponta para o Helm Chart localizado em `paladin/argocd/paladin` e utiliza o arquivo de valores `environments/values-dev.yaml` para configurações específicas do ambiente.

### `paladin/` (Helm Chart)

Este é o Helm Chart do Paladin, que encapsula todos os manifestos Kubernetes necessários para o deployment do componente.

-   `Chart.yaml`: Metadados do Helm Chart.
-   `values.yaml`: Contém os valores padrão para o Helm Chart. As configurações de Ingress (como `ingress.enabled`) são definidas aqui.
-   `environments/`: Contém arquivos de `values` específicos para cada ambiente, sobrescrevendo os valores padrão do `values.yaml` principal.
    -   `values-dev.yaml`: Define o domínio (`domain`) e outras configurações para o ambiente de desenvolvimento.
    -   `values-prod.yaml`: Define o domínio (`domain`) e outras configurações para o ambiente de produção.
-   `templates/`: Contém os manifestos Kubernetes renderizados pelo Helm.
    -   `crds.yaml`: Define os Custom Resource Definitions (CRDs) do Paladin Operator.
    -   `operator.yaml`: Define o deployment do Paladin Operator.
    -   `ingress.yaml`: Define os recursos de Ingress e IngressRoute para o acesso externo ao Paladin. Este arquivo utiliza a variável `.Values.domain` para configurar os hosts dos ingressos dinamicamente, com base no ambiente.

## Processo de Deployment com ArgoCD

Para realizar o deployment do Paladin usando o ArgoCD, siga os passos abaixo:

1.  **Acesso ao ArgoCD CLI:** Certifique-se de ter o `argocd` CLI instalado e configurado para se conectar à sua instância do ArgoCD.

2.  **Criação da Aplicação ArgoCD:**
    Para fazer o deployment do Paladin no ambiente de desenvolvimento, execute o seguinte comando a partir do diretório raiz do seu repositório (onde este `README.md` está localizado):

    ```bash
    argocd app create paladin-dev --repo https://github.com/italo-moraes/bacen-drex-kubernetes-dev-stack.git --path paladin/argocd/paladin --dest-server https://kubernetes.default.svc --dest-namespace paladin --values paladin/argocd/paladin/environments/values-dev.yaml --sync-policy automated
    ```

    -   `--repo`: URL do seu repositório Git.
    -   `--path`: Caminho para o diretório do Helm Chart dentro do seu repositório.
    -   `--dest-server`: URL do servidor Kubernetes (geralmente `https://kubernetes.default.svc`).
    -   `--dest-namespace`: Namespace onde o Paladin será implantado (neste caso, `paladin`).
    -   `--values`: Caminho para o arquivo de valores específico do ambiente.
    -   `--sync-policy automated`: Configura o ArgoCD para sincronizar automaticamente as alterações do repositório para o cluster, com `prune` (remover recursos que não estão mais no Git) e `selfHeal` (corrigir desvios de estado).

3.  **Sincronização e Monitoramento:**
    Após a criação da aplicação, o ArgoCD irá automaticamente sincronizar o estado desejado do repositório com o cluster. Você pode monitorar o status do deployment através da UI do ArgoCD ou via CLI:

    ```bash
    argocd app get paladin-dev
    argocd app logs paladin-dev
    ```

    Quaisquer alterações futuras no Helm Chart ou nos arquivos de valores no repositório Git serão detectadas e aplicadas automaticamente pelo ArgoCD, mantendo o ambiente sempre atualizado e em sincronia com o Git.
