# Plano de Deployment do Firefly com ArgoCD

## Objetivo
Criar scripts de deployment para o Firefly utilizando ArgoCD, considerando que as dependências externas (Hyperledger Besu, PostgreSQL, IPFS, Prometheus) já estão configuradas no cluster e os componentes internos do Firefly serão implantados pelo chart. Serão criadas duas configurações: `multiparty` e `gateway`. O `firefly-signer` será implantado como uma aplicação ArgoCD separada.

## Premissas
*   Hyperledger Besu já configurado e acessível (endpoint RPC).
*   PostgreSQL já configurado e acessível.
*   IPFS já configurado e acessível.
*   Prometheus já configurado e acessível (para coleta de métricas do Firefly).
*   ArgoCD já instalado e configurado no cluster.

## Estrutura de Diretórios
```
.
├── applications/
│   ├── firefly-gateway-app.yaml
│   ├── firefly-multiparty-app.yaml
│   └── firefly-signer-app.yaml
├── values/
│   ├── firefly-gateway-values.yaml
│   └── firefly-multiparty-values.yaml
└── PLAN.md
```

## Passos

### 1. Análise do Chart Firefly (Concluído)
*   `firefly-helm-charts/charts/firefly/Chart.yaml`: Identificadas dependências e versão. **Confirmado que `firefly-evmconnect` é uma dependência do chart `firefly` e será implantado como uma sub-chart quando habilitado.**
*   `firefly-helm-charts/charts/firefly/values.yaml`: Entendidas as opções de configuração para serviços externos e habilitação/desabilitação de componentes.
*   `firefly-helm-charts/charts/firefly-evmconnect/values.yaml`: Confirmado `config.jsonRpcUrl` para o endpoint do Besu.
*   `firefly-helm-charts/charts/firefly-signer/`: Identificado como um chart separado que requer um deployment ArgoCD próprio.

### 2. Criação dos Arquivos `values.yaml` Customizados (Concluído)
Os arquivos de configuração de valores foram criados e organizados no diretório `values/`.

#### Estrutura Base (`values/firefly-multiparty-values.yaml` e `values/firefly-gateway-values.yaml`):
```yaml
# Habilitar componentes internos do Firefly
dataexchange:
  enabled: true
sandbox:
  enabled: true
evmconnect:
  enabled: true # Habilita a sub-chart firefly-evmconnect
erc1155:
  enabled: true
erc20erc721:
  enabled: true

# Configurações para serviços externos
config:
  postgresUrl: "postgresql://user:password@postgres-service:5432/firefly" # Substituir pelo seu URL do PostgreSQL
  ipfsApiUrl: "http://ipfs-api-service:5001" # Substituir pelo seu URL da API do IPFS
  ipfsGatewayUrl: "http://ipfs-gateway-service:8080" # Substituir pelo seu URL do Gateway do IPFS
  fireflyContractAddress: "0x..." # Substituir pelo endereço do contrato Firefly pré-implantado
  fireflyContractFirstEvent: 0 # Substituir pelo bloco do primeiro evento do contrato Firefly
  metricsEnabled: true # Manter habilitado para Prometheus externo
  # Outras configurações específicas do Firefly, como organização, etc.
  organizationName: "MyOrg" # Exemplo: Nome da organização
  organizationKey: "0x..." # Exemplo: Chave da organização (endereço Ethereum ou similar)

# Configuração do EVMConnect interno (sub-chart) para apontar para o Besu externo
evmconnect:
  config:
    jsonRpcUrl: "http://besu-service:8545" # Substituir pelo seu endpoint RPC do Besu
```

### 3. Definição das Configurações `multiparty` e `gateway` (Concluído)
Os arquivos de valores específicos para cada configuração estão em `values/`.

