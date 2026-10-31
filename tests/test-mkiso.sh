#!/usr/bin/env bash
# test-mkiso.sh — unit test of bootstrap/mkiso.sh (stage 4) with stub host
# tools. Covers:
#   * the host-tool fail-fast gate (xorriso is new — validated here)
#   * the preconditions (kernel, runit) before any work happens
#   * the STRUCTURAL validation of the produced image: a listing without a
#     boot-critical member must fail the stage instead of shipping an ISO
#     that cannot boot
#   * failure propagation from initramfs/mksquashfs (non-zero in = non-zero out)
#   * knob propagation (VOL_ID, SQUASH_COMP reach the tools)
#
# No root and no real ISO tooling is needed — everything is stubbed.
set -uo pipefail
REPO="${MYDISTRO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/mkiso-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
OUT() { cat "$W/last.out"; }
ERR() { cat "$W/last.err"; }

BIN="$W/bin"; mkdir -p "$BIN"

# ---- stub host tools ---------------------------------------------------------
# every stub records its invocation in $STUB_LOG so the tests can assert on
# the arguments mkiso.sh passed down
cat > "$BIN/mksquashfs" <<'EOF'
#!/bin/sh
echo "mksquashfs $*" >> "$STUB_LOG"
: > "$2"
EOF
cat > "$BIN/grub-mkrescue" <<'EOF'
#!/bin/sh
echo "grub-mkrescue $*" >> "$STUB_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
dd if=/dev/zero of="$out" bs=1K count=8 status=none
EOF
cat > "$BIN/xorriso" <<'EOF'
#!/bin/sh
# fake xorriso: `-indev ISO -ls DIR` prints the members under DIR recorded in
# $XORRISO_LS (one absolute path per line) as bare names — mimicking the
# variable listing formats real xorriso versions emit
dir=""; prev=""
for a in "$@"; do [ "$prev" = "-ls" ] && dir="$a"; prev="$a"; done
[ -n "$dir" ] && grep "^$dir/" "$XORRISO_LS" 2>/dev/null | sed "s|^$dir/||"
exit 0
EOF
cat > "$BIN/initramfs" <<'EOF'
#!/bin/sh
echo "initramfs $*" >> "$STUB_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = "--out" ] && out="$a"; prev="$a"; done
printf 'initramfs-bytes' > "$out"
EOF
chmod +x "$BIN"/*
export STUB_LOG="$W/stub.log"

# ---- root fixture ------------------------------------------------------------
ROOT="$W/root"
mkdir -p "$ROOT/boot" "$ROOT/usr/bin" "$ROOT/etc/runit"
echo fake-kernel > "$ROOT/boot/vmlinuz-6.1.0-fake"
printf '#!/bin/sh\n' > "$ROOT/usr/bin/runit"; chmod +x "$ROOT/usr/bin/runit"
echo 'stage 1' > "$ROOT/etc/runit/1"
KVER="vmlinuz-6.1.0-fake"

XORRISO_LS="$W/ls.txt"; export XORRISO_LS
good_ls() {   # the listing of a correctly built image
    printf '/boot/%s\n/boot/initramfs.img\n/boot/grub/grub.cfg\n/live/rootfs.squashfs\n' "$KVER" > "$XORRISO_LS"
}

RUN_MKISO() {  # RUN_MKISO [VAR=value ...] -> exit code; output in last.out/last.err
    : > "$STUB_LOG"
    env PATH="$BIN:$PATH" INITRAMFS_BIN="$BIN/initramfs" "$@" \
        bash "$REPO/bootstrap/mkiso.sh" "$ROOT" "$W/out/my.iso" \
        > "$W/last.out" 2> "$W/last.err"
    echo $?
}

# ---- A. host-tool fail-fast gate ---------------------------------------------
good_ls
if command -v xorriso >/dev/null 2>&1; then
    # a host with a real xorriso cannot simulate its absence via PATH
    echo "SKIP A (host provides a real xorriso)"
else
    mv "$BIN/xorriso" "$W/xorriso.hidden"
    RC=$(RUN_MKISO)
    check "A1 missing xorriso exits 1"          "[[ $RC -eq 1 ]]"
    check "A2 message names the tool"           "ERR | grep -q 'missing host tool' && ERR | grep -q xorriso"
    check "A3 nothing was built"                "[[ ! -s $W/out/my.iso ]] && ! grep -q mksquashfs $STUB_LOG"
    mv "$W/xorriso.hidden" "$BIN/xorriso"
fi

# ---- B. preconditions checked before any work --------------------------------
mv "$ROOT/boot/$KVER" "$W/kernel.hidden"
RC=$(RUN_MKISO)
check "B1 no kernel exits 1"                    "[[ $RC -eq 1 ]]"
check "B2 message says no kernel"               "ERR | grep -q 'no kernel'"
check "B3 nothing was built"                    "[[ ! -s $W/out/my.iso ]]"
mv "$W/kernel.hidden" "$ROOT/boot/$KVER"
mv "$ROOT/usr/bin/runit" "$W/runit.hidden"
RC=$(RUN_MKISO)
check "B4 missing runit exits 1"                "[[ $RC -eq 1 ]]"
check "B5 message names runit"                  "ERR | grep -q 'runit missing'"
mv "$W/runit.hidden" "$ROOT/usr/bin/runit"

# ---- C. happy path -----------------------------------------------------------
good_ls
RC=$(RUN_MKISO)
check "C1 exit 0"                               "[[ $RC -eq 0 ]]"
check "C2 structure OK reported"                "OUT | grep -q 'ISO structure OK'"
check "C3 ISO produced"                         "[[ -s $W/out/my.iso ]]"
check "C4 initramfs got --root and --out"       "grep -q 'initramfs --root .* --out' $STUB_LOG"
check "C5 mksquashfs got the compression"       "grep -q 'mksquashfs .* -comp xz' $STUB_LOG"
check "C6 grub-mkrescue got the volid"          "grep -q 'grub-mkrescue .* MYDISTRO' $STUB_LOG"
RC=$(RUN_MKISO VOL_ID=CUSTOM SQUASH_COMP=zstd)
check "C7 VOL_ID propagates to grub-mkrescue"   "grep -q 'grub-mkrescue .* CUSTOM' $STUB_LOG"
check "C8 SQUASH_COMP propagates to mksquashfs" "grep -q 'mksquashfs .* -comp zstd' $STUB_LOG"

# ---- C2. compression options ---------------------------------------------------
good_ls
RC=$(RUN_MKISO)
check "C9 xz gets block size, dictionary and the x86 filter" "grep -q 'mksquashfs .* -comp xz -b 1M -Xdict-size 100% -Xbcj x86' $STUB_LOG"
RC=$(RUN_MKISO SQUASH_COMP=zstd)
check "C10 zstd gets level 19"                            "grep -q 'mksquashfs .* -comp zstd -b 1M -Xcompression-level 19' $STUB_LOG"
RC=$(RUN_MKISO SQUASH_COMP=gzip)
check "C11 gzip still works, no extra options"            "[[ $RC -eq 0 ]] && grep -q 'mksquashfs .* -comp gzip -noappend' $STUB_LOG"
RC=$(RUN_MKISO SQUASH_COMP=lz4)
check "C12 unknown compression refused (exit 2)"          "[[ $RC -eq 2 ]] && ERR | grep -q 'SQUASH_COMP must be'"

# ---- D. structural validation ------------------------------------------------
printf '/boot/%s\n/boot/grub/grub.cfg\n/live/rootfs.squashfs\n' "$KVER" > "$XORRISO_LS"
RC=$(RUN_MKISO)
check "D1 initramfs missing from image fails"   "[[ $RC -eq 1 ]]"
check "D2 message names the member"             "ERR | grep -q \"validation FAILED: '/boot/initramfs.img'\""
check "D3 refuses to ship the image"            "ERR | grep -q 'refusing to ship'"
check "D4 the image itself existed (post-build gate)" "[[ -s $W/out/my.iso ]] && grep -q 'grub-mkrescue' $STUB_LOG"

printf '/boot/%s\n/boot/initramfs.img\n/boot/grub/grub.cfg\n' "$KVER" > "$XORRISO_LS"
RC=$(RUN_MKISO)
check "D5 squashfs missing from image fails"    "[[ $RC -eq 1 ]]"
check "D6 message names the squashfs"           "ERR | grep -q \"validation FAILED: '/live/rootfs.squashfs'\""

good_ls
printf '#!/bin/sh\nexit 7\n' > "$BIN/xorriso-crash"; chmod +x "$BIN/xorriso-crash"
# swap in a xorriso that always crashes: the gate must fail CLOSED
save="$BIN/xorriso"; mv "$save" "$W/xorriso.good"
cp "$BIN/xorriso-crash" "$BIN/xorriso"
RC=$(RUN_MKISO)
check "D7 a crashing xorriso fails the stage"   "[[ $RC -eq 1 ]]"
mv "$W/xorriso.good" "$BIN/xorriso"

# ---- E. failure propagation --------------------------------------------------
good_ls
rm -f "$W/out/my.iso"
printf '#!/bin/sh\nexit 3\n' > "$BIN/initramfs-fail"; chmod +x "$BIN/initramfs-fail"
RC=$(RUN_MKISO INITRAMFS_BIN="$BIN/initramfs-fail")
check "E1 initramfs failure propagates (exit 3)" "[[ $RC -eq 3 ]]"
check "E2 no ISO shipped"                        "[[ ! -s $W/out/my.iso ]] && ! grep -q 'mksquashfs' $STUB_LOG"
rm -f "$W/out/my.iso"
printf '#!/bin/sh\nexit 5\n' > "$BIN/mksquashfs-fail"; chmod +x "$BIN/mksquashfs-fail"
mv "$BIN/mksquashfs" "$W/mksquashfs.good"
cp "$BIN/mksquashfs-fail" "$BIN/mksquashfs"
RC=$(RUN_MKISO)
check "E3 mksquashfs failure propagates (exit 5)" "[[ $RC -eq 5 ]]"
check "E4 no ISO shipped"                         "[[ ! -s $W/out/my.iso ]]"
mv "$W/mksquashfs.good" "$BIN/mksquashfs"

echo; echo "  PASS: $PASS   FAIL: $FAIL"; [[ $FAIL -eq 0 ]]
