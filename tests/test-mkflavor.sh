#!/usr/bin/env bash
# tests/test-mkflavor.sh — mkflavor-inner.sh against a throwaway tree with a stub
# nawa: the packages of the order file are installed ONE BY ONE in that order
# with --no-deps in repo mode, but with dependency resolution in auto mode so missing packages get their build toolchain; the distribution key is trusted, a package
# the repository lacks stops the build with a pointer to the package workflow,
# and the rollback/remote cache is dropped. Needs no root and no real build.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

FINAL="$W/final"; mkdir -p "$FINAL"
cat > "$W/nawa" <<'STUB'
#!/usr/bin/env bash
# nawa [--recipes D] --root R <trust KEY | install [--no-deps] --from M [--repo U] PKG>
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
# offline systemctl on a root: --root DIR {is-enabled|enable|disable} UNIT
cat > "$W/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ $1 == --root ]] || exit 2
root="$2"; action="$3"; unit="$4"
echo "systemctl $root $action $unit" >> "$STUB_LOG"
link="$root/etc/systemd/system/multi-user.target.wants/$unit"
case "$action" in
  is-enabled) [[ -L $link ]] ;;
  disable) [[ -L $link ]] || exit 1; rm "$link" ;;
  enable) [[ -f "$root/usr/lib/systemd/system/${unit/@*./@.}" || -f "$root/usr/lib/systemd/system/$unit" ]] || exit 1
          mkdir -p "$(dirname "$link")"; ln -s "/usr/lib/systemd/system/$unit" "$link" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$W/systemctl"
export STUB_LOG="$W/calls.log"; : > "$STUB_LOG"
printf 'KEY\n' > "$W/key.pub"
: > "$W/services"
printf 'alpha\nbeta\ngamma\n' > "$W/order"

run() {   # $1 = order file, $2 = package the stub refuses ("" = none)
    env -i PATH="$PATH" FLAVOR_BUILD_NAWA=0 ${RUN_ENV:-} STUB_LOG="$STUB_LOG" STUB_FAIL="${2:-}" HOME="$W" \
        FINAL_ROOT="$FINAL" NAWA_BIN="$W/nawa" FLAVOR_SYSTEMCTL="$W/systemctl" FASEELA="$REPO" \
        FLAVOR_ORDER="$1" FLAVOR_SERVICES="$W/services" FLAVOR_KEY="$W/key.pub" FLAVOR_REPO="https://repo.example/stable" FLAVOR_FROM="${3:-repo}" \
        bash "$REPO/bootstrap/mkflavor-inner.sh"
}

run "$W/order" > "$W/out.log" 2>&1 || { cat "$W/out.log"; fail "inner script failed"; }
installs="$(grep '^install ' "$STUB_LOG" | sed 's/.* //' | tr '\n' ' ')"
[[ $installs == "alpha beta gamma " ]] || fail "install order: $installs"
grep -q "^trust / $W/key.pub" "$STUB_LOG"      || fail "key not trusted in the build root"
grep -q "^trust $FINAL $W/key.pub" "$STUB_LOG" || fail "key not trusted in the image"
[[ "$(grep -c -- '--from repo --no-deps --repo https://repo.example/stable' "$STUB_LOG")" == 3 ]] \
    || fail "every install must be --no-deps --from repo --repo URL: $(cat "$STUB_LOG")"
[[ -z "$(ls -A "$FINAL/var/cache/nawa")" ]] || fail "var/cache/nawa not emptied"

# auto mode may compile missing packages, so dependency resolution must remain
# enabled; otherwise build dependencies such as Meson are never installed.
: > "$STUB_LOG"; rm -rf "$FINAL"; mkdir -p "$FINAL"
run "$W/order" "" auto > "$W/auto.log" 2>&1 || { cat "$W/auto.log"; fail "auto mode failed"; }
[[ "$(grep -c -- '--from auto' "$STUB_LOG")" == 3 ]] || fail "auto installs did not use --from auto"
if grep -q -- '--no-deps' "$STUB_LOG"; then
    fail "auto mode suppressed build dependencies: $(cat "$STUB_LOG")"
