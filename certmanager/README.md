# Cert-Manager para K3s

Este diretório contém scripts e configurações para instalar e configurar o cert-manager no cluster Kubernetes para gerenciamento automático de certificados TLS.

## Instalação

Para instalar ou atualizar o cert-manager no cluster, execute:

```bash
# Opcionalmente, defina o e-mail para Let's Encrypt (ou será usado o valor padrão)
export EMAIL=seu-email@exemplo.com

# Execute o script de instalação
./deploy-cert-manager.sh
```

## Suporte a Redes Corporativas

O script de instalação detecta automaticamente se você está em uma rede corporativa com interceptação SSL (por exemplo, soluções como Netskope, Zscaler, etc.) que podem causar problemas com a validação de certificados. Neste caso, o script:

1. Detecta e extrai os certificados CA corporativos
2. Cria um Secret com estes certificados
3. Configura o cert-manager para confiar nestes certificados

Para pular esta verificação, você pode definir:
```bash
export SKIP_CERT_CHECK=true
```

Para diagnosticar problemas com certificados corporativos manualmente:
```bash
./diagnose-certificates.sh
```

## Arquivos

- `deploy-cert-manager.sh` - Script principal para instalação e configuração do cert-manager
- `cert-manager-values.yaml` - Configurações personalizadas para o Helm chart (para uso futuro)
- `letsencrypt-certmanager.yaml.template` - Template para criação do ClusterIssuer

## Utilização

Após a instalação, você pode solicitar certificados TLS adicionando as seguintes anotações aos seus recursos Ingress:

```yaml
annotations:
  cert-manager.io/cluster-issuer: "letsencrypt-certmanager"
  kubernetes.io/tls-acme: "true"
```

Exemplo de um Ingress com TLS:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: exemplo-ingress
  namespace: seu-namespace
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-certmanager"
    kubernetes.io/tls-acme: "true"
    kubernetes.io/ingress.class: traefik
spec:
  tls:
  - hosts:
    - seu-dominio.com
    secretName: seu-dominio-tls
  rules:
  - host: seu-dominio.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: seu-servico
            port:
              number: 80
```

## Verificação e Troubleshooting

Para verificar o status do cert-manager:

```bash
kubectl get pods -n cert-manager
```

Para verificar o ClusterIssuer:

```bash
kubectl describe clusterissuer letsencrypt-certmanager
```

Para verificar certificados:

```bash
kubectl get certificates --all-namespaces
kubectl get certificaterequests --all-namespaces
```

Para verificar eventos relacionados a certificados:

```bash
kubectl get events --field-selector involvedObject.kind=Certificate --all-namespaces
kubectl get events --field-selector involvedObject.kind=CertificateRequest --all-namespaces
```

### Problemas com Certificados Corporativos

Se você estiver em uma rede corporativa e encontrar erros relacionados a certificados, use o script diagnóstico:

```bash
./diagnose-certificates.sh
```

Este script:
1. Testa a conexão com o servidor Let's Encrypt
2. Analisa os certificados recebidos para detectar intercepção SSL
3. Oferece opções para instalar certificados CA corporativos no cert-manager

Erros comuns relacionados a certificados incluem:
- `x509: certificate signed by unknown authority`
- `x509: certificate is not trusted`
- `x509: certificate has expired or is not yet valid`

Estes erros geralmente ocorrem quando há um proxy SSL corporativo que intercepta o tráfego HTTPS.
