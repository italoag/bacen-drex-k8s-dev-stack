# Certificados Corporativos para Cert-Manager

Este documento descreve as alterações feitas para suportar certificados corporativos no cert-manager, especialmente em ambientes com proxies SSL como Netskope.

## Problema

Em ambientes corporativos, as conexões HTTPS são frequentemente interceptadas por soluções de segurança como Netskope, Zscaler, ou proxies corporativos. Essas soluções substituem os certificados originais por certificados assinados pela CA corporativa.

Quando o cert-manager tenta se conectar ao Let's Encrypt para validar ou solicitar certificados, ele pode falhar com erros como:
- `x509: certificate signed by unknown authority`
- `x509: certificate is not trusted`

## Solução Implementada

O script `deploy-cert-manager.sh` agora inclui funcionalidades para:

1. **Detectar Redes Corporativas**:
   - Verifica se o certificado retornado ao acessar Let's Encrypt é legítimo ou foi interceptado
   - Analisa o certificado para determinar se é de uma solução corporativa conhecida

2. **Extrair Certificados CA**:
   - Extrai toda a cadeia de certificados usando OpenSSL
   - Salva os certificados para uso no cluster

3. **Configurar o Cert-Manager**:
   - Cria um Secret com os certificados CA corporativos
   - Configura o cert-manager para confiar nesses certificados por meio de volume mounts e argumentos extras

4. **Ferramenta de Diagnóstico**:
   - Script `diagnose-certificates.sh` para analisar e diagnosticar problemas de certificados
   - Permite instalação manual de certificados corporativos

## Como Funciona

1. **Detecção Automática**: Ao executar `deploy-cert-manager.sh`, o script:
   - Conecta-se a `https://acme-v02.api.letsencrypt.org/directory`
   - Analisa o emissor do certificado recebido
   - Determina se está em uma rede com interceptação SSL

2. **Instalação de Certificados**:
   - Os certificados corporativos são extraídos e salvos em um Secret Kubernetes
   - O cert-manager é configurado para usar estes certificados como CAs confiáveis 

3. **Diagnóstico de Problemas**:
   - O script `diagnose-certificates.sh` oferece análise manual e instalação de certificados

## Ambientes Suportados

Esta solução deve funcionar nos seguintes cenários:
- Redes com Netskope instalado
- Ambientes com proxies SSL e TLS inspection
- Ambientes corporativos com firewall aplicando TLS MITM

## Desativando a Verificação

Se necessário, você pode desativar esta funcionalidade:
```bash
export SKIP_CERT_CHECK=true
./deploy-cert-manager.sh
```
