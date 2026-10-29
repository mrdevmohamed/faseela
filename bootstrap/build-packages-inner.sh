#!/usr/bin/env bash
# bootstrap/build-packages-inner.sh — runs INSIDE a rootfs (invoked by
# .github/workflows/packages.yml via enter-root.sh): build the packages named
# in $PKGS with dpm and leave the archives in /build/out.
#
#   package NOT installed yet -> `dpm install --yes`: builds it AND every
#                                missing dependency from the recipes
#   package already installed -> `dpm build --install --force`: rebuilds just
#                                this one (its dependencies are in the rootfs)
#
# Env: PKGS (space-separated names), ISOLATION (none|env|sandbox|closure),
#      DPM_JOBS
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
REPO=/mydistro
: "${PKGS:?PKGS is empty}"
ISOLATION="${ISOLATION:-sandbox}"

dpm() {
    /usr/bin/dpm --recipes "$REPO/recipes" --profiles "$REPO/profiles" \
        --builddir /build --jobs "${DPM_JOBS:-4}" "$@"
}

mkdir -p /build/out
failed=()
for p in $PKGS; do
    echo "::group::dpm: $p (isolation=$ISOLATION)"
    if [[ -d /var/lib/dpm/local/$p ]]; then
        dpm build --install --force --isolation "$ISOLATION" "$p" || failed+=("$p")
    else
        dpm install --yes --force --isolation "$ISOLATION" "$p" || failed+=("$p")
    fi
    echo "::endgroup::"
done

echo "== built archives:"
ls -l /build/out/*.dpm.tar.zst 2>/dev/null || true
if (( ${#failed[@]} )); then
    echo "build-packages: FAILED: ${failed[*]}" >&2
    exit 1
fi
