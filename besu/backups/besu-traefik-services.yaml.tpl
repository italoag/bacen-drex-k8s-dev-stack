# Template para geração dinâmica via envsubst e shell
# Este arquivo será gerado dinamicamente pelo script de deploy

apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: besu-rpc-lb
  namespace: ${NAMESPACE}
spec:
  weighted:
    services:
${BESU_TRAEFIK_SERVICE_BLOCKS}
