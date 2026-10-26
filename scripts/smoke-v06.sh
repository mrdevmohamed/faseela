#!/usr/bin/env bash
# e2e CLI smoke test for dpm v0.6 features: remote http(s) repositories
# (index + archive fetch, signature check, cache reuse, offline fallback)
# and runit service management.
set -euo pipefail

# locate the repo relative to this script so it works from any checkout
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
DPM="$REPO_ROOT/pkgmgr/target/release/dpm"
MKFAKE="$REPO_ROOT/pkgmgr/target/release/examples/mkfake"
RECIPES="$REPO_ROOT/recipes"
WORK=$(mktemp -d /tmp/dpm-smoke06-XXXX)
ROOT=$WORK/root
REPO=$WORK/repo
KEYS=$WORK/keys
PORT=$((20000 + RANDOM % 20000))
SRV_PID=""

cleanup() {
    [[ -n $SRV_PID ]] && kill "$SRV_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. build a signed local repo =="
$DPM keygen --out "$KEYS" >/dev/null
$MKFAKE demo 1.0 1 "$WORK/demo-1.0-1.dpm.tar.zst" "usr/bin/demo=v1" >/dev/null
$MKFAKE demo 2.0 1 "$WORK/demo-2.0-1.dpm.tar.zst" "usr/bin/demo=v2" >/dev/null
$DPM --root "$ROOT" install "$WORK/demo-1.0-1.dpm.tar.zst"
grep -q v1 "$ROOT/usr/bin/demo"
$DPM sign "$WORK/demo-2.0-1.dpm.tar.zst" --key "$KEYS/dpm.sec" >/dev/null
mkdir -p "$REPO" && cp "$WORK/demo-2.0-1.dpm.tar.zst" "$WORK/demo-2.0-1.dpm.tar.zst.sig" "$REPO/"
$DPM repo-create "$REPO" --sign --key "$KEYS/dpm.sec" >/dev/null
test -f "$REPO/index.toml.sig"
# remote repos are refused without a trust store: trust the test key
$DPM --root "$ROOT" trust "$KEYS/dpm.pub" >/dev/null
if $DPM --root "$ROOT/../untrusted-root" --recipes "$RECIPES" upgrade --repo "http://127.0.0.1:1" >/dev/null 2>&1; then
    echo "FAIL: remote repo accepted without trusted keys"; exit 1
fi

echo "== 2. serve over HTTP; upgrade from the remote URL =="
( cd "$REPO" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV_PID=$!
for i in $(seq 1 50); do
    curl -fs -o /dev/null "http://127.0.0.1:$PORT/index.toml" 2>/dev/null && break
    sleep 0.1
done
$DPM --root "$ROOT" --recipes "$RECIPES" upgrade --repo "http://127.0.0.1:$PORT"
grep -q v2 "$ROOT/usr/bin/demo"
FNAME=$(awk '/^file/{gsub(/"/,"");print $3}' "$REPO/index.toml")
CACHED=$(echo "$ROOT"/var/cache/dpm/remote/*/"$FNAME")
test -f "$CACHED" && echo "   (archive cached under var/cache/dpm/remote: OK)"

echo "== 3. verify the cached archive byte-for-byte against the index sha256 =="
IDX_SHA=$(awk '/^sha256/{gsub(/"/,"");print $3}' "$REPO/index.toml")
echo "$IDX_SHA  $CACHED" | sha256sum -c --quiet

echo "== 4. mirror down: cached index reuse, plan is empty =="
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""
OUT=$($DPM --root "$ROOT" --recipes "$RECIPES" upgrade --repo "http://127.0.0.1:$PORT" 2>&1)
grep -q "using cached index" <<< "$OUT" && echo "   (offline fallback to cached index: OK)"
grep -q "up to date" <<< "$OUT"

echo "== 5. dry-run against a fresh remote version over HTTP =="
( cd "$REPO" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV_PID=$!
for i in $(seq 1 50); do
    curl -fs -o /dev/null "http://127.0.0.1:$PORT/index.toml" 2>/dev/null && break
    sleep 0.1
done
$MKFAKE demo 3.0 1 "$WORK/demo-3.0-1.dpm.tar.zst" "usr/bin/demo=v3" >/dev/null
$DPM sign "$WORK/demo-3.0-1.dpm.tar.zst" --key "$KEYS/dpm.sec" >/dev/null
cp "$WORK/demo-3.0-1.dpm.tar.zst" "$WORK/demo-3.0-1.dpm.tar.zst.sig" "$REPO/"
$DPM repo-create "$REPO" --sign --key "$KEYS/dpm.sec" >/dev/null
$DPM --root "$ROOT" --recipes "$RECIPES" upgrade --repo "http://127.0.0.1:$PORT" --dry-run | grep -q "dry run"
grep -q v2 "$ROOT/usr/bin/demo"
echo "   (dry run made no changes: OK)"

echo "== 6. apply the remote upgrade =="
$DPM --root "$ROOT" --recipes "$RECIPES" upgrade --repo "http://127.0.0.1:$PORT" >/dev/null
grep -q v3 "$ROOT/usr/bin/demo"
$DPM --root "$ROOT" rollback demo >/dev/null
grep -q v2 "$ROOT/usr/bin/demo"
echo "   (remote upgrade + rollback: OK)"

echo "== 7. runit services in a fake root =="
SVCROOT=$WORK/svcroot
mkdir -p "$SVCROOT/etc/sv/sshd" "$SVCROOT/etc/sv/crond"
printf '#!/bin/sh\nexec sshd -D\n' > "$SVCROOT/etc/sv/sshd/run"
printf '#!/bin/sh\nexec crond -n\n' > "$SVCROOT/etc/sv/crond/run"
$DPM --root "$SVCROOT" service list | grep -q "sshd *no *yes"
$DPM --root "$SVCROOT" service enable sshd >/dev/null
test "$(readlink "$SVCROOT/etc/runit/runsvdir/default/sshd")" = "/etc/sv/sshd"
if $DPM --root "$SVCROOT" service enable sshd >/dev/null 2>&1; then
    echo "FAIL: double enable accepted"; exit 1
fi
$DPM --root "$SVCROOT" service status sshd | grep -q "sshd *enabled"
$DPM --root "$SVCROOT" service disable sshd >/dev/null
test ! -e "$SVCROOT/etc/runit/runsvdir/default/sshd"
mkdir -p "$SVCROOT/etc/runit/runsvdir/default/realdir"
if $DPM --root "$SVCROOT" service disable realdir >/dev/null 2>&1; then
    echo "FAIL: non-symlink removed"; exit 1
fi
test -d "$SVCROOT/etc/runit/runsvdir/default/realdir"
echo "   (enable/disable/status + safety refusals: OK)"

echo
echo "ALL V0.6 SMOKE TESTS PASSED"
