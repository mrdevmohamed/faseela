#!/usr/bin/env bash
# bootstrap/mkiso.sh — STAGE 4: produce a bootable hybrid ISO from the built
# root (stage2/3 output).
#
# Layout produced:
#   /boot/vmlinuz-<ver>      the target root's kernel
#   /boot/initramfs.img      built by bootstrap/initramfs.sh (static busybox)
#   /live/rootfs.squashfs    the entire target root, compressed
#   /boot/grub/grub.cfg      live menu (BIOS+UEFI via grub-mkrescue)
#
# Boot flow: grub -> kernel + initramfs -> /init finds the media, loads
# storage modules, mounts rootfs.squashfs read-only, stacks a tmpfs overlay
# on top (overlayfs) and switch_roots into /usr/bin/runit.
#
# Host requirements:
#   mksquashfs        (Debian: squashfs-tools)
#   grub-mkrescue     (Debian: grub-pc-bin grub-efi-amd64-bin xorriso mtools)
#   gcc + make        (to compile the initramfs busybox)
#
# ROOT is the FINAL root: /mnt/mydistro/sysroot in the default two-root layout
# (build-all passes it), or /mnt/mydistro itself for a --single-root build.
#
# Usage:
#   sudo ./mkiso.sh /mnt/mydistro/sysroot out/mydistro-x86_64.iso
# Env overrides: VOL_ID (default MYDISTRO), SQUASH_COMP (gzip|xz|zstd), JOBS
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:?usage: mkiso.sh /mnt/mydistro out.iso}"
OUT_ISO="${2:?usage: mkiso.sh /mnt/mydistro out.iso}"
VOL_ID="${VOL_ID:-MYDISTRO}"
SQUASH_COMP="${SQUASH_COMP:-gzip}"
JOBS="${NAWA_JOBS:-4}"

[[ $EUID -eq 0 ]] || echo "mkiso: WARNING: not root — squashfs will record the invoking user's ownership" >&2
[[ -d $ROOT ]] || { echo "mkiso: $ROOT is not a directory"; exit 1; }

for tool in mksquashfs grub-mkrescue xorriso; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "mkiso: missing host tool '$tool'" >&2
        echo "       Debian: apt install squashfs-tools grub-pc-bin grub-efi-amd64-bin xorriso mtools" >&2
        exit 1
    }
done
# overridable for the stub-based test (scripts/test-mkiso.sh); the real
# pipeline always uses bootstrap/initramfs.sh
INITRAMFS_BIN="${INITRAMFS_BIN:-$HERE/initramfs.sh}"

# `|| true` inside the substitution: with pipefail a missing kernel makes
# `ls` fail, and a failing assignment would kill the script silently (exit 2)
# BEFORE the friendly check below could run — the check must be reachable
KERNEL="$(ls "$ROOT"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 || true)"
[[ -n ${KERNEL:-} ]] || { echo "mkiso: no kernel in $ROOT/boot (install the linux recipe)" >&2; exit 1; }
KVER="$(basename "$KERNEL")"
[[ -x $ROOT/usr/bin/runit ]] || { echo "mkiso: $ROOT/usr/bin/runit missing (install runit)" >&2; exit 1; }
[[ -f $ROOT/etc/runit/1 ]] || { echo "mkiso: $ROOT/etc/runit/1 missing (install runit-services)" >&2; exit 1; }

echo "== stage4: kernel      = $KVER"
echo "== stage4: compression = $SQUASH_COMP"

WORK="$(mktemp -d /tmp/mkiso.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ISO="$WORK/iso"
mkdir -p "$ISO/boot/grub" "$ISO/live"

# 1) initramfs (static busybox + /init + storage modules)
echo "== stage4: building initramfs"
"$INITRAMFS_BIN" --root "$ROOT" --out "$ISO/boot/initramfs.img" --jobs "$JOBS"

