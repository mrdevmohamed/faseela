#!/usr/bin/env bash
# e2e CLI smoke test for dpm v0.5 features: signing, upgrade, rollback.
set -euo pipefail

# locate the repo relative to this script so it works from any checkout
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# override via env to smoke-test a release build: DPM=... MKFAKE=... ./smoke-v05.sh
DPM="${DPM:-$REPO_ROOT/pkgmgr/target/debug/dpm}"
MKFAKE="${MKFAKE:-$REPO_ROOT/pkgmgr/target/debug/examples/mkfake}"
WORK=$(mktemp -d /tmp/dpm-smoke-XXXX)
KEYS=$WORK/keys
ROOT=$WORK/root
REPO=$WORK/repo

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

py_make() { # name version rel body  ->  prints archive path
    local out="$WORK/$1-$2-$3.dpm.tar.zst"
    "$MKFAKE" "$1" "$2" "$3" "$out" "usr/bin/demo=$4" "etc/demo.conf=config $4" >/dev/null
    echo "$out"
}

echo "== 1. keygen (secret must be 0600) =="
$DPM keygen --out "$KEYS"
test "$(stat -c %a "$KEYS/dpm.sec")" = 600

A1=$(py_make demo 1.0 1 "v1")
A2=$(py_make demo 2.0 1 "v2")

echo "== 2. install unsigned v1 (no trust configured: bootstrap mode) =="
$DPM install --root "$ROOT" "$A1"
grep -q v1 "$ROOT/usr/bin/demo"

echo "== 3. trust the key; unsigned installs must now be refused =="
$DPM trust --root "$ROOT" "$KEYS/dpm.pub"
if $DPM install --root "$ROOT" "$A2" 2>/dev/null; then echo "FAIL: unsigned accepted"; exit 1; fi
echo "   (unsigned refused: OK)"

echo "== 4. sign v2; signed install must succeed =="
$DPM sign "$A2" --key "$KEYS/dpm.sec"
$DPM install --root "$ROOT" "$A2"
grep -q v2 "$ROOT/usr/bin/demo"

echo "== 5. tamper with a signed archive; install must fail =="
T=$(py_make demo 9.9 1 "evil")
$DPM sign "$T" --key "$KEYS/dpm.sec"
echo tampered >> "$T"
if $DPM install --root "$ROOT" "$T" 2>/dev/null; then echo "FAIL: tampered accepted"; exit 1; fi
echo "   (tampered refused: OK)"

echo "== 6. rollback v2 -> v1 =="
$DPM rollback --root "$ROOT" demo
grep -q v1 "$ROOT/usr/bin/demo"

echo "== 7. signed repo + upgrade 1.0 -> 2.0 =="
mkdir -p "$REPO" && cp "$A2" "$REPO/" && cp "$A2.sig" "$REPO/"
$DPM repo-create "$REPO" --sign --key "$KEYS/dpm.sec"
$DPM verify --root "$ROOT" --key "$KEYS/dpm.pub" "$REPO/index.toml"
$DPM upgrade --yes --root "$ROOT" --repo "$REPO"
grep -q v2 "$ROOT/usr/bin/demo"

echo "== 8. rollback ping-pong: 2.0 -> 1.0 -> 2.0 =="
$DPM rollback --root "$ROOT" demo && grep -q v1 "$ROOT/usr/bin/demo"
$DPM rollback --root "$ROOT" demo && grep -q v2 "$ROOT/usr/bin/demo"

echo "== 9. config protection across upgrade (v3) =="
$DPM rollback --root "$ROOT" demo            # back to v1
echo "my local tweak" > "$ROOT/etc/demo.conf"
A3=$(py_make demo 3.0 1 "v3")
$DPM sign "$A3" --key "$KEYS/dpm.sec"
cp "$A3" "$REPO/" && cp "$A3.sig" "$REPO/"
$DPM repo-create "$REPO" --sign --key "$KEYS/dpm.sec"
$DPM upgrade --yes --root "$ROOT" --repo "$REPO"
grep -q "my local tweak" "$ROOT/etc/demo.conf"
grep -q "config v3" "$ROOT/etc/demo.conf.dpm-new"
grep -q v3 "$ROOT/usr/bin/demo"
echo "   (/etc edit preserved + .dpm-new diversion: OK)"

echo
echo "ALL SMOKE TESTS PASSED"
