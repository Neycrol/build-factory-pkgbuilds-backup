#!/usr/bin/env bash
set -euo pipefail

# build-single.sh - The Soldier
# Executes a surgical strike build on a single package target.
# FEATURING: Auto-Upload & Robust Error Handling

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <package_path>"
  exit 1
fi

PKG_PATH="$1"
ROOT_DIR="$(pwd)"
ARTIFACT_DIR="${ROOT_DIR}/artifacts"
mkdir -p "$ARTIFACT_DIR"

# Env Vars for Push Each
PUSH_EACH="${PUSH_EACH:-0}"
REPO_NAME="${REPO_NAME:-buildfactory}"
RELEASE_TAG="${RELEASE_TAG:-buildfactory}"

echo "::group::[Setup] Initializing Combat Environment"

# 1. System Prep
pacman-key --init
pacman-key --populate archlinux
for i in {1..3}; do
  pacman -Syu --noconfirm && break || sleep 5
done
pacman -S --noconfirm --needed git sudo curl python jq base-devel openssh

# 2. Builder User
if ! id -u builder >/dev/null 2>&1; then
  useradd -m builder
  echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
fi
chown -R builder:builder "$ROOT_DIR"

# 3. God Mode GCC Injection
GOD_GCC_URL="${GOD_GCC_URL:-}"
GOD_GCC_TOKEN="${GOD_GCC_TOKEN:-}"

