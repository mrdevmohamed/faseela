#!/usr/bin/env bash
# tests/validate-install.sh — stub-based validation of bootstrap/install.sh
# (runs as a normal user; no real disks touched)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root
WORK=$(mktemp -d /tmp/nawa-install-validate-XXXX)
trap 'rm -rf "$WORK"' EXIT

STUBS=$WORK/stubs
mkdir -p "$STUBS"
CMDLOG=$WORK/cmds.txt
: > "$CMDLOG"

# every stub appends its full invocation then succeeds
mkstub() {
    local name=$1; shift
    cat > "$STUBS/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$CMDLOG"
exit 0
EOF
    chmod +x "$STUBS/$name"
}
for t in parted mkfs.ext4 mkfs.vfat wipefs partprobe rsync grub-install chroot mount umount mkswap; do
    mkstub "$t"
done
# fallocate: log, then create the file (the installer chmods it afterwards)
cat > "$STUBS/fallocate" <<EOF
#!/usr/bin/env bash
echo "fallocate \$*" >> "$CMDLOG"
for a in "\$@"; do last="\$a"; done
: > "\$last"
EOF
chmod +x "$STUBS/fallocate"
# lsblk: two whole disks and a loop device; the wizard must offer only the disks
cat > "$STUBS/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$CMDLOG"
printf '%s\n' '/dev/loop0 100M loop ' '/dev/vda 20G disk QEMU HARDDISK' '/dev/vdb 8G disk Other Disk'
EOF
chmod +x "$STUBS/lsblk"
# blkid returns a stable fake UUID per device
cat > "$STUBS/blkid" <<EOF
#!/usr/bin/env bash
echo "blkid \$*" >> "$CMDLOG"
for a in "\$@"; do
    case "\$a" in
        /dev/vda1) echo "aaaa-1111" ;;
        /dev/vda2) echo "bbbb-2222" ;;
    esac
done
exit 0
EOF
chmod +x "$STUBS/blkid"

# fake boot media
KSRC=$WORK/cdrom/boot
mkdir -p "$KSRC"
touch "$KSRC/vmlinuz-6.10.5" "$KSRC/initramfs.img"

check() { # description, pattern in cmdlog  (-e: patterns may start with --)
    if grep -qE -e "$2" "$CMDLOG"; then
        echo "  ok: $1"
    else
        echo "  FAIL: $1 (missing: $2)"; exit 1
    fi
}
check_absent() {
    if grep -qE "$2" "$CMDLOG"; then
        echo "  FAIL: $1 (unexpected: $2)"; exit 1
    else
        echo "  ok: $1"
    fi
}

export PATH="$STUBS:$PATH"

run_install() {
    # NOTE: no NAWA_INSTALL_DRYRUN here — the stubs on PATH shadow every
    # disk-mutating tool (parted/mkfs/grub-install/...), so the script runs
    # for real against a fake environment and the cmdlog captures the args.
    ( cd "$WORK" && NAWA_INSTALL_TEST=1 \
      MNT="$WORK/mnt" KERNEL_SRC="$KSRC" FW_FORCE="$1" \
      bash "$HERE/bootstrap/install.sh" /dev/vda --hostname testhost --yes )
}

# a fake package cache (rollback support): two archives + a remote subcache
# that must NOT be copied
PCACHE=$WORK/pkgcache
mkdir -p "$PCACHE/remote/deadbeef"
touch "$PCACHE/zlib-1.3-1.nawa.tar.zst" "$PCACHE/gcc-14-1.nawa.tar.zst"
touch "$PCACHE/remote/deadbeef/index.toml"
export NAWA_PKG_CACHE_SRC="$PCACHE"

# ============================================================ UEFI path ====
echo "== UEFI install =="
mkdir -p "$WORK/mnt/etc"
printf '127.0.0.1 localhost faseela\n' > "$WORK/mnt/etc/hosts"
run_install uefi

