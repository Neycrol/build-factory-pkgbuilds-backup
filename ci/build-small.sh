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

install_pkgs_if_present() {
  local to_install=()
  for path in "$@"; do
    if [[ -f "$path" ]]; then
      to_install+=( "$path" )
    fi
  done
  if [[ ${#to_install[@]} -eq 0 ]]; then
    return 1
  fi
  sudo pacman -U --noconfirm --needed "${to_install[@]}"
}

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
  MAKEPKG_CONF="${MAKEPKG_CONF:-$BINREPO_DIR/makepkg.conf}"
  if [[ ! -f "$MAKEPKG_CONF" ]]; then
    cp /etc/makepkg.conf "$MAKEPKG_CONF"
  fi
  if grep -qE '^OPTIONS=' "$MAKEPKG_CONF"; then
    if ! grep -qE '^OPTIONS=.*!debug' "$MAKEPKG_CONF"; then
      sed -i -E 's/(^OPTIONS=\([^)]*)\bdebug\b/\1!debug/' "$MAKEPKG_CONF"
    fi
  fi
  export MAKEPKG_CONF

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

INSTALL_AFTER_BUILD=(
  "kde-bolt/protocols"
  "kde-bolt/libkscreen"
)

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

  if grep -q '^pkgver()' PKGBUILD; then
    makepkg -o --skippgpcheck
  fi

  srcinfo=$(makepkg --printsrcinfo --skippgpcheck)
  pkgver=$(awk -F' = ' '/^\tpkgver = /{print $2; exit}' <<<"$srcinfo")
  pkgrel=$(awk -F' = ' '/^\tpkgrel = /{print $2; exit}' <<<"$srcinfo")
  epoch=$(awk -F' = ' '/^\tepoch = /{print $2; exit}' <<<"$srcinfo")

  mapfile -t pkgnames < <(awk -F' = ' '/^\tpkgname = /{print $2}' <<<"$srcinfo")
  mapfile -t archs < <(awk -F' = ' '/^\tarch = /{print $2}' <<<"$srcinfo")

  arch=""
  if [[ ${#archs[@]} -gt 0 ]]; then
    for candidate in "${archs[@]}"; do
      if [[ "$candidate" == "x86_64" ]]; then
        arch="x86_64"
        break
      fi
    done
    if [[ -z "$arch" ]]; then
      if [[ " ${archs[*]} " == *" any "* ]]; then
        arch="any"
      else
        arch="${archs[0]}"
      fi
    fi
  fi

  if [[ -z "$arch" ]]; then
    echo "Failed to determine arch from srcinfo."
    popd >/dev/null
    exit 1
  fi

  if [[ -n "$epoch" ]]; then
    pkgver="${epoch}:${pkgver}"
  fi

  pkgpaths=()
  for name in "${pkgnames[@]}"; do
    pkgpaths+=("$PKGDEST/${name}-${pkgver}-${pkgrel}-${arch}.pkg.tar.zst")
  done

  if [[ ${#pkgpaths[@]} -eq 0 ]]; then
    echo "Failed to compute package list."
    popd >/dev/null
    exit 1
  fi

  filtered_pkgpaths=()
  for pkgfile in "${pkgpaths[@]}"; do
    pkgbase=$(basename "$pkgfile")
    if [[ "$pkgbase" == *-debug-*.pkg.tar.zst ]]; then
      continue
    fi
    filtered_pkgpaths+=("$pkgfile")
  done
  pkgpaths=("${filtered_pkgpaths[@]}")

  if [[ ${#pkgpaths[@]} -eq 0 ]]; then
    echo "Only debug packages detected; skipping."
    popd >/dev/null
    echo "::endgroup::"
    continue
  fi

  repo_pkgpaths=()
  for pkgfile in "${pkgpaths[@]}"; do
    repo_pkgpaths+=( "$BINREPO_DIR/repo/$(basename "$pkgfile")" )
  done

  repo_db="$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz"
  db_entries=""
  if [[ -f "$repo_db" ]]; then
    db_entries=$(bsdtar -tf "$repo_db" 2>/dev/null || true)
  fi

  if [[ -n "$db_entries" ]]; then
    all_in_db=true
    for pkgfile in "${pkgpaths[@]}"; do
      pkgbase=$(basename "$pkgfile")
      pkgid="${pkgbase%.pkg.tar.zst}"
      pkgid="${pkgid%-x86_64}"
      pkgid="${pkgid%-any}"
      if ! grep -Fxq "${pkgid}/desc" <<<"$db_entries"; then
        all_in_db=false
        break
      fi
    done

    if [[ "$all_in_db" == true ]]; then
      if [[ " ${INSTALL_AFTER_BUILD[*]} " == *" ${pkgdir} "* ]]; then
        if ! install_pkgs_if_present "${repo_pkgpaths[@]}"; then
          echo "Repo packages missing; will rebuild."
          all_in_db=false
        fi
      fi

      if [[ "$all_in_db" == true ]]; then
        echo "Remote repo db already has all package entries; skipping build."
        popd >/dev/null
        echo "::endgroup::"
        continue
      fi
    fi
  fi

  remote_present=true
  for pkgfile in "${pkgpaths[@]}"; do
    pkgbase=$(basename "$pkgfile")
    if git -C "$BINREPO_DIR" cat-file -e "HEAD:repo/$pkgbase" 2>/dev/null; then
      continue
    fi
    remote_present=false
    break
  done

  if [[ "$remote_present" == true ]]; then
    if [[ " ${INSTALL_AFTER_BUILD[*]} " == *" ${pkgdir} "* ]]; then
      if ! install_pkgs_if_present "${repo_pkgpaths[@]}"; then
        echo "Repo packages missing; will rebuild."
        remote_present=false
      fi
    fi

    if [[ "$remote_present" == true ]]; then
      echo "Remote repo already has all package files; skipping build."
      popd >/dev/null
      echo "::endgroup::"
      continue
    fi
  fi

  missing=false
  for pkgfile in "${pkgpaths[@]}"; do
    if [[ ! -f "$pkgfile" ]]; then
      missing=true
      break
    fi
  done

  if [[ "$missing" == false ]]; then
    if [[ " ${INSTALL_AFTER_BUILD[*]} " == *" ${pkgdir} "* ]]; then
      install_pkgs_if_present "${pkgpaths[@]}"
    fi
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
  makepkg -sC -f --noconfirm --skippgpcheck

  mapfile -t built_pkgs < <(find "$PKGDEST" -maxdepth 1 -type f -name '*.pkg.tar.zst' -newer "$build_marker" 2>/dev/null || true)
  rm -f "$build_marker"

  if [[ ${#built_pkgs[@]} -eq 0 ]]; then
    echo "No new packages detected in PKGDEST for ${pkgdir}"
  fi

  popd >/dev/null

  if [[ ${#built_pkgs[@]} -gt 0 ]]; then
    repo_files=()
    repo_pkgs=()
    debug_pkgs=()
    for pkgfile in "${built_pkgs[@]}"; do
      pkgbase=$(basename "$pkgfile")
      if [[ "$pkgbase" == *-debug-*.pkg.tar.zst ]]; then
        debug_pkgs+=("$pkgfile")
      else
        repo_files+=("$pkgbase")
        repo_pkgs+=("$pkgfile")
      fi
    done

    if [[ ${#debug_pkgs[@]} -gt 0 ]]; then
    if [[ " ${INSTALL_AFTER_BUILD[*]} " == *" ${pkgdir} "* ]] && [[ ${#repo_pkgs[@]} -gt 0 ]]; then
      install_pkgs_if_present "${repo_pkgs[@]}"
    fi

      echo "Removing debug packages to keep artifacts under GitHub limits."
      rm -f "${debug_pkgs[@]}"
    fi

    if [[ ${#repo_files[@]} -gt 0 ]]; then
      missing_repo_files=()
      for pkgbase in "${repo_files[@]}"; do
        if [[ ! -f "$BINREPO_DIR/repo/$pkgbase" ]]; then
          missing_repo_files+=("$pkgbase")
        fi
      done
      if [[ ${#missing_repo_files[@]} -gt 0 ]]; then
        echo "Expected package files missing in repo: ${missing_repo_files[*]}"
        exit 1
      fi

      repo_pkgpaths=()
  for pkgfile in "${pkgpaths[@]}"; do
    repo_pkgpaths+=( "$BINREPO_DIR/repo/$(basename "$pkgfile")" )
  done

  repo_db="$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz"
      repo_files_db="$BINREPO_DIR/repo/${REPO_NAME}.files.tar.gz"
      db_entries=""
      if [[ -f "$repo_db" ]]; then
        db_entries=$(bsdtar -tf "$repo_db" 2>/dev/null || true)
      fi

      new_repo_files=()
      for pkgbase in "${repo_files[@]}"; do
        if [[ -n "$db_entries" ]]; then
          pkgid="${pkgbase%.pkg.tar.zst}"
          pkgid="${pkgid%-x86_64}"
          pkgid="${pkgid%-any}"
          if grep -Fxq "${pkgid}/desc" <<<"$db_entries"; then
            echo "Repo DB already has ${pkgid}; skipping repo-add for it."
            continue
          fi
        fi
        new_repo_files+=("$pkgbase")
      done

      if [[ ${#new_repo_files[@]} -gt 0 ]]; then
        if [[ "$PUSH_EACH" == "1" ]]; then
          if ! git -C "$BINREPO_DIR" pull --rebase origin main; then
            echo "Failed to update binrepo before repo-add."
            exit 1
          fi
        fi

        if ! (cd "$BINREPO_DIR/repo" && repo-add -R "${REPO_NAME}.db.tar.gz" "${new_repo_files[@]}"); then
          echo "repo-add failed; rebuilding database from all package files."
          rm -f "$repo_db" "$repo_files_db"
          (cd "$BINREPO_DIR/repo" && repo-add -R "${REPO_NAME}.db.tar.gz" *.pkg.tar.zst)
        fi
        rm -f "$BINREPO_DIR/repo/${REPO_NAME}.db" "$BINREPO_DIR/repo/${REPO_NAME}.files"
        cp -f "$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.db"
        cp -f "$BINREPO_DIR/repo/${REPO_NAME}.files.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.files"
        repo_updated=1
      else
        echo "Repo DB already contains entries; skipping repo-add."
      fi

      if [[ "$PUSH_EACH" == "1" ]]; then
        git -C "$BINREPO_DIR" add repo
        for pkgbase in "${repo_files[@]}"; do
          git -C "$BINREPO_DIR" add -f "repo/$pkgbase"
        done
        if ! git -C "$BINREPO_DIR" diff --cached --quiet; then
          git -C "$BINREPO_DIR" commit -m "Update ${pkgdir} $(date -u +%Y-%m-%d)"
          for attempt in 1 2 3; do
            if git -C "$BINREPO_DIR" pull --rebase origin main; then
              if git -C "$BINREPO_DIR" push; then
                break
              fi
            else
              git -C "$BINREPO_DIR" rebase --abort >/dev/null 2>&1 || true
            fi
            if [[ $attempt -eq 3 ]]; then
              echo "Push failed after retries."
              exit 1
            fi
            sleep 2
          done
        fi
      fi
    else
      echo "Only debug packages built; skipping repo-add."
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
  repo_pkgpaths=()
  for pkgfile in "${pkgpaths[@]}"; do
    repo_pkgpaths+=( "$BINREPO_DIR/repo/$(basename "$pkgfile")" )
  done

  repo_db="$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz"
  if [[ -f "$repo_db" ]]; then
    echo "Repo DB already present; skip rebuild."
  elif ls "$BINREPO_DIR/repo"/*.pkg.tar.zst >/dev/null 2>&1; then
    (cd "$BINREPO_DIR/repo" && repo-add -R "${REPO_NAME}.db.tar.gz" *.pkg.tar.zst)
    rm -f "$BINREPO_DIR/repo/${REPO_NAME}.db" "$BINREPO_DIR/repo/${REPO_NAME}.files"
    cp -f "$BINREPO_DIR/repo/${REPO_NAME}.db.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.db"
    cp -f "$BINREPO_DIR/repo/${REPO_NAME}.files.tar.gz" "$BINREPO_DIR/repo/${REPO_NAME}.files"
  else
    echo "No packages found; skip repo-add."
  fi
fi
