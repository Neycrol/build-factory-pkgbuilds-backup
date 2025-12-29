#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$ROOT_DIR/ci/packages-small.txt}"
BINREPO_DIR="${BINREPO_DIR:-$ROOT_DIR/.binrepo}"
REPO_NAME="${REPO_NAME:-buildfactory}"
CPU_TARGET_FILE="${CPU_TARGET_FILE:-$ROOT_DIR/ci/cpu-target.conf}"

mkdir -p "$BINREPO_DIR/repo" "$BINREPO_DIR/srcdest"

export PKGDEST="$BINREPO_DIR/repo"
export SRCDEST="${SRCDEST:-$BINREPO_DIR/srcdest}"
export GIT_PROGRESS=1

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
