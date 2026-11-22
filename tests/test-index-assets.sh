#!/usr/bin/env bash
# tests/test-index-assets.sh — scripts/index-assets.py reads a repository index,
# and the ISO build's default package repository is the schema-v5 endpoint.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
tool() { python3 -I "$REPO/scripts/index-assets.py" "$@"; }

cat > "$W/index.toml" <<'T'
[repository]
schema = 5

[[package]]
name = "vim"
version = "9.1"
rel = 2
arch = "x86_64"
file = "vim-9.1-2.nawa.tar.zst"
sha256 = "aa"
download_url = "https://github.com/o/r/releases/download/packages-v5-0001/vim-9.1-2.nawa.tar.zst"

[[package]]
name = "sway"
version = "1.9"
rel = 1
arch = "x86_64"
file = "sway-1.9-1.nawa.tar.zst"
sha256 = "bb"
T

[[ "$(tool "$W/index.toml" names | tr '\n' ' ')" == "vim-9.1-2.nawa.tar.zst sway-1.9-1.nawa.tar.zst " ]] || fail "names"
ok "names lists every archive file"
[[ "$(tool "$W/index.toml" urls vim-9.1-2.nawa.tar.zst)" == $'vim-9.1-2.nawa.tar.zst\thttps://github.com/o/r/releases/download/packages-v5-0001/vim-9.1-2.nawa.tar.zst' ]] || fail "urls"
ok "urls maps a file to its download_url"
tool "$W/index.toml" urls sway-1.9-1.nawa.tar.zst 2>/dev/null && fail "an entry without a url must fail"
tool "$W/index.toml" urls missing-1-1.nawa.tar.zst 2>/dev/null && fail "an unknown file must fail"
ok "entries without an https url, or unknown files, fail"
printf '[repository]\nschema = 5\n' > "$W/empty.toml"
tool "$W/empty.toml" names 2>/dev/null && fail "an index without packages must fail"
tool "$W/missing.toml" names 2>/dev/null && fail "a missing index must fail"
ok "empty or missing index fails"

# the default repository of an image build is the signed schema-v5 index
( . "$REPO/bootstrap/package-repo.sh"
  [[ $FASEELA_PKG_REPO == "https://github.com/mrdevmohamed/faseela-repo/releases/download/stable-v5" ]] ) || fail "default repo"
( export FASEELA_PKG_REPO=/tmp/dir; . "$REPO/bootstrap/package-repo.sh"; [[ $FASEELA_PKG_REPO == /tmp/dir ]] ) || fail "override"
ok "package-repo.sh defaults to stable-v5 and honours FASEELA_PKG_REPO"
# nothing in the image build may still point at the legacy endpoints
if grep -rnE 'releases/download/stable(-v3)?(["/ ]|$)|release (view|download) stable( |$)' \
    "$REPO/bootstrap" "$REPO/.github/workflows/release.yml" "$REPO/scripts"; then
    fail "a legacy package endpoint is still referenced"
fi
ok "no legacy stable/stable-v3 endpoint is referenced by the build"
echo "test-index-assets: all passed"
