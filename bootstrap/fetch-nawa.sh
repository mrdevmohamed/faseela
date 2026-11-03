#!/usr/bin/env bash
# bootstrap/fetch-nawa.sh — unpack the Nawa source pinned by Bootstrap itself.
#
# bootstrap/nawa-source.toml is the authoritative source lock. It deliberately
# lives in the Faseela repository, not in faseela-repo: the bootstrap compiler
# must not depend on the binary package repository being updated first.
#
# The same lock is applied to recipes/base/nawa/recipe.toml by
# sync-nawa-recipe.py before stage 2, so the bootstrap binary and the Nawa
# package installed into the final root always come from the same source.
#
# Behaviour:
#   * the archive is cached in $REPO/srccache and checked against the lock SHA;
#   * $REPO/nawa carries a .pinned-sha256 stamp for safe no-op reruns;
#   * an unstamped $REPO/nawa is a developer checkout and is never overwritten.
#
# Usage: fetch-nawa.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO/bootstrap/nawa-source.toml"
DEST="$REPO/nawa"
CACHE="${NAWA_SRC_CACHE:-$REPO/srccache}"

string_field() {
    awk -F ' = ' -v key="$1" '$1 == key { gsub(/^"/, "", $2); gsub(/"$/, "", $2); print $2; exit }' "$LOCK"
}
integer_field() {
    awk -F ' = ' -v key="$1" '$1 == key { print $2; exit }' "$LOCK"
}

[[ -r $LOCK ]] || { echo "fetch-nawa: source lock $LOCK not found" >&2; exit 1; }
SCHEMA="$(integer_field schema)"
[[ "$SCHEMA" == 1 ]] || {
    echo "fetch-nawa: unsupported source lock schema '$SCHEMA' (expected 1)" >&2; exit 1;
}
SOURCE_REPO="$(string_field repository)"
VERSION="$(string_field version)"
REL="$(integer_field rel)"
COMMIT="$(string_field commit)"
SHA="$(string_field sha256)"
TOP="nawa-$COMMIT"
URL="https://github.com/$SOURCE_REPO/archive/$COMMIT.tar.gz"

[[ "$SOURCE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "fetch-nawa: invalid repository in $LOCK" >&2; exit 1;
}
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
    echo "fetch-nawa: commit in $LOCK must be a full 40-character lowercase SHA" >&2; exit 1;
}
[[ "$SHA" =~ ^[0-9a-f]{64}$ && $SHA != 0000000000000000000000000000000000000000000000000000000000000000 ]] || {
    echo "fetch-nawa: invalid or empty sha256 in $LOCK" >&2; exit 1;
}
[[ "$VERSION" =~ ^[0-9A-Za-z.+_-]+$ && "$REL" =~ ^[1-9][0-9]*$ ]] || {
    echo "fetch-nawa: invalid version/rel in $LOCK" >&2; exit 1;
}

if [[ -d $DEST && ! -f $DEST/.pinned-sha256 ]]; then
    echo "fetch-nawa: using your own checkout in $DEST (no .pinned-sha256 stamp) — not touching it"
    exit 0
fi
if [[ -f $DEST/.pinned-sha256 && "$(cat "$DEST/.pinned-sha256")" == "$SHA" ]]; then
    echo "fetch-nawa: $DEST is already at the pinned source ($COMMIT)"
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
        echo "fetch-nawa: need curl or wget on the host to download the Nawa source" >&2
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
[[ -f $TMP/$TOP/Cargo.toml ]] || {
    echo "fetch-nawa: $TOP/Cargo.toml missing in the archive" >&2
    exit 1
}
# Reject a lock whose package version does not match its source archive.
ACTUAL_VERSION="$(awk -F '"' '/^version = "/ { print $2; exit }' "$TMP/$TOP/Cargo.toml")"
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || {
    echo "fetch-nawa: source version $ACTUAL_VERSION does not match lock version $VERSION" >&2
    exit 1
}

rm -rf "$DEST"
mv "$TMP/$TOP" "$DEST"
printf '%s\n' "$SHA" > "$DEST/.pinned-sha256"
echo "fetch-nawa: Nawa $VERSION-$REL ($COMMIT) ready in $DEST"
