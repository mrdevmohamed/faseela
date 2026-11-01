#!/usr/bin/env bash
# tests/test-check-closure.sh — scripts/check-closure.py: a package whose ELF
# needs a library that no package of the flavor provides is reported (the
# perl -> libxcrypt case that failed stage3 after two hours).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FLAVOR_PY="${FLAVOR_PY:-$REPO/scripts/flavor.py}"
[[ -f $FLAVOR_PY ]] || FLAVOR_PY="$REPO/../faseela-repo/scripts/flavor.py"
[[ -f $FLAVOR_PY ]] || { echo "test-check-closure: skipped (no flavor.py)"; exit 0; }
command -v readelf >/dev/null || { echo "test-check-closure: skipped (no readelf)"; exit 0; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$W/scripts" "$W/recipes" "$W/arch" "$W/p"
cp "$REPO/scripts/check-closure.py" "$FLAVOR_PY" "$W/scripts/"
rec() { mkdir -p "$W/recipes/base/$1"; printf '[package]\nname = "%s"\nversion = "1"\nrel = 1\n[depends]\nrun = [%s]\n' "$1" "$2" > "$W/recipes/base/$1/recipe.toml"; }
rec glibc ''; rec perl '"glibc"'
printf '[flavor.t]\ninclude = ["glibc", "perl"]\n' > "$W/flavors.toml"

# an ELF that needs libc.so.6 (the host's /bin/true), and a package that provides it
mkdir -p "$W/p/perl/usr/bin" "$W/p/glibc/usr/lib"
cp /bin/true "$W/p/perl/usr/bin/perl"
: > "$W/p/glibc/usr/lib/libc.so.6"   # a file of that name is all the check looks for
for x in perl glibc; do tar -czf "$W/arch/$x-1-1.nawa.tar.zst" -C "$W/p/$x" .; done
chk() { python3 -I "$W/scripts/check-closure.py" "$@"; }

chk "$W/arch" t || fail "complete closure rejected"
rm "$W/arch/glibc-1-1.nawa.tar.zst"
out="$(chk "$W/arch" t)" && fail "missing library not detected"
grep -q 'perl: .*needs libc.so.6' <<< "$out" || fail "perl / libc.so.6 not named: $out"
grep -q '^::error' <<< "$out" || fail "no ::error annotation: $out"
echo "test-check-closure: ok"
