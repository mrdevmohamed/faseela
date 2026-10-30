#!/usr/bin/env bash
# bootstrap/fetch-nawa.sh — unpack the pinned nawa source into <repo>/nawa.
#
# nawa lives in its own repository (github.com/mrdevmohamed/nawa). The stage-2
# bootstrap compiles it from $REPO/nawa (offline: the crates are vendored in
# that repository), so before the repo is synced into the chroot this script
# makes sure $REPO/nawa holds EXACTLY the commit pinned in
# recipes/base/nawa/recipe.toml (faseela-repo) — the same pin the `nawa` recipe
# builds from (see scripts/pin-nawa-source.py in faseela-repo).
#
# Behaviour:
#   * the tarball is downloaded once to $REPO/srccache and verified against the
#     recipe's sha256 (a mismatch aborts and deletes the download);
#   * $REPO/nawa carries a .pinned-sha256 stamp; if it already matches the
#     recipe nothing is downloaded or touched;
#   * a $REPO/nawa WITHOUT a stamp is a checkout you made yourself (e.g. to
#     hack on nawa and bootstrap with it): it is used as-is and never
#     overwritten.
#
# Usage: fetch-nawa.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RECIPE="$REPO/recipes/base/nawa/recipe.toml"
DEST="$REPO/nawa"
CACHE="${NAWA_SRC_CACHE:-$REPO/srccache}"

field() { sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" "$RECIPE" | head -n1; }

[[ -r $RECIPE ]] || { echo "fetch-nawa: $RECIPE not found" >&2; exit 1; }
URL="$(field source)"
SHA="$(field sha256)"
TOP="$(field source_dir)"
[[ -n $URL && -n $TOP ]] || { echo "fetch-nawa: no source/source_dir in $RECIPE" >&2; exit 1; }
[[ $SHA =~ ^[0-9a-f]{64}$ && $SHA != 0000000000000000000000000000000000000000000000000000000000000000 ]] || {
    echo "fetch-nawa: the nawa recipe has no sha256 pin yet — in faseela-repo run: python3 scripts/pin-nawa-source.py" >&2
    exit 1
}

if [[ -d $DEST && ! -f $DEST/.pinned-sha256 ]]; then
    echo "fetch-nawa: using your own checkout in $DEST (no .pinned-sha256 stamp) — not touching it"
    exit 0
fi
if [[ -f $DEST/.pinned-sha256 && "$(cat "$DEST/.pinned-sha256")" == "$SHA" ]]; then
    echo "fetch-nawa: $DEST is already at the pinned commit"
    exit 0
fi

mkdir -p "$CACHE"
TARBALL="$CACHE/$TOP.tar.gz"
if [[ ! -f $TARBALL ]] || ! echo "$SHA  $TARBALL" | sha256sum -c --status; then
    echo "fetch-nawa: downloading $URL"
    rm -f "$TARBALL.part"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 -o "$TARBALL.part" "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$TARBALL.part" "$URL"
    else
        echo "fetch-nawa: need curl or wget on the host to download the nawa source" >&2
        exit 1
    fi
    if ! echo "$SHA  $TARBALL.part" | sha256sum -c --status; then
        echo "fetch-nawa: sha256 mismatch for $URL — expected $SHA" >&2
        rm -f "$TARBALL.part"
        exit 1
    fi
    mv "$TARBALL.part" "$TARBALL"
fi

TMP="$(mktemp -d "$REPO/.nawa-fetch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
tar -C "$TMP" -xzf "$TARBALL"
[[ -f $TMP/$TOP/Cargo.toml ]] || { echo "fetch-nawa: $TOP/Cargo.toml missing in the tarball" >&2; exit 1; }
rm -rf "$DEST"
mv "$TMP/$TOP" "$DEST"
printf '%s\n' "$SHA" > "$DEST/.pinned-sha256"
echo "fetch-nawa: nawa source ready in $DEST"
