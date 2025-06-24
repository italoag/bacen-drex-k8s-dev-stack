#!/usr/bin/env bash
set -euo pipefail

# === CONFIGURAÇÃO ===
# Arquivo a ser removido do histórico
TARGET="vault/vault-unseal.txt"

# 1) Captura a URL original do remoto "origin"
ORIGIN_URL=$(git config --get remote.origin.url || true)
if [[ -z "$ORIGIN_URL" ]]; then
  echo "⚠️  Não foi possível detectar a URL do remoto 'origin'."
  echo "   Defina manualmente: git remote add origin <url>"
  exit 1
fi

# 2) Verifica se estamos no branch principal
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
  echo "⚠️  Você não está no branch 'main' ou 'master' (atual: $BRANCH)."
  echo "   Faça checkout para o branch principal e execute de novo."
  exit 1
fi

# 3) (Opcional) Sugere reclonar para um “fresh clone”
if [[ -z "${FORCE_CLONE:-}" ]]; then
  echo "ℹ️  Para máxima segurança, recomenda-se rodar em um fresh clone:"
  echo "     git clone $ORIGIN_URL repo-limpo && cd repo-limpo"
  echo "   Ou exportar FORCE_CLONE=1 para ignorar este aviso."
  sleep 3
fi

# 4) Cria um branch de backup antes de mexer no histórico
BACKUP="backup-before-remove-$(date +%Y%m%d%H%M%S)"
git checkout -b "$BACKUP"
echo "✅ Criado branch de backup: $BACKUP"

# 5) Volta para o branch principal
git checkout "$BRANCH"

# 6) Roda git-filter-repo (ou fallback) para remover o TARGET
if command -v git-filter-repo &> /dev/null; then
  echo "🔍 Usando git-filter-repo (force) para remover '$TARGET'..."
  git filter-repo --force --invert-paths --path "$TARGET"
else
  echo "⚠️  git-filter-repo não encontrado. Usando git filter-branch..."
  git filter-branch --force \
    --index-filter "git rm --cached --ignore-unmatch '$TARGET'" \
    --prune-empty --tag-name-filter cat -- --all
fi

# 7) Restaura o remoto origin (git-filter-repo automaticamente remove-o)
echo "🔗 Restaurando o remoto 'origin' para $ORIGIN_URL"
git remote remove origin 2> /dev/null || true
git remote add origin "$ORIGIN_URL"

# 8) Limpa refs originais e objetos órfãos
echo "🧹 Limpando refs originais e otimizando git gc..."
rm -rf .git/refs/original/ .git/filter-repo
git reflog expire --expire=now --all
git gc --prune=now --aggressive

# 9) Força o push do histórico reescrito
echo "🚀 Forçando push de todos os branches e tags para origin..."
git push origin --force --all
git push origin --force --tags

echo "🎉 Concluído! '$TARGET' foi removido do histórico."
echo "ℹ️  Todos os colaboradores devem reclonar ou resetar:"
echo "    git clone $ORIGIN_URL"
echo "  ou, no clone atual:"
echo "    git fetch origin"
echo "    git reset --hard origin/$BRANCH"