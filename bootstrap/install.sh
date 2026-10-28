#!/usr/bin/env bash
# bootstrap/install.sh — disk installer, run INSIDE the live system (stage 4).
#
# Copies the running live root onto a real disk, installs grub, and produces
# a persistent bootable system:
#
#   1. partition the target (GPT+ESP on UEFI, MBR on BIOS)
#   2. mkfs (ext4 root, vfat ESP) and mount under $MNT
#   3. rsync the live root (squashfs+overlay) onto the target
#   4. kernel + initramfs from the boot media (/cdrom) into /boot
#   5. /etc/fstab from real UUIDs
#   6. grub-install (BIOS: MBR / UEFI: removable ESP) + static grub.cfg
#      passing root=UUID=... so the initramfs boots straight off disk
#   7. hostname + root password (interactive chroot)
#   8. package cache (/var/cache/dpm) — kept on the installed system so
#      `dpm rollback <pkg>` and offline reinstalls work there too
#
# Env overrides (mainly for testing):
#   MNT      mountpoint prefix    (default /mnt)
#   FW_FORCE bios|uefi            skip firmware autodetection
#   DPM_PKG_CACHE_SRC             package cache source (default /var/cache/dpm)
#   DPM_INSTALL_DRYRUN=1          log mutating commands instead of running them
#
# Usage:
#   sudo install.sh /dev/vda [--hostname myhost] [--yes] [--no-pkg-cache]
set -euo pipefail

PROG=install.sh
MNT="${MNT:-/mnt}"
DISK=""
HOSTNAME_ARG=""
ASSUME_YES=0
PKG_CACHE=1
DRYRUN="${DPM_INSTALL_DRYRUN:-0}"

log()  { echo "install: $*"; }
die()  { echo "install: error: $*" >&2; exit 1; }
run() {
    if [ "$DRYRUN" = 1 ]; then
        echo "+ $*"
    else
        "$@"
    fi
}

# unmount the target if anything fails after it was mounted
MOUNTED=0
cleanup() {
    local rc=$?
    if [ "$MOUNTED" = 1 ] && [ "$DRYRUN" != 1 ]; then
        sync
        umount -R "$MNT" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT

# --- argument parsing -------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --hostname) HOSTNAME_ARG="${2:?--hostname needs a value}"; shift 2 ;;
        --yes)      ASSUME_YES=1; shift ;;
        --no-pkg-cache) PKG_CACHE=0; shift ;;
        -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
        -*)         die "unknown option $1" ;;
        *)          DISK="$1"; shift ;;
    esac
done

# DPM_INSTALL_TEST=1 relaxes the root + block-device checks for stub-based validation
[ "$(id -u)" = 0 ] || [ "${DPM_INSTALL_TEST:-0}" = 1 ] || die "must run as root (boot the ISO and log in as root)"
[ -n "$DISK" ] || { sed -n '2,20p' "$0"; exit 1; }
[ -b "$DISK" ] || [ "${DPM_INSTALL_TEST:-0}" = 1 ] || die "$DISK is not a block device"

# only whole disks, never partitions
case "$DISK" in
    /dev/nvme*n*p[0-9]*|/dev/mmcblk*p[0-9]*|/dev/loop*p[0-9]*|/dev/sd*[0-9]|/dev/vd*[0-9]|/dev/xvd*[0-9]|/dev/hd*[0-9])
        die "$DISK looks like a partition — give the whole disk (e.g. /dev/vda, /dev/nvme0n1)" ;;
esac

# never touch a disk that is in use — most importantly the boot medium (/cdrom)
# or the disk the running system lives on
if [ "${DPM_INSTALL_TEST:-0}" != 1 ] && \
   awk -v d="$DISK" 'index($1, d) == 1 { found = 1 } END { exit !found }' /proc/mounts; then
    die "$DISK (or one of its partitions) is mounted — is it the live medium or the running system? refusing"
fi

# partition device names: nvme0n1 -> nvme0n1p1, vda -> vda1
case "$DISK" in
    *[0-9]) PART_PREFIX="${DISK}p" ;;
    *)      PART_PREFIX="$DISK" ;;
esac

