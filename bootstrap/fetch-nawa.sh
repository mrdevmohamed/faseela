#!/usr/bin/env bash
# bootstrap/fetch-nawa.sh — fetch the Nawa source named by the fetched recipe.
#
# recipes/base/nawa/recipe.toml is the single source of truth for the source
# URL and SHA-256. Bootstrap reads that same pin before Nawa exists, then
# builds from the extracted tree with the seed Cargo toolchain.
#
# Behaviour:
#   * the archive is cached in $REPO/srccache and checked against the recipe SHA;
#   * $REPO/nawa carries a .pinned-sha256 stamp for safe no-op reruns;
#   * an unstamped $REPO/nawa is a developer checkout and is never overwritten.
#
# Usage: fetch-nawa.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RECIPE="$REPO/recipes/base/nawa/recipe.toml"
DEST="$REPO/nawa"
CACHE="\${NAWA_SRC_CACHE:-$REPO/srccache}"

# Preserve an explicit developer checkout, even when the recipe tree is absent.
if [[ -d $DEST && ! -f $DEST/.pinned-sha256 ]]; then
    echo "fetch-nawa: using your own checkout in $DEST (no .pinned-sha256 stamp) — not touching it"
    exit 0
fi

# The normal build driver fetches recipes first; keep the standalone script safe too.
if [[ ! -r $RECIPE ]]; then
    bash "$REPO/bootstrap/fetch-recipes.sh"
fi
[[ -r $RECIPE ]] || {
    echo "fetch-nawa: missing $RECIPE (fetch the Faseela package recipes first)" >&2
    exit 1
}

# Parse TOML structurally. Do not scrape package.source: it is a deliberate
# local marker for old Nawa binaries. The real source is the single named
# package.sources entry.
SOURCE_META="$(
python3 - "$RECIPE" <<'PY'
import re
import sys
import tomllib
from pathlib import Path

recipe = Path(sys.argv[1])
try:
    document = tomllib.loads(recipe.read_text(encoding="utf-8"))
except (OSError, tomllib.TOMLDecodeError) as exc:
    raise SystemExit(f"fetch-nawa: cannot parse {recipe}: {exc}")

package = document.get("package", {})
if package.get("name") != "nawa":
    raise SystemExit("fetch-nawa: recipe package.name must be 'nawa'")

sources = package.get("sources")
if not isinstance(sources, list):
    raise SystemExit("fetch-nawa: recipe must contain [[package.sources]]")

matches = [
    source for source in sources
    if isinstance(source, dict) and source.get("name") == "nawa"
]
if len(matches) != 1:
    raise SystemExit("fetch-nawa: recipe must contain exactly one source named 'nawa'")

source = matches[0]
url = source.get("url")
match = re.fullmatch(
    r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/archive/([0-9a-f]{40})\.tar\.gz",
    url if isinstance(url, str) else "",
)
if not match:
    raise SystemExit(f"fetch-nawa: invalid Nawa GitHub archive URL: {url!r}")

repository = f"{match.group(1)}/{match.group(2)}"
if repository != "mrdevmohamed/nawa":
    raise SystemExit(f"fetch-nawa: unexpected upstream repository {repository!r}")

commit = match.group(3)
sha256 = source.get("sha256")
if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
    raise SystemExit("fetch-nawa: source sha256 must be 64 lowercase hex characters")
if sha256 == "0" * 64:
    raise SystemExit("fetch-nawa: source sha256 is an empty placeholder")

version = package.get("version")
if not isinstance(version, str) or not re.fullmatch(r"[0-9A-Za-z.+_-]+", version):
    raise SystemExit("fetch-nawa: invalid package.version")
rel = package.get("rel")
if not isinstance(rel, int) or isinstance(rel, bool) or rel < 1:
    raise SystemExit("fetch-nawa: package.rel must be a positive integer")

print("\\t".join((repository, commit, sha256, version, str(rel))))
PY
)" || exit 1

IFS=$'\\t' read -r SOURCE_REPO COMMIT SHA VERSION REL <<< "$SOURCE_META"
TOP="nawa-$COMMIT"
URL="https://github.com/$SOURCE_REPO/archive/$COMMIT.tar.gz"

if [[ -f $DEST/.pinned-sha256 && "$(cat "$DEST/.pinned-sha256")" == "$SHA" ]]; then
    echo "fetch-nawa: $DEST is already at the recipe-pinned source ($COMMIT)"
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
# Reject a recipe pin whose version does not match the downloaded source.
ACTUAL_VERSION="$(awk -F '"' '/^version = "/ { print $2; exit }' "$TMP/$TOP/Cargo.toml")"
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || {
    echo "fetch-nawa: source version $ACTUAL_VERSION does not match recipe version $VERSION" >&2
    exit 1
}

rm -rf "$DEST"
mv "$TMP/$TOP" "$DEST"
printf '%s\\n' "$SHA" > "$DEST/.pinned-sha256"
echo "fetch-nawa: Nawa $VERSION-$REL ($COMMIT) ready in $DEST"
