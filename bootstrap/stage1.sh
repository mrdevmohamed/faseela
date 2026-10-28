#!/usr/bin/env bash
# bootstrap/stage1.sh — STAGE 1: prepare the chroot and verify the seed.
#
# 1. unpack the seed into $LFS — the Debian-based seed.tar.zst, OR (when
#    SEED_ROOTFS=<file> is set) the rootfs tarball a previous build published
#    (mkrootfs.sh): the distribution then builds itself with its own toolchain
#    and seed-from-rootfs.sh adapts that rootfs to what stages 2-3 expect
# 2. mount virtual filesystems, DNS + CA bundle for the chroot
# 3. chroot and verify that the seed toolchain compiles/links/runs C, C++
#    and Rust (the seed's native toolchain IS the temporary toolchain;
#    stage2 builds the real one from the recipes)
#
# Requirements: run as root (or with fakeroot-less bind mount privileges).
# Usage: sudo ./stage1.sh /mnt/mydistro
#        sudo SEED_ROOTFS=out/mydistro-x86_64-rootfs.tar.zst ./stage1.sh /mnt/mydistro
# Env: SEED_ROOTFS         rootfs tarball to use as the seed instead of seed.tar.zst
#      SEED_ROOTFS_SHA256  expected sha256 of SEED_ROOTFS (checked in addition
#                          to the .sha256 sidecar, which is checked when present)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LFS="${1:?usage: stage1.sh /mnt/mydistro}"
[[ "$(realpath -m "$LFS")" != "/" ]] || { echo "stage1: refusing to use / as the target"; exit 1; }
SEED_ROOTFS="${SEED_ROOTFS:-}"
if [[ -n $SEED_ROOTFS ]]; then
    SEED="$(realpath -m -- "$SEED_ROOTFS")"
    SEED_KIND=rootfs
else
    SEED="$HERE/seed/seed.tar.zst"
    SEED_KIND=debian
fi
SEED_SHA256="$SEED.sha256"   # sidecar written by build-seed.sh / mkrootfs.sh

[[ $EUID -eq 0 ]] || { echo "stage1: must run as root"; exit 1; }
if [[ ! -f $SEED ]]; then
    if [[ $SEED_KIND == rootfs ]]; then echo "stage1: rootfs seed not found: $SEED"
    else echo "stage1: seed missing — run seed/build-seed.sh first"; fi
    exit 1
fi
echo "== stage1: seed kind: $SEED_KIND ($SEED)"

# verify the seed BEFORE unpacking it over $LFS: a truncated or corrupt
# tarball used to surface as a confusing error deep inside the unpack (or,
# worse, as a half-unpacked root on resume). zstd -t checks the frame CRC;
# the sidecar (when present — hand-built seeds may lack it) pins the exact
# artifact build-seed.sh produced.
command -v zstd >/dev/null 2>&1 || { echo "stage1: zstd not found on the host (required to unpack the seed)"; exit 1; }
if ! zstd -t "$SEED" 2>/dev/null; then
    echo "stage1: seed failed its zstd integrity check: $SEED" >&2
    echo "stage1: rebuild it:  bootstrap/seed/build-seed.sh   (or delete it and re-run build-all.sh)" >&2
    exit 1
fi
if [[ -f $SEED_SHA256 ]]; then
    if ! (cd "$(dirname "$SEED")" && sha256sum -c --quiet "$(basename "$SEED").sha256"); then
        echo "stage1: seed sha256 mismatch against $SEED_SHA256 — the tarball changed" >&2
        echo "stage1: since it was built. Rebuild it with bootstrap/seed/build-seed.sh." >&2
        exit 1
    fi
else
    echo "stage1: NOTE: no sha256 sidecar for the seed — proceeding unverified (hand-built seed?)" >&2
fi
# an explicit pin (e.g. the hash published in the release notes) beats the
# sidecar, which travels WITH the file and therefore proves only integrity
if [[ -n ${SEED_ROOTFS_SHA256:-} ]]; then
    got="$(sha256sum "$SEED" | cut -d' ' -f1)"
    if [[ $got != "${SEED_ROOTFS_SHA256,,}" ]]; then
        echo "stage1: sha256 of $SEED is $got, expected $SEED_ROOTFS_SHA256" >&2
        exit 1
    fi
    echo "stage1: seed sha256 matches the pinned value"
fi
# provenance: print what the seed records about itself, if anything
manifest_head="$(tar -xOf "$SEED" ./opt/seed/manifest.txt 2>/dev/null | head -8 || true)"
if [[ -n $manifest_head ]]; then printf '%s\n' "$manifest_head"; fi

echo "== stage1: unpacking seed into $LFS"
mkdir -p "$LFS"
if [[ $SEED_KIND == rootfs ]]; then
    # a rootfs seed is a whole system and must come back exactly as
    # mkrootfs.sh packed it (numeric ids, file capabilities)
    tar -xf "$SEED" -C "$LFS" --numeric-owner --xattrs --acls
else
    tar -xf "$SEED" -C "$LFS"
fi
[[ -x "$LFS/usr/bin/env" && -x "$LFS/usr/bin/bash" ]] || {
    echo "stage1: seed looks incomplete (no /usr/bin/env or bash) — rebuild it with seed/build-seed.sh"; exit 1; }
if [[ $SEED_KIND == rootfs ]]; then
    # verify it is a usable seed, reset the package db, write env.sh/manifest
    bash "$HERE/seed-from-rootfs.sh" "$LFS" "$SEED"
fi

echo "== stage1: mounting virtual filesystems"
# no `|| true` anymore: ensure-chroot-mounts.sh is idempotent and fails
# LOUDLY if a mount fails (the old silent block let a dead /proc reach
# stage2, where rustup proxies died on "no /proc/self/exe available")
bash "$HERE/ensure-chroot-mounts.sh" "$LFS"

# --- network inside the chroot -------------------------------------------
# DNS: the seed has no /etc/resolv.conf. Copy the host's (dereferenced; a
# systemd-resolved stub at 127.0.0.53 still works, the chroot shares the
# host network namespace). Fall back to public resolvers if it is unusable.
mkdir -p "$LFS/etc"
rm -f "$LFS/etc/resolv.conf"
if [[ -s /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "$LFS/etc/resolv.conf"
else
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$LFS/etc/resolv.conf"
fi
# TLS: dpkg -x never ran update-ca-certificates, so build the bundle.
CA_BUNDLE="$LFS/etc/ssl/certs/ca-certificates.crt"
if [[ ! -s $CA_BUNDLE ]]; then
    mkdir -p "$(dirname "$CA_BUNDLE")"
    if compgen -G "$LFS/usr/share/ca-certificates/mozilla/*.crt" >/dev/null; then
        cat "$LFS"/usr/share/ca-certificates/mozilla/*.crt > "$CA_BUNDLE"
    elif [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
        cp -L /etc/ssl/certs/ca-certificates.crt "$CA_BUNDLE"
    else
        echo "stage1: WARNING: no CA bundle found, https downloads will fail" >&2
    fi
fi

# copy the build-relevant repo parts into the chroot (excludes the ~1 GB
# seed tarball, seed-root scratch and the host's cargo output — see
# sync-repo.sh)
bash "$HERE/sync-repo.sh" "$LFS"

bash "$HERE/enter-root.sh" "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-xterm}" DPM_JOBS="${DPM_JOBS:-4}" \
    LFS=/ LFS_TGT="$(uname -m)-mydistro-linux-gnu" \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    bash -c '. /opt/seed/env.sh && bash /mydistro/bootstrap/stage1-inner.sh'

echo "== stage1: chroot ready, seed toolchain verified"