fi

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
U="usr/lib/systemd/system"; WANTS="etc/systemd/system/multi-user.target.wants"
: > "$STUB_LOG"; rm -rf "$FINAL"; mkdir -p "$FINAL/$U" "$FINAL/$WANTS"
for svc in cosmic-greeter.service lightdm.service getty@.service; do : > "$FINAL/$U/$svc"; done
ln -s "/$U/lightdm.service" "$FINAL/$WANTS/lightdm.service"
ln -s "/$U/getty@.service" "$FINAL/$WANTS/getty@tty1.service"
printf '%s\n' 'disable getty@tty1' 'disable lightdm' 'enable cosmic-greeter' > "$W/services"
run "$W/order" > "$W/out4.log" 2>&1 || { cat "$W/out4.log"; fail "service policy failed"; }
[[ ! -L "$FINAL/$WANTS/getty@tty1.service" ]] || fail "getty@tty1 remained enabled"
[[ ! -L "$FINAL/$WANTS/lightdm.service" ]] || fail "LightDM remained enabled"
[[ "$(readlink "$FINAL/$WANTS/cosmic-greeter.service")" == "/$U/cosmic-greeter.service" ]] || fail "COSMIC greeter unit was not enabled"
grep -q "^systemctl $FINAL disable getty@tty1.service$" "$STUB_LOG" || fail "getty disable action not executed"
grep -q "^systemctl $FINAL disable lightdm.service$" "$STUB_LOG" || fail "LightDM disable action not executed"
grep -q "^systemctl $FINAL enable cosmic-greeter.service$" "$STUB_LOG" || fail "COSMIC greeter enable action not executed"

# The seed's nawa may predate schema v5: the pinned nawa is compiled with the
# seed's cargo and installed BEFORE anything is installed from the repository,
# and an unchanged pin is not rebuilt.
mkdir -p "$W/fasl/nawa" "$W/bin"
: > "$W/fasl/nawa/Cargo.toml"; : > "$W/fasl/nawa/Cargo.lock"; printf 'PINSHA\n' > "$W/fasl/nawa/.pinned-sha256"
mkdir -p "$W/fasl/bootstrap"; cp "$REPO/bootstrap/final-root.sh" "$REPO/bootstrap/package-repo.sh" "$W/fasl/bootstrap/"
cat > "$W/bin/cargo" <<'STUB'
#!/usr/bin/env bash
echo "cargo $*" >> "$STUB_LOG"
if [[ $1 == build ]]; then
    mkdir -p target/release
    printf '#!/bin/sh\necho "nawa pinned"\n' > target/release/nawa; chmod +x target/release/nawa
fi
STUB
chmod +x "$W/bin/cargo"
pinned() {
    env -i PATH="$PATH" FLAVOR_CARGO_DIR="$W/bin" STUB_LOG="$STUB_LOG" STUB_FAIL="" HOME="$W" FINAL_ROOT="$FINAL" \
        NAWA_BIN="$W/nawa-installed" FLAVOR_NAWA_STAMP="$W/nawa.stamp" FLAVOR_SYSTEMCTL="$W/systemctl" \
        FASEELA="$W/fasl" FLAVOR_ORDER="$W/order" FLAVOR_SERVICES="$W/services" FLAVOR_KEY="$W/key.pub" \
        FLAVOR_REPO="https://repo.example/stable-v5" FLAVOR_FROM=repo \
        bash "$REPO/bootstrap/mkflavor-inner.sh"
}
: > "$STUB_LOG"; rm -rf "$FINAL"; mkdir -p "$FINAL"
# the stub nawa must run as the installed binary AFTER the cargo build replaced it
if pinned > "$W/pin.log" 2>&1; then :; else grep -q 'nawa pinned' "$W/pin.log" || { cat "$W/pin.log"; fail "pinned nawa was not built and installed"; }; fi
grep -q '^cargo build --release --offline --locked' "$STUB_LOG" || fail "pinned nawa was not compiled"
[[ -x $W/nawa-installed ]] || fail "pinned nawa was not installed"
[[ "$(cat "$W/nawa.stamp")" == PINSHA ]] || fail "pin stamp not written"
: > "$STUB_LOG"; rm -rf "$FINAL"; mkdir -p "$FINAL"
pinned > "$W/pin2.log" 2>&1 || true
grep -q '^cargo build' "$STUB_LOG" && fail "an unchanged pin was rebuilt"
grep -q 'already at the pinned source' "$W/pin2.log" || fail "no skip message for an unchanged pin"

echo "test-mkflavor: ok"
