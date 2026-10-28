#!/usr/bin/env bash
# bootstrap/mkrootfs.sh — STAGE 4: pack the finished final root into a
# standalone rootfs tarball (<name>-rootfs.tar.zst + .sha256 + .packages).
#
# The tarball is the SAME tree mkiso.sh squashes into the ISO, but as a plain
# archive. It is published next to the ISO and has a second job: it can be
# the seed of the NEXT build (`build-all.sh --seed-rootfs <file>`), so the
# distribution builds itself with its own toolchain instead of starting from
# the prebuilt Debian seed again (see bootstrap/seed-from-rootfs.sh).
#
# Only the finished system goes in: no pseudo-fs content, no build scratch,
# no bootstrap-seed leftovers. A root that fails the sanity checks below is
# refused — a rootfs that cannot be unpacked and used is worse than none.
#
# ROOT is the FINAL root: /mnt/mydistro/sysroot in the default two-root layout
# (build-all passes it), or /mnt/mydistro itself for a --single-root build.
#
# Usage:
#   sudo ./mkrootfs.sh /mnt/mydistro/sysroot out/mydistro-x86_64-rootfs.tar.zst
# Env overrides: ROOTFS_ZSTD_LEVEL (default 12), DPM_JOBS (zstd threads, 0=all)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:?usage: mkrootfs.sh ROOT out-rootfs.tar.zst}"
OUT="${2:?usage: mkrootfs.sh ROOT out-rootfs.tar.zst}"
LEVEL="${ROOTFS_ZSTD_LEVEL:-12}"
THREADS="${ROOTFS_ZSTD_THREADS:-0}"

[[ $LEVEL =~ ^[0-9]+$ && $LEVEL -ge 1 && $LEVEL -le 19 ]] \
    || { echo "mkrootfs: ROOTFS_ZSTD_LEVEL must be 1..19 (got '$LEVEL')" >&2; exit 2; }
[[ $OUT == *.tar.zst ]] || { echo "mkrootfs: output name must end in .tar.zst (got '$OUT')" >&2; exit 2; }
[[ -d $ROOT ]] || { echo "mkrootfs: $ROOT is not a directory" >&2; exit 1; }
for tool in tar zstd sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "mkrootfs: missing host tool '$tool'" >&2; exit 1; }
done
[[ $EUID -eq 0 ]] || echo "mkrootfs: WARNING: not root — the archive records the invoking user's view of ownership and may skip unreadable files" >&2

# the pseudo-fs bind mounts of the chroot must not be read into the archive
# (same reason as in mkiso.sh); unmount them first, idempotent
if mountpoint -q "$ROOT/proc" || mountpoint -q "$ROOT/dev" \
   || mountpoint -q "$ROOT/sys" || mountpoint -q "$ROOT/run"; then
    if [[ $EUID -ne 0 ]]; then
        echo "mkrootfs: chroot pseudo-fs are still mounted in $ROOT — they must not enter the archive" >&2
        echo "mkrootfs: run as root, or first:  sudo $HERE/umount-chroot.sh $ROOT" >&2
        exit 1
    fi
    echo "== rootfs: unmounting chroot pseudo-fs (must not enter the archive)"
    bash "$HERE/umount-chroot.sh" "$ROOT"
fi

# ---- sanity: this must look like a finished system ------------------------
bad=0
for f in usr/bin/bash usr/bin/dpm usr/lib/libc.so.6 usr/bin/gcc; do
    [[ -e $ROOT/$f ]] || { echo "mkrootfs: ERROR: /$f missing in $ROOT" >&2; bad=1; }
done
[[ -d $ROOT/var/lib/dpm/local ]] || { echo "mkrootfs: ERROR: no dpm database in $ROOT (var/lib/dpm/local)" >&2; bad=1; }
for d in opt/seed opt/cargo opt/rustup opt/cross-tools build build3 mydistro; do
    [[ -e $ROOT/$d ]] && { echo "mkrootfs: ERROR: /$d (bootstrap/build leftover) is in $ROOT" >&2; bad=1; }
done
(( bad == 0 )) || { echo "mkrootfs: $ROOT is not a finished, clean root — refusing to pack it" >&2; exit 1; }
# not an error: a rootfs without rust is a valid system, it just cannot seed
# a later build (seed-from-rootfs.sh enforces that on the consuming side)
for f in usr/bin/rustc usr/bin/cargo; do
    [[ -e $ROOT/$f ]] || echo "mkrootfs: NOTE: /$f is missing — this rootfs cannot be used as a build seed" >&2
done

# ---- pack -------------------------------------------------------------------
# * --numeric-owner: ids, not names (the host's passwd is not the target's)
# * --xattrs/--acls: file capabilities (e.g. ping) survive the round trip
# * --sort=name: stable member order (diffable listings)
# * --one-file-system: a stray bind mount cannot drag host data in
# * the excludes keep the mountpoint DIRECTORIES but not their content, plus
#   everything that is build scratch / seed leftover in a single-root layout
mkdir -p "$(dirname "$OUT")"
TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT
echo "== rootfs: packing $ROOT (zstd -$LEVEL)"
tar --create --numeric-owner --xattrs --acls --sort=name --one-file-system \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
    --exclude='./run/*'  --exclude='./tmp/*' \
    --exclude='./build'  --exclude='./build3' --exclude='./mydistro' \
    --exclude='./sources' --exclude='./.dpm' --exclude='./sysroot' \
    --exclude='./lost+found' \
    -C "$ROOT" . \
  | zstd -q -T"$THREADS" -"$LEVEL" -o "$TMP" -f
mv -f "$TMP" "$OUT"
trap - EXIT

# ---- sidecars -----------------------------------------------------------------
# .sha256 is `sha256sum -c` compatible and is what stage1 verifies before it
# unpacks the file as a seed; .packages is a human-readable inventory
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
PKGLIST="${OUT%.tar.zst}.packages"
ls "$ROOT/var/lib/dpm/local" 2>/dev/null | sort > "$PKGLIST"

# ---- validation: it must decompress and contain what a consumer needs --------
echo "== rootfs: validating the archive"
zstd -t -q "$OUT" || { echo "mkrootfs: ERROR: $OUT failed its zstd integrity test" >&2; exit 1; }
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
zstd -dc "$OUT" | tar -t > "$LIST"
for member in ./usr/bin/bash ./usr/bin/dpm ./usr/lib/libc.so.6 ./etc/passwd; do
    # exact, whole-line match: a member name must not match by substring
    grep -qxF -- "$member" "$LIST" || {
        echo "mkrootfs: ERROR: validation failed: '$member' is not in $OUT" >&2
        exit 1; }
done
for leaked in ./opt/seed ./build ./build3 ./mydistro ./sysroot; do
    if grep -qE -- "^${leaked//./\\.}(/|$)" "$LIST"; then
        echo "mkrootfs: ERROR: validation failed: $leaked leaked into $OUT" >&2
        exit 1
    fi
done
echo "== rootfs: OK ($(wc -l < "$LIST") members, $(wc -l < "$PKGLIST") packages)"
echo "== rootfs: done -> $OUT ($(du -h "$OUT" | cut -f1))"
echo "== rootfs: sha256 $(cut -d' ' -f1 "$OUT.sha256")"
