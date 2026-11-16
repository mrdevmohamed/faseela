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
  service)
    action="$1"; name="$2"
    echo "service $root $action $name" >> "$STUB_LOG"
    link="$root/etc/runit/runsvdir/default/$name"
    case "$action" in
      disable) [[ -L $link ]] || exit 1; rm "$link"; mkdir -p "$root/etc/runit/disabled"; : > "$root/etc/runit/disabled/$name" ;;
      enable) [[ -x "$root/etc/sv/$name/run" ]] || exit 1; mkdir -p "$(dirname "$link")"; ln -s "/etc/sv/$name" "$link" ;;
      *) exit 2 ;;
    esac ;;
esac
STUB
chmod +x "$W/nawa"
export STUB_LOG="$W/calls.log"; : > "$STUB_LOG"
printf 'KEY\n' > "$W/key.pub"
: > "$W/services"
printf 'alpha\nbeta\ngamma\n' > "$W/order"

run() {   # $1 = order file, $2 = package the stub refuses ("" = none)
    env -i PATH="$PATH" ${RUN_ENV:-} STUB_LOG="$STUB_LOG" STUB_FAIL="${2:-}" HOME="$W" \
        FINAL_ROOT="$FINAL" NAWA_BIN="$W/nawa" FASEELA="$REPO" \
        FLAVOR_ORDER="$1" FLAVOR_SERVICES="$W/services" FLAVOR_KEY="$W/key.pub" FLAVOR_REPO="https://repo.example/stable" FLAVOR_FROM=repo \
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

# revdep: a binary whose library no package provides fails the image
: > "$STUB_LOG"; rm -rf "$FINAL"; mkdir -p "$FINAL"
printf '#!/bin/sh\necho "ELF 64-bit LSB"\n' > "$W/file"
printf '#!/bin/sh\necho " 0x1 (NEEDED)             Shared library: [libnope.so.9]"\n' > "$W/readelf"
chmod +x "$W/file" "$W/readelf"
if RUN_ENV="FILE_BIN=$W/file READELF_BIN=$W/readelf" run "$W/order" > "$W/out3.log" 2>&1; then
    fail "an unresolved library was accepted"
fi
grep -q 'needs libnope.so.9' "$W/out3.log"      || fail "missing library not named"
grep -q 'depends.run' "$W/out3.log"             || fail "no pointer to depends.run"

# Flavor service policy: disable the console getty/old display manager before
# enabling the greeter selected by the image profile.
: > "$STUB_LOG"; rm -rf "$FINAL"; mkdir -p "$FINAL/etc/sv/cosmic-greeter" "$FINAL/etc/sv/lightdm" "$FINAL/etc/sv/getty-tty1" "$FINAL/etc/runit/runsvdir/default"
for svc in cosmic-greeter lightdm getty-tty1; do printf '#!/bin/sh\\nexit 0\\n' > "$FINAL/etc/sv/$svc/run"; chmod +x "$FINAL/etc/sv/$svc/run"; done
ln -s /etc/sv/lightdm "$FINAL/etc/runit/runsvdir/default/lightdm"
ln -s /etc/sv/getty-tty1 "$FINAL/etc/runit/runsvdir/default/getty-tty1"
printf 'disable getty-tty1\\ndisable lightdm\\nenable cosmic-greeter\\n' > "$W/services"
run "$W/order" > "$W/out4.log" 2>&1 || { cat "$W/out4.log"; fail "service policy failed"; }
[[ ! -L "$FINAL/etc/runit/runsvdir/default/getty-tty1" ]] || fail "getty-tty1 remained enabled"
[[ ! -L "$FINAL/etc/runit/runsvdir/default/lightdm" ]] || fail "LightDM remained enabled"
[[ "$(readlink "$FINAL/etc/runit/runsvdir/default/cosmic-greeter")" == "/etc/sv/cosmic-greeter" ]] || fail "COSMIC greeter service was not enabled"
grep -q "^service $FINAL disable getty-tty1$" "$STUB_LOG" || fail "getty disable action not executed"
grep -q "^service $FINAL disable lightdm$" "$STUB_LOG" || fail "LightDM disable action not executed"
grep -q "^service $FINAL enable cosmic-greeter$" "$STUB_LOG" || fail "COSMIC greeter enable action not executed"

echo "test-mkflavor: ok"
