#!/usr/bin/env bash
# test-build-all-mock.sh — end-to-end test of bootstrap/build-all.sh ORCHESTRATION
# (stamps, resume, failure trap, epilogue) using mock stage scripts.
#
# The real build-all.sh is copied into a throwaway tree with stub stage
# scripts; the copy's root pre-flight is relaxed (this container has no root
# and blocks userns uid_map self-writes) — same for the disk-space floor.
# The production file keeps both checks; these tests exercise the
# ORCHESTRATION logic (stamps, resume, trap, epilogue), not the guards.
#
# Usage: tests/test-build-all-mock.sh   (from the repo root or anywhere)
set -uo pipefail

REPO="${MYDISTRO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$REPO/bootstrap/build-all.sh"
WORK="$(mktemp -d /tmp/build-all-test.XXXXXX)"
MOCK="$WORK/repo/bootstrap"
TGT="$WORK/target"
ISO="$WORK/out/mock.iso"
PASS=0 FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say()  { printf '\n\033[1m== TEST: %s\033[0m\n' "$*"; }
ok()   { printf '\033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

[[ -f $SRC ]] || { echo "cannot find $SRC"; exit 1; }

# ---------------------------------------------------------------- mock tree --
mkdir -p "$MOCK/seed" "$WORK/out" "$WORK/bin"
cp "$SRC" "$MOCK/build-all.sh"
chmod +x "$MOCK/build-all.sh"
# relax ONLY the disk floor in the throwaway copy (see header comment)
sed -i 's/^MIN_FREE_KB=.*/MIN_FREE_KB=1/' "$MOCK/build-all.sh"
sed -i 's/\[\[ $EUID -ne 0 \]\]/false/' "$MOCK/build-all.sh"
# build-all.sh fetches the recipes from faseela-repo first; the mock tree has
# recipes of its own (made further down), so that step is a stub here
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK/fetch-recipes.sh"
# stub the host tools the pre-flight looks for (container lacks them):
# mksquashfs/grub-mkrescue/xorriso for the iso stage, zstd for stages 1-3
for t in mksquashfs grub-mkrescue xorriso zstd; do
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$t"; chmod +x "$WORK/bin/$t"
done
BASE_PATH="$PATH"   # pre-stub PATH — the G2 tests re-run without the ISO stubs
export PATH="$WORK/bin:$PATH"

cat > "$MOCK/seed/build-seed.sh" <<'EOF'
echo "mock: assembling seed"
EOF
cat > "$MOCK/stage1.sh" <<'EOF'
set -e
echo "mock: stage1 into $1 (SEED_ROOTFS=${SEED_ROOTFS:-unset} SHA=${SEED_ROOTFS_SHA256:-unset})"
mkdir -p "$1/usr/bin" "$1/dev" "$1/proc"
echo ok > "$1/usr/bin/env"
EOF
cat > "$MOCK/stage2.sh" <<'EOF'
set -e
echo "mock: stage2 graph (SINGLE_ROOT=${SINGLE_ROOT:-unset})"
echo built > "$1/stage2.marker"
[[ "${SINGLE_ROOT:-0}" == 1 ]] || mkdir -p "$1/sysroot"
EOF
cat > "$MOCK/stage3.sh" <<'EOF'
set -e
echo "mock: stage3 self-host"
echo rebuilt > "$1/stage3.marker"
EOF
cat > "$MOCK/mkrootfs.sh" <<'EOF'
set -e
ROOT="$1"; OUT="$2"
echo "mock: mkrootfs $ROOT -> $OUT"
mkdir -p "$(dirname "$OUT")"
echo "$ROOT" > "$(dirname "$OUT")/mkrootfs.root"
echo rootfsdata > "$OUT"
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
EOF
cat > "$MOCK/mkiso.sh" <<'EOF'
set -e
ROOT="$1"; OUT="$2"
echo "mock: mkiso $ROOT -> $OUT"
mkdir -p "$(dirname "$OUT")"
echo "$ROOT" > "$(dirname "$OUT")/mkiso.root"
dd if=/dev/zero of="$OUT" bs=1K count=64 status=none
EOF
cat > "$MOCK/umount-chroot.sh" <<'EOF'
echo "mock: umount (nothing mounted)"
EOF

STATE="$WORK/.target.build"   # dirname(TARGET)/.TARGET.build
STAMPS="$STATE/stamps"

RUN() {  # run the mock build-all (guards relaxed in the copy only)
    bash "$MOCK/build-all.sh" "$@" "$TGT" "$ISO" \
        > "$WORK/last.out" 2> "$WORK/last.err"
    echo $?
}
OUT() { cat "$WORK/last.out"; }
ERR() { cat "$WORK/last.err"; }

# ------------------------------------------------------------------- tests ---
say "A. full run from scratch (all six stages)"
RC=$(RUN)
check "A1 exit 0"                          "[[ $RC -eq 0 ]]"
check "A2 six stamps written"              "[[ \$(ls $STAMPS/*.done | wc -l) -eq 6 ]]"
check "A2b six input sidecars written"     "[[ \$(ls $STAMPS/*.inputs | wc -l) -eq 6 ]]"
check "A2c rootfs stamp exists"            "[[ -f $STAMPS/rootfs.done ]]"
check "A3 seed stamp exists"               "[[ -f $STAMPS/seed.done ]]"
check "A4 iso stamp exists"                "[[ -f $STAMPS/iso.done ]]"
check "A5 meta has 6 ok lines"             "[[ \$(grep -c '|ok$' $STATE/meta) -eq 6 ]]"
check "A6 one log file created"            "[[ \$(ls $STATE/logs | wc -l) -eq 1 ]]"
check "A7 ISO ready in output"             "OUT | grep -q 'ISO ready.*mock.iso'"
check "A8 ISO file non-empty"               "[[ -s $ISO ]]"
check "A9 stage markers in target"         "[[ -f $TGT/stage2.marker && -f $TGT/stage3.marker ]]"
check "A10 next steps mentioned"           "OUT | grep -q 'validate-install.sh'"
check "A11 ISO is made from the FINAL root" "[[ \$(cat $WORK/out/mkiso.root) == $TGT/sysroot ]]"
check "A12 layout recorded as two-root"    "[[ \$(cat $STATE/layout) == two-root ]]"
check "A13 final root dir created by stage2" "[[ -d $TGT/sysroot ]]"
check "A14 rootfs ready in output"         "OUT | grep -q 'rootfs ready.*mock-rootfs.tar.zst'"
check "A15 rootfs path derived from the ISO path" "[[ -s $WORK/out/mock-rootfs.tar.zst ]]"
check "A16 rootfs sidecar written"         "[[ -s $WORK/out/mock-rootfs.tar.zst.sha256 ]]"
check "A17 rootfs is made from the FINAL root" "[[ \$(cat $WORK/out/mkrootfs.root) == $TGT/sysroot ]]"
check "A18 rootfs runs BEFORE the iso"     "[[ \$(grep -n '^== .*: stage rootfs ' $WORK/last.out | head -1 | cut -d: -f1) -lt \$(grep -n '^== .*: stage iso ' $WORK/last.out | head -1 | cut -d: -f1) ]]"
check "A19 Debian seed: stage1 saw no rootfs seed" "OUT | grep -q 'SEED_ROOTFS=unset'"
check "A20 next-build hint names --seed-rootfs" "OUT | grep -q -- '--seed-rootfs'"

say "B. re-run: everything skipped"
RC=$(RUN)
check "B1 exit 0"                          "[[ $RC -eq 0 ]]"
check "B2 'nothing to run' notice"         "OUT | grep -q 'nothing to run'"
check "B3 no new log file"                 "[[ \$(ls $STATE/logs | wc -l) -eq 2 ]]"
check "B4 ISO still reported"              "OUT | grep -q 'ISO from a previous run'"

say "C. --list-stages shows 6/6"
bash "$MOCK/build-all.sh" --list-stages "$TGT" > "$WORK/list.out" 2>&1
check "C1 reports 6/6 complete"            "grep -q '6/6 stages recorded' $WORK/list.out"
check "C2 no stage pending"                "! grep -q ' pending' $WORK/list.out"

say "D. --from-stage 2 invalidates later stamps and re-runs them"
rm -f "$TGT/stage2.marker" "$TGT/stage3.marker"
RC=$(RUN --from-stage 2)
check "D1 exit 0"                          "[[ $RC -eq 0 ]]"
check "D2 invalidation notices for stage2+3+rootfs+iso" "OUT | grep -c 'invalidating stamp' | grep -q '^4\$'"
check "D3 stage1 stamp kept"              "[[ -f $STAMPS/stage1.done ]]"
check "D4 stage2/3 re-ran (markers back)" "[[ -f $TGT/stage2.marker && -f $TGT/stage3.marker ]]"
check "D5 meta now has 10 ok lines"        "[[ \$(grep -c '|ok$' $STATE/meta) -eq 10 ]]"

# build-all folds stderr into its log stream (exec > >(tee) 2>&1), so stdout
# AND stderr both land in last.out — the E-checks grep OUT, not ERR.
say "E. failure at stage3: trap guidance + resume skips earlier stages"
sed -i 's/^echo rebuilt.*/exit 1/' "$MOCK/stage3.sh"      # make stage3 fail
rm -f "$TGT/stage3.marker"
RC=$(RUN --from-stage 3)
check "E1 exit code is 1 (not 2, not 127)" "[[ $RC -eq 1 ]]"
check "E2 FAILED banner names stage3"     "OUT | grep -q \"FAILED during 'stage3'\""
check "E3 resume hint echoes the command"  "OUT | grep -q -- '--from-stage 3'"
check "E4 umount hint present"             "OUT | grep -q 'umount-chroot.sh'"
check "E5 log path in failure message"     "OUT | grep -q 'full log'"
check "E6 stage3 stamp NOT written"       "[[ ! -f $STAMPS/stage3.done ]]"
check "E7 iso stamp invalidated"          "[[ ! -f $STAMPS/iso.done ]]"
check "E8 rootfs stamp invalidated"       "[[ ! -f $STAMPS/rootfs.done ]]"
sed -i 's/^exit 1$/echo rebuilt > "$1\/stage3.marker"/' "$MOCK/stage3.sh"  # restore

say "F. resume after failure: only the broken stages run"
RC=$(RUN)
check "F1 exit 0"                          "[[ $RC -eq 0 ]]"
check "F2 stage2 not re-run (no banner)"   "! OUT | grep -q 'stage stage2 —'"
check "F3 stage3 re-ran (marker back)"    "[[ -f $TGT/stage3.marker ]]"
check "F4 iso re-stamped"                 "[[ -f $STAMPS/iso.done ]]"
check "F5 meta has 13 ok lines"            "[[ \$(grep -c '|ok$' $STATE/meta) -eq 13 ]]"
check "F6 rootfs re-stamped"               "[[ -f $STAMPS/rootfs.done ]]"

say "G. --no-iso skips the ISO only; --no-iso --no-rootfs stops after stage3"
rm -rf "$WORK/tgt2" "$WORK/.tgt2.build"
RC=$(bash "$MOCK/build-all.sh" --no-iso "$WORK/tgt2" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "G1 exit 0"                          "[[ $RC -eq 0 ]]"
check "G2 no iso stamp"                    "[[ ! -f $WORK/.tgt2.build/stamps/iso.done ]]"
check "G3 hint for later ISO"             "OUT | grep -q -- '--from-stage iso'"
check "G4 rootfs still built"              "[[ -f $WORK/.tgt2.build/stamps/rootfs.done ]]"
rm -rf "$WORK/tgt2b" "$WORK/.tgt2b.build"
RC=$(bash "$MOCK/build-all.sh" --no-iso --no-rootfs "$WORK/tgt2b" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "G5 --no-iso --no-rootfs exit 0"     "[[ $RC -eq 0 ]]"
check "G6 neither stamp written"           "[[ ! -f $WORK/.tgt2b.build/stamps/iso.done && ! -f $WORK/.tgt2b.build/stamps/rootfs.done ]]"
check "G7 stage3 stamp written"            "[[ -f $WORK/.tgt2b.build/stamps/stage3.done ]]"
RC=$(bash "$MOCK/build-all.sh" --no-iso --no-rootfs "$WORK/tgt2b" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "G8 re-run: nothing to run"          "[[ $RC -eq 0 ]] && OUT | grep -q 'nothing to run'"
bash "$MOCK/build-all.sh" --no-iso --no-rootfs --list-stages "$WORK/tgt2b" > "$WORK/last.out" 2>&1
check "G9 list marks both as skipped"      "OUT | grep -q 'rootfs.*skipped (--no-rootfs)' && OUT | grep -q 'iso.*skipped (--no-iso)'"

say "G2. --no-iso needs no ISO host tools (the release 'core' job scenario)"
# The CI core job builds --no-iso on a host that installs no ISO tools
# (release.yml: "No ISO host tools here: the ISOs are made by the matrix
# jobs") — pre-flight must not demand tools of stages that are switched
# off.  Run with the stubs (mksquashfs/grub-mkrescue/xorriso) REMOVED from
# PATH; the zstd stub stays because stages 1-3 still need it.
mkdir -p "$WORK/bin2"
cp "$WORK/bin/zstd" "$WORK/bin2/zstd"
NOPATH="$WORK/bin2:$BASE_PATH"
rm -rf "$WORK/tgt2n" "$WORK/.tgt2n.build"
RC=$(PATH="$NOPATH" bash "$MOCK/build-all.sh" --no-iso "$WORK/tgt2n" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "G2a exit 0 with no ISO tools on PATH"  "[[ $RC -eq 0 ]]"
check "G2b rootfs built, no ISO demanded"    "[[ -f $WORK/.tgt2n.build/stamps/rootfs.done ]]"
check "G2c no ISO stamp (stage skipped)"     "[[ ! -f $WORK/.tgt2n.build/stamps/iso.done ]]"
# negative control: on the same PATH *without* --no-iso the ISO tool check
# must still fire (proves the fix disabled the check only for skipped
# stages, not for real ISO builds).  Skipped gracefully on dev hosts that
# happen to have all five tools, where it would be vacuous.
have_all=1
for t in mksquashfs grub-mkrescue xorriso gcc make; do
    ( export PATH="$NOPATH"; command -v "$t" >/dev/null ) || have_all=0
done
if (( have_all )); then
    echo "  (host has every ISO tool; the negative control is vacuous here)"
else
    RC=$(PATH="$NOPATH" bash "$MOCK/build-all.sh" "$WORK/tgt2n" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
    check "G2d without --no-iso the ISO tools are still required" \
          "[[ $RC -eq 2 ]] && cat $WORK/last.out $WORK/last.err | grep -q 'iso stage misses host tool'"
fi

say "H. non-empty target without state is refused"
mkdir -p "$WORK/tgt3"; echo data > "$WORK/tgt3/precious.txt"
RC=$(bash "$MOCK/build-all.sh" "$WORK/tgt3" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "H1 exit 2 (usage error)"           "[[ $RC -eq 2 ]]"
check "H2 refusal message"                "ERR | grep -q 'not empty and has no build state'"
check "H3 file survived"                  "[[ -f $WORK/tgt3/precious.txt ]]"

say "I. --wipe replaces the target contents"
RC=$(bash "$MOCK/build-all.sh" --wipe "$WORK/tgt3" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "I1 exit 0"                          "[[ $RC -eq 0 ]]"
check "I2 old file gone"                  "[[ ! -e $WORK/tgt3/precious.txt ]]"
check "I3 stages built (env marker)"      "[[ -f $WORK/tgt3/usr/bin/env ]]"

say "J. dry-run writes nothing (fresh target)"
rm -rf "$WORK/tgt4" "$WORK/.tgt4.build"
unshare_unused() { :; }
bash "$MOCK/build-all.sh" --dry-run "$WORK/tgt4" > "$WORK/last.out" 2>&1
check "J1 no state dir created"           "[[ ! -e $WORK/.tgt4.build ]]"
check "J2 six dry-run commands listed"    "[[ \$(OUT | grep -c 'would run:') -eq 6 ]]"
check "J3 nothing executed (no target)"   "[[ ! -e $WORK/tgt4 ]]"

say "K. adopt a hand-built seed (no stamp yet)"
rm -rf "$WORK/tgt5" "$WORK/.tgt5.build"
mkdir -p "$MOCK/seed"; echo seeddata > "$MOCK/seed/seed.tar.zst"
RC=$(bash "$MOCK/build-all.sh" "$WORK/tgt5" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "K1 exit 0"                          "[[ $RC -eq 0 ]]"
check "K2 adoption notice"                "OUT | grep -q 'adopting existing'"
check "K3 seed stage not re-run"          "! OUT | grep -q 'mock: assembling seed'"
rm -f "$MOCK/seed/seed.tar.zst"

say "L. --single-root: layout switch invalidates stage2+3+rootfs+iso, ISO from TARGET"
RC=$(RUN --single-root)
check "L1 exit 0"                          "[[ $RC -eq 0 ]]"
check "L2 layout-switch notices (x4)"      "OUT | grep -c 'layout two-root -> single-root' | grep -q '^4\$'"
check "L2b rootfs made from TARGET itself" "[[ \$(cat $WORK/out/mkrootfs.root) == $TGT ]]"
check "L3 ISO made from TARGET itself"     "[[ \$(cat $WORK/out/mkiso.root) == $TGT ]]"
check "L4 stage2 saw SINGLE_ROOT=1"        "OUT | grep -q 'SINGLE_ROOT=1'"
check "L5 layout recorded as single-root"  "[[ \$(cat $STATE/layout) == single-root ]]"
check "L6 stage1 stamp untouched"          "[[ -f $STAMPS/stage1.done ]]"

say "M. back to two-root (default) switches again; same layout twice does not"
RC=$(RUN)
check "M1 exit 0"                          "[[ $RC -eq 0 ]]"
check "M2 layout-switch notice"            "OUT | grep -q 'layout single-root -> two-root'"
check "M3 ISO from sysroot again"          "[[ \$(cat $WORK/out/mkiso.root) == $TGT/sysroot ]]"
RC=$(RUN)
check "M4 same layout: nothing invalidated" "! OUT | grep -q 'layout '"

say "N. a build that predates the layout file counts as single-root"
rm -f "$STATE/layout"
RC=$(RUN)
check "N1 exit 0"                          "[[ $RC -eq 0 ]]"
check "N2 legacy build is switched"        "OUT | grep -q 'layout single-root -> two-root'"

say "O. ISO stage refuses a missing final root"
rm -rf "$TGT/sysroot" "$STAMPS/iso.done"
RC=$(RUN --from-stage iso)
check "O1 exit 2"                          "[[ $RC -eq 2 ]]"
check "O2 clear message"                   "OUT | grep -q 'final root .*sysroot does not exist'"

# RUNT: like RUN but against an arbitrary target (the P-Y scenarios each get
# a fresh one so they cannot inherit state from A-O)
RUNT() {
    local tgt="$1"; shift
    bash "$MOCK/build-all.sh" "$@" "$tgt" "$ISO" > "$WORK/last.out" 2> "$WORK/last.err"
    echo $?
}
STATE_OF() { printf '%s/.%s.build' "$WORK" "$1"; }
STAMPS_OF() { printf '%s/.%s.build/stamps' "$WORK" "$(basename -- "$1")"; }

say "P. changed options invalidate exactly the affected stages (input sidecars)"
rm -rf "$WORK/tgtP" "$WORK/.tgtP.build"
PST="$(STAMPS_OF "$WORK/tgtP")"
RC=$(RUNT "$WORK/tgtP")
check "P1 full build exits 0"              "[[ $RC -eq 0 ]]"
RC=$(RUNT "$WORK/tgtP" --with-gui)
check "P2 --with-gui exits 0"              "[[ $RC -eq 0 ]]"
check "P3 stage2 invalidated, gui named"   "OUT | grep -q 'invalidating stamp: stage2 (inputs changed: gui)'"
check "P4 stage2/3/rootfs/iso re-ran"      "OUT | grep -q 'mock: stage2 graph' && OUT | grep -q 'mock: mkrootfs' && OUT | grep -q 'mock: mkiso'"
check "P5 seed/stage1 stamps kept"         "[[ -f $PST/seed.done && -f $PST/stage1.done ]]"
check "P6 stage3/iso re-stamped"           "[[ -f $PST/stage3.done && -f $PST/iso.done ]]"
RC=$(RUNT "$WORK/tgtP" --with-gui)
check "P7 same options again: nothing to do" "OUT | grep -q 'nothing to run'"
RC=$(RUNT "$WORK/tgtP" --with-gui --stage3-world)
check "P8 --stage3-world exits 0"          "[[ $RC -eq 0 ]]"
check "P9 stage3 invalidated, world named" "OUT | grep -q 'invalidating stamp: stage3 (inputs changed: world)'"
check "P10 stage2 kept (stamp + not re-run)" "[[ -f $PST/stage2.done ]] && ! OUT | grep -q 'mock: stage2 graph'"
RC=$(RUNT "$WORK/tgtP")
check "P11 gui off re-runs stage2+"        "OUT | grep -q 'mock: stage2 graph' && OUT | grep -q 'mock: mkiso'"
check "P12 seed/stage1 still kept"         "[[ -f $PST/seed.done && -f $PST/stage1.done ]]"
RC=$(RUNT "$WORK/tgtP" --vol-id CUSTOM)
check "P13 --vol-id re-runs only iso"      "OUT | grep -q 'invalidating stamp: iso (inputs changed: volid)' && ! OUT | grep -q 'mock: mkrootfs'"
check "P14 stage2/3 skipped"               "! OUT | grep -q 'mock: stage2 graph' && ! OUT | grep -q 'mock: stage3'"
check "P15 stage2/3 stamps kept"           "[[ -f $PST/stage2.done && -f $PST/stage3.done ]]"
RC=$(RUNT "$WORK/tgtP" --vol-id CUSTOM --squash-comp zstd)
check "P16 --squash-comp re-runs only iso" "OUT | grep -q 'invalidating stamp: iso (inputs changed: comp)'"
RC=$(RUNT "$WORK/tgtP")
check "P17 back to defaults: iso only"     "OUT | grep -q 'invalidating stamp: iso' && ! OUT | grep -q 'mock: stage2 graph'"

say "Q. a recipe edit invalidates stage2 and downstream"
mkdir -p "$WORK/repo/recipes/testpkg"
printf '# mock recipe\n' > "$WORK/repo/recipes/testpkg/recipe.toml"
rm -rf "$WORK/tgtQ" "$WORK/.tgtQ.build"
QST="$(STAMPS_OF "$WORK/tgtQ")"
RC=$(RUNT "$WORK/tgtQ")
check "Q1 full build exits 0"              "[[ $RC -eq 0 ]]"
printf '# mock recipe, edited\n' >> "$WORK/repo/recipes/testpkg/recipe.toml"
RC=$(RUNT "$WORK/tgtQ")
check "Q2 recipe edit invalidates stage2, recipes named" "OUT | grep -q 'invalidating stamp: stage2 (inputs changed: recipes)'"
check "Q3 stage2/3/iso re-ran"             "OUT | grep -q 'mock: stage2 graph' && OUT | grep -q 'mock: mkiso'"
check "Q4 seed/stage1 kept"                "[[ -f $QST/seed.done && -f $QST/stage1.done ]]"
RC=$(RUNT "$WORK/tgtQ")
check "Q5 stable recipes: nothing to run"  "OUT | grep -q 'nothing to run'"

say "R. a stage-script edit invalidates from that stage onward"
printf '# edited\n' >> "$MOCK/stage1.sh"
RC=$(RUNT "$WORK/tgtQ")
check "R1 stage1 edit invalidates stage1, scripts named" "OUT | grep -q 'invalidating stamp: stage1 (inputs changed: scripts)'"
check "R2 stage1..iso re-ran"              "OUT | grep -q 'mock: stage1 into' && OUT | grep -q 'mock: mkiso'"
check "R3 seed stamp kept"                 "[[ -f $QST/seed.done ]]"
printf '# edited\n' >> "$MOCK/seed/build-seed.sh"
RC=$(RUNT "$WORK/tgtQ")
check "R4 seed-script edit re-runs everything" "OUT | grep -q 'invalidating stamp: seed' && OUT | grep -q 'mock: assembling seed'"

say "S. stamps that predate input tracking are stale and rebuilt"
rm -rf "$WORK/tgtS" "$WORK/.tgtS.build"
SST="$(STAMPS_OF "$WORK/tgtS")"
RC=$(RUNT "$WORK/tgtS")
check "S1 full build exits 0"              "[[ $RC -eq 0 ]]"
rm -f "$SST/"*.inputs
bash "$MOCK/build-all.sh" --list-stages "$WORK/tgtS" > "$WORK/last.out" 2>&1
check "S2 list shows all six stale"        "[[ \$(OUT | grep -c 'stale (inputs not recorded)') -eq 6 ]]"
check "S3 list summary counts stale"       "OUT | grep -q 'stale (inputs changed/unknown'"
RC=$(RUNT "$WORK/tgtS")
check "S4 all six invalidation notices"    "[[ \$(OUT | grep -c 'pre-dates input tracking') -eq 6 ]]"
check "S5 seed re-ran too"                 "OUT | grep -q 'mock: assembling seed'"

say "T. a failed stage is marked; --list-stages reports it; success clears it"
rm -rf "$WORK/tgtT" "$WORK/.tgtT.build"
TST="$(STAMPS_OF "$WORK/tgtT")"; TSTATE="$(STATE_OF tgtT)"
RC=$(RUNT "$WORK/tgtT")
check "T1 full build exits 0"              "[[ $RC -eq 0 ]]"
sed -i 's/^echo "mock: stage2 graph.*$/exit 1/' "$MOCK/stage2.sh"
RC=$(RUNT "$WORK/tgtT")
check "T2 stage2 failure exits 1"          "[[ $RC -eq 1 ]]"
check "T3 failure marker written"          "[[ -f $TSTATE/failed-stage2 ]]"
bash "$MOCK/build-all.sh" --list-stages "$WORK/tgtT" > "$WORK/last.out" 2>&1
check "T4 list shows stage2 FAILED"        "OUT | grep -q 'stage2.*FAILED'"
check "T5 list summary counts the failure" "OUT | grep -q '1 failed'"
sed -i 's/^exit 1$/echo "mock: stage2 graph"/' "$MOCK/stage2.sh"
RC=$(RUNT "$WORK/tgtT")
check "T6 resume after fix exits 0"        "[[ $RC -eq 0 ]]"
check "T7 marker cleared on success"       "[[ ! -e $TSTATE/failed-stage2 ]]"
check "T8 stage3/iso re-stamped"           "[[ -f $TST/stage3.done && -f $TST/iso.done ]]"
bash "$MOCK/build-all.sh" --list-stages "$WORK/tgtT" > "$WORK/last.out" 2>&1
check "T9 list is clean again"             "OUT | grep -q '6/6 stages recorded' && ! OUT | grep -q FAILED"

say "U. a concurrent build against the same target is rejected (state lock)"
( exec 9>>"$TSTATE/lock"; flock -x 9; sleep 10 ) &
LOCKPID=$!
sleep 1
RC=$(RUNT "$WORK/tgtT")
check "U1 concurrent run exits 2"          "[[ $RC -eq 2 ]]"
check "U2 lock message shown"              "cat $WORK/last.out $WORK/last.err | grep -q 'another build-all is already running'"
kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null
RC=$(RUNT "$WORK/tgtT")
check "U3 after release the run proceeds"  "[[ $RC -eq 0 ]]"

say "V. seed adoption is checksum-verified when a sidecar exists"
mkdir -p "$MOCK/seed"
echo seeddata > "$MOCK/seed/seed.tar.zst"
( cd "$MOCK/seed" && sha256sum seed.tar.zst > seed.tar.zst.sha256 )
rm -rf "$WORK/tgtV" "$WORK/.tgtV.build"
VST="$(STAMPS_OF "$WORK/tgtV")"
RC=$(RUNT "$WORK/tgtV")
check "V1 valid sidecar: seed adopted"     "! OUT | grep -q 'mock: assembling seed'"
check "V2 adoption notice"                 "OUT | grep -q 'adopting existing'"
check "V3 no seed stamp (adopted)"         "[[ ! -f $VST/seed.done ]]"
check "V4 later stages ran"                "[[ -f $VST/iso.done ]]"
bash "$MOCK/build-all.sh" --list-stages "$WORK/tgtV" > "$WORK/last.out" 2>&1
check "V5 list shows adopted seed"         "OUT | grep -q 'done (adopted'"
echo "0000000000000000000000000000000000000000000000000000000000000000  seed.tar.zst" > "$MOCK/seed/seed.tar.zst.sha256"
rm -rf "$WORK/tgtW" "$WORK/.tgtW.build"
RC=$(RUNT "$WORK/tgtW")
check "V6 corrupt sidecar: seed NOT adopted" "cat $WORK/last.out $WORK/last.err | grep -q 'NOT adopting'"
check "V7 seed stage re-runs"              "OUT | grep -q 'mock: assembling seed'"
check "V8 seed stamped after rebuild"      "[[ -f $(STAMPS_OF "$WORK/tgtW")/seed.done ]]"

say "W. --from-stage seed re-runs the seed even when it is adoptable"
( cd "$MOCK/seed" && sha256sum seed.tar.zst > seed.tar.zst.sha256 )
RC=$(RUNT "$WORK/tgtW" --from-stage seed)
check "W1 exit 0"                          "[[ $RC -eq 0 ]]"
check "W2 seed stage ran (not adopted)"    "OUT | grep -q 'mock: assembling seed'"
check "W3 no lying adoption notice"        "! OUT | grep -q 'adopting existing'"
check "W4 seed stamped"                    "[[ -f $(STAMPS_OF "$WORK/tgtW")/seed.done ]]"
rm -f "$MOCK/seed/seed.tar.zst" "$MOCK/seed/seed.tar.zst.sha256"

say "X. --wipe refuses protected paths, repo ancestors and HOME"
RC=$(bash "$MOCK/build-all.sh" --wipe /usr > "$WORK/last.out" 2> "$WORK/last.err"; echo $?)
check "X1 /usr refused (exit 2, message)"  "[[ $RC -eq 2 ]] && ERR | grep -q 'protected system path'"
check "X2 refusal created no state dir"    "[[ ! -e /.usr.build ]]"
RC=$(bash "$MOCK/build-all.sh" --wipe / > "$WORK/last.out" 2> "$WORK/last.err"; echo $?)
check "X3 / refused"                       "[[ $RC -eq 2 ]]"
RC=$(bash "$MOCK/build-all.sh" --wipe "$WORK" > "$WORK/last.out" 2> "$WORK/last.err"; echo $?)
check "X4 repo ancestor refused"           "ERR | grep -q 'contains the repository'"
check "X5 the work tree survived"          "[[ -d $WORK/repo ]]"
RC=$(bash "$MOCK/build-all.sh" --wipe "$HOME" > "$WORK/last.out" 2> "$WORK/last.err"; echo $?)
check "X6 HOME refused"                    "ERR | grep -q 'home directory'"

say "Y. --dry-run changes nothing even when stamps are stale"
printf '# mock recipe, edited again\n' >> "$WORK/repo/recipes/testpkg/recipe.toml"
Y_BEFORE="$(ls "$TST" | sort | tr '\n' ' ')"
bash "$MOCK/build-all.sh" --dry-run "$WORK/tgtT" > "$WORK/last.out" 2>&1
check "Y1 dry-run lists the four stale stages" "[[ \$(OUT | grep -c 'would run:') -eq 4 ]]"
check "Y2 dry-run touched no stamp files"  "[[ \$(ls $TST | sort | tr '\n' ' ') == '$Y_BEFORE' ]]"
check "Y3 dry-run printed no invalidation" "! OUT | grep -q 'invalidating stamp'"
RC=$(RUNT "$WORK/tgtT")
check "Y4 the real run then rebuilds them" "OUT | grep -q 'invalidating stamp: stage2 (inputs changed: recipes)'"

say "Z. rootfs seed (--seed-rootfs): the distro builds itself from a previous rootfs"
ZSEED="$WORK/prev-rootfs.tar.zst"
echo previous-release-rootfs > "$ZSEED"
( cd "$WORK" && sha256sum prev-rootfs.tar.zst > prev-rootfs.tar.zst.sha256 )
rm -rf "$WORK/tgtZ" "$WORK/.tgtZ.build"
ZST="$(STAMPS_OF "$WORK/tgtZ")"
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs "$ZSEED")
check "Z1 exit 0"                          "[[ $RC -eq 0 ]]"
check "Z2 Debian seed stage NOT run"       "! OUT | grep -q 'mock: assembling seed'"
check "Z3 stage1 received the rootfs seed" "OUT | grep -q \"SEED_ROOTFS=$ZSEED\""
check "Z4 no seed stamp (stage 0 not needed)" "[[ ! -f $ZST/seed.done ]]"
check "Z5 every later stage ran"           "[[ -f $ZST/stage1.done && -f $ZST/stage3.done && -f $ZST/rootfs.done && -f $ZST/iso.done ]]"
check "Z6 banner names the rootfs seed"    "OUT | grep -q 'seed:       ROOTFS'"
bash "$MOCK/build-all.sh" --seed-rootfs "$ZSEED" --list-stages "$WORK/tgtZ" > "$WORK/last.out" 2>&1
check "Z7 list: seed 'not needed'"         "OUT | grep -q 'seed.*not needed (rootfs seed: prev-rootfs.tar.zst)'"
check "Z8 list: 6/6"                       "OUT | grep -q '6/6 stages recorded'"
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs "$ZSEED")
check "Z9 same seed again: nothing to run" "OUT | grep -q 'nothing to run'"
# a NEW seed (the next release) invalidates stage 1 and everything after
echo next-release-rootfs > "$ZSEED"
( cd "$WORK" && sha256sum prev-rootfs.tar.zst > prev-rootfs.tar.zst.sha256 )
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs "$ZSEED")
check "Z10 changed seed invalidates stage1 (seed named)" "OUT | grep -q 'invalidating stamp: stage1 (inputs changed: seed)'"
check "Z11 stages 1-iso re-ran"            "OUT | grep -q 'mock: stage1 into' && OUT | grep -q 'mock: mkrootfs' && OUT | grep -q 'mock: mkiso'"
# pin is passed down and validated
ZHASH="$(sha256sum "$ZSEED" | cut -d' ' -f1)"
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs "$ZSEED" --seed-rootfs-sha256 "$ZHASH" --from-stage 1)
check "Z12 pinned hash reaches stage1"     "OUT | grep -q \"SHA=$ZHASH\""
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs "$ZSEED" --seed-rootfs-sha256 nothex)
check "Z13 malformed pin refused (exit 2)" "[[ $RC -eq 2 ]] && ERR | grep -q '64 hex digits'"
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs "$WORK/does-not-exist.tar.zst")
check "Z14 missing seed file refused"      "[[ $RC -eq 2 ]] && ERR | grep -q 'does not exist'"
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs-sha256 "$ZHASH")
check "Z15 pin without a seed refused"     "[[ $RC -eq 2 ]] && ERR | grep -q 'needs --seed-rootfs'"
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs "$ZSEED" --from-stage seed)
check "Z16 --from-stage seed refused"      "[[ $RC -eq 2 ]] && ERR | grep -q 'meaningless with --seed-rootfs'"
RC=$(RUNT "$WORK/tgtZ" --seed-rootfs "$ZSEED" --rootfs-out "$ZSEED")
check "Z17 seed == rootfs output refused"  "[[ $RC -eq 2 ]] && ERR | grep -q 'same file'"
RC=$(RUNT "$WORK/tgtZ" --rootfs-out "$WORK/out/custom.tar.zst" --from-stage rootfs)
check "Z18 --rootfs-out honoured"          "[[ $RC -eq 0 && -s $WORK/out/custom.tar.zst ]]"
RC=$(RUNT "$WORK/tgtZ" --rootfs-out "$WORK/out/custom.tgz")
check "Z19 bad rootfs extension refused"   "[[ $RC -eq 2 ]] && ERR | grep -q 'must end in .tar.zst'"
RC=$(RUNT "$WORK/tgtZ" --from-stage 4 --no-iso)
check "Z20 --from-stage 4 is the rootfs stage" "OUT | grep -q 'stage rootfs —'"
RC=$(RUNT "$WORK/tgtZ" --from-stage 5)
check "Z21 --from-stage 5 is the iso stage"    "OUT | grep -q 'stage iso —' && ! OUT | grep -q 'stage rootfs —'"

# ------------------------------------------------------------------ summary --
echo
printf '=====================\n  PASS: %d   FAIL: %d\n=====================\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
