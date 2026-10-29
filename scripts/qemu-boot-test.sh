#!/usr/bin/env bash
# scripts/qemu-boot-test.sh — boot an ISO in QEMU (BIOS, through grub, exactly
# as a user would) and succeed only when the login prompt appears on the
# serial console.
#
# It works because the live grub entries pass `console=ttyS0,115200` and
# runit's stage 1 then starts a getty on ttyS0 (recipes/system/runit-services).
# Nothing is logged in: reaching `login:` proves grub -> kernel -> initramfs ->
# squashfs/overlay -> runit -> getty all worked.
#
# On failure the serial log is printed and a screenshot of the VGA console
# (where the initramfs reports its errors) is saved next to it.
#
# Usage:  scripts/qemu-boot-test.sh ISO [OUTDIR]
# Env:    BOOT_TIMEOUT  seconds to wait for the prompt (default 300 with KVM, 900 without)
#         QEMU_MEM      guest RAM in MiB (default 2048)
set -euo pipefail

ISO="${1:?usage: qemu-boot-test.sh ISO [OUTDIR]}"
OUT="${2:-qemu-boot}"
MEM="${QEMU_MEM:-2048}"
[[ -s $ISO ]] || { echo "qemu-boot-test: $ISO is missing or empty" >&2; exit 2; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qemu-boot-test: qemu-system-x86_64 not installed" >&2; exit 2; }

mkdir -p "$OUT"
LOG="$OUT/serial.log"; MON="$OUT/monitor.sock"
rm -f "$LOG" "$MON"

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ACCEL=(-accel kvm -cpu host); TIMEOUT="${BOOT_TIMEOUT:-300}"
else
    echo "qemu-boot-test: no /dev/kvm - falling back to TCG (slow)"
    ACCEL=(-accel tcg -cpu max);  TIMEOUT="${BOOT_TIMEOUT:-900}"
fi

qemu-system-x86_64 "${ACCEL[@]}" -m "$MEM" -smp 2 \
    -cdrom "$ISO" -boot d \
    -display none -vga std \
    -serial "file:$LOG" \
    -monitor "unix:$MON,server,nowait" \
    -nic none -no-reboot &
QPID=$!
cleanup() { kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; }
trap cleanup EXIT

screenshot() {
    [[ -S $MON ]] || return 0
    if command -v socat >/dev/null 2>&1; then
        printf 'screendump %s\n' "$PWD/$OUT/screen.ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1 || true
        sleep 1
    fi
}

start=$SECONDS
echo "qemu-boot-test: booting $ISO (timeout ${TIMEOUT}s)"
while (( SECONDS - start < TIMEOUT )); do
    # agetty prints "<hostname> login: " without a newline
    if grep -aqE 'login: *$|login: ' "$LOG" 2>/dev/null; then
        echo "qemu-boot-test: PASS - login prompt after $((SECONDS - start))s"
        grep -aE 'login: ' "$LOG" | tail -1
        exit 0
    fi
    if ! kill -0 "$QPID" 2>/dev/null; then
        echo "qemu-boot-test: FAIL - QEMU exited before the login prompt" >&2
        tail -n 60 "$LOG" >&2 || true
        exit 1
    fi
    # an initramfs failure drops to a rescue shell and never reaches runit
    if grep -aqE 'Kernel panic|initramfs: (no boot media|squashfs mount failed|overlayfs mount failed|switch_root failed)' "$LOG" 2>/dev/null; then
        echo "qemu-boot-test: FAIL - boot failed" >&2
        screenshot
        tail -n 80 "$LOG" >&2
        exit 1
    fi
    sleep 2
done

echo "qemu-boot-test: FAIL - no login prompt within ${TIMEOUT}s" >&2
screenshot
echo "---- last serial output ----" >&2
tail -n 80 "$LOG" >&2 || true
exit 1