check "GPT label"            "parted -s /dev/vda mklabel gpt"
check "ESP 512MiB"           "mkpart ESP fat32 1MiB 513MiB"
check "esp flag"             "set 1 esp on"
check "mkfs.vfat on ESP"     "mkfs.vfat -F32 /dev/vda1"
check "mkfs.ext4 on root"    "mkfs.ext4 -F -q /dev/vda2"
check "rsync onto /mnt"      "rsync -aHX --numeric-ids"
check "rsync excludes \$MNT"  "--exclude=.*/mnt/\*"
# cp is a real command (not stubbed) — assert the result on disk instead
[ -f "$WORK/mnt/boot/vmlinuz-6.10.5" ] && echo "  ok: kernel copied from media" || { echo "  FAIL: kernel copy"; exit 1; }
check "grub UEFI removable"  "grub-install --target=x86_64-efi .* --removable --no-nvram"
check_absent "no i386-pc on UEFI" "grub-install --target=i386-pc"

grep -q "UUID=bbbb-2222  /      ext4" "$WORK/mnt/etc/fstab" && echo "  ok: fstab root UUID" || { echo "  FAIL: fstab root"; cat "$WORK/mnt/etc/fstab"; exit 1; }
grep -q "UUID=aaaa-1111  /boot/efi vfat" "$WORK/mnt/etc/fstab" && echo "  ok: fstab ESP UUID" || { echo "  FAIL: fstab ESP"; exit 1; }
grep -q "tmpfs            /run   tmpfs" "$WORK/mnt/etc/fstab" && echo "  ok: fstab /run tmpfs" || { echo "  FAIL: fstab /run row"; exit 1; }
grep -q "root=UUID=bbbb-2222" "$WORK/mnt/boot/grub/grub.cfg" && echo "  ok: grub.cfg root=UUID" || { echo "  FAIL: grub.cfg"; exit 1; }
grep -q "initrd /boot/initramfs.img" "$WORK/mnt/boot/grub/grub.cfg" && echo "  ok: grub.cfg initrd" || { echo "  FAIL: initrd"; exit 1; }
grep -q "^testhost$" "$WORK/mnt/etc/hostname" && echo "  ok: hostname written" || { echo "  FAIL: hostname"; exit 1; }
grep -q "localhost testhost" "$WORK/mnt/etc/hosts" && echo "  ok: hosts updated" || { echo "  FAIL: hosts"; exit 1; }
check "chroot passwd"        "chroot .* /usr/bin/passwd root"
check "unmount"              "umount -R .*"
[ -f "$WORK/mnt/boot/initramfs.img" ] && echo "  ok: initramfs copied" || { echo "  FAIL: initramfs copy"; exit 1; }

# package cache: copied for rollback, minus the remote subcache (the stub
# rsync only logs — assert the invocation, not the result on disk)
check "pkg cache rsync"      "rsync -a --exclude=remote .*/pkgcache/ .*mnt/var/cache/nawa"
ls "$WORK/mnt/var/cache/nawa" >/dev/null 2>&1 && echo "  ok: cache dir created on target" \
    || { echo "  FAIL: cache dir missing"; exit 1; }

# ============================================================ BIOS path ====
echo "== BIOS install =="
: > "$CMDLOG"
rm -rf "$WORK/mnt"; mkdir -p "$WORK/mnt/etc"
printf '127.0.0.1 localhost faseela\n' > "$WORK/mnt/etc/hosts"
run_install bios

check "MBR label"            "parted -s /dev/vda mklabel msdos"
check "single root part"     "mkpart primary ext4 1MiB 100%"
check "boot flag"            "set 1 boot on"
check_absent "no ESP on BIOS" "mkpart ESP"
check_absent "no vfat on BIOS" "mkfs.vfat"
check "grub MBR target"      "grub-install --target=i386-pc --boot-directory=.* /dev/vda"
check_absent "no UEFI target on BIOS" "x86_64-efi"
grep -q "UUID=aaaa-1111  /      ext4" "$WORK/mnt/etc/fstab" && echo "  ok: fstab root = vda1 UUID" || { echo "  FAIL: bios fstab"; cat "$WORK/mnt/etc/fstab"; exit 1; }
! grep -q "/boot/efi" "$WORK/mnt/etc/fstab" && echo "  ok: no EFI row on BIOS" || { echo "  FAIL: efi row present"; exit 1; }

