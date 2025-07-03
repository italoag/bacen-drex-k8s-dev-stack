# Template para geração dinâmica via envsubst e shell
# Este arquivo será gerado dinamicamente pelo script de deploy

apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: besu-ws-middleware
  namespace: ${NAMESPACE}
spec:
  headers:
    customRequestHeaders:
      Connection: "Upgrade"
      Upgrade: "websocket"
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: besu-retry-middleware
  namespace: ${NAMESPACE}
spec:
  retry:
    attempts: 3
    initialInterval: "500ms"
