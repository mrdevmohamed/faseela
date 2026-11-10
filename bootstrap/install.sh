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
#   7. hostname, time zone, an optional swap file, an optional normal user
#      (in wheel for doas, plus seat/video/render/input/audio for the GUI) and the
#      root password (interactive chroot)
#   8. package cache (/var/cache/nawa) — kept on the installed system so
#      `nawa rollback <pkg>` and offline reinstalls work there too
#
# On the live ISO this file is /usr/sbin/faseela-install (bootstrap/mkiso.sh
# puts it there). Without a disk argument, on a terminal, it asks everything
# step by step; with a disk argument it is fully scriptable.
#
# Env overrides (mainly for testing):
#   MNT      mountpoint prefix    (default /mnt)
#   FW_FORCE bios|uefi            skip firmware autodetection
#   NAWA_PKG_CACHE_SRC             package cache source (default /var/cache/nawa)
#   NAWA_INSTALL_DRYRUN=1          log mutating commands instead of running them
#
# Usage:
#   faseela-install                          interactive (asks disk, hostname, ...)
#   faseela-install /dev/vda [options]       non-interactive disk, others default
#     --hostname NAME      (default: keep the image's)
#     --timezone ZONE      e.g. Africa/Cairo (default: keep the image's)
#     --user NAME          create a normal user (asks for its password)
#     --swap SIZE|none     swap file, e.g. 2G or 512M (default: none)
#     --yes                do not ask to confirm erasing the disk
#     --no-pkg-cache       do not copy /var/cache/nawa
#     -i, --interactive    ask even when a disk was given
set -euo pipefail

PROG=install.sh
MNT="${MNT:-/mnt}"
DISK=""
HOSTNAME_ARG=""
TZ_ARG=""
USER_ARG=""
SWAP_ARG=""
INTERACTIVE=0
ASSUME_YES=0
PKG_CACHE=1
DRYRUN="${NAWA_INSTALL_DRYRUN:-0}"

log()  { echo "install: $*"; }
die()  { echo "install: error: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# --- input validation (shared by the flags and the interactive questions) ----
# each returns 0 when the value is acceptable; values end up in sed, /etc and
# chroot command lines, so they are kept boring
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
valid_user()     { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$1" != root ]; }
valid_swap()     { [[ "$1" =~ ^(none|[1-9][0-9]*[MG])$ ]]; }
valid_tz() {
    [[ "$1" =~ ^[A-Za-z0-9_+/-]+$ ]] && [[ "$1" != *..* ]] || return 1
    # with tzdata on the live system the zone must exist; without it, accept
    [ ! -d /usr/share/zoneinfo ] || [ -f "/usr/share/zoneinfo/$1" ]
}
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
        --timezone) TZ_ARG="${2:?--timezone needs a value}"; shift 2 ;;
        --user)     USER_ARG="${2:?--user needs a value}"; shift 2 ;;
        --swap)     SWAP_ARG="${2:?--swap needs a value}"; shift 2 ;;
        -i|--interactive) INTERACTIVE=1; shift ;;
        --yes)      ASSUME_YES=1; shift ;;
        --no-pkg-cache) PKG_CACHE=0; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         die "unknown option $1" ;;
        *)          DISK="$1"; shift ;;
    esac
done

# NAWA_INSTALL_TEST=1 relaxes the root + block-device checks for stub-based validation
# no disk and nobody to ask (no terminal): the usage text, and it comes BEFORE the
# root check — reading the usage needs no privileges, and a script that wrongly
# called us without a disk should be told what is missing, not "must be root"
if [ -z "$DISK" ] && [ ! -t 0 ] && [ "${NAWA_INSTALL_TEST:-0}" != 1 ]; then
    usage >&2
    exit 1
fi
[ "$(id -u)" = 0 ] || [ "${NAWA_INSTALL_TEST:-0}" = 1 ] || die "must run as root (boot the ISO and log in as root)"
# --- interactive questions ----------------------------------------------------
ask() {                       # ask "prompt" [default]   -> $ANSWER (default on a bare Enter)
    local ans
    if [ -n "${2:-}" ]; then printf '%s [%s]: ' "$1" "$2"; else printf '%s: ' "$1"; fi
    read -r ans || die "no more input (stdin closed) — nothing was changed"
    ANSWER="${ans:-${2:-}}"
}