# ==================================================== refusal behaviors ===
echo "== safety checks =="
( NAWA_INSTALL_TEST=1 MNT="$WORK/mnt" KERNEL_SRC="$KSRC" \
  bash "$HERE/bootstrap/install.sh" /dev/vda2 --yes ) 2>"$WORK/err.txt" \
  && { echo "  FAIL: partition accepted"; exit 1; } \
  || grep -q "looks like a partition" "$WORK/err.txt" && echo "  ok: partition refus[ed]"

# ==================================================== --no-pkg-cache =======
echo "== no-pkg-cache path =="
: > "$CMDLOG"
rm -rf "$WORK/mnt"; mkdir -p "$WORK/mnt/etc"
( cd "$WORK" && NAWA_INSTALL_TEST=1 \
  MNT="$WORK/mnt" KERNEL_SRC="$KSRC" FW_FORCE=bios \
  bash "$HERE/bootstrap/install.sh" /dev/vda --yes --no-pkg-cache )
check_absent "no cache rsync with --no-pkg-cache" "rsync -a --exclude=remote"
[ ! -e "$WORK/mnt/var/cache/nawa/zlib-1.3-1.nawa.tar.zst" ] \
    && echo "  ok: cache not copied" || { echo "  FAIL: cache copied despite --no-pkg-cache"; exit 1; }

# ==================================== flags: user, swap, time zone ==========
echo "== --user / --swap / --timezone =="
: > "$CMDLOG"
rm -rf "$WORK/mnt"; mkdir -p "$WORK/mnt/etc" "$WORK/mnt/usr/share/zoneinfo/Africa"
printf 'root:x:0:\nwheel:x:97:\nvideo:x:98:\naudio:x:99:\n' > "$WORK/mnt/etc/group"
touch "$WORK/mnt/usr/share/zoneinfo/Africa/Cairo"
( cd "$WORK" && NAWA_INSTALL_TEST=1 MNT="$WORK/mnt" KERNEL_SRC="$KSRC" FW_FORCE=bios \
  bash "$HERE/bootstrap/install.sh" /dev/vda --yes --user mohamed --swap 2G --timezone Africa/Cairo >/dev/null )
check "swap file allocated"        "fallocate -l 2G .*/mnt/swapfile"
[ "$(stat -c %a "$WORK/mnt/swapfile")" = 600 ] && echo "  ok: swap file mode 600" || { echo "  FAIL: swap file mode"; exit 1; }
check "swap signature written"     "mkswap -q .*/swapfile"
grep -q '^/swapfile .*swap' "$WORK/mnt/etc/fstab" && echo "  ok: fstab swap row" || { echo "  FAIL: fstab swap row"; cat "$WORK/mnt/etc/fstab"; exit 1; }
[ "$(readlink "$WORK/mnt/etc/localtime")" = /usr/share/zoneinfo/Africa/Cairo ] \
    && echo "  ok: /etc/localtime -> Africa/Cairo" || { echo "  FAIL: time zone link"; exit 1; }
# only the groups that exist on the target are passed (seat/input are missing here)
check "useradd with the existing groups only" "chroot .* useradd -m -s /bin/bash -G wheel,video,audio mohamed"
check "user password asked"        "chroot .* /usr/bin/passwd mohamed"
check "root password still asked"  "chroot .* /usr/bin/passwd root"

# no flags: nothing swap/user related happens
: > "$CMDLOG"
rm -rf "$WORK/mnt"; mkdir -p "$WORK/mnt/etc"
( cd "$WORK" && NAWA_INSTALL_TEST=1 MNT="$WORK/mnt" KERNEL_SRC="$KSRC" FW_FORCE=bios \
  bash "$HERE/bootstrap/install.sh" /dev/vda --yes >/dev/null )
check_absent "no swap without --swap"  "fallocate|mkswap"
check_absent "no user without --user"  "useradd"
! grep -q swap "$WORK/mnt/etc/fstab" && echo "  ok: no swap row by default" || { echo "  FAIL: swap row by default"; exit 1; }

