#!/usr/bin/env bash
# bootstrap/stage3.sh — STAGE 3: self-hosting rebuild.
#
# Rebuilds packages with the distro's OWN toolchain (installed in stage2),
# then removes the seed toolchain (/opt): after this stage the distro
# builds itself.
#
# Rebuild scope:
#   default           the recipes/toolchain set (fast self-host proof)
#   STAGE3_WORLD=1    the ENTIRE recipe graph (add WITH_GUI=1 to include recipes/gui)
#
# NOTE: the distro does not ship rustc yet — NAWA stays as the seed-built
# binary (recorded in the db).
#
# Usage (from the host): sudo ./stage3.sh /mnt/faseela
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LFS="${1:?usage: stage3.sh /mnt/faseela}"
[[ $EUID -eq 0 ]] || { echo "stage3: must run as root"; exit 1; }

# refresh the repo copy inside the chroot (merge semantics; excludes the seed
# tarball and the host's cargo output — see sync-repo.sh)
bash "$HERE/sync-repo.sh" "$LFS"

# what to rebuild: the same set stage 2 built (see stage-set.sh)
. "$HERE/stage-set.sh"
write_stage_set "$LFS"

# self-heal: same reason as stage2 — the stage-1 mounts die with the session
# while the stamp survives; without /proc inside the target, user-namespace
# setup in nawa's sandbox (writes /proc/self/uid_map) fails too
bash "$HERE/ensure-chroot-mounts.sh" "$LFS"

# two-root layout (see stage2.sh / final-root.sh); SINGLE_ROOT=1 = legacy
if [[ "${SINGLE_ROOT:-0}" == "1" ]]; then
    FINAL_ROOT=""
else
    FINAL_ROOT="${FINAL_ROOT:-/sysroot}"
    [[ $FINAL_ROOT == /* && $FINAL_ROOT != / ]] || { echo "stage3: FINAL_ROOT must be an absolute path other than /" >&2; exit 1; }
    mkdir -p "$LFS$FINAL_ROOT"
fi

# Resolve targeted Toolchain requests on the host; the target does not need Python.
# Nawa supplies the authoritative dependency order from the installed build root.
STAGE3_RESOLVED_PACKAGES=""
if [[ -n "$STAGE3_PACKAGES" ]]; then
    [[ "$STAGE3_WORLD" != "1" ]] || {
        echo "stage3: STAGE3_PACKAGES cannot be combined with STAGE3_WORLD=1" >&2
        exit 1
    }
    FULL_ORDER="$(bash "$HERE/enter-root.sh" "$LFS" /usr/bin/nawa \
        --recipes /faseela/recipes deps-all --include-installed)" || {
        echo "stage3: cannot obtain Nawa's dependency order for a selective Toolchain update" >&2
        exit 1
    }
    STAGE3_RESOLVED_PACKAGES="$(printf '%s\n' "$FULL_ORDER" | \
        python3 "$HERE/select-stage3.py" --recipes "$LFS/faseela/recipes" \
            --packages "$STAGE3_PACKAGES")" || exit 1
    [[ -n "$STAGE3_RESOLVED_PACKAGES" ]] || {
        echo "stage3: selective Toolchain request resolved to an empty package set" >&2
        exit 1
    }
    echo "stage3: resolved Toolchain order:"
    printf '  %s\n' "$STAGE3_RESOLVED_PACKAGES"
fi

# NOTE: /opt/cargo/bin is intentionally NOT in the inner PATH — stage3-inner
# verifies the system can rebuild itself with ONLY what it ships.
# The inner script lives in its own file (like stage1-inner/stage2-inner) so
# bash -n / shellcheck cover it, and so it never competes for stdin with the
# commands it runs.
bash "$HERE/enter-root.sh" "$LFS" /usr/bin/env -i \
    HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin TERM="${TERM:-dumb}" NAWA_JOBS="${NAWA_JOBS:-4}" STAGE3_WORLD="${STAGE3_WORLD:-0}" STAGE3_RESOLVED_PACKAGES="$STAGE3_RESOLVED_PACKAGES" WITH_GUI="${WITH_GUI:-0}" STAGE_SKIP="${STAGE_SKIP:-}" \
    STAGE3_ISOLATION="${STAGE3_ISOLATION:-none}" \
    FINAL_ROOT="$FINAL_ROOT" \
    bash /faseela/bootstrap/stage3-inner.sh

echo "== stage3: complete"
