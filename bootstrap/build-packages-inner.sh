#!/usr/bin/env bash
# bootstrap/build-packages-inner.sh — runs INSIDE a rootfs (invoked by
# .github/workflows/packages.yml via enter-root.sh): build the packages named
# in $PKGS with nawa and leave the archives in /build/out.
#
#   package NOT installed yet -> `nawa install --yes`: builds it AND every
#                                missing dependency from the recipes
#   package already installed -> `nawa build --install --force`: rebuilds just
#                                this one (its dependencies are in the rootfs)
#
# Env: PKGS (space-separated names), ISOLATION (none|env|sandbox|closure),
#      NAWA_JOBS
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
REPO=/mydistro
: "${PKGS:?PKGS is empty}"
ISOLATION="${ISOLATION:-sandbox}"

nawa() {
    /usr/bin/nawa --recipes "$REPO/recipes" --profiles "$REPO/profiles" \
        --builddir /build --jobs "${NAWA_JOBS:-4}" "$@"
}

mkdir -p /build/out
failed=()
for p in $PKGS; do
    echo "::group::nawa: $p (isolation=$ISOLATION)"
    if [[ -d /var/lib/nawa/local/$p ]]; then
        nawa build --install --force --isolation "$ISOLATION" "$p" || failed+=("$p")
    else
        nawa install --yes --force --isolation "$ISOLATION" "$p" || failed+=("$p")
    fi
    echo "::endgroup::"
done

echo "== built archives:"
ls -l /build/out/*.nawa.tar.zst 2>/dev/null || true
if (( ${#failed[@]} )); then
    echo "build-packages: FAILED: ${failed[*]}" >&2
    exit 1
fi
