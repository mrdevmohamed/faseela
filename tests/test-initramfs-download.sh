#!/usr/bin/env bash
# test-initramfs-download.sh — initramfs.sh gets the busybox source from the first
# source that works AND matches the recipe's sha256 (busybox.net was unreachable
# from CI once and the run died on four 135 s timeouts). No network: file:// mirrors.
set -uo pipefail
REPO="${FASEELA_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/initramfs-dl.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

mkdir -p "$W/repo/bootstrap" "$W/repo/recipes/boot/busybox" "$W/root"
cp "$REPO/bootstrap/initramfs.sh" "$W/repo/bootstrap/"
echo "pretend busybox" > "$W/good.tar.bz2"; echo junk > "$W/bad.tar.bz2"
H="$(sha256sum "$W/good.tar.bz2" | cut -d' ' -f1)"
printf '[package]\nversion = "9.9"\nsource = "https://127.0.0.1:9/downloads/busybox-%%{version}.tar.bz2"\nsha256 = "%s"\n' "$H" > "$W/repo/recipes/boot/busybox/recipe.toml"
run() { # run <mirrors> <cache>
    (cd "$W/repo" && BUSYBOX_MIRRORS="$1" NAWA_SRCCACHE="$2" timeout 120 bash bootstrap/initramfs.sh --root "$W/root" --out "$W/o.img" 2>&1)
}
run "file://$W/bad.tar.bz2 file://$W/good.tar.bz2" "$W/c1" > "$W/log1"
check "a dead primary and a corrupt mirror fall through to a good one" "cmp -s $W/c1/busybox-9.9.tar.bz2 $W/good.tar.bz2"
check "the corrupt download is not kept"                               "[[ ! -e $W/c1/busybox-9.9.tar.bz2.part ]]"
run "file://$W/bad.tar.bz2" "$W/c2" > "$W/log2"; rc=$?
check "only bad sources: it stops, saying how to supply the file"      "grep -q 'could not download busybox' $W/log2 && grep -q -- '--src' $W/log2 && [[ ! -e $W/c2/busybox-9.9.tar.bz2 ]]"
check "the default list has a mirror besides busybox.net"              "grep -q 'sources.buildroot.net/busybox' $REPO/bootstrap/initramfs.sh"
check "the connection timeout is short"                                "grep -q -- '--connect-timeout 20' $REPO/bootstrap/initramfs.sh"
check "CI caches the source"                                           "grep -q 'busybox-src-' $REPO/.github/workflows/release.yml"
echo; echo "  PASS: $PASS   FAIL: $FAIL"; [[ $FAIL -eq 0 ]]