ask_valid() {                 # ask_valid VALIDATOR "prompt" default "hint" — asks again until valid or empty
    local check="$1" prompt="$2" def="$3" hint="$4"
    while :; do
        ask "$prompt" "$def"
        if [ -z "$ANSWER" ] || "$check" "$ANSWER"; then return 0; fi
        echo "  $hint"
    done
}

list_disks() {                # name<TAB>size<TAB>model of every whole disk that is not in use
    command -v lsblk >/dev/null 2>&1 || die "lsblk is missing — give the disk on the command line"
    lsblk -dpn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | while read -r name size type model; do
        [ "$type" = disk ] || continue
        # skip disks with a mounted partition: the live medium, the running system
        if [ "${NAWA_INSTALL_TEST:-0}" != 1 ] && \
           awk -v d="$name" 'index($1, d) == 1 { found = 1 } END { exit !found }' /proc/mounts; then
            continue
        fi
        printf '%s\t%s\t%s\n' "$name" "$size" "${model:-unknown model}"
    done
}

choose_disk() {
    local lines n s m i choice
    mapfile -t lines < <(list_disks)
    [ "${#lines[@]}" -gt 0 ] || die "no installable disk found (disks with a mounted partition, like the live medium, are not offered)"
    echo "Disks:"
    for i in "${!lines[@]}"; do
        IFS=$'\t' read -r n s m <<<"${lines[$i]}"
        printf '  %d) %s  %s  %s\n' $((i + 1)) "$n" "$s" "$m"
    done
    while :; do
        ask "Install on which disk? (number or /dev path)" ""
        choice="$ANSWER"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#lines[@]}" ]; then
            DISK="${lines[$((choice - 1))]%%$'\t'*}"
            return 0
        fi
        for i in "${!lines[@]}"; do
            if [ "${lines[$i]%%$'\t'*}" = "$choice" ]; then DISK="$choice"; return 0; fi
        done
        echo "  not one of the listed disks"
    done
}

wizard() {
    echo "faseela installer — nothing is written until the final confirmation."
    echo
    [ -n "$DISK" ] || choose_disk
    ask_valid valid_hostname "Hostname (Enter = keep the image's)" "$HOSTNAME_ARG" \
        "letters, digits, '-' and '.' only"
    HOSTNAME_ARG="$ANSWER"
    ask_valid valid_tz "Time zone, e.g. Africa/Cairo or UTC (Enter = keep the image's)" "$TZ_ARG" \
        "unknown zone — the names are the files under /usr/share/zoneinfo"
    TZ_ARG="$ANSWER"
    ask_valid valid_user "User to create, in group wheel for doas (Enter = root only)" "$USER_ARG" \
        "lowercase letters, digits, '_' and '-'; not root"
    USER_ARG="$ANSWER"
    ask_valid valid_swap "Swap file size, e.g. 2G or 512M (none = no swap)" "${SWAP_ARG:-none}" \
        "use none, or a size like 512M or 2G"
    SWAP_ARG="$ANSWER"
    echo
    echo "Plan:  disk $DISK  (erased)"
    echo "       hostname ${HOSTNAME_ARG:-(unchanged)}, time zone ${TZ_ARG:-(unchanged)}"
    echo "       user ${USER_ARG:-(none — root only)}, swap ${SWAP_ARG:-none}"
    echo
}

if [ -z "$DISK" ] || [ "$INTERACTIVE" = 1 ]; then
    wizard
fi

[ -n "$DISK" ] || { usage >&2; exit 1; }
[ -b "$DISK" ] || [ "${NAWA_INSTALL_TEST:-0}" = 1 ] || die "$DISK is not a block device"

