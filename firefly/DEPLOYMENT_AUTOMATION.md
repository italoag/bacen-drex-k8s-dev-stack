# Automação do Deployment FireFly

## Resumo das Configurações Automáticas

### 1. Configurações Corrigidas no firefly-multiparty.yaml

#### 1.1 Configurações Básicas
```yaml
config:
  defaultBlockchainType: ethereum  # Essencial para templates corretos
  multipartyEnabled: true
  
  # Nome da organização e chave
  organizationName: "minhaOrg"
  organizationKey: "0xKey......"
```

#### 1.2 Configurações de Conectividade IPFS (CORRIGIDAS)
```yaml
config:
  # URLs corretas para o serviço IPFS no namespace firefly
  ipfsApiUrl: "http://ipfs-ipfs.firefly.svc:5001"
  ipfsGatewayUrl: "http://ipfs-ipfs.firefly.svc:8080"
```

#### 1.3 Configurações do EVMConnect
```yaml
config:
  evmconnectUrl: "http://firefly-evmconnect:5000"
  ethconnectTopic: "0"  # Valor correto conforme template
  ethconnectPrefixShort: "fly"
  ethconnectPrefixLong: "firefly"
  ethconnectRetry: true
```

#### 1.4 Configurações de Timeout
```yaml
config:
  httpRequestTimeout: 600s
  httpRequestMaxTimeout: 600s
```

#### 1.5 Configurações do Contrato
```yaml
config:
  fireflyContractAddress: "0xDEdB3f6382B73129Ad3f72AD737F348b44Ffc749"
  fireflyContractFirstEvent: 0
  fireflyContracts:
    - address: "0xDEdB3f6382B73129Ad3f72AD737F348b44Ffc749"
      firstEvent: 0
```

### 2. Configurações do Core

#### 2.1 Nome Customizado do Node
```yaml
core:
  nodeNameOverride: "eita-node"  # Sobrescreve o nome padrão
```

#### 2.2 Job de Registro Automático (ESSENCIAL)
```yaml
core:
  jobs:
    registration:
      enabled: true
      ffUrl: "http://firefly:5000"
      ffNamespaces:
        - default
```

### 3. Processo de Registro Automático

O job de registro (`firefly-eita-latest-arm64-registration`) executa automaticamente:

1. **Aguarda FireFly estar disponível**
   - Testa GET `/api/v1/namespaces/default/status`

2. **Verifica se organização está registrada**
   - Se `org.registered == false`, executa registro automático
   - POST `/api/v1/namespaces/default/network/organizations/self?confirm=true`

3. **Verifica se node está registrado**
   - Se `node.registered == false`, executa registro automático  
   - POST `/api/v1/namespaces/default/network/nodes/self?confirm=true`

### 4. Dependências Essenciais

Para o registro automático funcionar, estes serviços devem estar funcionando:

- ✅ **PostgreSQL**: Banco de dados configurado
- ✅ **IPFS**: Shared storage para mensagens
- ✅ **EVMConnect**: Conectividade blockchain
- ✅ **FireFly Core**: API principal
- ✅ **Data Exchange**: Para comunicação multiparty

### 5. Verificação do Sucesso

Após o deployment, verifique:

```bash
# 1. Verificar se o job foi executado
kubectl get jobs -n firefly

# 2. Verificar logs do job
kubectl logs job/firefly-eita-latest-arm64-registration -n firefly

# 3. Verificar status do registro
kubectl exec firefly-0 -n firefly -- curl -s "http://localhost:5000/api/v1/namespaces/default/status" | jq '.org.registered, .node.registered'
```

### 6. Resultado Esperado

Após deployment completo, o status deve mostrar:

```json
{
  "org": {
    "name": "EITA",
    "registered": true,
    "did": "did:firefly:org/EITA"
  },
  "node": {
    "name": "eita-node",
    "registered": true
  }
}
```

## Conclusão

**Todas as configurações necessárias estão agora automatizadas no firefly-multiparty.yaml:**

1. ✅ **Configuração correta do IPFS** (principal causa dos timeouts)
2. ✅ **Job de registro automático** habilitado e configurado corretamente
3. ✅ **Nome customizado do node** (eita-node)
4. ✅ **Configurações de timeout** adequadas
5. ✅ **Configurações de contrato** corretas para multiparty

O processo agora é **100% automatizado** via ArgoCD. Não há necessidade de intervenção manual para registrar organização ou nodes.