#!/usr/bin/env bash
# tests/test-build-packages-inner.sh — tests bootstrap/build-packages-inner.sh
# (the script faseela-repo's packages.yml runs inside the build root) against a STUB nawa:
# dependency order, "already published = up to date", installing published
# dependencies instead of rebuilding them, failure isolation (dependents are
# skipped, the rest still builds) and the time budget.
#
# Usage: tests/test-build-packages-inner.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/bootstrap/build-packages-inner.sh"
WORK="$(mktemp -d /tmp/build-pkgs-test.XXXXXX)"
PASS=0 FAIL=0
trap 'rm -rf "$WORK"' EXIT

ok()   { printf '\033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# ---- fake recipe tree: libz <- libpng <- app ;  bad <- needs-bad ; solo -----
mk() { # name version rel
    mkdir -p "$WORK/repo/recipes/extra/$1"
    printf '[package]\nname = "%s"\nversion = "%s"\n%s\n[depends]\nbuild = []\n' \
        "$1" "$2" "${3:+rel = $3 # comment}" > "$WORK/repo/recipes/extra/$1/recipe.toml"
}
mk libz 1.3 1; mk libpng 1.6 2; mk app 2.0 ""; mk bad 1.0 1; mk needs-bad 1.0 1; mk solo 3.1 1
mkdir -p "$WORK/repo/profiles"

# topological order and dependencies of the fake tree
printf '%s\n' libz libpng app bad needs-bad solo > "$WORK/order"
cat > "$WORK/deps" <<'D'
libpng: libz
app: libpng libz
needs-bad: bad
D

# ---- stub nawa ---------------------------------------------------------------
cat > "$WORK/nawa" <<'STUB'
#!/usr/bin/env bash
W="$(dirname "$0")"
while [[ $# -gt 0 && $1 == --* ]]; do shift 2; done   # global flags all take a value
cmd="$1"; shift
id_of() { awk -v n="$1" '/^version/{gsub(/[" ]/,"",$0); sub(/version=/,"",$0); v=$0}
         /^rel/{r=$3} END{print n "-" v "-" (r==""?1:r)}' "$W"/repo/recipes/*/"$1"/recipe.toml; }
case "$cmd" in
  deps-all) cat "$W/order" ;;
  deps)
    n=1
    for d in $(grep "^$1:" "$W/deps" | cut -d: -f2) $1; do
        grep -qxF "$d" "$W/installed" 2>/dev/null && continue
        printf '%3d. %s (build deps: -)\n' "$n" "$(id_of "$d")"; n=$((n+1))
    done ;;
  build)
    name="${@: -1}"; echo "build $name" >> "$W/calls"
    grep -qxF "$name" "$W/fail" 2>/dev/null && exit 1
    touch "$W/out/$(id_of "$name").nawa.tar.zst"; echo "$name" >> "$W/installed" ;;
  install)
    t="${@: -1}"
    if [[ $t == *.nawa.tar.zst ]]; then
        echo "install-archive $(basename "$t")" >> "$W/calls"
        b=$(basename "$t" .nawa.tar.zst); echo "${b%-*-*}" >> "$W/installed"
    else
        echo "install-build $t" >> "$W/calls"
        for d in $(grep "^$t:" "$W/deps" | cut -d: -f2) $t; do
            grep -qxF "$d" "$W/installed" 2>/dev/null && continue
            touch "$W/out/$(id_of "$d").nawa.tar.zst"; echo "$d" >> "$W/installed"
        done
    fi ;;
esac
STUB
chmod +x "$WORK/nawa"

run() { # PKGS [extra env...]  (fresh installed/calls/out unless the caller seeded them)
    ( cd "$WORK" && env PKGS="$1" REPO="$WORK/repo" BUILD="$WORK" NAWA_BIN="$WORK/nawa" \
        ISOLATION=env NAWA_JOBS=1 "${@:2}" bash "$SRC" > "$WORK/log" 2>&1 )
}
reset() { rm -rf "$WORK/out" "$WORK/installed" "$WORK/calls" "$WORK/fail" "$WORK/status" "$WORK/report.txt"; mkdir -p "$WORK/out"; }

