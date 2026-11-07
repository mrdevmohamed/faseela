#!/usr/bin/env bash
# test-sync-repo.sh — bootstrap/sync-repo.sh copies what the chroot needs,
# including dist/nawa.pub (final-root.sh installs the repository key from
# /faseela/dist inside the chroot; without it no key is trusted in the rootfs).
# Runs against a throwaway tree with stubbed fetch scripts; needs no root.
set -uo pipefail
REPO="${FASEELA_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/sync-repo-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

mk() {   # $1 = tree dir; a minimal repo checkout with stub fetchers
    mkdir -p "$1/bootstrap/seed" "$1/recipes/base/nawa" "$1/profiles" "$1/nawa/src" "$1/nawa/target"
    cp "$REPO/bootstrap/sync-repo.sh" "$REPO/bootstrap/sync-nawa-recipe.py" "$1/bootstrap/"
    cp "$REPO/bootstrap/nawa-source.toml" "$1/bootstrap/"
cat > "$1/recipes/base/nawa/recipe.toml" <<'TOML'
[package]
name = "nawa"
version = "0.1.0"
rel = 1
arch = ["x86_64"]
summary = "test"
license = ["GPL-3.0"]
source = "local:/nawa-schema-2-requires-a-newer-nawa"

[[package.sources]]
name = "nawa"
url = "https://github.com/mrdevmohamed/nawa/archive/0000000000000000000000000000000000000000.tar.gz"
sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
strip_components = 1

[depends]
build = []
TOML
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bootstrap/fetch-recipes.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bootstrap/fetch-nawa.sh"
    : > "$1/bootstrap/seed/seed.tar.zst"; : > "$1/nawa/target/junk"; : > "$1/nawa/src/main.rs"
}

mk "$W/with"; mkdir -p "$W/with/dist"; echo 068fd409 > "$W/with/dist/nawa.pub"
check "sync succeeds"                    "bash $W/with/bootstrap/sync-repo.sh $W/t1"
check "dist/nawa.pub reaches the chroot" "[[ -s $W/t1/faseela/dist/nawa.pub ]]"
check "Nawa recipe is synchronized from the Faseela lock" "grep -q "$(sed -n 's/^commit = "\(.*\)"/\1/p' bootstrap/nawa-source.toml)" $W/with/recipes/base/nawa/recipe.toml"
check "recipes and bootstrap are copied" "[[ -d $W/t1/faseela/recipes/base && -f $W/t1/faseela/bootstrap/sync-repo.sh ]]"
check "seed tarball is still excluded"   "[[ ! -e $W/t1/faseela/bootstrap/seed ]]"
check "nawa/target is still excluded"    "[[ ! -e $W/t1/faseela/nawa/target && -f $W/t1/faseela/nawa/src/main.rs ]]"

mk "$W/without"
check "a checkout without dist/ still syncs" "bash $W/without/bootstrap/sync-repo.sh $W/t2"
check "no dist/ is invented"                 "[[ ! -e $W/t2/faseela/dist ]]"

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
