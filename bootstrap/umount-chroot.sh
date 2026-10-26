#!/usr/bin/env bash
# bootstrap/umount-chroot.sh — unmount the virtual filesystems that stage1.sh
# bind-mounted into the target (run after stage2/stage3, or after a failed run).
#
# Usage: sudo ./umount-chroot.sh /mnt/mydistro
set -euo pipefail

LFS="${1:?usage: umount-chroot.sh /mnt/mydistro}"
[[ $EUID -eq 0 ]] || { echo "umount-chroot: must run as root"; exit 1; }
[[ "$(realpath -m "$LFS")" != "/" ]] || { echo "umount-chroot: refusing /"; exit 1; }

for m in dev/pts dev proc sys run; do
    if mountpoint -q "$LFS/$m"; then
        umount -v "$LFS/$m" || umount -lv "$LFS/$m"
    fi
done
echo "umount-chroot: done"
