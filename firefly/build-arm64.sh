#!/bin/bash

# Script para build do firefly-signer ARM64
set -e

GITHUB_USERNAME="italoag"
IMAGE_TAG="v1.1.21-arm64"
REGISTRY="ghcr.io"

echo "🚀 Building FireFly Signer for ARM64..."

# Verificar se o repositório foi clonado
if [ ! -d "firefly-signer" ]; then
    echo "Cloning firefly-signer repository..."
    git clone https://github.com/hyperledger/firefly-signer.git
fi

# Verificar Docker buildx
if ! docker buildx version > /dev/null 2>&1; then
    echo "❌ Docker buildx não encontrado. Instale o Docker Desktop ou configure buildx."
    exit 1
fi

# Criar builder se não existir
if ! docker buildx inspect multiarch > /dev/null 2>&1; then
    echo "Creating multiarch builder..."
    docker buildx create --name multiarch --use --bootstrap
else
    docker buildx use multiarch
fi

# Build da imagem
echo "Building multi-architecture image..."
docker buildx build \
    --platform linux/arm64,linux/amd64 \
    --file Dockerfile.arm64 \
    --tag "${REGISTRY}/${GITHUB_USERNAME}/firefly-signer:${IMAGE_TAG}" \
    --tag "${REGISTRY}/${GITHUB_USERNAME}/firefly-signer:latest" \
    --push \
    .

echo "✅ Build concluído!"
echo "Imagem disponível em: ${REGISTRY}/${GITHUB_USERNAME}/firefly-signer:${IMAGE_TAG}"
echo ""
echo "Para usar, atualize seu deployment:"
echo "  repository: ${REGISTRY}/${GITHUB_USERNAME}/firefly-signer"
echo "  tag: \"${IMAGE_TAG}\""