#### Configuração `multiparty` (`values/firefly-multiparty-values.yaml`)
Foco na comunicação entre nós Firefly.
```yaml
# values/firefly-multiparty-values.yaml
# ... (conteúdo base do values.yaml customizado) ...
dataexchange:
  enabled: true # Habilitar o DataExchange interno para comunicação multiparty

config:
  organizationName: "OrgA"
  organizationKey: "0x123..." # Chave da organização para o nó A
  # ... (outras configurações específicas de multiparty) ...

evmconnect:
  enabled: true
  config:
    jsonRpcUrl: "http://besu-service:8545" # Substituir pelo seu endpoint RPC do Besu
```

#### Configuração `gateway` (`values/firefly-gateway-values.yaml`)
Foco na interação com a blockchain e IPFS, sem comunicação direta entre nós Firefly.
```yaml
# values/firefly-gateway-values.yaml
# ... (conteúdo base do values.yaml customizado) ...
dataexchange:
  enabled: false # Desabilitar o DataExchange, pois não haverá comunicação direta entre nós Firefly

config:
  organizationName: "GatewayOrg"
  organizationKey: "0xabc..." # Chave da organização para o nó Gateway
  # ... (outras configurações específicas de gateway) ...

evmconnect:
  enabled: true
  config:
    jsonRpcUrl: "http://besu-service:8545" # Substituir pelo seu endpoint RPC do Besu
```

### 4. Criação dos Recursos ArgoCD `Application` (Concluído)
Os arquivos YAML para o recurso `Application` do ArgoCD foram criados e organizados no diretório `applications/`.

#### Exemplo de `Application` para `multiparty` (`applications/firefly-multiparty-app.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: firefly-multiparty
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/hyperledger/firefly-helm-charts.git # Ou o seu repositório do chart
    targetRevision: HEAD
    path: charts/firefly
    helm:
      valueFiles:
        - ../values/firefly-multiparty-values.yaml # Caminho para o seu arquivo de values customizado
  destination:
    server: https://kubernetes.default.svc
    namespace: firefly-multiparty # Namespace onde o Firefly será implantado
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

#### Exemplo de `Application` para `gateway` (`applications/firefly-gateway-app.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: firefly-gateway
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/hyperledger/firefly-helm-charts.git # Ou o seu repositório do chart
    targetRevision: HEAD
    path: charts/firefly
    helm:
      valueFiles:
        - ../values/firefly-gateway-values.yaml # Caminho para o seu arquivo de values customizado
  destination:
    server: https://kubernetes.default.svc
    namespace: firefly-gateway # Namespace onde o Firefly será implantado
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 5. Criação do Recurso ArgoCD `Application` para `firefly-signer` (Concluído)

#### Exemplo de `Application` para `firefly-signer` (`applications/firefly-signer-app.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: firefly-signer
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/hyperledger/firefly-helm-charts.git # Ou o seu repositório do chart
    targetRevision: HEAD
    path: charts/firefly-signer # Caminho para o chart do firefly-signer
  destination:
    server: https://kubernetes.default.svc
    namespace: firefly-signer # Namespace onde o Firefly Signer será implantado
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

## Próximos Passos (Para o Usuário)
1.  **Revisar e Ajustar os `values.yaml`:**
    *   Abra `values/firefly-multiparty-values.yaml` e `values/firefly-gateway-values.yaml`.
    *   Substitua os placeholders (`postgresql://user:password@postgres-service:5432/firefly`, `http://ipfs-api-service:5001`, `http://besu-service:8545`, `0x...`, `MyOrg`, `OrgA`, `GatewayOrg`, `0x123...`, `0xabc...`) pelos endereços reais dos seus serviços de PostgreSQL, IPFS, Besu, e pelos detalhes da sua organização e contratos Firefly.

2.  **Aplicar os Recursos ArgoCD:**
    *   Use `kubectl apply -f applications/firefly-multiparty-app.yaml` para implantar a configuração `multiparty`.
    *   Use `kubectl apply -f applications/firefly-gateway-app.yaml` para implantar a configuração `gateway`.
    *   Use `kubectl apply -f applications/firefly-signer-app.yaml` para implantar o `firefly-signer`.

3.  **Monitorar no ArgoCD:**
    *   Acesse a UI do ArgoCD para monitorar o status das aplicações `firefly-multiparty`, `firefly-gateway` e `firefly-signer`.