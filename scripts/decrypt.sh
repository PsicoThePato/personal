#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KB_DIR="$REPO_ROOT/knowledge_base"
VAULT_DIR="$KB_DIR/.vault"
AGE_KEY="${AGE_KEY_FILE:-$HOME/.age/personal.key}"

if [ ! -f "$AGE_KEY" ]; then
  echo "Error: Key file not found: $AGE_KEY"
  exit 1
fi

if [ ! -f "$VAULT_DIR/manifest.age" ]; then
  echo "No vault found — nothing to decrypt"
  exit 0
fi

# Decrypt manifest
MANIFEST=$(age --decrypt -i "$AGE_KEY" "$VAULT_DIR/manifest.age")

count=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  hash="${line%%:*}"
  rel_path="${line#*:}"
  vault_file="$VAULT_DIR/${hash}.age"
  target="$KB_DIR/$rel_path"

  if [ ! -f "$vault_file" ]; then
    echo "Warning: vault file missing for $rel_path"
    continue
  fi

  if [ ! -f "$target" ] || [ "$vault_file" -nt "$target" ]; then
    mkdir -p "$(dirname "$target")"
    age --decrypt -i "$AGE_KEY" -o "$target" "$vault_file"
    count=$((count + 1))
  fi
done <<< "$MANIFEST"

echo "Decrypted $count file(s)"
