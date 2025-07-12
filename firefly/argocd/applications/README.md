# FireFly ArgoCD Applications

Este diretório contém as definições de ArgoCD Applications para o deployment completo do FireFly Gateway.

## 📁 Estrutura dos Applications

### **1. firefly-gateway (Principal)**
- **Arquivo**: `../firefly-gateway.yaml`
- **Tipo**: ArgoCD Application com Helm Chart
- **Componentes**: FireFly Core, Data Exchange, EVMConnect, Token Connectors
- **Status**: ✅ Já ativo

### **2. firefly-sandbox**
- **Arquivo**: `firefly-sandbox-app.yaml`
- **Tipo**: ArgoCD Application com manifesto Kubernetes direto
- **Componentes**: Sandbox UI e API
- **Status**: 🔄 Novo (para migração)

### **3. firefly-ingress**
- **Arquivo**: `firefly-ingress-app.yaml`
- **Tipo**: ArgoCD Application com manifesto Kubernetes direto
- **Componentes**: Ingress HTTPS, Certificados SSL
- **Status**: 🔄 Novo (para migração)

### **4. firefly-cors-middleware**
- **Arquivo**: `firefly-cors-middleware-app.yaml`
- **Tipo**: ArgoCD Application com manifesto Kubernetes direto
- **Componentes**: Middleware CORS do Traefik
- **Status**: 🔄 Novo (opcional)

## 🚀 Deployment via ArgoCD

### **Para aplicar todos os ArgoCD Applications:**

```bash
# Aplicar todas as applications
kubectl apply -f argocd-apps/

# Ou individualmente:
kubectl apply -f argocd-apps/firefly-sandbox-app.yaml
kubectl apply -f argocd-apps/firefly-ingress-app.yaml
kubectl apply -f argocd-apps/firefly-cors-middleware-app.yaml
```

### **Ordem de deployment recomendada:**

1. **firefly-gateway** (já ativo)
2. **firefly-cors-middleware** (middleware)
3. **firefly-sandbox** (aplicação)
4. **firefly-ingress** (último - depende dos serviços)

## 🔄 Migração do kubectl para ArgoCD

### **Status atual:**
- ✅ `firefly-gateway.yaml` - Já no ArgoCD
- ⚠️ `firefly-sandbox.yaml` - kubectl direto
- ⚠️ `firefly-ingress.yaml` - kubectl direto

### **Após aplicar os ArgoCD Apps:**
- ✅ `firefly-gateway.yaml` - ArgoCD
- ✅ `firefly-sandbox.yaml` - ArgoCD  
- ✅ `firefly-ingress.yaml` - ArgoCD

## 📊 URLs finais:

- **FireFly Core API**: `https://firefly.cluster.eita.cloud/api/v1/status`
- **FireFly Core UI**: `https://firefly.cluster.eita.cloud/ui/`
- **Sandbox UI**: `https://firefly-sandbox.cluster.eita.cloud/`
- **Sandbox API**: `https://firefly-sandbox.cluster.eita.cloud/api/`

## 🎯 Benefícios da migração:

- ✅ GitOps completo
- ✅ Sincronização automática
- ✅ Rollbacks automáticos  
- ✅ Visibilidade centralizada no ArgoCD UI
- ✅ Gestão de dependências