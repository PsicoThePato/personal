#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
KB_DIR="$REPO_ROOT/knowledge_base"
VAULT_DIR="$KB_DIR/.vault"
RECIPIENTS_FILE="$REPO_ROOT/.age-recipients"

if [ ! -f "$RECIPIENTS_FILE" ]; then
  echo "Error: .age-recipients not found"
  exit 1
fi

mkdir -p "$VAULT_DIR"

# Clean old vault
find "$VAULT_DIR" -name "*.age" -delete 2>/dev/null || true

# Encrypt each .md to vault with hashed filename
MANIFEST=""
count=0

while IFS= read -r -d '' md_file; do
  rel_path="${md_file#$KB_DIR/}"
  hash=$(echo -n "$rel_path" | shasum -a 256 | cut -c1-16)
  vault_file="$VAULT_DIR/${hash}.age"

  age --encrypt -R "$RECIPIENTS_FILE" -o "$vault_file" "$md_file"
  MANIFEST="${MANIFEST}${hash}:${rel_path}\n"
  count=$((count + 1))
done < <(find "$KB_DIR" -name "*.md" -not -path "*/.vault/*" -print0)

# Encrypt the manifest
echo -e "$MANIFEST" | age --encrypt -R "$RECIPIENTS_FILE" -o "$VAULT_DIR/manifest.age"

# Stage vault, unstage any plaintext from knowledge_base
git add "$VAULT_DIR/"
git ls-files --cached "$KB_DIR" | grep -v '\.vault/' | while read -r f; do
  git rm --cached "$f" 2>/dev/null || true
done

if [ "$count" -gt 0 ]; then
  echo "Encrypted $count file(s) to vault"
fi
