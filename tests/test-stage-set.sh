#!/usr/bin/env bash
# tests/test-stage-set.sh — what stages 2/3 build: bootstrap/stage-set.sh writes
# <target>/faseela/bootstrap.set from a flavor, final-root.sh's filter_stage_set
# restricts a package order to it. The RESOLVER (scripts/flavor.py) belongs to
# faseela-repo and is tested there: here it is a stub, so this checks the
# plumbing only.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

# a throwaway faseela tree: the real stage-set.sh next to a stub resolver
mk() {
    rm -rf "$W/r" "$W/t"; mkdir -p "$W/r/bootstrap" "$W/r/scripts" "$W/r/recipes/x/a" "$W/t"
    cp "$REPO/bootstrap/stage-set.sh" "$W/r/bootstrap/"
    cat > "$W/r/scripts/flavor.py" <<'PY'
import sys
# flavor.py --flavors F resolve NAME --recipes R
if sys.argv[-5:-3] == ["resolve", "boom"] or "boom" in sys.argv:
    sys.exit(1)
print("glibc\ngcc\nnawa")
PY
    : > "$W/r/flavors.toml"
}
run() { ( . "$W/r/bootstrap/stage-set.sh"; "$@" ); }

mk
run write_stage_set "$W/t" >"$W/out" 2>&1
check "bootstrap set is written"            "[[ \$(cat $W/t/faseela/bootstrap.set) == \$'glibc\ngcc\nnawa' ]]"
check "it names the flavor and the count"   "grep -q \"flavor 'bootstrap' only: 3\" $W/out"

STAGE_SET=all run write_stage_set "$W/t" >"$W/out" 2>&1
check "STAGE_SET=all removes the set file"  "[[ ! -e $W/t/faseela/bootstrap.set ]]"

mk; rm "$W/r/flavors.toml"
run write_stage_set "$W/t" >"$W/out" 2>&1
check "no flavors.toml -> whole graph, warns" "[[ ! -e $W/t/faseela/bootstrap.set ]] && grep -q 'building the whole recipe graph' $W/out"

mk
STAGE_SET=boom run write_stage_set "$W/t" >"$W/out" 2>&1
check "an unresolvable flavor is an error"  "! STAGE_SET=boom bash -c '. $W/r/bootstrap/stage-set.sh; write_stage_set $W/t' && [[ ! -e $W/t/faseela/bootstrap.set ]]"

# filter_stage_set
export REPO="$W/f"; mkdir -p "$REPO"
. <(sed -n '/^filter_stage_set()/,/^}/p' "$(dirname "$0")/../bootstrap/final-root.sh")
printf 'glibc\nnawa\n' > "$REPO/bootstrap.set"
check "filter keeps only set members, in order" "[[ \$(printf 'vim\nglibc\ngcc\nnawa\n' | filter_stage_set) == \$'glibc\nnawa' ]]"
check "filter with no match is not an error"    "printf 'vim\n' | filter_stage_set | wc -l | grep -qx 0 && { printf 'vim\n' | filter_stage_set; true; }"
rm "$REPO/bootstrap.set"
check "no set file -> everything passes"        "[[ \$(printf 'vim\ngcc\n' | filter_stage_set) == \$'vim\ngcc' ]]"

echo; echo "test-stage-set: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