# bad input is refused before anything is touched
for bad in "--user root" "--user Bad_Name" "--swap 2" "--swap -1G" "--timezone ../etc/passwd"; do
    : > "$CMDLOG"
    # shellcheck disable=SC2086
    ( cd "$WORK" && NAWA_INSTALL_TEST=1 MNT="$WORK/mnt" KERNEL_SRC="$KSRC" FW_FORCE=bios \
      bash "$HERE/bootstrap/install.sh" /dev/vda --yes $bad ) >/dev/null 2>&1 \
      && { echo "  FAIL: accepted '$bad'"; exit 1; }
    ! grep -q "parted" "$CMDLOG" && echo "  ok: refused '$bad' before partitioning" || { echo "  FAIL: '$bad' reached parted"; exit 1; }
done

# ============================================== interactive wizard ==========
echo "== interactive wizard =="
: > "$CMDLOG"
rm -rf "$WORK/mnt"; mkdir -p "$WORK/mnt/etc" "$WORK/mnt/usr/share/zoneinfo/Africa"
printf 'root:x:0:\nwheel:x:97:\n' > "$WORK/mnt/etc/group"
touch "$WORK/mnt/usr/share/zoneinfo/Africa/Cairo"
# answers: disk 1 (vda; loop0 is not offered), a bad hostname then a good one,
# time zone, user, swap, and the typed confirmation of the disk name
ANSWERS=$(printf '%s\n' 1 'bad host!' mybox Africa/Cairo mohamed 1G /dev/vda)
( cd "$WORK" && NAWA_INSTALL_TEST=1 MNT="$WORK/mnt" KERNEL_SRC="$KSRC" FW_FORCE=bios \
  bash "$HERE/bootstrap/install.sh" <<<"$ANSWERS" > "$WORK/wizard.out" 2>&1 ) \
  || { echo "  FAIL: wizard run"; cat "$WORK/wizard.out"; exit 1; }
grep -q '1) /dev/vda' "$WORK/wizard.out" && echo "  ok: disks listed" || { echo "  FAIL: disk list"; cat "$WORK/wizard.out"; exit 1; }
! grep -q 'loop0' "$WORK/wizard.out" && echo "  ok: loop device not offered" || { echo "  FAIL: loop0 offered"; exit 1; }
grep -q "letters, digits" "$WORK/wizard.out" && echo "  ok: bad hostname re-asked" || { echo "  FAIL: no re-ask"; exit 1; }
check "wizard installs on the chosen disk" "parted -s /dev/vda mklabel msdos"
check "wizard swap size used"       "fallocate -l 1G"
check "wizard user created"         "useradd -m -s /bin/bash -G wheel mohamed"
grep -q '^mybox$' "$WORK/mnt/etc/hostname" && echo "  ok: wizard hostname" || { echo "  FAIL: wizard hostname"; exit 1; }

# a wrong typed confirmation aborts before anything is written
: > "$CMDLOG"
rm -rf "$WORK/mnt"; mkdir -p "$WORK/mnt/etc"
ANSWERS=$(printf '%s\n' 1 '' '' '' '' /dev/vdb)
( cd "$WORK" && NAWA_INSTALL_TEST=1 MNT="$WORK/mnt" KERNEL_SRC="$KSRC" FW_FORCE=bios \
  bash "$HERE/bootstrap/install.sh" <<<"$ANSWERS" ) >/dev/null 2>&1 \
  && { echo "  FAIL: wrong confirmation accepted"; exit 1; }
! grep -q "parted" "$CMDLOG" && echo "  ok: wrong confirmation aborts before partitioning" || { echo "  FAIL: wizard wrote after a wrong confirmation"; exit 1; }

# no disk and no terminal (and not the test hook): usage, exit 1, no waiting
if ( cd "$WORK" && MNT="$WORK/mnt" bash "$HERE/bootstrap/install.sh" </dev/null ) >"$WORK/usage.out" 2>&1; then
    echo "  FAIL: ran without a disk"; exit 1
else
    grep -q 'Usage' "$WORK/usage.out" && echo "  ok: usage without a disk (non-tty)" || { echo "  FAIL: no usage text"; cat "$WORK/usage.out"; exit 1; }
fi

echo
echo "INSTALLER VALIDATION PASSED"