if [[ -n "$GOD_GCC_URL" ]]; then
  echo ">> Injecting Divine Power (GCC God Mode)..."
  tmp_pkg=$(mktemp)
  download_ok=0
  
  curl_args=(-L --fail --retry 3)
  if [[ -n "$GOD_GCC_TOKEN" ]]; then
    curl_args+=(-H "Authorization: Bearer $GOD_GCC_TOKEN")
  fi
  
  if curl "${curl_args[@]}" "$GOD_GCC_URL" -o "$tmp_pkg"; then
    download_ok=1
  else
    echo "Direct download failed. Attempting GitHub API resolution..."
    if [[ -n "$GOD_GCC_TOKEN" ]] && [[ "$GOD_GCC_URL" == https://github.com/*/releases/download/* ]]; then
       cat <<EOF > resolve_asset.py
import sys, json, urllib.request
try:
    url = '$GOD_GCC_URL'
    token = '$GOD_GCC_TOKEN'
    parts = url.replace('https://github.com/', '').split('/')
    owner, repo, tag, asset_name = parts[0], parts[1], parts[4], parts[5]
    api_url = f'https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}'
    req = urllib.request.Request(api_url)
    req.add_header('Authorization', f'Bearer {token}')
    req.add_header('Accept', 'application/vnd.github+json')
    with urllib.request.urlopen(req) as r:
        data = json.load(r)
    for a in data.get('assets', []):
        if a['name'] == asset_name:
            print(a['url'])
            sys.exit(0)
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)
EOF
       python3 resolve_asset.py > asset_url.txt || true
       rm -f resolve_asset.py
       asset_url=$(cat asset_url.txt)
       if [[ -n "$asset_url" ]]; then
         curl -L --fail -H "Authorization: Bearer $GOD_GCC_TOKEN" -H "Accept: application/octet-stream" "$asset_url" -o "$tmp_pkg" && download_ok=1
       fi
       rm -f asset_url.txt
    fi
  fi

  if [[ "$download_ok" == "1" ]]; then
    pacman -U --noconfirm "$tmp_pkg" || echo "Warning: God GCC install failed, falling back to mortal GCC."
  else
    echo "Warning: God GCC download failed, falling back to mortal GCC."
  fi
  rm -f "$tmp_pkg"
fi

if [[ -x "/opt/gcc-git-god/bin/gcc" ]]; then
  export PATH="/opt/gcc-git-god/bin:$PATH"
  echo ">> God Mode Active: $(/opt/gcc-git-god/bin/gcc --version | head -n1)"
else
  install -d /opt/gcc-git-god/bin
  ln -sf /usr/bin/gcc /opt/gcc-git-god/bin/gcc
  ln -sf /usr/bin/g++ /opt/gcc-git-god/bin/g++
fi

# 4. Makepkg Configuration
MAKEPKG_CONF="/etc/makepkg.conf"
sed -i 's/^OPTIONS=(docs/OPTIONS=(!docs/' "$MAKEPKG_CONF"
sed -i 's/^OPTIONS=(strip/OPTIONS=(!strip/' "$MAKEPKG_CONF"
sed -i 's/!debug/debug/g' "$MAKEPKG_CONF"
sed -i "s/#MAKEFLAGS=\\\"-j2\\\"/MAKEFLAGS=\\\"-j$(nproc)\\\"/" "$MAKEPKG_CONF"
# Replace march=native with alderlake for CI
sed -i "s/-march=native/-march=alderlake/g; s/-mtune=native/-mtune=alderlake/g" "$MAKEPKG_CONF"

echo "::endgroup::"

# 5. Execute Build
echo "::group::[Build] Target: $PKG_PATH"

if [[ ! -d "$PKG_PATH" ]]; then
  echo "Error: Directory $PKG_PATH does not exist."
  exit 1
fi

cd "$PKG_PATH"

# Replace march=native in PKGBUILD for CI (target: alderlake)
if grep -q "march=native" PKGBUILD 2>/dev/null; then
  echo ">> Replacing march=native with march=alderlake in PKGBUILD..."
  sed -i "s/-march=native/-march=alderlake/g; s/-mtune=native/-mtune=alderlake/g" PKGBUILD
fi
chown -R builder:builder .

# DEBUG: Check files
echo ">> [Debug] File listing in $PKG_PATH:"
ls -la

# HOTFIX: ffmpeg werror
if [[ "$PKG_PATH" == *"ffmpeg"* ]]; then
  echo ">> Applying ffmpeg -Wno-error hotfix..."
  export CFLAGS="${CFLAGS:-} -Wno-error"
  export CXXFLAGS="${CXXFLAGS:-} -Wno-error"
fi

# HOTFIX: Dependency handling
# If we suspect missing deps (Exit 8), we can try to install the god-mode binrepo FIRST
# But wait, we need to know the repo URL.
# It is: https://github.com/Neycrol/misaka-treasure-chest
# We can add it to pacman.conf!
echo ">> Adding Misaka Treasure Chest to pacman.conf..."
cat <<PACMAN_REPO >> /etc/pacman.conf

[buildfactory]
SigLevel = Optional TrustAll
Server = https://github.com/Neycrol/misaka-treasure-chest/releases/download/buildfactory
PACMAN_REPO
# Sync DB
pacman -Sy || echo "Warning: Failed to sync custom repo."

echo ">> Starting makepkg..."
sudo -u builder PATH="$PATH" makepkg -s --noconfirm --skippgpcheck --noprogressbar

# 6. Harvest Artifacts
echo ">> Harvesting artifacts..."
find . -maxdepth 1 -name "*.pkg.tar.zst" -exec cp -v {} "$ARTIFACT_DIR/" \;
find . -maxdepth 1 -name "*.pkg.tar.zst.sig" -exec cp -v {} "$ARTIFACT_DIR/" \; 2>/dev/null || true

# Rename files with colons (epoch) for Windows compatibility
for f in "$ARTIFACT_DIR"/*:*; do
  [[ -e "$f" ]] && mv -v "$f" "${f//:/_}"
done

count=$(ls -1 "$ARTIFACT_DIR"/*.pkg.tar.zst 2>/dev/null | wc -l)
if [[ "$count" -eq 0 ]]; then
  echo "Error: No packages built."
  exit 1
fi
echo ">> Successfully built $count packages."
echo "::endgroup::"

# 7. Immediate Publish
if [[ "$PUSH_EACH" == "1" ]]; then
  echo "::group::[Publish] Immediate Upload to GitHub Releases"
  
  if [[ -z "${BINREPO_TOKEN:-}" ]]; then
    echo "Warning: BINREPO_TOKEN missing, skipping upload."
  else
    # Upload directly to GitHub Releases (no git push, no race condition!)
    echo ">> Uploading to GitHub Releases..."
    if [[ -f "$ROOT_DIR/ci/gh_release.py" ]]; then
       python3 "$ROOT_DIR/ci/gh_release.py" \
         "Neycrol" "misaka-treasure-chest" "${RELEASE_TAG}" "${BINREPO_TOKEN}" \
         "$ARTIFACT_DIR"/*.pkg.tar.zst
    else
       echo "Warning: ci/gh_release.py not found."
    fi
  fi
  echo "::endgroup::"
fi
