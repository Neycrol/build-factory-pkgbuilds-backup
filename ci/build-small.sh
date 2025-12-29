#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$ROOT_DIR/ci/packages-small.txt}"
BINREPO_DIR="${BINREPO_DIR:-$ROOT_DIR/.binrepo}"
REPO_NAME="${REPO_NAME:-buildfactory}"
CPU_TARGET_FILE="${CPU_TARGET_FILE:-$ROOT_DIR/ci/cpu-target.conf}"
GOD_GCC_URL="${GOD_GCC_URL:-}"
GOD_GCC_SHA256="${GOD_GCC_SHA256:-}"
GOD_GCC_TOKEN="${GOD_GCC_TOKEN:-${GITHUB_TOKEN:-}}"
PUSH_EACH="${PUSH_EACH:-0}"
CLEAN_AFTER_BUILD="${CLEAN_AFTER_BUILD:-0}"
CLEAN_SRCDEST="${CLEAN_SRCDEST:-0}"
CLEAN_PACMAN="${CLEAN_PACMAN:-0}"

mkdir -p "$BINREPO_DIR/repo" "$BINREPO_DIR/srcdest"

export PKGDEST="$BINREPO_DIR/repo"
export SRCDEST="${SRCDEST:-$BINREPO_DIR/srcdest}"

GIT_CONFIG_FILE="$BINREPO_DIR/gitconfig"
cat > "$GIT_CONFIG_FILE" <<'EOF'
[fetch]
    progress = true
[clone]
    progress = true
EOF
export MAKEPKG_GIT_CONFIG="$GIT_CONFIG_FILE"

GIT_WRAPPER_DIR="$BINREPO_DIR/git-wrapper"
mkdir -p "$GIT_WRAPPER_DIR"
cat > "$GIT_WRAPPER_DIR/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REAL_GIT="/usr/bin/git"

if [[ $# -eq 0 ]]; then
  exec "$REAL_GIT"
fi

cmd="$1"
shift

case "$cmd" in
  clone|fetch)
    exec "$REAL_GIT" "$cmd" --progress "$@"
    ;;
  *)
    exec "$REAL_GIT" "$cmd" "$@"
    ;;
esac
EOF
chmod +x "$GIT_WRAPPER_DIR/git"
export PATH="$GIT_WRAPPER_DIR:$PATH"

if [[ "${DEBUG_ENV:-0}" == "1" ]]; then
  env | sort | grep -E '^(MAKEPKG|GIT)_' || true
  command -v git || true
  git --version || true
fi

