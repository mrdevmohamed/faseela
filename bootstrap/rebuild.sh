#!/usr/bin/env bash
# bootstrap/rebuild.sh — INCREMENTAL rebuild of selected recipes.
#
# build-all.sh fingerprints the whole recipe tree, so editing ONE recipe
# invalidates stage 2, stage 3 (toolchain / world rebuild — hours) and the ISO.
# This script is the fast path for iterating on a few recipes in an existing
# build root: it rebuilds + reinstalls ONLY the packages you name (into the
# build root and the clean final root), and optionally repacks the ISO.
# It touches no stamps — the next full build-all.sh still treats the recipe
# tree as changed, which is the right thing for a release build.
#
# Usage:
#   sudo ./rebuild.sh [--iso OUT.iso] TARGET pkg [pkg...]
# Examples:
#   sudo ./rebuild.sh --iso out/test.iso /mnt/faseela runit-services shadow
#
# Dependents are not rebuilt (e.g. after changing a library, name the
# programs linked against it too). Env: NAWA_JOBS, SINGLE_ROOT=1 (legacy
# layout), STAGE2_ISOLATION (none|env|sandbox, default none), VOL_ID,
# SQUASH_COMP.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "usage: rebuild.sh [--iso OUT.iso] TARGET pkg [pkg...]" >&2; exit 2; }

ISO_OUT=""
if [[ ${1:-} == --iso ]]; then
    [[ $# -ge 2 ]] || usage
    ISO_OUT="$2"; shift 2
fi
[[ $# -ge 2 ]] || usage
LFS="$1"; shift
PKGS="$*"

[[ $EUID -eq 0 ]] || { echo "rebuild: must run as root"; exit 1; }
[[ -x "$LFS/usr/bin/env" && -x "$LFS/usr/bin/bash" ]] || {
    echo "rebuild: $LFS is not a built root — run build-all.sh first" >&2; exit 1; }
[[ -x "$LFS/usr/bin/nawa" ]] || { echo "rebuild: no nawa in $LFS — stage 2 never ran" >&2; exit 1; }

# fresh copy of the repo + chroot mounts (same as stage 2)
bash "$HERE/sync-repo.sh" "$LFS"
find "$LFS/faseela/nawa/src" -type f -exec touch -- {} +
touch -- "$LFS/faseela/nawa/Cargo.toml" 2>/dev/null || true
bash "$HERE/ensure-chroot-mounts.sh" "$LFS"

if [[ ${SINGLE_ROOT:-0} == 1 ]]; then
    FINAL_ROOT=""; FINAL_HOST="$LFS"
else
    FINAL_ROOT="${FINAL_ROOT:-/sysroot}"; FINAL_HOST="$LFS$FINAL_ROOT"
    mkdir -p "$FINAL_HOST"
fi

echo "== rebuild: $PKGS"
bash "$HERE/enter-root.sh" "$LFS" /usr/bin/env -i \
    HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM="${TERM:-dumb}" NAWA_JOBS="${NAWA_JOBS:-$(nproc 2>/dev/null || echo 4)}" \
    WITH_GUI="${WITH_GUI:-0}" STAGE_SKIP="${STAGE_SKIP:-}" FINAL_ROOT="$FINAL_ROOT" \
    STAGE2_ISOLATION="${STAGE2_ISOLATION:-none}" STAGE2_REBUILD="$PKGS" \
    bash -c 'if [ -r /opt/seed/env.sh ]; then . /opt/seed/env.sh; fi; bash /faseela/bootstrap/stage2-inner.sh'

# the squashfs must never contain the chroot's /proc /dev /sys
bash "$HERE/umount-chroot.sh" "$LFS" || true

if [[ -n $ISO_OUT ]]; then
    echo "== rebuild: repacking the ISO -> $ISO_OUT"
    bash "$HERE/mkiso.sh" "$FINAL_HOST" "$ISO_OUT"
fi
echo "== rebuild: done"
