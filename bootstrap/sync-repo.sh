#!/usr/bin/env bash
# bootstrap/sync-repo.sh — copy the build-relevant parts of the repo into the
# chroot at <TARGET>/mydistro (used by stage1/2/3).
#
# Replaces the old `cp -a nawa recipes profiles bootstrap $LFS/mydistro/`:
# that copy carried ~1 GB of seed tarball (bootstrap/seed/seed.tar.zst), any
# multi-GB bootstrap/seed/seed-root scratch dir and the host's nawa/target
# cargo output into the build root on EVERY stage — with the documented
# ~10 GB disk budget that can starve the build, and a host cargo target/
# would make cargo reuse host-built fingerprints instead of compiling inside
# the chroot.
#
# Excluded (relative to the repo root):
#   nawa/target            host cargo output (the chroot builds its own)
#   bootstrap/seed           seed tarball + seed-root scratch — never used
#                            inside the chroot (stage1 unpacks the tarball on
#                            the host side before entering)
#   srccache, out            host source cache / ISO outputs
#   bootstrap/.initramfs-build  initramfs.sh scratch (historical, when it
#                            still built under $PWD)
#
# Like `cp -a`, tar extraction MERGES: files already present in the chroot
# that no longer exist on the host are kept (stage2 relies on that for the
# in-chroot nawa/target build output).
#
# Usage: sync-repo.sh TARGET
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LFS="${1:?usage: sync-repo.sh TARGET}"
[[ -d $REPO/nawa && -d $REPO/recipes ]] || {
    echo "sync-repo: $REPO does not look like the repo root (no nawa/ or recipes/)" >&2
    exit 1
}

[[ -f $REPO/nawa/Cargo.toml ]] || {
    echo "sync-repo: $REPO/nawa is empty — initialise the nawa submodule:" >&2
    echo "sync-repo:   git submodule update --init" >&2
    exit 1
}

mkdir -p "$LFS/mydistro"
# shellcheck disable=SC2016  # excludes are tar patterns, not shell globs
tar -C "$REPO" -cf - \
    --exclude='nawa/target' \
    --exclude='bootstrap/seed' \
    --exclude='bootstrap/.initramfs-build' \
    --exclude='srccache' \
    --exclude='out' \
    nawa recipes profiles bootstrap |
    tar -C "$LFS/mydistro" -xf -
