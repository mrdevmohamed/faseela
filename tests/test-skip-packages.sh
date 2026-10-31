#!/usr/bin/env bash
# test-skip-packages.sh — bootstrap/final-root.sh: filter_skipped
# (profiles/skip-packages.txt, STAGE_SKIP). No root, no chroot: the function is
# sourced on its own.
set -uo pipefail
REPO="${FASEELA_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/skip-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

# only the function: final-root.sh does other work when sourced in a chroot
sed -n '/^filter_skipped()/,/^}/p' "$REPO/bootstrap/final-root.sh" > "$W/fn.sh"
check "S0 filter_skipped is defined in final-root.sh" "[[ -s $W/fn.sh ]]"
mkdir -p "$W/repo/profiles"
printf '# comment\nlinux-firmware\n  linux-firmware-extra   # trailing\n\n' > "$W/repo/profiles/skip-packages.txt"
LIST=$'glibc\nlinux\nlinux-firmware\nlinux-firmware-lite\nlinux-firmware-extra\nrust'

run() { ( REPO="$W/repo"; unset STAGE_SKIP; export "$@" 2>/dev/null; source "$W/fn.sh"; printf '%s\n' "$LIST" | filter_skipped ) ; }
out="$( REPO="$W/repo"; unset STAGE_SKIP; source "$W/fn.sh"; printf '%s\n' "$LIST" | filter_skipped )"
check "S1 listed packages are dropped"                    "! grep -qx 'linux-firmware' <<< '$out' && ! grep -qx 'linux-firmware-extra' <<< '$out'"
check "S2 the lite firmware stays (exact names only)"     "grep -qx 'linux-firmware-lite' <<< '$out'"
check "S3 everything else stays, in order"                "[[ \$(tr '\n' ' ' <<< '$out') == 'glibc linux linux-firmware-lite rust ' ]]"
out="$( REPO="$W/repo"; STAGE_SKIP=none; source "$W/fn.sh"; printf '%s\n' "$LIST" | filter_skipped )"
check "S4 STAGE_SKIP=none skips nothing"                  "[[ \$(wc -l <<< '$out') -eq 6 ]]"
out="$( REPO="$W/repo"; STAGE_SKIP='rust glibc'; source "$W/fn.sh"; printf '%s\n' "$LIST" | filter_skipped )"
check "S5 STAGE_SKIP replaces the file"                   "! grep -qx rust <<< '$out' && grep -qx linux-firmware <<< '$out'"
out="$( REPO="$W/none"; unset STAGE_SKIP; source "$W/fn.sh"; printf '%s\n' "$LIST" | filter_skipped )"
check "S6 no skip file: nothing skipped"                  "[[ \$(wc -l <<< '$out') -eq 6 ]]"
check "S7 the shipped list skips the meta + extra firmware, not lite" "grep -qx linux-firmware $REPO/profiles/skip-packages.txt && grep -qx linux-firmware-extra $REPO/profiles/skip-packages.txt && ! grep -qx linux-firmware-lite $REPO/profiles/skip-packages.txt"
echo; echo "  PASS: $PASS   FAIL: $FAIL"; [[ $FAIL -eq 0 ]]