# hostnames end up in /etc/hosts and sed — keep them boring
if [ -n "$HOSTNAME_ARG" ]; then
    [[ "$HOSTNAME_ARG" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
        || die "invalid hostname: $HOSTNAME_ARG"
fi

for tool in parted partprobe mkfs.ext4 rsync blkid grub-install chroot; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool '$tool' (is $DISK's system the full one?)"
done

# --- firmware mode ----------------------------------------------------------
if [ -n "${FW_FORCE:-}" ]; then
    FW="$FW_FORCE"
elif [ -d /sys/firmware/efi ]; then
    FW=uefi
else
    FW=bios
fi
log "firmware mode: $FW"

# --- final confirmation -----------------------------------------------------
log "ABOUT TO ERASE $DISK and install mydistro on it."
if [ "$ASSUME_YES" != 1 ]; then
    printf 'Type the disk name (%s) to continue: ' "$DISK"
    read -r answer
    [ "$answer" = "$DISK" ] || die "aborted"
fi

# --- 1) partitioning ---------------------------------------------------------
log "partitioning $DISK"
run wipefs -a "$DISK" 2>/dev/null || true
if [ "$FW" = uefi ]; then
    run parted -s "$DISK" mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 esp on \
        mkpart root ext4 513MiB 100%
    PART_ESP="${PART_PREFIX}1"
    PART_ROOT="${PART_PREFIX}2"
else
    run parted -s "$DISK" mklabel msdos \
        mkpart primary ext4 1MiB 100% \
        set 1 boot on
    PART_ROOT="${PART_PREFIX}1"
fi
run partprobe "$DISK"
command -v udevadm >/dev/null 2>&1 && run udevadm settle || sleep 2

# --- 2) filesystems -----------------------------------------------------------
log "creating filesystems"
run mkfs.ext4 -F -q "$PART_ROOT"
if [ "$FW" = uefi ]; then
    command -v mkfs.vfat >/dev/null 2>&1 || die "missing tool 'mkfs.vfat' (dosfstools)"
    run mkfs.vfat -F32 "$PART_ESP"
fi

run mkdir -p "$MNT"
run mount "$PART_ROOT" "$MNT"
MOUNTED=1
[ "$FW" = uefi ] && { run mkdir -p "$MNT/boot/efi"; run mount "$PART_ESP" "$MNT/boot/efi"; }

# --- 3) copy the live root ----------------------------------------------------
log "copying the system (this is the slow part)"
# exclude the actual $MNT prefix, not only /mnt — with a custom MNT inside
# the live tree rsync would otherwise copy the target into itself
run rsync -aHAX --numeric-ids \
    --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/run/* \
    --exclude=/tmp/* --exclude=/media/* --exclude=/cdrom/* \
    --exclude="${MNT%/}" --exclude="${MNT%/}"/* \
    --exclude=/lost+found --exclude=/var/cache/dpm \
    --exclude=/build --exclude=/build3 --exclude=/sources --exclude=/.dpm \
    / "$MNT/"

# mountpoint skeleton must exist on the target even though we excluded
# the contents (base-files normally provides the dirs; be safe anyway)
run mkdir -p "$MNT"/{proc,sys,dev,run,tmp,cdrom,media,mnt,boot,var/cache/dpm}
run chmod 1777 "$MNT/tmp"

# --- 3b) package cache (rollback support) --------------------------------------
# dpm install keeps every installed archive in /var/cache/dpm so
# `dpm rollback <pkg>` can restore the previous version offline. The main
# rsync excludes the cache (it would double the disk usage through the
# non-hardlinked copy) — copy it explicitly, minus the re-downloadable
# remote/ subcache. Opt out with --no-pkg-cache.
CACHE_SRC="${DPM_PKG_CACHE_SRC:-/var/cache/dpm}"
if [ "$PKG_CACHE" = 1 ] && [ -d "$CACHE_SRC" ]; then
    n=$(find "$CACHE_SRC" -maxdepth 1 -name '*.dpm.tar.zst' 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        log "copying the package cache ($n archive(s)) — rollback support"
        run rsync -a --exclude=remote "$CACHE_SRC/" "$MNT/var/cache/dpm/"
    else
        log "note: package cache has no archives — skipping the copy"
    fi
elif [ "$PKG_CACHE" != 1 ]; then
    log "note: package cache copy disabled (--no-pkg-cache) — 'dpm rollback' \
will need a repository"
fi

# --- 4) kernel + initramfs ----------------------------------------------------
# source order: KERNEL_SRC (test hook) > boot media > live /boot
KERNEL=""
INITRD=""
for src in ${KERNEL_SRC:+"$KERNEL_SRC"} /cdrom/boot /boot; do
    [ -z "$KERNEL" ] || break
    k="$(ls "$src"/vmlinuz-* 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$k" ] || continue
    # grub.cfg below always references /boot/initramfs.img, so a kernel
    # without one would give a system that cannot boot
    if [ ! -f "$src/initramfs.img" ]; then
        log "warning: $src has a kernel but no initramfs.img — skipping"
        continue
    fi
    KERNEL="$k"
    INITRD="$src/initramfs.img"
done
[ -n "$KERNEL" ] || die "no kernel with initramfs.img found in /cdrom/boot or /boot"
log "installing kernel $(basename "$KERNEL")"
run mkdir -p "$MNT/boot"
run cp "$KERNEL" "$MNT/boot/$(basename "$KERNEL")"
run cp "$INITRD" "$MNT/boot/initramfs.img"

# --- 5) fstab -------------------------------------------------------------------
ROOT_UUID="$(blkid -s UUID -o value "$PART_ROOT" | head -1)"
[ -n "$ROOT_UUID" ] || die "could not read UUID of $PART_ROOT"
log "root UUID: $ROOT_UUID"
{
    echo "# generated by mydistro install.sh"
    echo "UUID=$ROOT_UUID  /      ext4  defaults                0 1"
    if [ "$FW" = uefi ]; then
        ESP_UUID="$(blkid -s UUID -o value "$PART_ESP" | head -1)"
        echo "UUID=$ESP_UUID  /boot/efi vfat defaults            0 2"
    fi
    # /run must be tmpfs (udevd, runit service state, pidfiles); without these
    # rows runtime state would persist on disk across boots
    echo "tmpfs            /run   tmpfs defaults,mode=0755,nosuid,nodev 0 0"
    echo "tmpfs            /tmp   tmpfs defaults,nosuid            0 0"
} > "$MNT/etc/fstab"

# --- 6) bootloader ---------------------------------------------------------------
log "installing grub ($FW)"
if [ "$FW" = uefi ]; then
    run grub-install --target=x86_64-efi \
        --efi-directory="$MNT/boot/efi" --boot-directory="$MNT/boot" \
        --removable --no-nvram
else
    run grub-install --target=i386-pc --boot-directory="$MNT/boot" "$DISK"
fi

KNAME="$(basename "$KERNEL")"
mkdir -p "$MNT/boot/grub"
cat > "$MNT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=3

menuentry "mydistro" {
    linux /boot/$KNAME root=UUID=$ROOT_UUID quiet
    initrd /boot/initramfs.img
}

menuentry "mydistro (verbose)" {
    linux /boot/$KNAME root=UUID=$ROOT_UUID loglevel=7
    initrd /boot/initramfs.img
}
EOF

# --- 7) identity ------------------------------------------------------------------
if [ -n "$HOSTNAME_ARG" ]; then
    echo "$HOSTNAME_ARG" > "$MNT/etc/hostname"
    # make sure the hostname resolves: extend the 127.0.0.1 line when the
    # stock hosts file is there, otherwise append a fresh entry
    if grep -qE '^127\.0\.0\.1[[:space:]]' "$MNT/etc/hosts" 2>/dev/null; then
        sed -i -E "s/^(127\.0\.0\.1[[:space:]]+localhost)/\1 $HOSTNAME_ARG/" "$MNT/etc/hosts"
    else
        echo "127.0.0.1 localhost $HOSTNAME_ARG" >> "$MNT/etc/hosts"
    fi
fi
log "setting the root password (chroot)"
run chroot "$MNT" /usr/bin/passwd root

# --- teardown -----------------------------------------------------------------------
run sync
run umount -R "$MNT" 2>/dev/null || run umount "$MNT"
MOUNTED=0

log "done — $DISK now boots mydistro"
log "reboot (without the install media) and log in as root"