# only whole disks, never partitions
case "$DISK" in
    /dev/nvme*n*p[0-9]*|/dev/mmcblk*p[0-9]*|/dev/loop*p[0-9]*|/dev/sd*[0-9]|/dev/vd*[0-9]|/dev/xvd*[0-9]|/dev/hd*[0-9])
        die "$DISK looks like a partition — give the whole disk (e.g. /dev/vda, /dev/nvme0n1)" ;;
esac

# never touch a disk that is in use — most importantly the boot medium (/cdrom)
# or the disk the running system lives on
if [ "${NAWA_INSTALL_TEST:-0}" != 1 ] && \
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
    valid_hostname "$HOSTNAME_ARG" || die "invalid hostname: $HOSTNAME_ARG"
fi
[ -z "$USER_ARG" ] || valid_user "$USER_ARG" || die "invalid user name: $USER_ARG (lowercase letters, digits, _ and -; not root)"
[ -z "$SWAP_ARG" ] || valid_swap "$SWAP_ARG" || die "invalid swap size: $SWAP_ARG (use none, or a size like 512M or 2G)"
[ -z "$TZ_ARG" ] || valid_tz "$TZ_ARG" || die "unknown time zone: $TZ_ARG (see /usr/share/zoneinfo)"

for tool in parted partprobe mkfs.ext4 rsync blkid grub-install chroot; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool '$tool' (is $DISK's system the full one?)"
done
if [ -n "$SWAP_ARG" ] && [ "$SWAP_ARG" != none ]; then
    for tool in fallocate mkswap; do
        command -v "$tool" >/dev/null 2>&1 || die "missing tool '$tool' (util-linux) — needed for --swap"
    done
fi

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
log "ABOUT TO ERASE $DISK and install faseela on it."
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
run rsync -aHX --numeric-ids \
    --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/run/* \
    --exclude=/tmp/* --exclude=/media/* --exclude=/cdrom/* \
    --exclude="${MNT%/}" --exclude="${MNT%/}"/* \
    --exclude=/lost+found --exclude=/var/cache/nawa \
    --exclude=/build --exclude=/build3 --exclude=/sources --exclude=/.nawa \
    / "$MNT/"

# mountpoint skeleton must exist on the target even though we excluded
# the contents (base-files normally provides the dirs; be safe anyway)
run mkdir -p "$MNT"/{proc,sys,dev,run,tmp,cdrom,media,mnt,boot,var/cache/nawa}
run chmod 1777 "$MNT/tmp"

# --- 3b) package cache (rollback support) --------------------------------------
# nawa install keeps every installed archive in /var/cache/nawa so
# `nawa rollback <pkg>` can restore the previous version offline. The main
# rsync excludes the cache (it would double the disk usage through the
# non-hardlinked copy) — copy it explicitly, minus the re-downloadable
# remote/ subcache. Opt out with --no-pkg-cache.
CACHE_SRC="${NAWA_PKG_CACHE_SRC:-/var/cache/nawa}"
if [ "$PKG_CACHE" = 1 ] && [ -d "$CACHE_SRC" ]; then
    n=$(find "$CACHE_SRC" -maxdepth 1 -name '*.nawa.tar.zst' 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        log "copying the package cache ($n archive(s)) — rollback support"
        run rsync -a --exclude=remote "$CACHE_SRC/" "$MNT/var/cache/nawa/"
    else
        log "note: package cache has no archives — skipping the copy"
    fi
elif [ "$PKG_CACHE" != 1 ]; then
    log "note: package cache copy disabled (--no-pkg-cache) — 'nawa rollback' \
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
    KNAME="$(basename "$k")"
    KVER="${KNAME#vmlinuz-}"
    # Prefer a version-matched image; the live ISO currently also provides
    # the compatibility name initramfs.img.
    if [ -f "$src/initramfs-$KVER.img" ]; then
        INITRD="$src/initramfs-$KVER.img"
    elif [ -f "$src/initramfs.img" ]; then
        INITRD="$src/initramfs.img"
    else
        log "warning: $src has $KNAME but no matching initramfs — skipping"
        continue
    fi
    KERNEL="$k"
done
[ -n "$KERNEL" ] || die "no kernel with initramfs found in /cdrom/boot or /boot"
KNAME="$(basename "$KERNEL")"
KVER="${KNAME#vmlinuz-}"
log "installing kernel $KNAME"
run mkdir -p "$MNT/boot"
run cp "$KERNEL" "$MNT/boot/$KNAME"
run cp "$INITRD" "$MNT/boot/initramfs-$KVER.img"
# The installed GRUB config uses stable aliases. Each kernel hook updates
# these atomically after its versioned kernel/initramfs pair is complete.
run ln -sfn "vmlinuz-$KVER" "$MNT/boot/.vmlinuz.new"
run mv -Tf "$MNT/boot/.vmlinuz.new" "$MNT/boot/vmlinuz"
run ln -sfn "initramfs-$KVER.img" "$MNT/boot/.initramfs.new"
run mv -Tf "$MNT/boot/.initramfs.new" "$MNT/boot/initramfs.img"
# Prefer regenerating against the installed root's modules and firmware. The
# copied ISO image remains a valid fallback if this is an older rootfs that
# predates the saq package (github.com/mrdevmohamed/saq).
if [ -x "$MNT/usr/sbin/saq" ]; then
    log "generating the installed-system initramfs for $KVER"
    if ! run chroot "$MNT" /usr/sbin/saq --kernel "$KVER" --update-default; then
        log "warning: installed-system initramfs generation failed; retaining the validated Live ISO initramfs fallback"
    fi
fi

# --- 4b) swap file --------------------------------------------------------------
# a file on the root filesystem, not a partition: resizable later, and ext4
# (the only root filesystem this installer makes) supports it. fallocate is
# enough for swap on ext4; mkswap writes the signature.
SWAP_ROW=0
if [ -n "$SWAP_ARG" ] && [ "$SWAP_ARG" != none ]; then
    log "creating a $SWAP_ARG swap file"
    run fallocate -l "$SWAP_ARG" "$MNT/swapfile"
    run chmod 600 "$MNT/swapfile"
    run mkswap -q "$MNT/swapfile"
    SWAP_ROW=1
fi

# --- 5) fstab -------------------------------------------------------------------
ROOT_UUID="$(blkid -s UUID -o value "$PART_ROOT" | head -1)"
[ -n "$ROOT_UUID" ] || die "could not read UUID of $PART_ROOT"
log "root UUID: $ROOT_UUID"
{
    echo "# generated by faseela install.sh"
    echo "UUID=$ROOT_UUID  /      ext4  defaults                0 1"
    if [ "$FW" = uefi ]; then
        ESP_UUID="$(blkid -s UUID -o value "$PART_ESP" | head -1)"
        echo "UUID=$ESP_UUID  /boot/efi vfat defaults            0 2"
    fi
    # /run must be tmpfs (udevd, runit service state, pidfiles); without these
    # rows runtime state would persist on disk across boots
    echo "tmpfs            /run   tmpfs defaults,mode=0755,nosuid,nodev 0 0"
    echo "tmpfs            /tmp   tmpfs defaults,nosuid            0 0"
    [ "$SWAP_ROW" != 1 ] || echo "/swapfile        none   swap  defaults                  0 0"
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

# The Faseela boot screen. Optional, like in mkiso.sh: it needs the theme (from the live
# media, or from the faseela-branding package in the installed root) AND a GRUB font.
# grub-install brings the font when the grub package ships one; otherwise it comes from
# the live media, where grub-mkrescue put it. Missing either one keeps the plain menu.
MEDIA_BOOT="${KERNEL_SRC:-/cdrom/boot}"   # the live media's /boot (KERNEL_SRC is the test hook)
THEME_SRC=""
for d in "$MEDIA_BOOT/grub/themes/faseela" "$MNT/usr/share/grub/themes/faseela"; do
    if [ -f "$d/theme.txt" ]; then THEME_SRC="$d"; break; fi
done
FONT_SRC=""
for f in "$MNT/boot/grub/fonts/unicode.pf2" "$MEDIA_BOOT/grub/fonts/unicode.pf2" "$MNT/usr/share/grub/unicode.pf2"; do
    if [ -f "$f" ]; then FONT_SRC="$f"; break; fi
done
GRUB_THEME=0
if [ -n "$THEME_SRC" ] && [ -n "$FONT_SRC" ]; then
    run mkdir -p "$MNT/boot/grub/themes/faseela" "$MNT/boot/grub/fonts"
    run cp -r "$THEME_SRC/." "$MNT/boot/grub/themes/faseela/"
    [ "$FONT_SRC" = "$MNT/boot/grub/fonts/unicode.pf2" ] || run cp "$FONT_SRC" "$MNT/boot/grub/fonts/unicode.pf2"
    GRUB_THEME=1
    log "grub theme: faseela"
else
    log "grub theme: none (theme: ${THEME_SRC:-missing}, font: ${FONT_SRC:-missing}) — keeping the plain boot menu"
fi

: > "$MNT/boot/grub/grub.cfg"
if [ "$GRUB_THEME" = 1 ]; then
    cat >> "$MNT/boot/grub/grub.cfg" <<'GFX'
set menu_color_normal=white/black
set menu_color_highlight=black/yellow
if loadfont ${prefix}/fonts/unicode.pf2; then
    set gfxmode=auto
    insmod all_video
    insmod gfxterm
    insmod gfxmenu
    insmod png
    terminal_output gfxterm
    set theme=${prefix}/themes/faseela/theme.txt
    export theme
fi

GFX
fi
cat >> "$MNT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=3

menuentry "faseela" {
    linux /boot/vmlinuz root=UUID=$ROOT_UUID quiet
    initrd /boot/initramfs.img
}

menuentry "faseela (verbose)" {
    linux /boot/vmlinuz root=UUID=$ROOT_UUID loglevel=7
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

if [ -n "$TZ_ARG" ]; then
    if [ -f "$MNT/usr/share/zoneinfo/$TZ_ARG" ]; then
        log "time zone: $TZ_ARG"
        run ln -sf "/usr/share/zoneinfo/$TZ_ARG" "$MNT/etc/localtime"
    else
        log "warning: $TZ_ARG is not in the installed system's /usr/share/zoneinfo — /etc/localtime left as it was"
    fi
fi

# passwd reads the controlling terminal through /dev/tty. The target's /dev was
# deliberately excluded from rsync, so a plain chroot has no tty or pts devices
# and passwd cannot prompt. Bring the live pseudo-filesystems into the target;
# cleanup's umount -R removes these mounts on success and failure.
log "mounting chroot pseudo-filesystems"
run mount --rbind /dev "$MNT/dev"
run mount --make-rslave "$MNT/dev"
run mount -t proc proc "$MNT/proc"
run mount -t sysfs sysfs "$MNT/sys"

# a normal user: wheel is what /etc/doas.conf allows; seat/video/input/audio are
# what a sway session needs (gui-session creates those groups — only the ones
# that exist on the target are used, useradd refuses unknown groups)
if [ -n "$USER_ARG" ]; then
    GROUPS_CSV=""
    for g in wheel seat video render input audio; do
        if grep -q "^$g:" "$MNT/etc/group" 2>/dev/null; then GROUPS_CSV="${GROUPS_CSV:+$GROUPS_CSV,}$g"; fi
    done
    log "creating user $USER_ARG (groups: ${GROUPS_CSV:-none})"
    run chroot "$MNT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        useradd -m -s /bin/bash ${GROUPS_CSV:+-G "$GROUPS_CSV"} "$USER_ARG"
    log "password for $USER_ARG (chroot)"
    run chroot "$MNT" /usr/bin/passwd "$USER_ARG"
fi

log "setting the root password (chroot)"
run chroot "$MNT" /usr/bin/passwd root

# --- teardown -----------------------------------------------------------------------
run sync
run umount -R "$MNT" 2>/dev/null || run umount "$MNT"
MOUNTED=0

log "done — $DISK now boots faseela"
log "reboot (without the install media) and log in as ${USER_ARG:-root}"
[ -z "$USER_ARG" ] || log "$USER_ARG can use doas (group wheel); for the GUI run start-sway from a text console"
