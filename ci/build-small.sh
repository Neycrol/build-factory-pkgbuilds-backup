#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$ROOT_DIR/ci/packages-small.txt}"
BINREPO_DIR="${BINREPO_DIR:-$ROOT_DIR/.binrepo}"
REPO_NAME="${REPO_NAME:-buildfactory}"
CPU_TARGET_FILE="${CPU_TARGET_FILE:-$ROOT_DIR/ci/cpu-target.conf}"
GOD_GCC_URL="${GOD_GCC_URL:-}"
GOD_GCC_SHA256="${GOD_GCC_SHA256:-}"

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
    if curl -L --fail --retry 3 "$GOD_GCC_URL" -o "$tmp_pkg"; then
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

mapfile -t packages < <(grep -vE '^[[:space:]]*($|#)' "$PACKAGES_FILE" || true)

if [[ ${#packages[@]} -eq 0 ]]; then
  echo "No packages listed in $PACKAGES_FILE"
  exit 0
fi

for pkgdir in "${packages[@]}"; do
  echo "::group::${pkgdir}"
  pkgpath="$ROOT_DIR/$pkgdir/PKGBUILD"
  if [[ ! -f "$pkgpath" ]]; then
    echo "Missing PKGBUILD, skipping."
    echo "::endgroup::"
    continue
  fi

  pushd "$ROOT_DIR/$pkgdir" >/dev/null
  pkgpaths=$(makepkg --packagelist --nobuild --skippgpcheck)

  if [[ -z "$pkgpaths" ]]; then
    echo "Failed to compute package list."
    popd >/dev/null
    exit 1
  fi

  missing=false
  while IFS= read -r pkgfile; do
    if [[ ! -f "$pkgfile" ]]; then
      missing=true
      break
    fi
  done <<< "$pkgpaths"

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

  makepkg -sC --noconfirm --skippgpcheck
  popd >/dev/null
  echo "::endgroup::"

done

if ls "$BINREPO_DIR/repo"/*.pkg.tar.zst >/dev/null 2>&1; then
  (cd "$BINREPO_DIR/repo" && repo-add -R "${REPO_NAME}.db.tar.gz" *.pkg.tar.zst)
  cp -f "$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.db"
  cp -f "$BINREPO_DIR/repo/${REPO_NAME}.files.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.files"
else
  echo "No packages found; skip repo-add."
fi
