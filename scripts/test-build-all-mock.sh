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
# Usage: scripts/test-build-all-mock.sh   (from the repo root or anywhere)
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
# stub the iso host tools the pre-flight looks for (container lacks them)
for t in mksquashfs grub-mkrescue; do
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$t"; chmod +x "$WORK/bin/$t"
done
export PATH="$WORK/bin:$PATH"

cat > "$MOCK/seed/build-seed.sh" <<'EOF'
echo "mock: assembling seed"
EOF
cat > "$MOCK/stage1.sh" <<'EOF'
set -e
echo "mock: stage1 into $1"
mkdir -p "$1/usr/bin" "$1/dev" "$1/proc"
echo ok > "$1/usr/bin/env"
EOF
cat > "$MOCK/stage2.sh" <<'EOF'
set -e
echo "mock: stage2 graph"
echo built > "$1/stage2.marker"
EOF
cat > "$MOCK/stage3.sh" <<'EOF'
set -e
echo "mock: stage3 self-host"
echo rebuilt > "$1/stage3.marker"
EOF
cat > "$MOCK/mkiso.sh" <<'EOF'
set -e
ROOT="$1"; OUT="$2"
echo "mock: mkiso $ROOT -> $OUT"
mkdir -p "$(dirname "$OUT")"
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
say "A. full run from scratch (all five stages)"
RC=$(RUN)
check "A1 exit 0"                          "[[ $RC -eq 0 ]]"
check "A2 five stamps written"             "[[ \$(ls $STAMPS | wc -l) -eq 5 ]]"
check "A3 seed stamp exists"               "[[ -f $STAMPS/seed.done ]]"
check "A4 iso stamp exists"                "[[ -f $STAMPS/iso.done ]]"
check "A5 meta has 5 ok lines"             "[[ \$(grep -c '|ok$' $STATE/meta) -eq 5 ]]"
check "A6 one log file created"            "[[ \$(ls $STATE/logs | wc -l) -eq 1 ]]"
check "A7 ISO ready in output"             "OUT | grep -q 'ISO ready.*mock.iso'"
check "A8 ISO file non-empty"               "[[ -s $ISO ]]"
check "A9 stage markers in target"         "[[ -f $TGT/stage2.marker && -f $TGT/stage3.marker ]]"
check "A10 next steps mentioned"           "OUT | grep -q 'validate-install.sh'"

say "B. re-run: everything skipped"
RC=$(RUN)
check "B1 exit 0"                          "[[ $RC -eq 0 ]]"
check "B2 'nothing to run' notice"         "OUT | grep -q 'nothing to run'"
check "B3 no new log file"                 "[[ \$(ls $STATE/logs | wc -l) -eq 2 ]]"
check "B4 ISO still reported"              "OUT | grep -q 'ISO from a previous run'"

say "C. --list-stages shows 5/5"
bash "$MOCK/build-all.sh" --list-stages "$TGT" > "$WORK/list.out" 2>&1
check "C1 reports 5/5 complete"            "grep -q '5/5 stages recorded' $WORK/list.out"
check "C2 no stage pending"                "! grep -q ' pending' $WORK/list.out"

say "D. --from-stage 2 invalidates later stamps and re-runs them"
rm -f "$TGT/stage2.marker" "$TGT/stage3.marker"
RC=$(RUN --from-stage 2)
check "D1 exit 0"                          "[[ $RC -eq 0 ]]"
check "D2 invalidation notices for stage2+3+iso" "OUT | grep -c 'invalidating stamp' | grep -q '^3\$'"
check "D3 stage1 stamp kept"              "[[ -f $STAMPS/stage1.done ]]"
check "D4 stage2/3 re-ran (markers back)" "[[ -f $TGT/stage2.marker && -f $TGT/stage3.marker ]]"
check "D5 meta now has 8 ok lines"         "[[ \$(grep -c '|ok$' $STATE/meta) -eq 8 ]]"

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
sed -i 's/^exit 1$/echo rebuilt > "$1\/stage3.marker"/' "$MOCK/stage3.sh"  # restore

say "F. resume after failure: only the broken stages run"
RC=$(RUN)
check "F1 exit 0"                          "[[ $RC -eq 0 ]]"
check "F2 stage2 not re-run (no banner)"   "! OUT | grep -q 'stage stage2 —'"
check "F3 stage3 re-ran (marker back)"    "[[ -f $TGT/stage3.marker ]]"
check "F4 iso re-stamped"                 "[[ -f $STAMPS/iso.done ]]"
check "F5 meta has 10 ok lines"            "[[ \$(grep -c '|ok$' $STATE/meta) -eq 10 ]]"

say "G. --no-iso stops after stage3"
rm -rf "$WORK/tgt2" "$WORK/.tgt2.build"
RC=$(bash "$MOCK/build-all.sh" --no-iso "$WORK/tgt2" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "G1 exit 0"                          "[[ $RC -eq 0 ]]"
check "G2 no iso stamp"                    "[[ ! -f $WORK/.tgt2.build/stamps/iso.done ]]"
check "G3 hint for later ISO"             "OUT | grep -q -- '--from-stage iso'"

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
check "J2 five dry-run commands listed"   "[[ \$(OUT | grep -c 'would run:') -eq 5 ]]"
check "J3 nothing executed (no target)"   "[[ ! -e $WORK/tgt4 ]]"

say "K. adopt a hand-built seed (no stamp yet)"
rm -rf "$WORK/tgt5" "$WORK/.tgt5.build"
mkdir -p "$MOCK/seed"; echo seeddata > "$MOCK/seed/seed.tar.zst"
RC=$(bash "$MOCK/build-all.sh" "$WORK/tgt5" > "$WORK/last.out" 2>"$WORK/last.err"; echo $?)
check "K1 exit 0"                          "[[ $RC -eq 0 ]]"
check "K2 adoption notice"                "OUT | grep -q 'adopting existing'"
check "K3 seed stage not re-run"          "! OUT | grep -q 'mock: assembling seed'"
rm -f "$MOCK/seed/seed.tar.zst"

# ------------------------------------------------------------------ summary --
echo
printf '=====================\n  PASS: %d   FAIL: %d\n=====================\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
