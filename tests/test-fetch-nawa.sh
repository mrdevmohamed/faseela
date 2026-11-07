#!/usr/bin/env bash
# Test bootstrap/fetch-nawa.sh using the source pinned in recipes/base/nawa.
# No network, root privileges, or real Nawa source download is needed.
set -euo pipefail

SOURCE_REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d /tmp/fetch-nawa-test.XXXXXX)"
trap 'rm -rf "$W"' EXIT

REPO="$W/repo"
mkdir -p "$REPO/bootstrap" "$REPO/recipes/base/nawa" "$REPO/srccache" "$W/bin" "$W/source"
cp "$SOURCE_REPO/bootstrap/fetch-nawa.sh" "$REPO/bootstrap/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/bootstrap/fetch-recipes.sh"

COMMIT=0123456789abcdef0123456789abcdef01234567
TOP="nawa-$COMMIT"
mkdir -p "$W/source/$TOP"
cat > "$W/source/$TOP/Cargo.toml" <<'TOML'
[package]
name = "nawa"
version = "9.8.7"
TOML
tar -C "$W/source" -czf "$W/source.tar.gz" "$TOP"
SHA="$(sha256sum "$W/source.tar.gz" | awk '{print $1}')"

write_recipe() {
    local root="$1" sha="$2"
    mkdir -p "$root/recipes/base/nawa"
    cat > "$root/recipes/base/nawa/recipe.toml" <<TOML
[package]
name = "nawa"
version = "9.8.7"
rel = 4
arch = ["x86_64"]
summary = "test Nawa"
license = ["GPL-3.0"]
source = "local:/nawa-schema-2-requires-a-newer-nawa"

[[package.sources]]
name = "nawa"
url = "https://github.com/mrdevmohamed/nawa/archive/$COMMIT.tar.gz"
sha256 = "$sha"
strip_components = 1
TOML
}

write_recipe "$REPO" "$SHA"

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

# The recipe is the only pin; there is no bootstrap/nawa-source.toml.
[[ ! -e "$REPO/bootstrap/nawa-source.toml" ]]

# First fetch downloads, verifies, extracts and stamps the recipe-pinned source.
bash "$REPO/bootstrap/fetch-nawa.sh" > "$W/first.log"
grep -qx "$SHA" "$REPO/nawa/.pinned-sha256"
grep -q 'version = "9.8.7"' "$REPO/nawa/Cargo.toml"
grep -q 'Nawa 9.8.7-4' "$W/first.log"
[[ "$(wc -l < "$NAWA_CURL_LOG")" -eq 1 ]]

# A matching stamp is a no-op; it must not download again.
bash "$REPO/bootstrap/fetch-nawa.sh" > "$W/second.log"
grep -q 'already at the recipe-pinned source' "$W/second.log"
[[ "$(wc -l < "$NAWA_CURL_LOG")" -eq 1 ]]

# A developer checkout without a stamp is left untouched, even without recipes.
REPO2="$W/user-checkout"
mkdir -p "$REPO2/bootstrap" "$REPO2/nawa"
cp "$REPO/bootstrap/fetch-nawa.sh" "$REPO2/bootstrap/"
echo 'user worktree' > "$REPO2/nawa/KEEP"
bash "$REPO2/bootstrap/fetch-nawa.sh" > "$W/user.log"
grep -q 'your own checkout' "$W/user.log"
grep -qx 'user worktree' "$REPO2/nawa/KEEP"
[[ "$(wc -l < "$NAWA_CURL_LOG")" -eq 1 ]]

# A bad hash must fail and must not activate an extracted source tree.
REPO3="$W/bad-hash"
mkdir -p "$REPO3/bootstrap"
cp "$REPO/bootstrap/fetch-nawa.sh" "$REPO3/bootstrap/"
write_recipe "$REPO3" "0000000000000000000000000000000000000000000000000000000000000000"
if bash "$REPO3/bootstrap/fetch-nawa.sh" > "$W/bad.log" 2>&1; then
    echo "FAIL: fetch accepted a bad source SHA" >&2
    exit 1
fi
[[ ! -e "$REPO3/nawa" ]]
[[ "$(wc -l < "$NAWA_CURL_LOG")" -eq 1 ]]

# A recipe without exactly one named source is rejected before any download.
REPO4="$W/missing-source"
mkdir -p "$REPO4/bootstrap" "$REPO4/recipes/base/nawa"
cp "$REPO/bootstrap/fetch-nawa.sh" "$REPO4/bootstrap/"
cat > "$REPO4/recipes/base/nawa/recipe.toml" <<'TOML'
[package]
name = "nawa"
version = "9.8.7"
rel = 4
TOML
if bash "$REPO4/bootstrap/fetch-nawa.sh" > "$W/missing.log" 2>&1; then
    echo "FAIL: fetch accepted a recipe without the named Nawa source" >&2
    exit 1
fi
grep -q "exactly one source named 'nawa'" "$W/missing.log"
[[ "$(wc -l < "$NAWA_CURL_LOG")" -eq 1 ]]

echo "fetch-nawa tests: 5 scenarios passed"
