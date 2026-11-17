#!/usr/bin/env bash
# bootstrap/initramfs.sh — build the live-boot initramfs for stage 4.
#
# Produces a minimal initramfs containing:
#   /bin/busybox          static binary (CONFIG_STATIC=y) + applet links
#   /init                 live-boot script: find media -> squashfs -> overlay
#                         -> switch_root into /usr/lib/systemd/systemd (PID 1)
#   /modules/*.ko         storage + HID + filesystem modules copied from the
#                         target root (flat, for the insmod fallback), so the
#                         kernel can reach the CD/USB and mount the live image
#                         regardless of defconfig module-vs-builtin choices
#   /lib/modules/$KVER/   the SAME modules with their full dependency tree
#                         (resolved from the target root's modules.dep) plus
#                         modules.dep itself, so /init can use busybox
#                         modprobe — it loads every dependency automatically,
#                         in the right order, instead of a hand-kept list
#
# The tree is packed with busybox's own cpio+gzip applets: the only host
# requirements are gcc/make (to build static busybox) and the busybox
# tarball itself.
#
# Usage:
#   sudo ./initramfs.sh --root /mnt/faseela --out out/initramfs.img
#     [--src busybox-1.37.0.tar.bz2] [--jobs 4]
#
# Source lookup order: --src, $NAWA_SRCCACHE, <repo>/srccache, download.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRCCACHE="${NAWA_SRCCACHE:-$REPO/srccache}"
BUSYBOX_SHA256="$(sed -n 's/^sha256 *= *"\([0-9a-f]*\)".*/\1/p' "$REPO/recipes/boot/busybox/recipe.toml" | head -1)"
BUSYBOX_URL="$(sed -n 's/^source *= *"\(.*\)".*/\1/p' "$REPO/recipes/boot/busybox/recipe.toml" | head -1)"

ROOT=""
OUT=""
SRC=""
JOBS="${NAWA_JOBS:-4}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root| --out| --src| --jobs)
            [[ $# -ge 2 ]] || { echo "initramfs: $1 needs a value" >&2; exit 1; }
            case "$1" in
                --root) ROOT="$2" ;;
                --out)  OUT="$2"  ;;
                --src)  SRC="$2"  ;;
                --jobs) JOBS="$2" ;;
            esac
            shift 2 ;;
        *) echo "initramfs: unknown option $1" >&2; exit 1 ;;
    esac
done

[[ -n $ROOT ]] || { echo "usage: initramfs.sh --root /mnt/faseela --out initramfs.img"; exit 1; }
[[ -d $ROOT ]] || { echo "initramfs: target root $ROOT missing" >&2; exit 1; }
OUT="${OUT:-initramfs.img}"

# scratch in a private mktemp dir (the old $PWD/.initramfs-build collided
# between concurrent runs and littered the repo when the process was killed)
WORK="$(mktemp -d /tmp/initramfs-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1) obtain the busybox source tarball
# ---------------------------------------------------------------------------
if [[ -z $SRC ]]; then
    for cand in "$SRCCACHE"/busybox-*.tar.* "$HERE"/../srccache/busybox-*.tar.*; do
        [[ -f $cand ]] && { SRC="$cand"; break; }
    done
