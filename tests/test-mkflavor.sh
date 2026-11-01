#!/usr/bin/env bash
# tests/test-mkflavor.sh — mkflavor-inner.sh against a throwaway tree with a stub
# nawa: the packages of the order file are installed ONE BY ONE in that order
# with --no-deps from the repository, the distribution key is trusted, a package
# the repository lacks stops the build with a pointer to the package workflow,
# and the rollback/remote cache is dropped. Needs no root and no real build.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

FINAL="$W/final"; mkdir -p "$FINAL"
cat > "$W/nawa" <<'STUB'
#!/usr/bin/env bash
# nawa [--recipes D] --root R <trust KEY | install --no-deps --from M [--repo U] PKG>
args=("$@"); root=/
while [[ ${1:-} == --* ]]; do
    case "$1" in --root) root="$2"; shift 2 ;; --recipes) shift 2 ;; *) break ;; esac
done
cmd="$1"; shift
case "$cmd" in
  trust) echo "trust $root $1" >> "$STUB_LOG" ;;
  install)
    pkg="${!#}"
    echo "install $root ${args[*]}" >> "$STUB_LOG"
    [[ $pkg == "$STUB_FAIL" ]] && { echo "nawa: error: $pkg is not in the repository" >&2; exit 1; }
    mkdir -p "$root/var/lib/nawa/local/$pkg" "$root/var/cache/nawa/remote/x" "$root/usr/bin" "$root/usr/lib"
    : > "$root/var/cache/nawa/remote/x/$pkg.nawa.tar.zst"
    : > "$root/usr/bin/bash"; : > "$root/usr/bin/nawa"; : > "$root/usr/lib/libc.so.6" ;;
esac
STUB
chmod +x "$W/nawa"
export STUB_LOG="$W/calls.log"; : > "$STUB_LOG"
printf 'KEY\n' > "$W/key.pub"
printf 'alpha\nbeta\ngamma\n' > "$W/order"

run() {   # $1 = order file, $2 = package the stub refuses ("" = none)
    env -i PATH="$PATH" STUB_LOG="$STUB_LOG" STUB_FAIL="${2:-}" HOME="$W" \
        FINAL_ROOT="$FINAL" NAWA_BIN="$W/nawa" FASEELA="$REPO" \
        FLAVOR_ORDER="$1" FLAVOR_KEY="$W/key.pub" FLAVOR_REPO="https://repo.example/stable" FLAVOR_FROM=repo \
        bash "$REPO/bootstrap/mkflavor-inner.sh"
}

run "$W/order" > "$W/out.log" 2>&1 || { cat "$W/out.log"; fail "inner script failed"; }
installs="$(grep '^install ' "$STUB_LOG" | sed 's/.* //' | tr '\n' ' ')"
[[ $installs == "alpha beta gamma " ]] || fail "install order: $installs"
grep -q "^trust / $W/key.pub" "$STUB_LOG"      || fail "key not trusted in the build root"
grep -q "^trust $FINAL $W/key.pub" "$STUB_LOG" || fail "key not trusted in the image"
[[ "$(grep -c -- '--no-deps --from repo --repo https://repo.example/stable' "$STUB_LOG")" == 3 ]] \
    || fail "every install must be --no-deps --from repo --repo URL: $(cat "$STUB_LOG")"
[[ -z "$(ls -A "$FINAL/var/cache/nawa")" ]] || fail "var/cache/nawa not emptied"

# a package the repository lacks: hard error, the rest is not attempted, hint given
: > "$STUB_LOG"; rm -rf "$FINAL"; mkdir -p "$FINAL"
if run "$W/order" beta > "$W/out2.log" 2>&1; then fail "missing package was accepted"; fi
grep -q 'could not install beta' "$W/out2.log" || fail "missing-package message absent"
grep -q 'flavor:<name>' "$W/out2.log"          || fail "no pointer to the package workflow"
grep -q 'install .* gamma$' "$STUB_LOG" && fail "installation went on after a failure"

: > "$W/empty"
if run "$W/empty" > /dev/null 2>&1; then fail "empty order accepted"; fi
echo "test-mkflavor: ok"
