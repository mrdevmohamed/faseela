#!/usr/bin/env bash
# scripts/qemu-run.sh — run a faseela ISO (and optionally an install disk) in QEMU
# with the settings that make the GUI usable.
#
# The sway session draws through mesa's llvmpipe (software GL, JIT-compiled and
# multithreaded). That is fast enough on KVM with a few cores and a CPU that
# exposes its SIMD flags (-cpu host), and slow without them:
#   * no /dev/kvm  -> TCG emulation, everything (the JIT included) is 10-50x slower
#   * -smp 1       -> llvmpipe has one thread to rasterize with
#   * -cpu qemu64  -> no SSE4/AVX2 for llvmpipe to use
# This script picks the good defaults and says so when it cannot.
#
# Usage:
#   scripts/qemu-run.sh ISO [options]
#     --disk FILE        attach a disk image (qcow2 or raw) — the install target
#     --create-disk SIZE with --disk: create it first when missing (e.g. 20G)
#     --boot-disk        boot from the disk only (after installing); ISO not attached
#     --uefi             boot through OVMF (to test the UEFI install path; default BIOS)
#     --mem MIB          guest RAM (default 4096)
#     --cpus N           guest CPUs (default: host CPUs, at most 4)
#     --gl               virtio-vga-gl (virgl) instead of plain virtio-vga — experimental,
#                        needs a QEMU with OpenGL and a GTK/SDL display with gl=on
#     --serial           also show the serial console on stdio (console=ttyS0 is in the ISO's grub)
#     --dry-run          print the QEMU command line and stop
#
# Env: QEMU_ACCEL=kvm|tcg|auto (default auto), OVMF_CODE=/path/to/OVMF_CODE.fd
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "qemu-run: $*" >&2; exit 1; }

ISO=""; DISK=""; DISK_SIZE=""; BOOT_DISK=0; UEFI=0; MEM=4096; CPUS=""; GL=0; SERIAL=0; DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)        DISK="${2:?--disk needs a file}"; shift 2 ;;
        --create-disk) DISK_SIZE="${2:?--create-disk needs a size}"; shift 2 ;;
        --boot-disk)   BOOT_DISK=1; shift ;;
        --uefi)        UEFI=1; shift ;;
        --mem)         MEM="${2:?--mem needs MiB}"; shift 2 ;;
        --cpus)        CPUS="${2:?--cpus needs a number}"; shift 2 ;;
        --gl)          GL=1; shift ;;
        --serial)      SERIAL=1; shift ;;
        --dry-run)     DRY=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "unknown option $1" ;;
        *)             [[ -z $ISO ]] || die "more than one ISO given"; ISO="$1"; shift ;;
    esac
done
[[ $MEM =~ ^[0-9]+$ && $MEM -ge 512 ]] || die "--mem must be a number of MiB, at least 512"
[[ -z $CPUS || $CPUS =~ ^[1-9][0-9]*$ ]] || die "--cpus must be a positive number"
[[ -z $DISK_SIZE || -n $DISK ]] || die "--create-disk needs --disk FILE"
if [[ $BOOT_DISK -eq 1 ]]; then
    [[ -n $DISK ]] || die "--boot-disk needs --disk FILE"
else
    [[ -n $ISO ]] || { usage >&2; exit 1; }
    [[ $DRY -eq 1 || -s $ISO ]] || die "$ISO is missing or empty"
fi

command -v qemu-system-x86_64 >/dev/null 2>&1 || [[ $DRY -eq 1 ]] || die "qemu-system-x86_64 is not installed"

# --- acceleration -------------------------------------------------------------
ACCEL="${QEMU_ACCEL:-auto}"
if [[ $ACCEL == auto ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; else ACCEL=tcg; fi
fi
case "$ACCEL" in
    kvm) ACCEL_ARGS=(-accel kvm -cpu host) ;;
    tcg) ACCEL_ARGS=(-accel tcg -cpu max)
         echo "qemu-run: no KVM — emulating the CPU. The GUI will be very slow; the text console is fine." >&2
         echo "qemu-run: on Linux add yourself to the kvm group (or run on a host with /dev/kvm)." >&2 ;;
    *)   die "QEMU_ACCEL must be kvm, tcg or auto" ;;
esac
if [[ -z $CPUS ]]; then
    CPUS="$(nproc 2>/dev/null || echo 2)"; (( CPUS > 4 )) && CPUS=4
fi

# --- disk ---------------------------------------------------------------------
if [[ -n $DISK && ! -e $DISK ]]; then
    [[ -n $DISK_SIZE ]] || die "$DISK does not exist (add --create-disk 20G to create it)"
    if [[ $DRY -eq 1 ]]; then echo "+ qemu-img create -f qcow2 $DISK $DISK_SIZE"
    else qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null; fi
fi

# --- firmware -----------------------------------------------------------------
FW_ARGS=()
if [[ $UEFI -eq 1 ]]; then
    OVMF="${OVMF_CODE:-}"
    if [[ -z $OVMF ]]; then
        for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF_CODE.fd; do
            [[ -r $c ]] && { OVMF="$c"; break; }
        done
    fi
    [[ -n $OVMF && ( -r $OVMF || $DRY -eq 1 ) ]] || die "no OVMF firmware found (apt install ovmf), or set OVMF_CODE=/path"
    FW_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=${OVMF:-OVMF_CODE.fd}")
fi

# --- devices ------------------------------------------------------------------
# virtio-vga: the kernel has DRM_VIRTIO_GPU. A USB tablet gives sway an absolute
# pointer (no grab/ungrab dance); the USB keyboard goes through the xHCI the kernel has.
if [[ $GL -eq 1 ]]; then VGA=(-device virtio-vga-gl -display gtk,gl=on); else VGA=(-device virtio-vga -display gtk); fi
DEV=(-device qemu-xhci -device usb-kbd -device usb-tablet -nic user,model=virtio-net-pci)
BOOT_ARGS=()
[[ -n $DISK ]] && BOOT_ARGS+=(-drive "file=$DISK,if=virtio,format=$([[ $DISK == *.raw || $DISK == *.img ]] && echo raw || echo qcow2)")
if [[ $BOOT_DISK -eq 0 ]]; then BOOT_ARGS+=(-cdrom "$ISO" -boot order=dc); fi
SER=(); [[ $SERIAL -eq 1 ]] && SER=(-serial mon:stdio)

CMD=(qemu-system-x86_64 "${ACCEL_ARGS[@]}" -m "$MEM" -smp "$CPUS" "${FW_ARGS[@]}" "${VGA[@]}" "${DEV[@]}" "${BOOT_ARGS[@]}" "${SER[@]}")
if [[ $DRY -eq 1 ]]; then printf '%q ' "${CMD[@]}"; echo; exit 0; fi
exec "${CMD[@]}"