fi
if [[ -z $SRC ]]; then
    BB_VERSION="$(sed -n 's/^version *= *"\(.*\)".*/\1/p' "$REPO/recipes/boot/busybox/recipe.toml" | head -1)"
    BB_FILE="$(basename "${BUSYBOX_URL//%\{version\}/$BB_VERSION}")"
    # The recipe's URL first, then mirrors of the very same tarball (busybox.net is
    # sometimes unreachable from CI runners: a run once died on four 135 s timeouts).
    # Every candidate is verified against the recipe's sha256 before it is accepted, so
    # a mirror can be wrong or stale but never trusted blindly. Override or extend the
    # list with BUSYBOX_MIRRORS (space separated URLs).
    CANDIDATES=("${BUSYBOX_URL//%\{version\}/$BB_VERSION}")
    # shellcheck disable=SC2206 # a space separated list, on purpose
    CANDIDATES+=(${BUSYBOX_MIRRORS:-"https://sources.buildroot.net/busybox/$BB_FILE" \
        "https://deb.debian.org/debian/pool/main/b/busybox/busybox_$BB_VERSION.orig.tar.bz2"})
    mkdir -p "$SRCCACHE"
    SRC="$SRCCACHE/$BB_FILE"
    got=0
    for url in "${CANDIDATES[@]}"; do
        echo "initramfs: downloading busybox from $url"
        if curl -fL --connect-timeout 20 --max-time 600 --retry 2 --retry-connrefused -o "$SRC.part" "$url" \
            && { [[ -z $BUSYBOX_SHA256 ]] || echo "$BUSYBOX_SHA256  $SRC.part" | sha256sum -c --quiet; }; then
            mv -f "$SRC.part" "$SRC"
            got=1
            break
        fi
        echo "initramfs: $url did not work, trying the next source" >&2
        rm -f "$SRC.part"
    done
    [[ $got == 1 ]] || { echo "initramfs: could not download busybox from any of: ${CANDIDATES[*]}" >&2; echo "initramfs: pass --src busybox-$BB_VERSION.tar.bz2 or put it in $SRCCACHE" >&2; exit 1; }
fi
echo "initramfs: source $SRC"
if [[ -n $BUSYBOX_SHA256 ]]; then
    echo "$BUSYBOX_SHA256  $SRC" | sha256sum -c --quiet || { echo "initramfs: sha256 mismatch for $SRC" >&2; exit 1; }
else
    echo "initramfs: WARNING no sha256 pin found, skipping verification" >&2
fi

# ---------------------------------------------------------------------------
# 2) build static busybox
# ---------------------------------------------------------------------------
BBDIR="$WORK/busybox"
tar -xf "$SRC" -C "$WORK"
mv "$WORK"/busybox-* "$BBDIR"
make -C "$BBDIR" defconfig >/dev/null
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "$BBDIR/.config"
# busybox 1.37 tc applet fails against kernel headers >= 6.8 (TCA_CBQ_*
# removed upstream) — not needed in the initramfs
sed -i 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' "$BBDIR/.config"
echo "initramfs: compiling static busybox (-j$JOBS)"
make -C "$BBDIR" -j"$JOBS" >/dev/null
"$BBDIR/busybox" echo "initramfs: busybox smoke test OK"
if ldd "$BBDIR/busybox" >/dev/null 2>&1; then
    echo "initramfs: WARNING busybox is dynamically linked" >&2
fi

# ---------------------------------------------------------------------------
# 3) assemble the initramfs tree
# ---------------------------------------------------------------------------
TREE="$WORK/tree"
mkdir -p "$TREE/bin" "$TREE/modules" "$TREE/dev" "$TREE/proc" "$TREE/sys" \
         "$TREE/tmp" "$TREE/run" "$TREE/cdrom" "$TREE/iso-host" "$TREE/ro" "$TREE/rw" "$TREE/newroot"
install -m755 "$BBDIR/busybox" "$TREE/bin/busybox"
for applet in sh cat echo mount umount mkdir mknod switch_root insmod modprobe mdev \
              sleep seq ls blkid findfs grep sed cp rm ln dmesg sync uname reboot poweroff \
              chown chmod losetup tail; do
    ln -sf busybox "$TREE/bin/$applet"
done

# Storage + USB/HID controllers + filesystems from the target root.
# `|| true`: with pipefail a missing modules dir makes `ls` fail and the
# assignment would kill the script silently (exit 2) before the warning
# below could run
KVER="$(ls "$ROOT/lib/modules" 2>/dev/null | sort -V | tail -1 || true)"
MODLIST="scsi_mod cdrom sr_mod sd_mod sg ahci ata_piix nvme virtio virtio_ring virtio_pci virtio_blk virtio_scsi usb_common usbcore usb_storage uas xhci_pci ehci_pci uhci_hcd hid usbhid hid_generic iso9660 squashfs overlay loop fat vfat nls_cp437 dm_mod ext4 exfat ntfs3 isofs"
if [[ -z $KVER ]]; then
    echo "initramfs: WARNING no modules in $ROOT/lib/modules — CD/DVD boot may" \
         "need sr_mod built into the kernel" >&2
else
    echo "initramfs: copying storage modules from kernel $KVER"
    KMODDIR="$ROOT/lib/modules/$KVER"
    DEPFILE="$KMODDIR/modules.dep"
    if [[ -f $DEPFILE ]]; then
        # --------------------------------------------------------------
        # dependency-aware staging (modprobe path)
        #   modules.dep lines: "kernel/dir/mod.ko[.xz]: dep1 dep2 ..."
        # resolve each wanted module's dependency closure and copy every
        # .ko with its original layout, plus modules.dep itself
        # --------------------------------------------------------------
        declare -A MODLINE STAGED
        while IFS= read -r line; do
            [[ $line == *:* ]] || continue
            path="${line%%:*}"
            base="$(basename "$path")"
            base="${base%%.ko*}"
            MODLINE["$base"]="$line"
        done < "$DEPFILE"

        stage2() { # module basename
            local name="$1" line path deps dep dname
            [[ -n ${MODLINE["$name"]+x} ]] || return 0
            [[ -n ${STAGED["$name"]+x} ]] && return 0
            STAGED["$name"]=1
            line="${MODLINE["$name"]}"
            path="${line%%:*}"
            deps="${line#*:}"
            for dep in $deps; do
                dname="$(basename "$dep")"
                dname="${dname%%.ko*}"
                stage2 "$dname"
            done
            if [[ -f $KMODDIR/$path ]]; then
                mkdir -p "$TREE/lib/modules/$KVER/$(dirname "$path")"
                cp "$KMODDIR/$path" "$TREE/lib/modules/$KVER/$path"
            fi
        }

        for m in $MODLIST; do stage2 "$m"; done

        # modprobe reads the dep map from /lib/modules/$(uname -r)
        mkdir -p "$TREE/lib/modules/$KVER"
        cp "$DEPFILE" "$TREE/lib/modules/$KVER/modules.dep"
        staged=$(cd "$TREE/lib/modules/$KVER" && find . -name '*.ko*' | wc -l)
        if [[ $staged -gt 0 ]]; then
            echo "initramfs: staged $staged module(s) with dependencies (modprobe)"
        else
            echo "initramfs: WARNING modules.dep resolved nothing — falling back" \
                 "to flat staging" >&2
        fi
    fi

    # flat copy for the insmod fallback (always: keeps booting possible even
    # when the runtime kernel version does not match the staged dep tree)
    copied=0
    for m in $MODLIST; do
        for ext in ko ko.xz ko.zst ko.gz; do
            f="$(find "$KMODDIR" -name "$m.$ext" 2>/dev/null | head -1)"
            if [[ -n ${f:-} && -f $f && ! -e $TREE/modules/$m.$ext ]]; then
                cp "$f" "$TREE/modules/$m.$ext"
                copied=$((copied+1))
                break
            fi
        done
    done
    echo "initramfs: $copied module(s) staged flat (insmod fallback)"
fi

# ---------------------------------------------------------------------------
# 4) the /init script
# ---------------------------------------------------------------------------
cat > "$TREE/init" <<'INIT_EOF'
#!/bin/busybox sh
# faseela live-boot initramfs /init
busybox mkdir -p /bin /dev /proc /sys /tmp /run /cdrom /iso-host /ro /rw /newroot
busybox --install -s /bin
export PATH=/bin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { [ -e /dev/console ] || mknod /dev/console c 5 1; }

echo "faseela initramfs: loading storage/HID/filesystem modules"
# preferred: busybox modprobe against the staged dependency tree — it loads
# every dependency in the right order (anything built-in is simply unknown
# to modprobe and skipped). Fallback: the flat insmod loop.
MODLIST="scsi_mod cdrom sr_mod sd_mod sg ahci ata_piix nvme \
    virtio virtio_ring virtio_pci virtio_blk virtio_scsi \
    usb_common usbcore usb_storage uas \
    xhci_pci ehci_pci uhci_hcd hid usbhid hid_generic \
    iso9660 squashfs overlay loop fat vfat nls_cp437 dm_mod ext4 exfat ntfs3 isofs"
kv="$(uname -r)"
if [ -f "/lib/modules/$kv/modules.dep" ]; then
    for m in $MODLIST; do modprobe "$m" 2>/dev/null; done
else
    [ -d "/lib/modules/$kv" ] || [ -d /lib/modules ] && \
        echo "initramfs: NOTE modules.dep missing for kernel $kv — using insmod"
    for ko in $MODLIST; do
        for ext in ko ko.xz ko.zst ko.gz; do
            [ -f /modules/$ko.$ext ] && insmod /modules/$ko.$ext 2>/dev/null && break
        done
    done
fi

# ---------------------------------------------------------------------------
# disk boot: root= on the kernel cmdline (set by the disk installer's grub)
#   root=UUID=<uuid>  resolved with busybox findfs
#   root=/dev/...     used as-is
# When present we boot straight off the real filesystem; without it we fall
# through to the live-media scan below.
# ---------------------------------------------------------------------------
rootdev=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        root=UUID=*) rootdev="$(findfs "${arg#root=}" 2>/dev/null || true)" ;;
        root=/dev/*) rootdev="${arg#root=}" ;;
    esac
done
if [ -n "$rootdev" ] && mount "$rootdev" /ro 2>/dev/null; then
    echo "initramfs: disk boot from $rootdev"
    mkdir -p /ro/proc /ro/sys /ro/dev /ro/run
    mount --move /proc /ro/proc
    mount --move /sys /ro/sys
    mount --move /dev /ro/dev
    echo "initramfs: switch_root -> systemd"
    export PATH=/bin:/usr/bin:/usr/sbin:/sbin
    exec switch_root /ro /usr/lib/systemd/systemd
fi
[ -z "$rootdev" ] || echo "initramfs: WARNING root=$rootdev not mountable — trying live media"

echo "initramfs: waiting for boot media"
# The media is the device whose filesystem contains /live/rootfs.squashfs
# (mkiso.sh layout). Checking for the file — not just "mountable" — skips the
# EFI system partition that a hybrid ISO written to a USB stick exposes.
#
# Two ways to find it, tried in turn on every pass:
#   1. direct: a block device that IS the ISO filesystem — a burnt CD, a USB stick
#      written with dd, or the device-mapper device Ventoy builds over the ISO file
#      (/dev/mapper/*, /dev/dm-*)
#   2. iso-scan: the ISO is a FILE on some partition (Ventoy's data partition, or any
#      disk booted through GRUB's loopback). Every partition is mounted read-only, the
#      ISO is found there and loop-mounted. `iso-scan/filename=/path.iso` (or
#      `findiso=`) on the kernel command line names the file; without it, the
#      *.iso files up to three directories deep are tried, faseela's first.
SQUASH=/cdrom/live/rootfs.squashfs
isohint=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        iso-scan/filename=*) isohint="${arg#iso-scan/filename=}" ;;
        findiso=*)           isohint="${arg#findiso=}" ;;
    esac
done

# try_iso <file>: loop-mount an ISO image at /cdrom, success only when it holds the live image
try_iso() {
    mount -t iso9660 -o ro,loop "$1" /cdrom 2>/dev/null || return 1
    [ -f "$SQUASH" ] && return 0
    umount /cdrom 2>/dev/null
    return 1
}

# scan_iso_files <dev>: look for a faseela ISO on one partition. On success the partition
# stays mounted at /iso-host (the loop device needs it) and $found names the ISO.
scan_iso_files() {
    mount -o ro "$1" /iso-host 2>/dev/null || return 1
    if [ -n "$isohint" ] && [ -f "/iso-host$isohint" ] && try_iso "/iso-host$isohint"; then
        found="$1:$isohint"; return 0
    fi
    for f in /iso-host/*[Ff]aseela*.iso /iso-host/*/*[Ff]aseela*.iso /iso-host/*/*/*[Ff]aseela*.iso \
             /iso-host/*.iso /iso-host/*/*.iso /iso-host/*/*/*.iso; do
        [ -f "$f" ] || continue
        if try_iso "$f"; then found="$1:${f#/iso-host}"; return 0; fi
    done
    umount /iso-host 2>/dev/null
    return 1
}

