# Build Factory PKGBUILD Backup

This private repository backs up PKGBUILD and patch files from the local build factory workspace. It also drives GitHub Actions builds that publish binary packages into the companion repo.

Scope
- Included: PKGBUILD and *.patch/*.diff files, with original directory layout preserved.
- Excluded:
  - kernel-universe (custom kernel build)
  - browser/ungoogled-chromium
  - game/proton-god/wine-tkg-git

CI / Actions
- Workflow: .github/workflows/build-small.yml
- Build script: ci/build-small.sh
- Package list: ci/packages-small.txt
- Binary repo target: Neycrol/misaka-treasure-chest (repo/)

Secrets
- BINREPO_TOKEN: PAT with contents:write to push to Neycrol/misaka-treasure-chest.
- GOD_GCC_TOKEN: optional, used to download the GCC toolchain release (defaults to github.token).
- GOD_GCC_URL / GOD_GCC_SHA256: optional override for the GCC toolchain asset.

CPU tuning
- ci/cpu-target.conf sets CPU_MARCH and CPU_MTUNE.
- build-small.sh replaces -march=native/-mtune=native and sets RUSTFLAGS target-cpu accordingly.

Behavior notes
- Debug packages are removed automatically to stay under GitHub file size limits.
- PUSH_EACH=1 pushes repo updates after each package to reduce disk usage.
- CLEAN_AFTER_BUILD/CLEAN_SRCDEST/CLEAN_PACMAN control cleanup between packages.

glibc note
- CI intentionally omits the gd makedepends to avoid linking memusagestat against libheif/libstdc++.
- If you need memusagestat, build locally with gd installed.

codex-git note
- tools/codex-git is built with O3/native and ThinLTO by default.
- Optional envs in PKGBUILD: CODEX_PGO_GENERATE/CODEX_PGO_USE/CODEX_MLGO_MODEL/CODEX_CSSPGO_PROFILE/CODEX_RUST_LTO/CODEX_BOLT_PROFILE.

Notes
- bcachefs-tools-git includes FUSE enable patch and DKMS cleanup (tools-only).
- Some src/PrismLauncher files were uploaded earlier and are redundant (PKGBUILD fetches them). Remove them if you want this repo to be tools/patches only.
