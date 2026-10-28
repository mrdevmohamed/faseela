#!/usr/bin/env bash
# bootstrap/umount-chroot.sh — unmount the virtual filesystems that stage1.sh
# bind-mounted into the target (run after stage2/stage3, or after a failed run).
#
# Usage: sudo ./umount-chroot.sh /mnt/mydistro
set -euo pipefail

LFS="${1:?usage: umount-chroot.sh /mnt/mydistro}"
[[ $EUID -eq 0 ]] || { echo "umount-chroot: must run as root"; exit 1; }
[[ "$(realpath -m "$LFS")" != "/" ]] || { echo "umount-chroot: refusing /"; exit 1; }

# try every mountpoint even when one refuses to unmount — aborting on the
# first failure would leave the rest mounted while callers believe teardown
# happened (mirrors ensure-chroot-mounts.sh, which verifies on the mount side)
failed=0
for m in dev/pts dev proc sys run; do
    if mountpoint -q "$LFS/$m"; then
        if ! umount -v "$LFS/$m" 2>/dev/null && ! umount -lv "$LFS/$m" 2>/dev/null; then
            echo "umount-chroot: could not unmount $LFS/$m" >&2
            failed=1
        fi
    fi
done
# verify instead of assuming: a failed lazy unmount above can still resolve
for m in dev/pts dev proc sys run; do
    if mountpoint -q "$LFS/$m" 2>/dev/null; then
        echo "umount-chroot: still mounted: $LFS/$m" >&2
        failed=1
    fi
done
(( failed )) && exit 1
echo "umount-chroot: done"