found=""
for i in $(seq 1 15); do
    for dev in /dev/sr[0-9]* /dev/sd[a-z] /dev/sd[a-z]*[0-9] /dev/vd[a-z] /dev/vd[a-z]*[0-9] \
               /dev/nvme*n*p[0-9] /dev/nvme*n[0-9] /dev/mmcblk*p[0-9] /dev/mapper/* /dev/dm-[0-9]*; do
        [ -b "$dev" ] || continue
        for fs in iso9660 ""; do
            if [ -n "$fs" ]; then mount -t "$fs" -o ro "$dev" /cdrom 2>/dev/null || continue
            else mount -o ro "$dev" /cdrom 2>/dev/null || continue; fi
            if [ -f "$SQUASH" ]; then found="$dev"; break 3; fi
            umount /cdrom 2>/dev/null
        done
    done
    for dev in /dev/sd[a-z]*[0-9] /dev/sd[a-z] /dev/vd[a-z]*[0-9] /dev/vd[a-z] \
               /dev/nvme*n*p[0-9] /dev/mmcblk*p[0-9]; do
        [ -b "$dev" ] || continue
        scan_iso_files "$dev" && break 2
    done
    sleep 1
done
if [ -z "$found" ]; then
    echo "initramfs: no boot media with /live/rootfs.squashfs found"
    echo "initramfs: block devices seen:"; cat /proc/partitions
    exec sh
fi
echo "initramfs: boot media at $found"

mount -t squashfs -o ro "$SQUASH" /ro || { echo "initramfs: squashfs mount failed"; exec sh; }

# persistence: a partition labelled FASEELA_PERSIST (ext4) keeps the overlay's
# upper layer, so changes survive a reboot. Without it (or with `nopersist` on
# the kernel command line) the upper layer is a tmpfs, as before. Create one with
#   mkfs.ext4 -L FASEELA_PERSIST /dev/sdX3
nopersist=""
for arg in $(cat /proc/cmdline); do
    [ "$arg" = nopersist ] && nopersist=1
done
persist=""
[ -n "$nopersist" ] || persist="$(findfs LABEL=FASEELA_PERSIST 2>/dev/null || true)"
if [ -n "$persist" ] && mount -t ext4 -o noatime "$persist" /rw 2>/dev/null; then
    echo "initramfs: persistence on $persist"
else
    [ -z "$persist" ] || echo "initramfs: WARNING cannot mount $persist — changes will not be kept"
    mount -t tmpfs tmpfs /rw
fi
mkdir -p /rw/upper /rw/work
mount -t overlay overlay -o lowerdir=/ro,upperdir=/rw/upper,workdir=/rw/work /newroot \
    || { echo "initramfs: overlayfs mount failed"; exec sh; }

# >>> live-user
# live session only: unlock root (base-files ships `root:*`, which makes login
# impossible on the ISO) and add an ordinary user, `live`, so the system can be tried
# without installing: log in as `live` (no password), `doas` needs none either. All
# of it lives in the overlay — the squashfs is untouched, and the disk installer removes
# it again from the installed system (bootstrap/install.sh). Not run for disk boots.
make_live_user() {   # make_live_user <root-dir>
    r="$1"
    [ -f "$r/etc/shadow" ] && sed -i 's/^root:[^:]*:/root::/' "$r/etc/shadow"
    if ! grep -q '^live:' "$r/etc/passwd" 2>/dev/null; then
        echo 'live:x:1000:1000:Faseela live:/home/live:/bin/bash' >> "$r/etc/passwd"
        grep -q '^live:' "$r/etc/group" || echo 'live:x:1000:' >> "$r/etc/group"
    fi
    if grep -q '^live:' "$r/etc/shadow" 2>/dev/null; then
        sed -i 's/^live:[^:]*:/live::/' "$r/etc/shadow"
    else
        echo 'live::19980:0:99999:7:::' >> "$r/etc/shadow"
    fi
    # the groups the desktop session and storage/audio need — only those that exist
    for g in wheel seat video render input audio cdrom; do
        grep -q "^$g:" "$r/etc/group" || continue
        grep -q "^$g:[^:]*:[^:]*:\(.*,\)\{0,1\}live\(,.*\)\{0,1\}$" "$r/etc/group" && continue
        sed -i "/^$g:/{s/:\$/:live/;t;s/\$/,live/}" "$r/etc/group"
    done
    if [ ! -d "$r/home/live" ]; then
        mkdir -p "$r/home/live"
        [ -d "$r/etc/skel" ] && cp -a "$r/etc/skel/." "$r/home/live/" 2>/dev/null
        chown -R 1000:1000 "$r/home/live"
        chmod 755 "$r/home/live"
    fi
    # no password prompt for doas in the live session (the account has no password)
    if [ -f "$r/etc/doas.conf" ] && ! grep -q '^permit nopass live$' "$r/etc/doas.conf"; then
        echo 'permit nopass live' >> "$r/etc/doas.conf"
    fi
    echo live > "$r/etc/faseela-live"
    grep -q 'Faseela live session' "$r/etc/issue" 2>/dev/null || \
        printf '\nFaseela live session: log in as "live" (no password).\nTo install to disk, log in and run: doas faseela-install\n\n' >> "$r/etc/issue"
}
# <<< live-user
make_live_user /newroot
echo "initramfs: live session — user 'live' and root have empty passwords"
# (with persistence the changes above are re-applied at every boot)

# hand the pseudo filesystems over to the real root; keep the boot media
# mounted at /cdrom inside the live system (the disk installer reads the
# kernel + initramfs from there)
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys
mount --move /dev /newroot/dev
mkdir -p /newroot/cdrom
mount --move /cdrom /newroot/cdrom
# ISO booted as a file (Ventoy): its partition backs the loop device, keep it mounted
# (and visible to the installer, which never offers a disk with a mounted partition)
if grep -q " /iso-host " /newroot/proc/mounts; then
    mkdir -p /newroot/media/iso-host
    mount --move /iso-host /newroot/media/iso-host
fi

echo "initramfs: switch_root -> systemd"
export PATH=/bin:/usr/bin:/usr/sbin:/sbin
exec switch_root /newroot /usr/lib/systemd/systemd

# never reached unless switch_root failed
echo "initramfs: switch_root failed — dropping to rescue shell"
exec sh
INIT_EOF
chmod 755 "$TREE/init"

# ---------------------------------------------------------------------------
# 5) pack with busybox's own cpio+gzip (no host tools needed)
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUT")"
( cd "$TREE" && "$BBDIR/busybox" find . | "$BBDIR/busybox" cpio -o -H newc | "$BBDIR/busybox" gzip -9 ) > "$OUT"

sh -n "$TREE/init" && echo "initramfs: /init syntax OK"
echo "initramfs: wrote $OUT ($(du -h "$OUT" | cut -f1))"
