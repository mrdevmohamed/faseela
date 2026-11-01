#!/usr/bin/env bash
# tests/test-verify-reproducible.sh — the `compare` half of verify-reproducible.sh
# (the `run` half needs a real chroot).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
V="$REPO/bootstrap/verify-reproducible.sh"
mkdir -p "$W/a" "$W/b"
for d in a b; do echo same > "$W/$d/glibc-2.40-1.nawa.tar.zst"; done
export EXCEPTIONS="$W/exc"; : > "$EXCEPTIONS"

bash "$V" compare "$W/a" "$W/b" > "$W/o" || fail "identical sets reported as different"
grep -q '1 identical, 0 differ' "$W/o" || fail "summary: $(cat "$W/o")"

echo x > "$W/a/gcc-14.2-1.nawa.tar.zst"; echo y > "$W/b/gcc-14.2-1.nawa.tar.zst"
bash "$V" compare "$W/a" "$W/b" > "$W/o" && fail "a differing package was accepted"
grep -q 'DIFFERS: gcc-14.2-1' "$W/o" || fail "gcc not named: $(cat "$W/o")"

echo gcc > "$EXCEPTIONS"      # a known exception is reported, not failed
bash "$V" compare "$W/a" "$W/b" > "$W/o" || fail "known exception failed the check"
grep -q 'known:   gcc-14.2-1' "$W/o" || fail "exception not reported"

: > "$W/b/extra-1-1.nawa.tar.zst"
bash "$V" compare "$W/a" "$W/b" > "$W/o" && fail "an archive only in stage 4 was accepted"
grep -q 'only stage 4: extra-1-1' "$W/o" || fail "extra archive not named"

mkdir "$W/e1" "$W/e2"
bash "$V" compare "$W/e1" "$W/e2" > /dev/null 2>&1 && fail "empty sets accepted"
echo "test-verify-reproducible: ok"
