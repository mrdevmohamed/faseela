#!/usr/bin/env bash
# bootstrap/stage2.sh — STAGE 2: build & install the core system with DPM.
#
# Runs inside the chroot (after stage1). Builds DPM itself first (with the
# seed's rustc), installs it, then walks the toolchain recipes in
# dependency order and builds + installs every one of them.
#
# Usage (from the host): sudo ./stage2.sh /mnt/mydistro
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LFS="${1:?usage: stage2.sh /mnt/mydistro}"

[[ $EUID -eq 0 ]] || { echo "stage2: must run as root"; exit 1; }

# refresh the repo copy inside the chroot: stage1 copied it once, so edits made
# on the host since then would otherwise never reach the chroot. cp -a merges,
# so build output already in the chroot (pkgmgr/target) is kept.
REPO="$(dirname "$HERE")"
mkdir -p "$LFS/mydistro"
cp -a "$REPO/pkgmgr" "$REPO/recipes" "$REPO/profiles" "$REPO/bootstrap" "$LFS/mydistro/"

# kept merge output means cargo fingerprints can go stale wrong: cp -a restores
# the host's (often older) source mtimes, so after an in-chroot source edit is
# overwritten cargo considers its existing target up to date and relinks a
# binary built from NO-LONGER-EXISTING sources (observed: a `--no-same-owner`
# tar argv from a discarded patch, which GNU tar then mis-parsed as the
# archive name). Re-stamping the copy's dpm sources beats every cached
# artifact mtime, so cargo genuinely recompiles the crate on each stage2 run;
# dependencies stay cached, so this costs seconds.
find "$LFS/mydistro/pkgmgr/src" -type f -exec touch -- {} +
touch -- "$LFS/mydistro/pkgmgr/Cargo.toml" 2>/dev/null


[[ -x "$LFS/usr/bin/env" && -x "$LFS/usr/bin/bash" ]] || {
    echo "stage2: $LFS has no usable seed root (/usr/bin/env or bash missing)." >&2
    echo "stage2: stage 1 is recorded as done but the target was emptied or never unpacked;" >&2
    echo "stage2: re-run it with:  build-all.sh --from-stage 1 $LFS   (or --fresh)" >&2
    exit 1; }

# self-heal: the stage-1 bind mounts live in the kernel and die on reboot /
# umount-chroot.sh, while the stage1.done stamp survives on disk.  Without
# this, enter-root pivots into a /proc-less chroot and every rustup proxy
# fails with "no /proc/self/exe available".  Idempotent + loud on failure.
bash "$HERE/ensure-chroot-mounts.sh" "$LFS"

# two-root layout: the clean final root lives INSIDE the build root at
# $LFS/sysroot (== /sysroot in the chroot). SINGLE_ROOT=1 = legacy behaviour.
if [[ "${SINGLE_ROOT:-0}" == "1" ]]; then
    FINAL_ROOT=""
else
    FINAL_ROOT="${FINAL_ROOT:-/sysroot}"
    [[ $FINAL_ROOT == /* && $FINAL_ROOT != / ]] || { echo "stage2: FINAL_ROOT must be an absolute path other than /" >&2; exit 1; }
    mkdir -p "$LFS$FINAL_ROOT"
fi

bash "$HERE/enter-root.sh" "$LFS" /usr/bin/env -i \
    HOME=/root TERM="$TERM" DPM_JOBS="${DPM_JOBS:-4}" WITH_GUI="${WITH_GUI:-0}" \
    FINAL_ROOT="$FINAL_ROOT" \
    STAGE2_ISOLATION="${STAGE2_ISOLATION:-none}" \
    bash -c '. /opt/seed/env.sh && bash /mydistro/bootstrap/stage2-inner.sh'

echo "== stage2: core system installed"
