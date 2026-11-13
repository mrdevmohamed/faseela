#!/usr/bin/env bash
# bootstrap/mkflavor.sh — build a flavor of the distribution WITHOUT compiling
# anything: install the packages of a flavor (flavors.toml in faseela-repo)
# from the package repository into a fresh, empty root.
#
#   sudo bootstrap/mkflavor.sh [--repo URL|DIR] [--from repo|auto] TARGET FLAVOR
#
#   TARGET  a finished bootstrap build root (stages 1-3 done): it supplies the
#           nawa that does the installing and the chroot it runs in
#   FLAVOR  iso-nogui | iso-sway | iso-xfce | rootfs-min | ...  (see flavors.toml)
#
# Result: TARGET/sysroot-FLAVOR — a clean root holding exactly the flavor's
# packages and the distribution's signing key. Pack it with
#   bootstrap/mkiso.sh    TARGET/sysroot-FLAVOR out.iso
#   bootstrap/mkrootfs.sh TARGET/sysroot-FLAVOR out-rootfs.tar.zst
#
# --repo   the package repository (http(s) URL or directory with index.toml);
#          default: nawa's built-in one (faseela-repo, release `stable`)
# --from   repo (default): a package the repository lacks is an ERROR listing
#          what is missing — the fix is to run the package workflow
#          (faseela-repo: packages.yml, packages `flavor:FLAVOR`), not to
#          compile 150 packages inside an image build.
#          auto: build what is missing from the recipes (slow, development).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
FLAVOR_REPO="" FROM="repo"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || { echo "mkflavor: --repo needs a value" >&2; exit 2; }; FLAVOR_REPO="$2"; shift 2 ;;
        --from) [[ $# -ge 2 ]] || { echo "mkflavor: --from needs a value" >&2; exit 2; }; FROM="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*) echo "mkflavor: unknown option '$1'" >&2; exit 2 ;;
        *) break ;;
    esac
done
TARGET="${1:?usage: mkflavor.sh [--repo URL|DIR] [--from repo|auto] TARGET FLAVOR}"
FLAVOR="${2:?usage: mkflavor.sh [--repo URL|DIR] [--from repo|auto] TARGET FLAVOR}"
case "$FROM" in repo|auto) ;; *) echo "mkflavor: --from must be repo or auto" >&2; exit 2 ;; esac
[[ $FLAVOR =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "mkflavor: bad flavor name '$FLAVOR'" >&2; exit 2; }

[[ $EUID -eq 0 ]] || { echo "mkflavor: must run as root" >&2; exit 1; }
[[ -d $TARGET && -x $TARGET/usr/bin/nawa ]] \
    || { echo "mkflavor: $TARGET is not a finished build root (no usr/bin/nawa)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "mkflavor: missing host tool python3 (>= 3.11)" >&2; exit 1; }

bash "$HERE/fetch-recipes.sh"
[[ -f $REPO/flavors.toml && -f $REPO/scripts/flavor.py ]] \
    || { echo "mkflavor: this faseela-repo revision has no flavors.toml" >&2; exit 1; }
python3 -I "$REPO/scripts/flavor.py" --flavors "$REPO/flavors.toml" resolve "$FLAVOR" \
    --recipes "$REPO/recipes" > "$TARGET/faseela-flavor.order"
echo "== flavor $FLAVOR: $(wc -l < "$TARGET/faseela-flavor.order") packages from ${FLAVOR_REPO:-the default repository} (--from $FROM)"

bash "$HERE/sync-repo.sh" "$TARGET"
bash "$HERE/ensure-chroot-mounts.sh" "$TARGET"
# network + the key the repository's index is signed with
rm -f "$TARGET/etc/resolv.conf"; cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
install -m644 "$REPO/dist/nawa.pub" "$TARGET/faseela-nawa.pub"

ROOT_NAME="sysroot-$FLAVOR"
rm -rf "${TARGET:?}/$ROOT_NAME"
mkdir -p "$TARGET/$ROOT_NAME"
bash "$HERE/enter-root.sh" "$TARGET" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-dumb}" FINAL_ROOT="/$ROOT_NAME" \
    FLAVOR_REPO="$FLAVOR_REPO" FLAVOR_FROM="$FROM" \
    bash /faseela/bootstrap/mkflavor-inner.sh

rm -f "$TARGET/faseela-flavor.order" "$TARGET/faseela-nawa.pub"
echo "== flavor $FLAVOR: $TARGET/$ROOT_NAME ($(du -sh "$TARGET/$ROOT_NAME" | cut -f1))"
