#!/usr/bin/env bash
# bootstrap/ensure-chroot-mounts.sh — make sure the chroot pseudo-filesystems
# (dev, dev/pts, proc, sys, run) are mounted in the target, mounting whatever
# is missing.  Idempotent: safe to run any number of times, from any stage.
#
# WHY THIS EXISTS: the bind mounts stage1 creates live in the KERNEL (mount
# table), not on disk — a reboot or umount-chroot.sh kills them while the
# stage stamps on disk survive.  Any later stage that trusts the stamp then
# enters a chroot whose /proc is an empty directory, and every rustup proxy
# dies with:
#
#     error: Unable to proceed. Could not locate working directory.:
#            no /proc/self/exe available. Is /proc mounted?
#
# (rustup proxies resolve themselves and their sysroot via /proc/self/exe —
# see rust-lang/rust#46090.)  stage2/stage3 call this script before
# enter-root.sh so they self-heal after a reboot; stage1 calls it instead of
# its old silent `|| true` mount block that used to swallow failures.
#
# Usage (root): ensure-chroot-mounts.sh TARGET
set -euo pipefail

LFS="${1:?usage: ensure-chroot-mounts.sh TARGET}"
[[ $EUID -eq 0 ]] || { echo "ensure-chroot-mounts: must run as root" >&2; exit 1; }
[[ "$(realpath -m "$LFS")" != "/" ]] || { echo "ensure-chroot-mounts: refusing /" >&2; exit 1; }
[[ -x "$LFS/usr/bin/env" ]] || {
    echo "ensure-chroot-mounts: $LFS does not look like a prepared target (no /usr/bin/env)" >&2
    echo "ensure-chroot-mounts: run stage 1 first:  build-all.sh --from-stage 1 $LFS" >&2
    exit 1;
}

echo "ensure-chroot-mounts: checking dev/proc/sys/run in $LFS"
mkdir -p "$LFS"/{dev,proc,sys,run}

# mount whatever is missing — `mountpoint -q X || mount ...` is the whole
# idempotency story; no `|| true` anywhere: a failed mount must fail HERE,
# loudly, not three layers deeper inside cargo
mountpoint -q "$LFS/dev"     || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/dev/pts" || mount -t devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mountpoint -q "$LFS/proc"    || mount -t proc  proc  "$LFS/proc"
mountpoint -q "$LFS/sys"     || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"     || mount -t tmpfs tmpfs "$LFS/run"

# verify — mount(2) can fail in ways the old silent block used to hide
bad=0
for m in dev/pts dev proc sys run; do
    if ! mountpoint -q "$LFS/$m"; then
        echo "ensure-chroot-mounts: FAILED: $LFS/$m is not a mountpoint" >&2
        bad=1
    fi
done
if (( bad )); then
    echo "ensure-chroot-mounts: the chroot is unusable without these mounts" >&2
    echo "ensure-chroot-mounts: (check: kernel mounts allowed? target path correct?)" >&2
    exit 1
fi

# DNS for the chroot — only if stage1 has not provided one already (stage1
# owns the full canonical logic; this is the resume-path fallback so that a
# direct start at stage2/3 also gets a working resolver)
if [[ ! -s "$LFS/etc/resolv.conf" ]]; then
    mkdir -p "$LFS/etc"
    if [[ -s /etc/resolv.conf ]]; then
        cp -L /etc/resolv.conf "$LFS/etc/resolv.conf" 2>/dev/null || true
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$LFS/etc/resolv.conf"
    fi
fi

echo "ensure-chroot-mounts: dev/proc/sys/run verified in $LFS"
