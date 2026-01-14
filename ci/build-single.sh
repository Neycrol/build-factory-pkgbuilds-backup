#!/usr/bin/env bash
set -euo pipefail

# build-single.sh - The Soldier
# Executes a surgical strike build on a single package target.
# NOW FEATURING: Immediate Air Support (Auto-Upload)

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
sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(nproc)\"/