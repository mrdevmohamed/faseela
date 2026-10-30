#!/usr/bin/env bash
# bootstrap/mkrootfs-min-inner.sh — runs INSIDE the target (invoked by
# mkrootfs-min.sh): install the packages listed in /mydistro-min.order (one
# per line, dependencies first) from the build root's archives into the clean
# root $FINAL_ROOT, using the same helpers as the two-root layout.
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
NAWA_BIN="${NAWA_BIN:-/usr/bin/nawa}"
ORDER="${MIN_ORDER:-/mydistro-min.order}"
# overridable so scripts/test-mkrootfs-min.sh can run this against a throwaway tree
MYDISTRO="${MYDISTRO:-/mydistro}"

# shellcheck source=final-root.sh
. "$MYDISTRO/bootstrap/final-root.sh"
final_root_enabled || { echo "mkrootfs-min-inner: FINAL_ROOT is not set" >&2; exit 1; }
[[ -s $ORDER ]] || { echo "mkrootfs-min-inner: $ORDER is missing or empty" >&2; exit 1; }

n=0
while IFS= read -r pkg; do
    [[ -n $pkg ]] || continue
    archive=$(find_archive "$pkg") || {
        echo "mkrootfs-min-inner: no archive of $pkg in the build root (build3/out, build/out, var/cache/nawa)" >&2
        exit 1; }
    echo "== rootfs-min: $pkg  ($(basename "$archive"))"
    install_final "$archive"
    n=$((n+1))
done < "$ORDER"

finalize_final_root

# nawa copies every installed archive into var/cache/nawa for rollback. A build
# environment never rolls back, and the copies double the size of the tarball.
rm -rf "${FINAL_ROOT:?}"/var/cache/nawa/*
echo "== rootfs-min: $n packages installed into $FINAL_ROOT"
