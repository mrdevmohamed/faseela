#!/usr/bin/env bash
# bootstrap/enter-root.sh — run a command inside the target root, like
# `chroot`, but via a private mount namespace + pivot_root(2).
#
# Why not chroot: the kernel refuses unshare(CLONE_NEWUSER) from a chrooted
# process (EPERM), so `nawa build --isolation sandbox|closure` cannot work
# inside a chroot. After pivot_root in its own mount namespace the process's
# root IS the namespace root, so user namespaces are allowed again.
#
# Usage (root):  enter-root.sh /mnt/mydistro CMD [ARGS...]
#
# The old (host) root is detached with a lazy umount, so the build cannot see
# the host filesystem. The mounts stage1 made under TARGET (dev, proc, sys,
# run) come along via --rbind. Needs `unshare` and `pivot_root` (util-linux)
# on the HOST; inside the target it needs one of `umount`, `python3` or `perl`
# to drop the old root (the seed ships python3 and perl).
set -euo pipefail

TARGET="${1:?usage: enter-root.sh TARGET CMD [ARGS...]}"; shift
[[ $# -ge 1 ]] || { echo "enter-root: no command given" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "enter-root: must run as root" >&2; exit 1; }
TARGET="$(realpath -e "$TARGET")"
[[ $TARGET != / ]] || { echo "enter-root: refusing /" >&2; exit 1; }
command -v unshare >/dev/null && command -v pivot_root >/dev/null || {
    echo "enter-root: needs unshare and pivot_root (util-linux) on the host" >&2; exit 1; }

BOOTSTRAP_DIR="$(cd "$(dirname "$0")" && pwd)"

# gate 1 (host side): fail HERE, with a fixable message, if the stage-1
# mounts are dead — before building a namespace that would carry an empty
# /proc into the target.  Inside such a chroot every rustup proxy dies on
# "no /proc/self/exe available" (it resolves itself via /proc/self/exe).
if ! mountpoint -q "$TARGET/proc"; then
    echo "enter-root: $TARGET/proc is NOT a mountpoint — the stage-1 bind mounts are dead" >&2
    echo "enter-root: (a reboot or umount-chroot.sh kills them; the stage stamps survive)" >&2
    echo "enter-root: fix on the host:  sudo $BOOTSTRAP_DIR/ensure-chroot-mounts.sh $TARGET" >&2
    exit 1
fi

exec unshare --mount --propagation private -- bash -c '
    set -euo pipefail
    T=$1; HOST_BOOTSTRAP=$2; shift 2
    mount --rbind "$T" "$T"          # TARGET must be a mount point
    mount --make-rprivate "$T"
    cd "$T"
    mkdir -p .pivot-old
    pivot_root . .pivot-old
    cd /
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin   # the host PATH is meaningless now
    # gate 2 (in-namespace): --rbind only carries mounts that were LIVE on
    # the host; if they were dead this is an empty /proc and any build would
    # die confusingly much deeper — fail here instead
    if [[ ! -e /proc/self ]]; then
        echo "enter-root: /proc did NOT come through --rbind — the stage-1 mounts were dead" >&2
        echo "enter-root: fix on the host:  sudo $HOST_BOOTSTRAP/ensure-chroot-mounts.sh $T" >&2
        exit 1
    fi
    # drop the host root with whatever tool the target has; a tool that exists
    # but is broken just falls through to the next one
    if ! { { command -v umount >/dev/null 2>&1 && umount -l /.pivot-old; } ||
           { command -v python3 >/dev/null 2>&1 && python3 -c "import ctypes,sys; sys.exit(0 if ctypes.CDLL(None, use_errno=True).umount2(b\"/.pivot-old\", 2) == 0 else 1)"; } ||
           { command -v perl >/dev/null 2>&1 && perl -e "require qw(syscall.ph); exit(syscall(&SYS_umount2, \"/.pivot-old\", 2) == 0 ? 0 : 1)"; }; } 2>/dev/null; then
        echo "enter-root: cannot detach the host root (no working umount/python3/perl in target)" >&2
        exit 1
    fi
    rmdir /.pivot-old 2>/dev/null || true
    exec "$@"
' enter-root "$TARGET" "$BOOTSTRAP_DIR" "$@"
