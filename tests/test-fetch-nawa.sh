#!/usr/bin/env bash
# Test bootstrap/fetch-nawa.sh with a local archive and a stub curl.
# No network, root privileges, or real Nawa source download is needed.
set -euo pipefail

SOURCE_REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d /tmp/fetch-nawa-test.XXXXXX)"
trap 'rm -rf "$W"' EXIT

REPO="$W/repo"
mkdir -p "$REPO/bootstrap" "$REPO/srccache" "$W/bin" "$W/source"
cp "$SOURCE_REPO/bootstrap/fetch-nawa.sh" "$REPO/bootstrap/"
COMMIT=0123456789abcdef0123456789abcdef01234567
TOP="nawa-$COMMIT"
mkdir -p "$W/source/$TOP/.cargo" "$W/source/$TOP/vendor"
cat > "$W/source/$TOP/Cargo.toml" <<'TOML'
[package]
name = "nawa"
version = "9.8.7"
TOML
: > "$W/source/$TOP/.cargo/config.toml"
tar -C "$W/source" -czf "$W/source.tar.gz" "$TOP"
SHA="$(sha256sum "$W/source.tar.gz" | awk '{print $1}')"
cat > "$REPO/bootstrap/nawa-source.toml" <<TOML
schema = 1
repository = "mrdevmohamed/nawa"
version = "9.8.7"
rel = 4
commit = "$COMMIT"
sha256 = "$SHA"
TOML

cat > "$W/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n $out && -n ${NAWA_TEST_TARBALL:-} ]]
printf 'called\n' >> "$NAWA_CURL_LOG"
cp "$NAWA_TEST_TARBALL" "$out"
CURL
chmod +x "$W/bin/curl"
export PATH="$W/bin:$PATH"
export NAWA_TEST_TARBALL="$W/source.tar.gz"
export NAWA_CURL_LOG="$W/curl.log"

# First fetch downloads, verifies, extracts and stamps the locked source.
bash "$REPO/bootstrap/fetch-nawa.sh" > "$W/first.log"
grep -qx "$SHA" "$REPO/nawa/.pinned-sha256"
grep -q 'version = "9.8.7"' "$REPO/nawa/Cargo.toml"
grep -q 'Nawa 9.8.7-4' "$W/first.log"
[[ "$(wc -l < "$NAWA_CURL_LOG")" -eq 1 ]]

# A matching stamp is a no-op; it must not download again.
bash "$REPO/bootstrap/fetch-nawa.sh" > "$W/second.log"
grep -q 'already at the pinned source' "$W/second.log"
[[ "$(wc -l < "$NAWA_CURL_LOG")" -eq 1 ]]

# A developer checkout without a stamp is left untouched.
REPO2="$W/user-checkout"
mkdir -p "$REPO2/bootstrap" "$REPO2/nawa"
cp "$REPO/bootstrap/fetch-nawa.sh" "$REPO2/bootstrap/"
cp "$REPO/bootstrap/nawa-source.toml" "$REPO2/bootstrap/"
echo 'user worktree' > "$REPO2/nawa/KEEP"
bash "$REPO2/bootstrap/fetch-nawa.sh" > "$W/user.log"
grep -q 'user checkout' "$W/user.log"
grep -qx 'user worktree' "$REPO2/nawa/KEEP"
[[ "$(wc -l < "$NAWA_CURL_LOG")" -eq 1 ]]

# A bad hash must fail and must not activate an extracted source tree.
REPO3="$W/bad-hash"
mkdir -p "$REPO3/bootstrap"
cp "$REPO/bootstrap/fetch-nawa.sh" "$REPO3/bootstrap/"
sed 's/^sha256 = ".*"$/sha256 = "0000000000000000000000000000000000000000000000000000000000000000"/' \
    "$REPO/bootstrap/nawa-source.toml" > "$REPO3/bootstrap/nawa-source.toml"
if bash "$REPO3/bootstrap/fetch-nawa.sh" > "$W/bad.log" 2>&1; then
    echo "FAIL: fetch accepted a bad source SHA" >&2
    exit 1
fi
[[ ! -e "$REPO3/nawa" ]]

echo "fetch-nawa tests: 4 passed"
