#!/usr/bin/env bash
set -euo pipefail

# NOME DO ARQUIVO A REMOVER
TARGET="vault/vault-unseal.txt"

# 1) Verifica se estamos no branch principal
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
  echo "⚠️  Você não está no branch 'main' ou 'master' (atual: $BRANCH)."
  echo "   Mude para o branch principal e execute de novo."
  exit 1
fi

# 2) Cria um branch de backup antes de mexer no histórico
BACKUP="backup-before-remove-$(date +%Y%m%d%H%M%S)"
git checkout -b "$BACKUP"
echo "✅ Criado branch de backup: $BACKUP"

# 3) Volta para o principal e começa a limpeza
git checkout "$BRANCH"

# 4) Tenta usar git-filter-repo
if command -v git-filter-repo &> /dev/null; then
  echo "🔍 Usando git-filter-repo para remover '$TARGET' do histórico..."
  git filter-repo --invert-paths --path "$TARGET"
else
  echo "⚠️  git-filter-repo não encontrado. Usando fallback com git filter-branch..."
  git filter-branch --force \
    --index-filter "git rm --cached --ignore-unmatch '$TARGET'" \
    --prune-empty --tag-name-filter cat -- --all
fi

# 5) Limpeza de refs e objetos órfãos
echo "🧹 Limpando referências originais e otimizando gc..."
rm -rf .git/refs/original/ .git/filter-repo
git reflog expire --expire=now --all
git gc --prune=now --aggressive

# 6) Força o push para reescrever o histórico remoto
echo "🚀 Forçando push de todos os branches e tags..."
git push origin --force --all
git push origin --force --tags

echo "🎉 Feito! O arquivo '$TARGET' foi removido do histórico."
echo "ℹ️  Aviso: todos os colaboradores precisarão clonar o repositório novamente."