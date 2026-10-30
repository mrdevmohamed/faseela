#!/usr/bin/env bash
# bootstrap/seed-from-rootfs.sh — turn an UNPACKED rootfs of this distribution
# (the artifact mkrootfs.sh publishes next to the ISO) into a bootstrap seed,
# i.e. make it look to stages 1-3 like the root the Debian seed would give.
#
# Called by stage1.sh right after it unpacked the tarball into TARGET. What the
# later stages need, and what this script provides:
#
#   * a working toolchain (gcc, make, python, perl, curl, rustc/cargo, ...)
#     — verified here, loudly, before any hour of compiling is spent;
#   * an EMPTY dpm database. The rootfs was a finished system, so its db
#     records every package as installed and stage 2 (which skips what the db
#     records) would build NOTHING. The old db is parked in
#     var/lib/dpm/seed-local instead. Files without a db owner are exactly how
#     stage 3's self-host proof recognises "left over from the seed", so the
#     semantics of the Debian seed are kept: after stage 2 every package is
#     rebuilt by the previous release's toolchain, after stage 3 by its own;
#   * /opt/seed/env.sh (sourced by stage 1/2) and /opt/seed/manifest.txt
#     (provenance: which rootfs seeded this build). stage 3 deletes /opt/seed
#     like it does for the Debian seed — and the final root never sees it.
#
# Usage: seed-from-rootfs.sh ROOT [ROOTFS_TARBALL]
#   ROOT            the unpacked rootfs (the build root, e.g. /mnt/mydistro)
#   ROOTFS_TARBALL  only used for the provenance record
set -euo pipefail

ROOT="${1:?usage: seed-from-rootfs.sh ROOT [ROOTFS_TARBALL]}"
SRC="${2:-}"
[[ -d $ROOT ]] || { echo "seed-from-rootfs: $ROOT is not a directory" >&2; exit 1; }

# ---- 1) is it a usable seed? ------------------------------------------------
missing=()
for f in usr/bin/env usr/bin/bash usr/bin/sh usr/bin/dpm usr/lib/libc.so.6 \
         usr/bin/gcc usr/bin/g++ usr/bin/make usr/bin/ld usr/bin/ldconfig \
         usr/bin/python3 usr/bin/perl usr/bin/curl usr/bin/pkg-config \
         usr/bin/rustc usr/bin/cargo; do
    [[ -e $ROOT/$f || -L $ROOT/$f ]] || missing+=("/$f")
done
# the gcc driver alone is not a compiler: cc1/cc1plus must be there too
for cc in cc1 cc1plus; do
    compgen -G "$ROOT/usr/libexec/gcc/*/*/$cc" >/dev/null \
      || compgen -G "$ROOT/usr/lib/gcc/*/*/$cc" >/dev/null \
      || missing+=("/usr/libexec/gcc/*/*/$cc")
done
if (( ${#missing[@]} > 0 )); then
    echo "seed-from-rootfs: this rootfs cannot seed a build — missing: ${missing[*]}" >&2
    echo "seed-from-rootfs: it must come from a full build of this distribution" >&2
    echo "seed-from-rootfs: (base-devel + rust + curl + python + perl)." >&2
    exit 1
fi
# the Debian seed marker: a rootfs that still has one was not built by us
if [[ -e $ROOT/opt/seed/manifest.txt ]] && grep -q 'debian packages' "$ROOT/opt/seed/manifest.txt" 2>/dev/null; then
    echo "seed-from-rootfs: $ROOT looks like the Debian seed, not a distro rootfs" >&2
    exit 1
fi

# ---- 2) park the package database ------------------------------------------
DB="$ROOT/var/lib/dpm/local"
PARKED="$ROOT/var/lib/dpm/seed-local"
# idempotent: a second run (resumed stage 1) finds the db already empty and
# must keep the parked copy instead of replacing it with that empty one
npkgs=0
if [[ -d $DB ]] && [[ -n "$(ls -A "$DB" 2>/dev/null)" ]]; then
    rm -rf "$PARKED"
    mv "$DB" "$PARKED"
fi
mkdir -p "$DB"
# rollback records of the previous build refer to versions of THAT db; with the
# db reset they would point at packages this root does not record
rm -rf "$ROOT/var/lib/dpm/undo"
if [[ -d $PARKED ]]; then
    npkgs="$(find "$PARKED" -mindepth 1 -maxdepth 1 -type d | wc -l)"
fi

# ---- 3) env.sh + provenance --------------------------------------------------
mkdir -p "$ROOT/opt/seed"
cat > "$ROOT/opt/seed/env.sh" <<'EOF'
# sourced inside the chroot during stage1/2 (rootfs seed: the toolchain lives
# in /usr, there is no /opt/cargo or /opt/rustup to put on PATH)
export DPM_JOBS="${DPM_JOBS:-4}"
EOF
{
    echo "# mydistro bootstrap seed manifest (ROOTFS seed — self-hosting build)"
    echo "kind = rootfs"
    echo "prepared-utc = $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host = $(uname -srm)"
    echo "seed-builder = bootstrap/seed-from-rootfs.sh"
    if [[ -n $SRC && -f $SRC ]]; then
        echo "rootfs = $(basename -- "$SRC")"
        echo "rootfs-size = $(stat -c %s "$SRC")"
        if [[ -f $SRC.sha256 ]]; then echo "rootfs-sha256 = $(cut -d' ' -f1 "$SRC.sha256")"; fi
    fi
    echo "rustc = $(chroot "$ROOT" /usr/bin/rustc --version 2>/dev/null || echo unknown)"
    echo ""
    echo "# packages the rootfs was built from ($npkgs; its db is parked in /var/lib/dpm/seed-local):"
    ls "$PARKED" 2>/dev/null || true
} > "$ROOT/opt/seed/manifest.txt"

echo "== seed-from-rootfs: $ROOT is a rootfs seed ($npkgs packages parked, db reset: stage 2 rebuilds the graph)"
