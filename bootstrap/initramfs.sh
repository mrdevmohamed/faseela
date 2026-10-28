#!/usr/bin/env bash
# bootstrap/initramfs.sh — build the live-boot initramfs for stage 4.
#
# Produces a minimal initramfs containing:
#   /bin/busybox          static binary (CONFIG_STATIC=y) + applet links
#   /init                 live-boot script: find media -> squashfs -> overlay
#                         -> switch_root into /usr/bin/runit
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
#   sudo ./initramfs.sh --root /mnt/mydistro --out out/initramfs.img
#     [--src busybox-1.37.0.tar.bz2] [--jobs 4]
#
# Source lookup order: --src, $DPM_SRCCACHE, <repo>/srccache, download.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRCCACHE="${DPM_SRCCACHE:-$REPO/srccache}"
BUSYBOX_SHA256="$(sed -n 's/^sha256 *= *"\([0-9a-f]*\)".*/\1/p' "$REPO/recipes/boot/busybox/recipe.toml" | head -1)"
BUSYBOX_URL="$(sed -n 's/^source *= *"\(.*\)".*/\1/p' "$REPO/recipes/boot/busybox/recipe.toml" | head -1)"

ROOT=""
OUT=""
SRC=""
JOBS="${DPM_JOBS:-4}"

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

[[ -n $ROOT ]] || { echo "usage: initramfs.sh --root /mnt/mydistro --out initramfs.img"; exit 1; }
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
    echo "initramfs: downloading busybox from $BUSYBOX_URL"
    mkdir -p "$SRCCACHE"
    SRC="$SRCCACHE/$(basename "$BUSYBOX_URL")"
    curl -fL --retry 3 -o "$SRC" "$(sed "s|%{version}|$(sed -n 's/^version *= *"\(.*\)".*/\1/p' "$REPO/recipes/boot/busybox/recipe.toml")|" <<< "$BUSYBOX_URL")"
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
    # PID 1 of the initramfs is /bin/busybox — a dynamic binary cannot exec
    # there (no loader on the cpio) and the ISO would boot to a kernel panic.
    # The defconfig patch above normally forces CONFIG_STATIC=y; if this ever
    # stops working, fail the build instead of shipping an unbootable image.
    echo "initramfs: FATAL busybox is dynamically linked (CONFIG_STATIC patch failed)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3) assemble the initramfs tree
# ---------------------------------------------------------------------------
TREE="$WORK/tree"
mkdir -p "$TREE/bin" "$TREE/modules" "$TREE/dev" "$TREE/proc" "$TREE/sys" \
         "$TREE/tmp" "$TREE/run" "$TREE/cdrom" "$TREE/ro" "$TREE/rw" "$TREE/newroot"
install -m755 "$BBDIR/busybox" "$TREE/bin/busybox"
for applet in sh cat echo mount umount mkdir mknod switch_root insmod modprobe mdev \
              sleep seq ls blkid findfs grep sed cp rm ln dmesg sync uname reboot poweroff; do
    ln -sf busybox "$TREE/bin/$applet"
done

# Storage + USB/HID controllers + filesystems from the target root.
# `|| true`: with pipefail a missing modules dir makes `ls` fail and the
# assignment would kill the script silently (exit 2) before the warning
# below could run
KVER="$(ls "$ROOT/lib/modules" 2>/dev/null | sort -V | tail -1 || true)"
MODLIST="scsi_mod cdrom sr_mod sd_mod sg ahci ata_piix nvme virtio virtio_ring virtio_pci virtio_blk virtio_scsi usb_common usbcore usb_storage uas xhci_pci ehci_pci uhci_hcd hid usbhid hid_generic iso9660 squashfs overlay loop fat vfat nls_cp437 dm_mod"
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
# mydistro live-boot initramfs /init
busybox mkdir -p /bin /dev /proc /sys /tmp /run /cdrom /ro /rw /newroot
busybox --install -s /bin
export PATH=/bin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { [ -e /dev/console ] || mknod /dev/console c 5 1; }

echo "mydistro initramfs: loading storage/HID/filesystem modules"
# preferred: busybox modprobe against the staged dependency tree — it loads
# every dependency in the right order (anything built-in is simply unknown
# to modprobe and skipped). Fallback: the flat insmod loop.
MODLIST="scsi_mod cdrom sr_mod sd_mod sg ahci ata_piix nvme \
    virtio virtio_ring virtio_pci virtio_blk virtio_scsi \
    usb_common usbcore usb_storage uas \
    xhci_pci ehci_pci uhci_hcd hid usbhid hid_generic \
    iso9660 squashfs overlay loop fat vfat nls_cp437 dm_mod"
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
    echo "initramfs: switch_root -> runit"
    export PATH=/bin:/usr/bin:/usr/sbin:/sbin
    exec switch_root /ro /usr/bin/runit
fi
[ -z "$rootdev" ] || echo "initramfs: WARNING root=$rootdev not mountable — trying live media"

echo "initramfs: waiting for boot media"
# The media is the device whose filesystem contains /live/rootfs.squashfs
# (mkiso.sh layout). Checking for the file — not just "mountable" — skips the
# EFI system partition that a hybrid ISO written to a USB stick exposes.
SQUASH=/cdrom/live/rootfs.squashfs
found=""
for i in $(seq 1 15); do
    for dev in /dev/sr[0-9]* /dev/sd[a-z] /dev/sd[a-z]*[0-9] /dev/vd[a-z] /dev/vd[a-z]*[0-9] /dev/nvme*n*p[0-9] /dev/nvme*n[0-9]; do
        [ -b "$dev" ] || continue
        for fs in iso9660 ""; do
            if [ -n "$fs" ]; then mount -t "$fs" -o ro "$dev" /cdrom 2>/dev/null || continue
            else mount -o ro "$dev" /cdrom 2>/dev/null || continue; fi
            if [ -f "$SQUASH" ]; then found="$dev"; break 3; fi
            umount /cdrom 2>/dev/null
        done
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

mount -t tmpfs tmpfs /rw
mkdir -p /rw/upper /rw/work
mount -t overlay overlay -o lowerdir=/ro,upperdir=/rw/upper,workdir=/rw/work /newroot \
    || { echo "initramfs: overlayfs mount failed"; exec sh; }

# live session only: unlock root (base-files ships `root:*`, which makes login
# impossible on the ISO). The change lives in the tmpfs overlay — the squashfs
# and disk installs are untouched (the installer sets a real root password).
[ -f /newroot/etc/shadow ] && sed -i 's/^root:[^:]*:/root::/' /newroot/etc/shadow
echo "initramfs: live session — root has an empty password"

# hand the pseudo filesystems over to the real root; keep the boot media
# mounted at /cdrom inside the live system (the disk installer reads the
# kernel + initramfs from there)
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys
mount --move /dev /newroot/dev
mkdir -p /newroot/cdrom
mount --move /cdrom /newroot/cdrom

echo "initramfs: switch_root -> runit"
export PATH=/bin:/usr/bin:/usr/sbin:/sbin
exec switch_root /newroot /usr/bin/runit

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
