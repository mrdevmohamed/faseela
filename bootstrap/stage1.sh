#!/usr/bin/env bash
# bootstrap/stage1.sh — STAGE 1: prepare the chroot and verify the seed.
#
# 1. unpack the seed into $LFS
# 2. mount virtual filesystems, DNS + CA bundle for the chroot
# 3. chroot and verify that the seed toolchain compiles/links/runs C, C++
#    and Rust (the seed's native toolchain IS the temporary toolchain;
#    stage2 builds the real one from the recipes)
#
# Requirements: run as root (or with fakeroot-less bind mount privileges).
# Usage: sudo ./stage1.sh /mnt/mydistro
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
LFS="${1:?usage: stage1.sh /mnt/mydistro}"
[[ "$(realpath -m "$LFS")" != "/" ]] || { echo "stage1: refusing to use / as the target"; exit 1; }
SEED="$HERE/seed/seed.tar.zst"

[[ $EUID -eq 0 ]] || { echo "stage1: must run as root"; exit 1; }
[[ -f $SEED ]] || { echo "stage1: seed missing — run seed/build-seed.sh first"; exit 1; }

echo "== stage1: unpacking seed into $LFS"
mkdir -p "$LFS"
tar -xf "$SEED" -C "$LFS"
[[ -x "$LFS/usr/bin/env" && -x "$LFS/usr/bin/bash" ]] || {
    echo "stage1: seed looks incomplete (no /usr/bin/env or bash) — rebuild it with seed/build-seed.sh"; exit 1; }

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

# copy repo + recipes into the chroot
mkdir -p "$LFS/mydistro"
cp -a "$REPO/pkgmgr" "$REPO/recipes" "$REPO/profiles" "$REPO/bootstrap" "$LFS/mydistro/"

bash "$HERE/enter-root.sh" "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-xterm}" DPM_JOBS="${DPM_JOBS:-4}" \
    LFS=/ LFS_TGT="$(uname -m)-mydistro-linux-gnu" \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    bash -c '. /opt/seed/env.sh && bash /mydistro/bootstrap/stage1-inner.sh'

echo "== stage1: chroot ready, seed toolchain verified"
