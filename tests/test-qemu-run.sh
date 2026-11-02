#!/usr/bin/env bash
# test-qemu-run.sh — scripts/qemu-run.sh builds the right QEMU command line
# (--dry-run: nothing is started, no QEMU needed).
set -uo pipefail
REPO="${FASEELA_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/qemu-run-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
RUN() { bash "$REPO/scripts/qemu-run.sh" "$@" > "$W/out" 2> "$W/err"; echo $?; }
OUT() { cat "$W/out"; }
ERR() { cat "$W/err"; }

echo iso > "$W/a.iso"

RC=$(QEMU_ACCEL=kvm RUN "$W/a.iso" --cpus 3 --mem 2048 --dry-run)
check "1 KVM: exit 0"                       "[[ $RC -eq 0 ]]"
check "2 KVM: -cpu host (llvmpipe SIMD)"    "OUT | grep -q -- '-accel kvm -cpu host'"
check "3 cpus and memory reach QEMU"        "OUT | grep -q -- '-m 2048 -smp 3'"
check "4 virtio-vga + USB tablet"           "OUT | grep -q -- '-device virtio-vga ' && OUT | grep -q usb-tablet"
check "5 ISO attached, CD first"            "OUT | grep -q -- \"-cdrom $W/a.iso\" && OUT | grep -q -- 'order=dc'"
check "6 no TCG warning with KVM"           "! ERR | grep -q 'no KVM'"

RC=$(QEMU_ACCEL=tcg RUN "$W/a.iso" --dry-run)
check "7 TCG: warns the GUI will be slow"   "ERR | grep -q 'GUI will be very slow'"
check "8 TCG: -cpu max"                     "OUT | grep -q -- '-accel tcg -cpu max'"

RC=$(QEMU_ACCEL=kvm RUN "$W/a.iso" --gl --dry-run)
check "9 --gl selects virtio-vga-gl"        "OUT | grep -q 'virtio-vga-gl' && OUT | grep -q 'gl=on'"

RC=$(QEMU_ACCEL=kvm RUN "$W/a.iso" --disk "$W/d.qcow2" --create-disk 20G --dry-run)
check "10 --create-disk announced"          "OUT | grep -q 'qemu-img create -f qcow2 .*d.qcow2 20G'"
check "11 disk attached as virtio"          "OUT | grep -q 'd.qcow2.*if=virtio'"

touch "$W/d.qcow2"
RC=$(QEMU_ACCEL=kvm RUN --boot-disk --disk "$W/d.qcow2" --dry-run)
check "12 --boot-disk: no ISO attached"     "[[ $RC -eq 0 ]] && ! OUT | grep -q -- '-cdrom'"

RC=$(RUN "$W/a.iso" --disk "$W/missing.qcow2" --dry-run)
check "13 missing disk without --create-disk refused" "[[ $RC -ne 0 ]] && ERR | grep -q 'create-disk'"
RC=$(RUN "$W/a.iso" --mem 100 --dry-run)
check "14 tiny memory refused"              "[[ $RC -ne 0 ]]"
RC=$(RUN "$W/a.iso" --cpus 0 --dry-run)
check "15 zero cpus refused"                "[[ $RC -ne 0 ]]"
RC=$(RUN --dry-run)
check "16 no ISO prints the usage"          "[[ $RC -ne 0 ]] && ERR | grep -q 'Usage'"
RC=$(OVMF_CODE="$W/OVMF.fd" QEMU_ACCEL=kvm RUN "$W/a.iso" --uefi --dry-run)
check "17 --uefi uses the pflash firmware"  "OUT | grep -q 'if=pflash.*OVMF.fd'"

echo "== $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
