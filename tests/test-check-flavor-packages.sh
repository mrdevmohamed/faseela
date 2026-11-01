#!/usr/bin/env bash
# tests/test-check-flavor-packages.sh — scripts/check-flavor-packages.py on a
# synthetic faseela tree (the resolver is faseela-repo's; a copy is used here).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FLAVOR_PY="${FLAVOR_PY:-$REPO/scripts/flavor.py}"
[[ -f $FLAVOR_PY ]] || FLAVOR_PY="$REPO/../faseela-repo/scripts/flavor.py"
[[ -f $FLAVOR_PY ]] || { echo "test-check-flavor-packages: skipped (no flavor.py: run bootstrap/fetch-recipes.sh)"; exit 0; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$W/scripts" "$W/recipes"
cp "$REPO/scripts/check-flavor-packages.py" "$FLAVOR_PY" "$W/scripts/"
rec() { mkdir -p "$W/recipes/$2/$1"; printf '[package]\nname = "%s"\nversion = "%s"\nrel = %s\n[depends]\nrun = [%s]\n' "$1" "$3" "$4" "$5" > "$W/recipes/$2/$1/recipe.toml"; }
rec glibc base 2.40 1 ''
rec nawa base 1.0 6 '"glibc"'
rec vim extra 9.1 2 '"glibc"'
rec sway gui 1.9 1 '"glibc"'
cat > "$W/flavors.toml" <<'T'
[flavor.bootstrap]
include = ["nawa"]
[flavor.iso-nogui]
include = ["@base", "@extra"]
[flavor.iso-gui]
extends = ["iso-nogui"]
include = ["@gui"]
T
chk() { python3 -I "$W/scripts/check-flavor-packages.py" "$@"; }

printf 'vim-9.1-2.nawa.tar.zst\n' > "$W/assets"
out="$(chk "$W/assets" iso-nogui)" || fail "complete flavor reported missing: $out"
grep -q 'all 1 packages' <<< "$out" || fail "bootstrap packages must not be expected in the repository: $out"

out="$(chk "$W/assets" iso-gui)" && fail "missing sway not detected"
grep -q 'sway' <<< "$out" || fail "sway not named: $out"

printf 'vim-9.0-1.nawa.tar.zst\n' > "$W/assets"   # an OLD version is not the recipe's version
chk "$W/assets" iso-nogui > /dev/null && fail "stale version accepted"
echo "test-check-flavor-packages: ok"
