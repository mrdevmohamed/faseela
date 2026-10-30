#!/usr/bin/env bash
# bootstrap/mkrootfs-min.sh — pack a SMALL rootfs: base-devel + nawa (+ a few
# network tools), no kernel, no rust, no GUI, no desktop/extra packages.
#
# Two rootfs tarballs exist on purpose:
#   mkrootfs.sh      the whole system incl. rust — the SEED of the next build
#                    (build-all.sh --seed-rootfs)
#   mkrootfs-min.sh  this one — the build ENVIRONMENT: small enough to be
#                    imported as a container image or unpacked on a CI runner
#                    in seconds, with everything `nawa build` needs to build
#                    packages EXCEPT rust (packages that need rust, i.e. nawa
#                    itself, are built from the big rootfs).
#
# It is assembled from the ARCHIVES the finished build left in the build root
# (build3/out, build/out, var/cache/nawa), so it needs a completed stage 2/3
# target, but nothing is rebuilt. The closure of [depends].run is computed by
# scripts/rootfs-closure.py; the install itself runs inside the target
# (mkrootfs-min-inner.sh) because nawa links against the distro's own libc.
# The tree is then packed by mkrootfs.sh, so the sanity checks, the layout
# and the .sha256/.packages sidecars are identical to the big rootfs.
#
# Usage:  sudo ./mkrootfs-min.sh /mnt/mydistro out/mydistro-x86_64-rootfs-min.tar.zst
# Env:    ROOTFS_MIN_PACKAGES  what to install (default below; the closure of
#                              their runtime dependencies is added)
#         ROOTFS_MIN_DIR       scratch dir name inside TARGET (default sysroot-min)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
TARGET="${1:?usage: mkrootfs-min.sh TARGET out-rootfs-min.tar.zst}"
OUT="${2:?usage: mkrootfs-min.sh TARGET out-rootfs-min.tar.zst}"
PACKAGES="${ROOTFS_MIN_PACKAGES:-base-devel nawa git curl ca-certificates}"
MIN_DIR="${ROOTFS_MIN_DIR:-sysroot-min}"

[[ $EUID -eq 0 ]] || { echo "mkrootfs-min: must run as root" >&2; exit 1; }
[[ -d $TARGET && -x $TARGET/usr/bin/nawa ]] \
    || { echo "mkrootfs-min: $TARGET is not a finished build root (no usr/bin/nawa)" >&2; exit 1; }
[[ $MIN_DIR =~ ^[A-Za-z0-9._-]+$ ]] \
    || { echo "mkrootfs-min: ROOTFS_MIN_DIR must be a plain directory name" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "mkrootfs-min: missing host tool python3 (>= 3.11)" >&2; exit 1; }

# 1) closure, computed on the host from the recipes of THIS checkout
# shellcheck disable=SC2086  # PACKAGES is a word list on purpose
python3 "$REPO/scripts/rootfs-closure.py" "$REPO/recipes" $PACKAGES > "$TARGET/mydistro-min.order"
echo "== rootfs-min: $(wc -l < "$TARGET/mydistro-min.order") packages: $(tr '\n' ' ' < "$TARGET/mydistro-min.order")"

# 2) the inner script reads recipes/scripts from the chroot copy of the repo
bash "$HERE/sync-repo.sh" "$TARGET"
bash "$HERE/ensure-chroot-mounts.sh" "$TARGET"

rm -rf "${TARGET:?}/$MIN_DIR"
mkdir -p "$TARGET/$MIN_DIR"
bash "$HERE/enter-root.sh" "$TARGET" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-dumb}" FINAL_ROOT="/$MIN_DIR" \
    bash /mydistro/bootstrap/mkrootfs-min-inner.sh

# 3) pack with the same tool (and the same sanity checks) as the big rootfs
bash "$HERE/mkrootfs.sh" "$TARGET/$MIN_DIR" "$OUT"

rm -rf "${TARGET:?}/$MIN_DIR" "$TARGET/mydistro-min.order"
echo "== rootfs-min: $(du -h "$OUT" | cut -f1)  $OUT"
