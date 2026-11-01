#!/usr/bin/env bash
# bootstrap/verify-reproducible.sh — is the self-hosted core a fixed point?
#
#   sudo bootstrap/verify-reproducible.sh [--strict] run TARGET
#   bootstrap/verify-reproducible.sh        compare DIR_A DIR_B
#
# stage 2 is built by the SEED's compiler and stage 3 by OUR compiler, so
# stage 2 and stage 3 differ by design — comparing them proves nothing. The
# meaningful check is stage 3 against stage 4: the same packages built again by
# the stage-3 toolchain. If both are byte-identical the core is a fixed point
# (the way gcc checks its own 3-stage bootstrap), and nothing of the seed is
# left in what we ship.
#
# `run` takes a TARGET whose stage 3 finished: it keeps stage 3's archives,
# makes them the dependency set, rebuilds the bootstrap set once more with
# stage3-inner.sh (same build path /build3, same SOURCE_DATE_EPOCH logic as
# nawa uses) and compares the two archive sets. It MODIFIES the target (stage 4
# is installed over stage 3): use it on a build you can throw away, for
# instance the scheduled/dispatch run, never before packing a release.
#
# Report only by default (exit 0, differing packages listed); --strict makes a
# difference exit 1. Packages that differ for a known reason (embedded build
# time, ...) are listed in profiles/reproducible-exceptions.txt (one name per
# line) and only reported as such.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STRICT=0
[[ ${1:-} == --strict ]] && { STRICT=1; shift; }
CMD="${1:-}"; shift || true

# compare DIR_A DIR_B: archives (*.nawa.tar.zst) byte for byte, by name
compare() {
    local a="$1" b="$2" f n same=0 diff=() only_a=() only_b=() known=() exc
    [[ -d $a && -d $b ]] || { echo "verify-reproducible: both arguments must be directories" >&2; return 2; }
    exc=" $(grep -hv '^\s*#' "${EXCEPTIONS:-$REPO/profiles/reproducible-exceptions.txt}" 2>/dev/null | tr -s '[:space:]' ' ') "
    for f in "$a"/*.nawa.tar.zst; do
        [[ -e $f ]] || continue
        n="$(basename "$f")"
        if [[ ! -e $b/$n ]]; then only_a+=("$n"); continue; fi
        if cmp -s "$f" "$b/$n"; then same=$((same+1))
        else
            local pkg="${n%%-[0-9]*}"
            if [[ $exc == *" $pkg "* ]]; then known+=("$n"); else diff+=("$n"); fi
        fi
    done
    for f in "$b"/*.nawa.tar.zst; do
        [[ -e $f ]] || continue
        n="$(basename "$f")"; [[ -e $a/$n ]] || only_b+=("$n")
    done
    echo "verify-reproducible: $same identical, ${#diff[@]} differ, ${#known[@]} differ for a known reason, ${#only_a[@]} only in stage 3, ${#only_b[@]} only in stage 4"
    [[ ${#diff[@]}    -eq 0 ]] || printf '  DIFFERS: %s\n' "${diff[@]}"
    [[ ${#known[@]}   -eq 0 ]] || printf '  known:   %s\n' "${known[@]}"
    [[ ${#only_a[@]}  -eq 0 ]] || printf '  only stage 3: %s\n' "${only_a[@]}"
    [[ ${#only_b[@]}  -eq 0 ]] || printf '  only stage 4: %s\n' "${only_b[@]}"
    (( same + ${#known[@]} > 0 )) || { echo "verify-reproducible: no archives to compare" >&2; return 2; }
    [[ ${#diff[@]} -eq 0 && ${#only_a[@]} -eq 0 && ${#only_b[@]} -eq 0 ]]
}

case "$CMD" in
    compare)
        compare "${1:?compare DIR_A DIR_B}" "${2:?compare DIR_A DIR_B}" || rc=$?
        exit "${rc:-0}" ;;
    run)
        TARGET="${1:?usage: verify-reproducible.sh [--strict] run TARGET}"
        [[ $EUID -eq 0 ]] || { echo "verify-reproducible: must run as root" >&2; exit 1; }
        [[ -d $TARGET/build3/out ]] || { echo "verify-reproducible: $TARGET/build3/out missing — stage 3 has not finished" >&2; exit 1; }
        bash "$HERE/sync-repo.sh" "$TARGET"
        bash "$HERE/ensure-chroot-mounts.sh" "$TARGET"
        FINAL_ROOT="${FINAL_ROOT:-/sysroot}"
        rm -rf "${TARGET:?}/build3.stage3"
        bash "$HERE/enter-root.sh" "$TARGET" /usr/bin/env -i \
            HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM="${TERM:-dumb}" NAWA_JOBS="${NAWA_JOBS:-4}" \
            STAGE3_WORLD=1 STAGE3_ISOLATION="${STAGE3_ISOLATION:-closure}" FINAL_ROOT="$FINAL_ROOT" \
            bash -c 'set -e
                mv /build3/out /build3.stage3
                cp -a /build3.stage3/. /build/out/     # stage 3 becomes the dependency set
                rm -rf /build3
                bash /faseela/bootstrap/stage3-inner.sh'
        rc=0; compare "$TARGET/build3.stage3" "$TARGET/build3/out" || rc=$?
        if (( rc != 0 && STRICT )); then exit 1; fi
        exit 0 ;;
    *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