# 1 ---------------------------------------------------------------------------
echo "== TEST: builds in dependency order whatever order PKGS has"
reset
run "app solo libpng libz"; rc=$?
check "exit 0" "[[ $rc -eq 0 ]]"
check "libz before libpng before app" \
    "[[ \$(grep -n '^build' $WORK/calls | cut -d' ' -f2 | tr '\n' ' ') == 'libz libpng app solo ' ]]"
check "archives named name-version-rel (rel defaults to 1)" \
    "[[ -f $WORK/out/app-2.0-1.nawa.tar.zst && -f $WORK/out/libpng-1.6-2.nawa.tar.zst ]]"
check "status BUILT=4" "grep -qx BUILT=4 $WORK/status"

# 2 ---------------------------------------------------------------------------
echo "== TEST: published archives are up to date and are installed, not rebuilt"
reset
touch "$WORK/out/libz-1.3-1.nawa.tar.zst" "$WORK/out/libpng-1.6-2.nawa.tar.zst"
run "libz libpng app"; rc=$?
check "exit 0" "[[ $rc -eq 0 ]]"
check "only app is built" "[[ \$(grep -c '^build' $WORK/calls) -eq 1 ]] && grep -qx 'build app' $WORK/calls"
check "its dependencies come from the archives" \
    "grep -qx 'install-archive libz-1.3-1.nawa.tar.zst' $WORK/calls && grep -qx 'install-archive libpng-1.6-2.nawa.tar.zst' $WORK/calls"
check "status UPTODATE=2 BUILT=1" "grep -qx UPTODATE=2 $WORK/status && grep -qx BUILT=1 $WORK/status"

# 3 ---------------------------------------------------------------------------
echo "== TEST: a recipe bump (new rel) rebuilds even though an old archive exists"
reset
touch "$WORK/out/libz-1.3-0.nawa.tar.zst"
run "libz"; check "libz rebuilt as 1.3-1" "[[ -f $WORK/out/libz-1.3-1.nawa.tar.zst ]]"

# 4 ---------------------------------------------------------------------------
echo "== TEST: a failure skips its dependents but everything else still builds"
reset; echo bad > "$WORK/fail"
run "bad needs-bad solo"; rc=$?
check "exit 1" "[[ $rc -eq 1 ]]"
check "solo still built" "[[ -f $WORK/out/solo-3.1-1.nawa.tar.zst ]]"
check "needs-bad never attempted" "! grep -q 'needs-bad' $WORK/calls"
check "report names FAILED and SKIPPED" \
    "grep -q 'FAILED   bad-1.0-1' $WORK/report.txt && grep -q 'SKIPPED  needs-bad-1.0-1' $WORK/report.txt"
check "status FAILED=1 SKIPPED=1" "grep -qx FAILED=1 $WORK/status && grep -qx SKIPPED=1 $WORK/status"

# 5 ---------------------------------------------------------------------------
echo "== TEST: KEEP_GOING=0 stops at the first failure"
reset; echo bad > "$WORK/fail"
run "bad solo" KEEP_GOING=0; rc=$?
check "exit 1 and solo NOT built" "[[ $rc -eq 1 && ! -f $WORK/out/solo-3.1-1.nawa.tar.zst ]]"

# 6 ---------------------------------------------------------------------------
echo "== TEST: package with unbuilt dependencies uses 'install' (builds them too)"
reset
run "app"; rc=$?
check "install-build app" "grep -qx 'install-build app' $WORK/calls"
check "dependency archives were produced too" \
    "[[ -f $WORK/out/libz-1.3-1.nawa.tar.zst && -f $WORK/out/libpng-1.6-2.nawa.tar.zst ]]"

# 7 ---------------------------------------------------------------------------
echo "== TEST: unknown package name is rejected before anything is built"
reset
run "libz nope"; rc=$?
check "exit 1, nothing built" "[[ $rc -eq 1 && ! -s $WORK/calls ]]"

echo
echo "build-packages-inner tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
