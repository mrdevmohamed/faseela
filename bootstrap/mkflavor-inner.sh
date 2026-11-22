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
SERVICES="${FLAVOR_SERVICES:-/faseela-flavor.services}"
KEY="${FLAVOR_KEY:-/faseela-nawa.pub}"
FROM="${FLAVOR_FROM:-repo}"
# overridable so tests can run this against a throwaway tree with a stub nawa
FASEELA="${FASEELA:-/faseela}"

# shellcheck source=final-root.sh
. "$FASEELA/bootstrap/final-root.sh"
final_root_enabled || { echo "mkflavor-inner: FINAL_ROOT is not set" >&2; exit 1; }
[[ -s $ORDER ]] || { echo "mkflavor-inner: $ORDER is missing or empty" >&2; exit 1; }
[[ -f $SERVICES ]] || { echo "mkflavor-inner: $SERVICES is missing" >&2; exit 1; }

# The seed rootfs is the PREVIOUS release's, so its nawa can predate the
# schema-v5 recipes ([relations] tables and their source marker) and the v5
# index, and refuses both. Install the nawa pinned by recipes/base/nawa first,
# compiled with the seed's own cargo exactly as stage2-inner.sh does.
# FLAVOR_BUILD_NAWA=0 skips it (tests drive this script with a stub nawa).
install_pinned_nawa() {
    [[ ${FLAVOR_BUILD_NAWA:-1} == 0 ]] && return 0
    local src="$FASEELA/nawa" stamp="${FLAVOR_NAWA_STAMP:-/var/lib/faseela-nawa.pinned}" want
    [[ -f $src/Cargo.toml && -f $src/Cargo.lock ]] || return 0
    want=$(cat "$src/.pinned-sha256" 2>/dev/null || true)
    if [[ -n $want && -f $stamp && "$(cat "$stamp")" == "$want" ]]; then
        echo "== flavor: nawa already at the pinned source"
        return 0
    fi
    echo "== flavor: building the pinned nawa (the seed's may not read schema v5)"
    (
        export PATH="${FLAVOR_CARGO_DIR:+$FLAVOR_CARGO_DIR:}/opt/cargo/bin:$PATH"
        command -v cargo >/dev/null 2>&1 \
            || { echo "mkflavor-inner: no cargo in the seed: cannot build the pinned nawa" >&2; exit 1; }
        cd "$src"
        cargo fetch --locked
        cargo build --release --offline --locked
        install -Dm755 target/release/nawa "$NAWA_BIN"
    )
    "$NAWA_BIN" --version
    [[ -n $want ]] && { mkdir -p "$(dirname "$stamp")"; printf '%s\n' "$want" > "$stamp"; }
    return 0
}
install_pinned_nawa

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
# In repo mode every selected package must already exist as an archive, and
# its runtime dependencies are already ordered in the flavor closure. In auto
# mode, however, a missing package is compiled on demand: do NOT pass
# --no-deps, because that also suppresses its [depends].build toolchain (e.g.
# Meson for systemd), leaving configure to fail with "command not found".
install_flags=(--yes --from "$FROM")
if [[ $FROM != auto ]]; then
    install_flags+=(--no-deps)
fi
while IFS= read -r pkg; do
    [[ -n $pkg ]] || continue
    echo "== flavor: $pkg"
    if "$NAWA_BIN" --recipes "$FASEELA/recipes" --root "$FINAL_ROOT" \
            install "${install_flags[@]}" "${repo[@]}" "$pkg"; then
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

# Apply the flavor service policy only after all selected service packages are
# present. Disable conflicting units first; absent units are harmless, while a
# requested unit that cannot be enabled must fail the image build.
# systemctl works offline on a root directory: it only manages the unit
# symlinks. FLAVOR_SYSTEMCTL overrides it (the tests use a stub); otherwise the
# host's systemctl is used, or the image's own through chroot.
systemctl_root() {
    if [[ -n ${FLAVOR_SYSTEMCTL:-} ]]; then
        "$FLAVOR_SYSTEMCTL" --root "$FINAL_ROOT" "$@"
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl --root="$FINAL_ROOT" "$@"
    else
        chroot "$FINAL_ROOT" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin systemctl "$@"
    fi
}
while read -r action service extra; do
    [[ -n ${action:-} ]] || continue
    [[ -z ${extra:-} ]] || {
        echo "mkflavor-inner: malformed service action: $action $service $extra" >&2
        exit 1
    }
    unit="$service"
    [[ $unit == *.* ]] || unit="$unit.service"
    case "$action" in
        disable)
            if systemctl_root is-enabled "$unit" >/dev/null 2>&1; then
                echo "== flavor: disable service $service"
                systemctl_root disable "$unit"
            fi
            ;;
        enable)
            echo "== flavor: enable service $service"
            systemctl_root enable "$unit"
            ;;
        *)
            echo "mkflavor-inner: unknown service action '$action' for '$service'" >&2
            exit 1
            ;;
    esac
done < "$SERVICES"

finalize_final_root

# revdep: every library a shipped binary needs must be provided by a package of
# the image. This is what catches a recipe whose depends.run misses a library
# (the repository happily installs it, the system then fails at runtime).
verify_final_root_needed_resolved "$FINAL_ROOT" || {
    echo "mkflavor-inner: binaries in the image need libraries that no installed package provides" >&2
    echo "mkflavor-inner: add the package providing it to that recipe's depends.run in faseela-repo" >&2
    exit 1
}

# nawa keeps every installed archive for rollback, and the downloaded ones in
# the remote cache: an image never rolls back, and the copies double its size.
rm -rf "${FINAL_ROOT:?}"/var/cache/nawa/*
echo "== flavor: $n packages installed into $FINAL_ROOT"
