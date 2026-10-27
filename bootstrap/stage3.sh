#!/usr/bin/env bash
# bootstrap/stage3.sh — STAGE 3: self-hosting rebuild.
#
# Rebuilds packages with the distro's OWN toolchain (installed in stage2),
# then removes the seed toolchain (/opt): after this stage the distro
# builds itself.
#
# Rebuild scope:
#   default           toolchain set only (fast self-host proof)
#   STAGE3_WORLD=1    the ENTIRE recipe graph (add WITH_GUI=1 to include recipes/gui)
#
# NOTE: the distro does not ship rustc yet — DPM stays as the seed-built
# binary (recorded in the db).
#
# Usage (from the host): sudo ./stage3.sh /mnt/mydistro
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LFS="${1:?usage: stage3.sh /mnt/mydistro}"
[[ $EUID -eq 0 ]] || { echo "stage3: must run as root"; exit 1; }

# refresh the repo copy inside the chroot: stage1 copied it once, so edits made
# on the host since then would otherwise never reach the chroot. cp -a merges,
# so build output already in the chroot (pkgmgr/target) is kept.
REPO="$(dirname "$HERE")"
mkdir -p "$LFS/mydistro"
cp -a "$REPO/pkgmgr" "$REPO/recipes" "$REPO/profiles" "$REPO/bootstrap" "$LFS/mydistro/"

# self-heal: same reason as stage2 — the stage-1 mounts die with the session
# while the stamp survives; without /proc inside the target, user-namespace
# setup in dpm's sandbox (writes /proc/self/uid_map) fails too
bash "$HERE/ensure-chroot-mounts.sh" "$LFS"

# two-root layout (see stage2.sh / final-root.sh); SINGLE_ROOT=1 = legacy
if [[ "${SINGLE_ROOT:-0}" == "1" ]]; then
    FINAL_ROOT=""
else
    FINAL_ROOT="${FINAL_ROOT:-/sysroot}"
    [[ $FINAL_ROOT == /* && $FINAL_ROOT != / ]] || { echo "stage3: FINAL_ROOT must be an absolute path other than /" >&2; exit 1; }
    mkdir -p "$LFS$FINAL_ROOT"
fi

bash "$HERE/enter-root.sh" "$LFS" /usr/bin/env -i \
    HOME=/root TERM="$TERM" DPM_JOBS="${DPM_JOBS:-4}" STAGE3_WORLD="${STAGE3_WORLD:-0}" WITH_GUI="${WITH_GUI:-0}" \
    FINAL_ROOT="$FINAL_ROOT" \
    bash <<'EOS'
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export DPM_JOBS="${DPM_JOBS:-4}"
. /mydistro/bootstrap/final-root.sh
if final_root_enabled; then
    echo "== stage3: two-root layout: build root=/  final root=$FINAL_ROOT"
fi
# Build isolation (docs/design/build-isolation.md §5.4): stage3 is the first
# fully hermetic pass — `closure` builds against assembled archives, never the
# live system, so the seed (deleted below) is provably unnecessary.
ISOLATION="${STAGE3_ISOLATION:-none}"
case "$ISOLATION" in
    none|env|sandbox|closure) ;;
    *) echo "stage3: STAGE3_ISOLATION must be none|env|sandbox|closure" >&2; exit 1 ;;
esac
echo "== stage3: isolation=$ISOLATION"

# NOTE: /opt/cargo/bin is intentionally NOT in PATH here — we verify the
# system can rebuild itself with ONLY what it ships.

if [[ "${STAGE3_WORLD:-0}" == "1" ]]; then
    echo "== stage3: rebuilding the ENTIRE graph with the distro's own gcc"
    # --include-installed: every package IS installed at this point, and
    # deps-all skips what the db records — without the flag the order would
    # come back empty and nothing would be rebuilt
    ORDER=$(/usr/bin/dpm --recipes /mydistro/recipes deps-all --include-installed) || {
        echo "stage3: deps-all --include-installed failed — the installed dpm" >&2
        echo "stage3: may predate the flag; re-run stage2 (it rebuilds dpm) first" >&2
        exit 1
    }
    if [[ "${WITH_GUI:-0}" != "1" && -d /mydistro/recipes/gui ]]; then
        GUI_PKGS=" $(ls /mydistro/recipes/gui | tr '\n' ' ') "
        ORDER=$(for p in $ORDER; do [[ "$GUI_PKGS" == *" $p "* ]] || echo "$p"; done)
    fi
    COUNT=$(echo "$ORDER" | awk 'NF{n++} END{print n+0}')
    [ "$COUNT" -gt 0 ] || { echo "stage3: world rebuild found nothing to build" >&2; exit 1; }
else
    echo "== stage3: rebuilding the toolchain set with the distro's own gcc"
    ORDER="linux-headers glibc binutils m4 gmp mpfr mpc gcc make pkgconf"
    COUNT=10
fi

mkdir -p /build3

# two-root: make sure the final root already holds every installed package
# (e.g. `--from-stage 3` after a build made before the two-root layout)
if final_root_enabled; then
    SYNC_ORDER=$(/usr/bin/dpm --recipes /mydistro/recipes deps-all --include-installed) || SYNC_ORDER=""
    if [[ "${WITH_GUI:-0}" != "1" && -d /mydistro/recipes/gui ]]; then
        GUI_PKGS=" $(ls /mydistro/recipes/gui | tr '\n' ' ') "
        SYNC_ORDER=$(for p in $SYNC_ORDER; do [[ "$GUI_PKGS" == *" $p "* ]] || echo "$p"; done)
    fi
    printf '%s\n' "$SYNC_ORDER" > /build3/final-root.order
    sync_final_root /build3/final-root.order
fi

# `closure` needs the base-devel archive before anything else: it IS the
# base layer of every build root
if [ "$ISOLATION" = "closure" ]; then
    case " $ORDER " in
        *" base-devel "*) ;;
        *) ORDER="base-devel $ORDER"; COUNT=$((COUNT+1)) ;;
    esac
fi

i=0
for pkg in $ORDER; do
    i=$((i+1))
    echo "== stage3: [$i/$COUNT] $pkg"
    /usr/bin/dpm --recipes /mydistro/recipes --profiles /mydistro/profiles --builddir /build3 \
        --jobs "$DPM_JOBS" build ${ISOLATION:+--isolation "$ISOLATION"} "$pkg"
    # match "<pkg>-<digit>..." with a glob (grep -E would misparse names
    # containing '+' etc. as regex metacharacters); e.g. `linux` never picks
    # up `linux-headers-*`
    ARCHIVE=$(ls /build3/out/"$pkg"-[0-9]*.dpm.tar.zst 2>/dev/null | sort -V | tail -1)
    [ -n "$ARCHIVE" ] || { echo "stage3: no archive built for $pkg" >&2; exit 1; }
    /usr/bin/dpm --root / install --force "$ARCHIVE"
    install_final "$ARCHIVE"
done

echo "== stage3: removing seed toolchain"
rm -rf /opt/cross-tools /opt/cargo /opt/rustup /opt/seed
# the final root never contained the seed; verify that and refresh ld.so.cache
finalize_final_root
echo "== stage3: self-hosted (rebuilt with its own compiler)"
EOS

echo "== stage3: complete"
