#!/usr/bin/env bash
set -euo pipefail

# publish.sh - The Quartermaster (Releases-only mode)
# Uploads packages to GitHub Releases (no 100MB limit)

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <artifacts_dir>"
  exit 1
fi

ARTIFACTS_DIR="$1"
ROOT_DIR="$(pwd)"
REPO_NAME="${REPO_NAME:-buildfactory}"
RELEASE_TAG="${RELEASE_TAG:-buildfactory}"
OWNER="Neycrol"
REPO="misaka-treasure-chest"

if [[ -z "${BINREPO_TOKEN:-}" ]]; then
  echo "Error: BINREPO_TOKEN is missing. Cannot deploy."
  exit 1
fi

echo "::group::[Setup] Preparing packages"
WORK_DIR=$(mktemp -d)
mkdir -p "$WORK_DIR/repo"

# Copy artifacts
cp -v "$ARTIFACTS_DIR"/*.pkg.tar.zst "$WORK_DIR/repo/" 2>/dev/null || true
rm -f "$WORK_DIR/repo"/*-debug-*.pkg.tar.zst

cd "$WORK_DIR/repo"
PKG_COUNT=$(ls *.pkg.tar.zst 2>/dev/null | wc -l)
if [[ "$PKG_COUNT" -eq 0 ]]; then
  echo "No packages to publish."
  exit 0
fi
echo "Found $PKG_COUNT packages to publish"
echo "::endgroup::"

echo "::group::[Database] Building package database"
# Download existing db from release (if exists)
echo "Fetching existing database..."
curl -sL -H "Authorization: Bearer $BINREPO_TOKEN" \
  "https://github.com/$OWNER/$REPO/releases/download/$RELEASE_TAG/${REPO_NAME}.db.tar.gz" \
  -o "${REPO_NAME}.db.tar.gz" 2>/dev/null || true

# Add new packages to db
repo-add -R "${REPO_NAME}.db.tar.gz" *.pkg.tar.zst

# Create symlinks
cp -f "${REPO_NAME}.db.tar.gz" "${REPO_NAME}.db"
cp -f "${REPO_NAME}.files.tar.gz" "${REPO_NAME}.files"
echo "::endgroup::"

echo "::group::[Release] Uploading to GitHub Releases"
# Upload via gh_release.py
python3 "$ROOT_DIR/ci/gh_release.py" \
  "$OWNER" "$REPO" "$RELEASE_TAG" "$BINREPO_TOKEN" \
  *.pkg.tar.zst \
  "${REPO_NAME}.db.tar.gz" \
  "${REPO_NAME}.db" \
  "${REPO_NAME}.files.tar.gz" \
  "${REPO_NAME}.files"
echo "::endgroup::"

# Cleanup
rm -rf "$WORK_DIR"
echo "✅ Published $PKG_COUNT packages to GitHub Releases"
