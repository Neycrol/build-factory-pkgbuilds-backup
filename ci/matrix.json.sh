#!/usr/bin/env bash
set -euo pipefail

# matrix.json.sh - The Tactician
# Reads the battle plan (packages-small.txt) and generates a JSON strategy matrix.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$ROOT_DIR/ci/packages-small.txt}"

if [[ ! -f "$PACKAGES_FILE" ]]; then
  echo "Error: Strategy file not found at $PACKAGES_FILE" >&2
  exit 1
fi

# Use jq to read lines, filter comments/empty, and output a compact JSON array.
# Defensive check: ensure at least one package exists.
json_output=$(grep -vE '^\s*#|^\s*$' "$PACKAGES_FILE" | jq -R -s -c 'split("\n")[:-1]')

if [[ "$json_output" == "[]" ]]; then
  echo "Error: No targets found in battle plan." >&2
  exit 1
fi

echo "$json_output"
