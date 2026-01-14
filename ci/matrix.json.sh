#!/usr/bin/env bash
set -euo pipefail

# matrix.json.sh - The Tactician
# Reads the battle plan (packages-small.txt) and generates a JSON strategy matrix.
# Usage: ./matrix.json.sh [filter_regex] [invert_match=0|1]

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$ROOT_DIR/ci/packages-small.txt}"
FILTER="${1:-.*}"
INVERT="${2:-0}"

if [[ ! -f "$PACKAGES_FILE" ]]; then
  echo "Error: Strategy file not found at $PACKAGES_FILE" >&2
  exit 1
fi

# Use jq to read lines, filter comments/empty, and output a compact JSON array.
# We apply grep filter first.
grep_cmd="grep"
if [[ "$INVERT" == "1" ]]; then
  grep_cmd="grep -v"
fi

# Pipeline:
# 1. Filter out comments/empty.
# 2. Apply argument filter (e.g. "kde-bolt").
# 3. JSONify.
json_output=$(grep -vE '^\s*#|^\s*$' "$PACKAGES_FILE" | $grep_cmd -E "$FILTER" | jq -R -s -c 'split("\n")[:-1]')

if [[ "$json_output" == "[]" ]]; then
  # It's okay to have empty tiers, return empty list but don't fail hard
  echo "[]"
  exit 0
fi

echo "$json_output"