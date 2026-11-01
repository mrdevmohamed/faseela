#!/usr/bin/env bash
# bootstrap/mkflavor-inner.sh — runs INSIDE the build root (invoked by
# mkflavor.sh): install the packages listed in /faseela-flavor.order (one per
# line, dependencies first) from the package repository into the empty root
# $FINAL_ROOT, one `nawa install` per package so hooks run as soon as the
# chroot is usable (the same loop mkrootfs-min-inner.sh runs over archives).
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
NAWA_BIN="${NAWA_BIN:-/usr/bin/nawa}"
ORDER="${FLAVOR_ORDER:-/faseela-flavor.order}"
KEY="${FLAVOR_KEY:-/faseela-nawa.pub}"
FROM="${FLAVOR_FROM:-repo}"
# overridable so tests can run this against a throwaway tree with a stub nawa
FASEELA="${FASEELA:-/faseela}"

# shellcheck source=final-root.sh
. "$FASEELA/bootstrap/final-root.sh"
final_root_enabled || { echo "mkflavor-inner: FINAL_ROOT is not set" >&2; exit 1; }
[[ -s $ORDER ]] || { echo "mkflavor-inner: $ORDER is missing or empty" >&2; exit 1; }

repo=()
[[ -n ${FLAVOR_REPO:-} ]] && repo=(--repo "$FLAVOR_REPO")

# A remote repository is only used when its index signature is trusted:
# trust the distribution key for this run AND in the image (so the installed
# system can `nawa upgrade` from the same repository).
if [[ -r $KEY ]]; then
    for r in "" "$FINAL_ROOT"; do
        "$NAWA_BIN" --root "${r:-/}" trust "$KEY"
    done
fi

repair_final_layout
n=0 missing=()
while IFS= read -r pkg; do
    [[ -n $pkg ]] || continue
    echo "== flavor: $pkg"
    if "$NAWA_BIN" --recipes "$FASEELA/recipes" --root "$FINAL_ROOT" \
            install --no-deps --from "$FROM" "${repo[@]}" "$pkg"; then
        n=$((n+1))
    else
        missing+=("$pkg")
        # nothing after a failed package can be trusted to install cleanly
        break
    fi
done < "$ORDER"

if (( ${#missing[@]} )); then
    echo "mkflavor-inner: could not install ${missing[*]} from the repository." >&2
    echo "mkflavor-inner: build and publish it first (faseela-repo > Actions > Build packages > packages: flavor:<name>)," >&2
    echo "mkflavor-inner: or retry with --from auto to build what is missing from the recipes (slow)." >&2
    exit 1
fi

finalize_final_root

# nawa keeps every installed archive for rollback, and the downloaded ones in
# the remote cache: an image never rolls back, and the copies double its size.
rm -rf "${FINAL_ROOT:?}"/var/cache/nawa/*
echo "== flavor: $n packages installed into $FINAL_ROOT"
