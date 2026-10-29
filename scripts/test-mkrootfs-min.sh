#!/usr/bin/env bash
# scripts/test-mkrootfs-min.sh — mkrootfs-min-inner.sh against a throwaway
# tree with a stub dpm (same pattern as test-final-root.sh): proves that the
# packages of the order file are installed in that order, from the newest
# archive, that a missing archive is a hard error, and that the rollback cache
# is dropped.  Needs no root and no real build.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

BUILD="$W/build-root"; FINAL="$W/final"
mkdir -p "$BUILD/build3/out" "$BUILD/build/out" "$BUILD/var/cache/dpm" "$FINAL"
# alpha has two versions: the newest must win; beta only exists in build/out
: > "$BUILD/build3/out/alpha-1.0-1.dpm.tar.zst"
: > "$BUILD/build3/out/alpha-1.10-1.dpm.tar.zst"
: > "$BUILD/build/out/beta-2-1.dpm.tar.zst"

# stub dpm: `dpm --root R install --force ARCHIVE` records the call and fakes
# the files finalize_final_root insists on
cat > "$W/dpm" <<'STUB'
#!/usr/bin/env bash
root="$2"; archive="$5"
base="$(basename "$archive")"; pkg="${base%%-[0-9]*}"
echo "$pkg $base" >> "$STUB_LOG"
mkdir -p "$root/var/lib/dpm/local/$pkg" "$root/var/cache/dpm" "$root/usr/bin" "$root/usr/lib"
: > "$root/var/cache/dpm/$base"
: > "$root/usr/bin/bash"; : > "$root/usr/bin/dpm"; : > "$root/usr/lib/libc.so.6"
STUB
chmod +x "$W/dpm"
export STUB_LOG="$W/calls.log"; : > "$STUB_LOG"

printf 'alpha\nbeta\n' > "$W/order"
run() {
    env -i PATH="$PATH" STUB_LOG="$STUB_LOG" HOME="$W" \
        FINAL_ROOT="$FINAL" BUILD_ROOT="$BUILD" DPM_BIN="$W/dpm" \
        MIN_ORDER="$1" MYDISTRO="$REPO" \
        bash "$REPO/bootstrap/mkrootfs-min-inner.sh"
}

run "$W/order" > "$W/out.log" 2>&1 || { cat "$W/out.log"; fail "inner script failed"; }
[[ "$(cut -d' ' -f1 "$STUB_LOG" | tr '\n' ' ')" == "alpha beta " ]] || fail "install order: $(cat "$STUB_LOG")"
grep -q 'alpha-1.10-1' "$STUB_LOG" || fail "newest alpha archive not used"
[[ -d $FINAL/var/lib/dpm/local/alpha && -d $FINAL/var/lib/dpm/local/beta ]] || fail "packages not recorded"
[[ -z "$(ls -A "$FINAL/var/cache/dpm")" ]] || fail "var/cache/dpm not emptied"

# a package without an archive must stop the build, loudly
printf 'alpha\nmissing\n' > "$W/order2"
if run "$W/order2" > "$W/out2.log" 2>&1; then fail "missing archive was accepted"; fi
grep -q 'no archive of missing' "$W/out2.log" || fail "missing-archive message absent"

# an empty / absent order file is an error too
: > "$W/empty"
if run "$W/empty" > /dev/null 2>&1; then fail "empty order accepted"; fi

# the closure helper: dependencies come first, cycles do not loop, unknown names fail
mkdir -p "$W/rec/base/a" "$W/rec/base/b" "$W/rec/base/c"
printf '[depends]\nrun = ["b", "c"]\n' > "$W/rec/base/a/recipe.toml"
printf '[depends]\nrun = ["c"]\n'      > "$W/rec/base/b/recipe.toml"
printf '[depends]\nrun = ["b"]\n'      > "$W/rec/base/c/recipe.toml"   # b <-> c cycle
out="$(python3 "$REPO/scripts/rootfs-closure.py" "$W/rec" a | tr '\n' ' ')"
[[ "$out" == "c b a " ]] || fail "closure order: '$out'"
if python3 "$REPO/scripts/rootfs-closure.py" "$W/rec" nope >/dev/null 2>&1; then fail "unknown package accepted"; fi

echo "test-mkrootfs-min: all checks passed"
