#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINREPO_DIR="${BINREPO_DIR:-$ROOT_DIR/.binrepo}"
REPO_NAME="${REPO_NAME:-buildfactory}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/*.pkg.tar.zst"
  exit 1
fi

mkdir -p "$BINREPO_DIR/repo"

for pkg in "$@"; do
  cp -f "$pkg" "$BINREPO_DIR/repo/"
done

(cd "$BINREPO_DIR/repo" && repo-add -R "${REPO_NAME}.db.tar.gz" *.pkg.tar.zst)
cp -f "$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.db"
cp -f "$BINREPO_DIR/repo/${REPO_NAME}.files.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.files"

if [[ "${PUSH:-0}" == "1" ]]; then
  git -C "$BINREPO_DIR" add repo
  if ! git -C "$BINREPO_DIR" diff --cached --quiet; then
    git -C "$BINREPO_DIR" commit -m "Update packages"
    git -C "$BINREPO_DIR" push
  fi
fi
