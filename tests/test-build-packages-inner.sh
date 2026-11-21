#!/usr/bin/env bash
# tests/test-build-packages-inner.sh — tests bootstrap/build-packages-inner.sh
# (the script faseela-repo's packages.yml runs inside the build root) against a STUB nawa:
# dependency order, "already published = up to date", installing published
# dependencies instead of rebuilding them, failure isolation (dependents are
# skipped, the rest still builds), the time budget and freeing the work trees
# of finished builds (a run of Rust packages must not fill the runner's disk).
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
mk service 1.0 1; mk provider 1.0 1; mk consumer 1.0 1
mkdir -p "$WORK/repo/profiles"

# topological order and dependencies of the fake tree
printf '%s\n' libz libpng app bad needs-bad solo service provider consumer > "$WORK/order"
cat > "$WORK/deps" <<'D'
libpng: libz
app: libpng libz
needs-bad: bad
consumer: service provider
D

# ---- stub nawa ---------------------------------------------------------------
cat > "$WORK/nawa" <<'STUB'
#!/usr/bin/env bash
W="$(dirname "$0")"
[[ " $* " != *" --force "* ]] || { echo "--force is forbidden in package build imports" >&2; exit 2; }
while [[ $# -gt 0 && $1 == --* ]]; do shift 2; done   # global flags all take a value
cmd="$1"; shift
id_of() { awk -v n="$1" '/^version/{gsub(/[" ]/,"",$0); sub(/version=/,"",$0); v=$0}
         /^rel/{r=$3} END{print n "-" v "-" (r==""?1:r)}' "$W"/repo/recipes/*/"$1"/recipe.toml; }
tree() { # leave <id>/{src,pkg} + a phase log behind, as nawa does
    local id; id="$(id_of "$1")"
    mkdir -p "$W/$id/src/target" "$W/$id/pkg"; echo big > "$W/$id/src/target/big"; echo log > "$W/$id/compile.log"
}
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
    # real nawa: `build --install` verifies the fresh (unsigned) archive and has no --allow-unsigned
    [[ -e $W/trusted && " $* " == *" --install "* ]] && { echo "unsigned but a trusted key is configured" >&2; exit 1; }
    tree "$name"
    grep -qxF "$name" "$W/fail" 2>/dev/null && exit 1
    touch "$W/out/$(id_of "$name").nawa.tar.zst" ;;
  install)
    t="${@: -1}"
    [[ -e $W/trusted && " $* " != *" --allow-unsigned "* ]] && { echo "unsigned but a trusted key is configured" >&2; exit 1; }
    if [[ $t == *.nawa.tar.zst ]]; then
        echo "install-archive $(basename "$t")" >> "$W/calls"
        b=$(basename "$t" .nawa.tar.zst); echo "${b%-*-*}" >> "$W/installed"
    else
        echo "install-build $t" >> "$W/calls"
        for d in $(grep "^$t:" "$W/deps" | cut -d: -f2) $t; do
            grep -qxF "$d" "$W/installed" 2>/dev/null && continue
            tree "$d"
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
reset() { rm -rf "$WORK"/*-[0-9]*-[0-9]*/ "$WORK/out" "$WORK/installed" "$WORK/calls" "$WORK/fail" "$WORK/status" "$WORK/report.txt" "$WORK/trusted"; mkdir -p "$WORK/out"; }

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

# 6b --------------------------------------------------------------------------
echo "== TEST: newly built packages are not imported before their runtime closure"
reset; touch "$WORK/trusted"
run "provider consumer"; rc=$?
check "exit 0" "[[ $rc -eq 0 ]]"
check "provider archive remains in OUT after its build" "[[ -f $WORK/out/provider-1.0-1.nawa.tar.zst ]]"
check "runtime service is imported before provider" "[[ $(grep -n 'install-archive service-' $WORK/calls | cut -d: -f1) -lt $(grep -n 'install-archive provider-' $WORK/calls | cut -d: -f1) ]]"
check "provider is imported before consumer build" "[[ $(grep -n 'install-archive provider-' $WORK/calls | cut -d: -f1) -lt $(grep -n 'build consumer' $WORK/calls | cut -d: -f1) ]]"
check "new package was not self-imported immediately after its build" "[[ $(grep -n 'build provider' $WORK/calls | cut -d: -f1) -lt $(grep -n 'install-archive provider-' $WORK/calls | cut -d: -f1) ]]"
reset; touch "$WORK/trusted"
run "app"; rc=$?
check "install --build fallback still works" "[[ $rc -eq 0 ]] && grep -qx 'install-build app' $WORK/calls"

# 7 ---------------------------------------------------------------------------
echo "== TEST: unknown package name is rejected before anything is built"
reset
run "libz nope"; rc=$?
check "exit 1, nothing built" "[[ $rc -eq 1 && ! -s $WORK/calls ]]"

# 8 ---------------------------------------------------------------------------
echo "== TEST: the work tree of a built package is deleted, nothing else is"
reset
run "app solo"; rc=$?
check "exit 0" "[[ $rc -eq 0 ]]"
check "no <id>/src or <id>/pkg is left (the app AND the dependencies built for it)" \
    "[[ -z \$(ls -d $WORK/*/src $WORK/*/pkg 2>/dev/null) ]]"
check "archives, report and status are untouched" \
    "[[ -f $WORK/out/app-2.0-1.nawa.tar.zst && -f $WORK/out/solo-3.1-1.nawa.tar.zst && -s $WORK/report.txt && -s $WORK/status ]]"
check "repo/ and other non-work directories are untouched" "[[ -d $WORK/repo/recipes && -d $WORK/out ]]"
check "the report line says how much disk is free" "grep -Eq '^BUILT    app-2.0-1 .*disk free' $WORK/report.txt"

# 9 ---------------------------------------------------------------------------
echo "== TEST: the work tree of a FAILED build stays (the workflow collects its logs)"
reset; echo bad > "$WORK/fail"
run "bad solo"; rc=$?
check "exit 1" "[[ $rc -eq 1 ]]"
check "bad-1.0-1 keeps its tree and log" "[[ -f $WORK/bad-1.0-1/compile.log && -d $WORK/bad-1.0-1/src ]]"
check "solo, built afterwards, is cleaned" "[[ ! -e $WORK/solo-3.1-1 ]]"
reset; echo bad > "$WORK/fail"
run "bad solo" KEEP_GOING=0; rc=$?
check "a later success does not delete the failed tree" "[[ -f $WORK/bad-1.0-1/compile.log ]]"
reset; echo bad > "$WORK/fail"
run "solo bad needs-bad libz"; rc=$?
check "trees of successes on both sides of a failure are gone, the failed one stays" \
    "[[ ! -e $WORK/solo-3.1-1 && ! -e $WORK/libz-1.3-1 && -f $WORK/bad-1.0-1/compile.log ]]"

# 10 --------------------------------------------------------------------------
echo "== TEST: KEEP_WORK=1 keeps every work tree"
reset
run "libz solo" KEEP_WORK=1; rc=$?
check "exit 0 and both trees are still there" \
    "[[ $rc -eq 0 && -d $WORK/libz-1.3-1/src && -d $WORK/solo-3.1-1/src ]]"

echo
echo "build-packages-inner tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