if [[ -f "$CPU_TARGET_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CPU_TARGET_FILE"
fi

CPU_MARCH="${CPU_MARCH:-}"
CPU_MTUNE="${CPU_MTUNE:-$CPU_MARCH}"

if [[ -n "$CPU_MARCH" ]]; then
  export CFLAGS="${CFLAGS:-} -march=${CPU_MARCH}"
  export CXXFLAGS="${CXXFLAGS:-} -march=${CPU_MARCH}"
  if [[ -n "$CPU_MTUNE" ]]; then
    export CFLAGS="${CFLAGS} -mtune=${CPU_MTUNE}"
    export CXXFLAGS="${CXXFLAGS} -mtune=${CPU_MTUNE}"
  fi
  export RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=${CPU_MARCH}"
fi

if [[ -z "${MAKEFLAGS:-}" ]]; then
  export MAKEFLAGS="-j$(nproc)"
fi

if [[ "${CI:-}" == "true" ]]; then
  if [[ -n "$GOD_GCC_URL" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      sudo pacman -S --noconfirm --needed curl
    fi
    tmp_pkg=$(mktemp)
    download_ok=0
    curl_args=(-L --fail --retry 3)
    if [[ -n "$GOD_GCC_TOKEN" ]]; then
      curl_args+=(-H "Authorization: Bearer $GOD_GCC_TOKEN")
    fi
    if curl "${curl_args[@]}" "$GOD_GCC_URL" -o "$tmp_pkg"; then
      download_ok=1
    else
      echo "Direct GCC download failed; attempting GitHub API."
      if [[ -n "$GOD_GCC_TOKEN" ]] && [[ "$GOD_GCC_URL" == https://github.com/*/releases/download/* ]]; then
        if ! command -v python >/dev/null 2>&1; then
          sudo pacman -S --noconfirm --needed python
        fi
        stripped=${GOD_GCC_URL#https://github.com/}
        owner=${stripped%%/*}
        rest=${stripped#*/}
        repo=${rest%%/*}
        rest=${rest#*/}
        rest=${rest#releases/download/}
        tag=${rest%%/*}
        asset=${rest#*/}
        api_url="https://api.github.com/repos/${owner}/${repo}/releases/tags/${tag}"
        asset_url=$(python - "$api_url" "$GOD_GCC_TOKEN" "$asset" <<'PY' || true
import json
import sys
import urllib.request

api_url, token, asset_name = sys.argv[1:4]
req = urllib.request.Request(api_url)
req.add_header("Accept", "application/vnd.github+json")
if token:
    req.add_header("Authorization", f"Bearer {token}")
with urllib.request.urlopen(req) as resp:
    data = json.load(resp)
for item in data.get("assets", []):
    if item.get("name") == asset_name:
        print(item.get("url", ""))
        break
PY
)
        if [[ -n "$asset_url" ]]; then
          if curl -L --fail -H "Authorization: Bearer $GOD_GCC_TOKEN" -H "Accept: application/octet-stream" "$asset_url" -o "$tmp_pkg"; then
            download_ok=1
          fi
        else
          echo "GCC asset not found via API; check tag or asset name."
        fi
      else
        echo "GCC URL not in release-download form or token missing; skipping API fallback."
      fi
    fi

    if [[ "$download_ok" == "1" ]]; then
      if [[ -n "$GOD_GCC_SHA256" ]]; then
        echo "${GOD_GCC_SHA256}  $tmp_pkg" | sha256sum -c -
      fi
      if ! sudo pacman -U --noconfirm "$tmp_pkg"; then
        echo "GCC toolchain install failed; continuing with system gcc."
      fi
    else
      echo "GCC toolchain download failed; continuing with system gcc."
    fi
    rm -f "$tmp_pkg"
  fi

  if /opt/gcc-git-god/bin/gcc --version >/dev/null 2>&1; then
    export PATH="/opt/gcc-git-god/bin:$PATH"
  else
    echo "GCC toolchain missing or unusable; creating system gcc fallback."
    sudo install -d /opt/gcc-git-god/bin /opt/gcc-git-god/lib64
    for tool in gcc g++ cc c++ gcc-ar gcc-nm gcc-ranlib; do
      if [[ -x "/usr/bin/$tool" ]]; then
        sudo ln -sf "/usr/bin/$tool" "/opt/gcc-git-god/bin/$tool"
      fi
    done
  fi
fi

if [[ "$PUSH_EACH" == "1" ]]; then
  git -C "$BINREPO_DIR" config user.name "github-actions[bot]"
  git -C "$BINREPO_DIR" config user.email "github-actions[bot]@users.noreply.github.com"
  if [[ -n "${BINREPO_TOKEN:-}" ]]; then
    origin_url=$(git -C "$BINREPO_DIR" remote get-url origin)
    if [[ "$origin_url" == https://github.com/* ]]; then
      origin_path=${origin_url#https://github.com/}
      git -C "$BINREPO_DIR" remote set-url origin "https://x-access-token:${BINREPO_TOKEN}@github.com/${origin_path}"
    fi
  else
    echo "BINREPO_TOKEN missing; disabling per-package push."
    PUSH_EACH=0
  fi
fi

mapfile -t packages < <(grep -vE '^[[:space:]]*($|#)' "$PACKAGES_FILE" || true)

if [[ ${#packages[@]} -eq 0 ]]; then
  echo "No packages listed in $PACKAGES_FILE"
  exit 0
fi

repo_updated=0

for pkgdir in "${packages[@]}"; do
  echo "::group::${pkgdir}"
  pkgpath="$ROOT_DIR/$pkgdir/PKGBUILD"
  if [[ ! -f "$pkgpath" ]]; then
    echo "Missing PKGBUILD, skipping."
    echo "::endgroup::"
    continue
  fi

  pushd "$ROOT_DIR/$pkgdir" >/dev/null
  mapfile -t pkgpaths < <(makepkg --packagelist --nobuild --skippgpcheck)

  if [[ ${#pkgpaths[@]} -eq 0 ]]; then
    echo "Failed to compute package list."
    popd >/dev/null
    exit 1
  fi

  missing=false
  for pkgfile in "${pkgpaths[@]}"; do
    if [[ ! -f "$pkgfile" ]]; then
      missing=true
      break
    fi
  done

  if [[ "$missing" == false ]]; then
    echo "Up-to-date; skipping build."
    popd >/dev/null
    echo "::endgroup::"
    continue
  fi

  if [[ -n "$CPU_MARCH" ]]; then
    sed -i \
      -e "s/-march=native/-march=${CPU_MARCH}/g" \
      -e "s/-mtune=native/-mtune=${CPU_MTUNE}/g" \
      -e "s/-mcpu=native/-mcpu=${CPU_MARCH}/g" \
      -e "s/target-cpu=native/target-cpu=${CPU_MARCH}/g" \
      PKGBUILD
  fi

  build_marker=$(mktemp -p "$BINREPO_DIR" build-marker.XXXXXX)
  makepkg -sC --noconfirm --skippgpcheck

  mapfile -t built_pkgs < <(find "$PKGDEST" -maxdepth 1 -type f -name '*.pkg.tar.zst' -newer "$build_marker" 2>/dev/null || true)
  rm -f "$build_marker"

  if [[ ${#built_pkgs[@]} -eq 0 ]]; then
    echo "No new packages detected in PKGDEST for ${pkgdir}"
  fi

  popd >/dev/null

  if [[ ${#built_pkgs[@]} -gt 0 ]]; then
    repo_files=()
    for pkgfile in "${built_pkgs[@]}"; do
      repo_files+=("$(basename "$pkgfile")")
    done
    (cd "$BINREPO_DIR/repo" && repo-add -R "${REPO_NAME}.db.tar.gz" "${repo_files[@]}")
    ln -sf "$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.db"
    ln -sf "$BINREPO_DIR/repo/${REPO_NAME}.files.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.files"
    repo_updated=1

    if [[ "$PUSH_EACH" == "1" ]]; then
      git -C "$BINREPO_DIR" add repo
      if ! git -C "$BINREPO_DIR" diff --cached --quiet; then
        git -C "$BINREPO_DIR" commit -m "Update ${pkgdir} $(date -u +%Y-%m-%d)"
        git -C "$BINREPO_DIR" push
      fi
    fi
  fi

  if [[ "$CLEAN_AFTER_BUILD" == "1" ]]; then
    rm -rf "$ROOT_DIR/$pkgdir/pkg" "$ROOT_DIR/$pkgdir/src"
    if [[ "$CLEAN_SRCDEST" == "1" ]] && [[ -d "$SRCDEST" ]]; then
      find "$SRCDEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    if [[ "$CLEAN_PACMAN" == "1" ]]; then
      sudo pacman -Scc --noconfirm || true
    fi
  fi

  echo "::endgroup::"

done

if [[ "$repo_updated" -eq 0 ]]; then
  if ls "$BINREPO_DIR/repo"/*.pkg.tar.zst >/dev/null 2>&1; then
    (cd "$BINREPO_DIR/repo" && repo-add -R "${REPO_NAME}.db.tar.gz" *.pkg.tar.zst)
    ln -sf "$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.db"
    ln -sf "$BINREPO_DIR/repo/${REPO_NAME}.files.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.files"
  else
    echo "No packages found; skip repo-add."
  fi
fi
