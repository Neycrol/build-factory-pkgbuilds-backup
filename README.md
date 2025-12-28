# Build Factory PKGBUILD Backup

This private repository backs up PKGBUILD and patch files from the local build factory workspace. It is intended as a handover document and a safety net for AUR maintenance.

Scope
- Included: PKGBUILD and *.patch/*.diff files, with original directory layout preserved.
- Excluded:
  - kernel-universe (custom kernel build)
  - browser/ungoogled-chromium
  - game/proton-god/wine-tkg-git

How to use
- Copy a project directory to a clean build directory.
- Review PKGBUILD and patches, then run makepkg.
- Update this repo by re-exporting the files and pushing changes.

Notes
- bcachefs-tools-git includes FUSE enable patch and DKMS cleanup (tools-only).