# 2) squashfs of the whole target root; the repo/build scratch and the
#    duplicate kernel image stay out of the image (build3 is stage3's
#    build dir — its archives are already installed and cached in
#    /var/cache/nawa, which the disk installer copies for rollback)
# The squashfs must NEVER contain the host's /dev or a live /proc: mksquashfs
# reads through mountpoints, so leftover stage-1 pseudo-fs mounts would bake
# host device nodes and proc entries into the ISO.  Unmount them first
# (idempotent; nothing later in this stage needs them).  Note: this happens
# even with build-all --keep-mounts — a clean squashfs wins.
if mountpoint -q "$ROOT/proc" || mountpoint -q "$ROOT/dev" \
   || mountpoint -q "$ROOT/sys" || mountpoint -q "$ROOT/run"; then
    if [[ $EUID -ne 0 ]]; then
        echo "mkiso: chroot pseudo-fs are still mounted in $ROOT — they must not enter the squashfs" >&2
        echo "mkiso: run as root, or first:  sudo $HERE/umount-chroot.sh $ROOT" >&2
        exit 1
    fi
    echo "== stage4: unmounting chroot pseudo-fs (must not enter the squashfs)"
    bash "$HERE/umount-chroot.sh" "$ROOT"
fi

echo "== stage4: mksquashfs of $ROOT"
# Excludes are relative to ROOT and only passed when they exist (a clean
# two-root final root has none of the build dirs; the legacy single root does).
EXCL=()
for d in build build3 mydistro sources boot .nawa; do
    [[ -e $ROOT/$d ]] && EXCL+=("$d")
done
mksquashfs "$ROOT" "$ISO/live/rootfs.squashfs" \
    -comp "$SQUASH_COMP" -noappend -no-recovery -processors "$JOBS" \
    ${EXCL[@]:+-e "${EXCL[@]}"}

# 3) kernel + grub config
# console=ttyS0 first, tty0 last: the kernel log also goes to the serial line
# (CI boots the ISO in QEMU and waits for the login prompt there), while
# /dev/console stays the screen, so a real machine behaves as before.
cp "$KERNEL" "$ISO/boot/$KVER"
cat > "$ISO/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "mydistro (live)" {
    linux /boot/$KVER quiet console=ttyS0,115200 console=tty0
    initrd /boot/initramfs.img
}

menuentry "mydistro (live, verbose)" {
    linux /boot/$KVER loglevel=7 console=ttyS0,115200 console=tty0
    initrd /boot/initramfs.img
}
EOF

# 4) hybrid ISO (BIOS + UEFI when the efi grub modules are installed)
echo "== stage4: grub-mkrescue"
mkdir -p "$(dirname "$OUT_ISO")"
grub-mkrescue -o "$OUT_ISO" "$ISO" -volid "$VOL_ID" 2>/dev/null \
    || grub-mkrescue -o "$OUT_ISO" "$ISO" -volid "$VOL_ID"

# 5) structural validation: "the ISO exists and is non-empty" is not
#    enough — verify the image actually contains the files a boot needs.
#    This is NOT a boot test (that still requires a VM); it catches a
#    grub-mkrescue that silently produced a non-bootable layout, a wrong
#    working dir or a mangled kernel copy. The name is matched as a
#    substring of the directory listing on purpose: xorriso -ls output
#    formats differ between versions (bare names vs iso:/ prefixed paths),
#    and we validate our own just-written image, not an adversarial one.
echo "== stage4: validating the ISO structure"
iso_dir_has() {   # iso_dir_has <iso-dir> <name>
    # stderr is deliberately NOT silenced: a broken xorriso must be visible
    # in the log, not reduced to "member missing" (with pipefail either way
    # the check fails closed — an unreadable image is never shipped)
    xorriso -indev "$OUT_ISO" -ls "$1" | grep -q -- "$2"
}
for member in "/boot/$KVER" /boot/initramfs.img /boot/grub/grub.cfg /live/rootfs.squashfs; do
    if ! iso_dir_has "$(dirname "$member")" "$(basename "$member")"; then
        echo "mkiso: ISO validation FAILED: '$member' is not in $OUT_ISO" >&2
        echo "mkiso: the image is not bootable as built — refusing to ship it" >&2
        exit 1
    fi
done
echo "== stage4: ISO structure OK (kernel, initramfs, grub.cfg, squashfs present)"

echo "== stage4: done -> $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
