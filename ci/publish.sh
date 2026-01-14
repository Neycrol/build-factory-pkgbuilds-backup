#!/usr/bin/env bash
set -euo pipefail

# publish.sh - The Quartermaster
# Aggregates build artifacts, updates the database, and ships the goods.

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <artifacts_dir>"
  exit 1
fi

ARTIFACTS_DIR="$1"
ROOT_DIR="$(pwd)"
BINREPO_DIR="${ROOT_DIR}/.binrepo"
REPO_NAME="${REPO_NAME:-buildfactory}"
RELEASE_TAG="${RELEASE_TAG:-buildfactory}"

if [[ -z "${BINREPO_TOKEN:-}" ]]; then
  echo "Error: BINREPO_TOKEN is missing. Cannot deploy."
  exit 1
fi

echo "::group::[Setup] Cloning Supply Depot"
# Clean slate
rm -rf "$BINREPO_DIR"

# Configure Git credential helper for the token
git config --global credential.helper store
echo "https://x-access-token:${BINREPO_TOKEN}@github.com" > ~/.git-credentials

git clone "https://github.com/Neycrol/misaka-treasure-chest.git" "$BINREPO_DIR"
cd "$BINREPO_DIR"

# Configure identity
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
echo "::endgroup::"

echo "::group::[Database] Updating Package Index"
# Move artifacts into place
mkdir -p repo
cp -v "$ARTIFACTS_DIR"/*.pkg.tar.zst repo/ 2>/dev/null || true
# Clean debug packages if any leaked through
rm -f repo/*-debug-*.pkg.tar.zst

# Update DB
cd repo
# Find all packages to add (only the ones we just copied + existing ones if we want full regen, 
# but repo-add is incremental usually. To be safe/simple, we add all zst files in current dir)
# We only want to add the *new* ones ideally, but repo-add handles re-adding fine.
# Let's list the files we just brought in.
PKG_FILES=$(ls *.pkg.tar.zst)

if [[ -z "$PKG_FILES" ]]; then
  echo "No packages to add."
  exit 0
fi

# repo-add
# We use -R to remove old entries for the same package
repo-add -R "${REPO_NAME}.db.tar.gz" *.pkg.tar.zst

# Sync file extensions
rm -f "${REPO_NAME}.db" "${REPO_NAME}.files"
cp -f "${REPO_NAME}.db.tar.gz" "${REPO_NAME}.db"
cp -f "${REPO_NAME}.files.tar.gz" "${REPO_NAME}.files"
cd ..
echo "::endgroup::"

echo "::group::[Deploy] Pushing to Repository"
git add "repo/${REPO_NAME}.db.tar.gz" "repo/${REPO_NAME}.files.tar.gz" "repo/${REPO_NAME}.db" "repo/${REPO_NAME}.files"
git add repo/*.pkg.tar.zst

if git diff --cached --quiet; then
  echo "No changes to commit."
else
  git commit -m "Update packages $(date -u +%Y-%m-%d)"
  
  # Retry loop for push
  for i in {1..5}; do
    git pull --rebase origin main
    if git push origin main; then
      break
    fi
    echo "Push failed, retrying ($i/5)..."
    sleep 5
  done
fi
echo "::endgroup::"

echo "::group::[Release] Uploading to GitHub Releases"
# Extract Owner/Repo from remote
REMOTE_URL=$(git remote get-url origin)
# Convert https://github.com/Owner/Repo.git -> Owner Repo
# Simplified regex
if [[ "$REMOTE_URL" =~ github.com[:/]([^/]+)/([^/.]+)(\.git)? ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  
  echo "Detected Release Target: $OWNER/$REPO @ $RELEASE_TAG"
  
  # Call python script
  # We need to install python reqs? Standard library is sufficient for our script.
  python3 "$ROOT_DIR/ci/gh_release.py" \
    "$OWNER" "$REPO" "$RELEASE_TAG" "$BINREPO_TOKEN" \
    "$BINREPO_DIR"/repo/*.pkg.tar.zst \
    "$BINREPO_DIR"/repo/${REPO_NAME}.db.tar.gz \
    "$BINREPO_DIR"/repo/${REPO_NAME}.files.tar.gz

else
  echo "Could not parse remote URL: $REMOTE_URL"
fi
echo "::endgroup::"
