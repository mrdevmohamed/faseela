#!/usr/bin/env bash
# bootstrap/sync-repo.sh — copy the build-relevant parts of the repo into the
# chroot at <TARGET>/faseela (used by stage1/2/3).
#
# nawa itself lives in its own repository: fetch-nawa.sh unpacks the pinned
# commit into $REPO/nawa first (see bootstrap/fetch-nawa.sh).
#
# Replaces the old `cp -a nawa recipes profiles bootstrap $LFS/faseela/`:
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

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LFS="${1:?usage: sync-repo.sh TARGET}"
# the recipes live in faseela-repo: make sure $REPO/recipes holds them (a no-op
# once fetched, see fetch-recipes.sh)
bash "$HERE/fetch-recipes.sh"
[[ -d $REPO/recipes && -d $REPO/bootstrap ]] || {
    echo "sync-repo: $REPO does not look like the repo root (no recipes/ or bootstrap/)" >&2
    exit 1
}
# nawa is not part of this repository: unpack the commit pinned in
# recipes/base/nawa/recipe.toml (faseela-repo) into $REPO/nawa (no-op when
# already there)
bash "$HERE/fetch-nawa.sh"
[[ -d $REPO/nawa ]] || { echo "sync-repo: $REPO/nawa is missing after fetch-nawa" >&2; exit 1; }

mkdir -p "$LFS/faseela"
# .recipes-rev says which faseela-repo commit the recipes are (final-root.sh
# records it); it is absent when recipes/ is somebody's own copy
stamp=()
[[ -f $REPO/.recipes-rev ]] && stamp=(.recipes-rev)
# shellcheck disable=SC2016  # excludes are tar patterns, not shell globs
tar -C "$REPO" -cf - \
    --exclude='nawa/target' \
    --exclude='bootstrap/seed' \
    --exclude='bootstrap/.initramfs-build' \
    --exclude='srccache' \
    --exclude='out' \
    nawa recipes profiles bootstrap "${stamp[@]}" |
    tar -C "$LFS/faseela" -xf -
# compat: the checkout used to live at /mydistro inside the chroot, and
# faseela-repo's package workflow may still call /mydistro/bootstrap/...
# Remove this line once faseela-repo uses /faseela.
ln -sfn faseela "$LFS/mydistro"
