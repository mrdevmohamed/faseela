#!/usr/bin/env bash
# test-fetch-recipes.sh — unit test of bootstrap/fetch-recipes.sh against a
# throwaway "GitHub" on the local disk (RECIPES_GIT_BASE=file://...); needs
# neither network nor root.
set -uo pipefail
REPO="${MYDISTRO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/fetch-recipes-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

SCRIPT="$REPO/bootstrap/fetch-recipes.sh"
SLUG=mrdevmohamed/faseela-repo
GH="$W/gh/$SLUG"                       # the fake faseela-repo (a normal git repo)
export RECIPES_GIT_BASE="file://$W/gh"
unset RECIPES_REF RECIPES_DIR RECIPES_REPO

g() { git -C "$GH" -c user.name=t -c user.email=t@t -c init.defaultBranch=master "$@"; }
# commit the current fixture tree and publish its archive the way GitHub serves it
publish() {
    g add -A && g commit -q -m "$1"
    local sha; sha="$(g rev-parse HEAD)"
    mkdir -p "$GH/archive"
    g archive --format=tar.gz --prefix="faseela-repo-$sha/" -o "$GH/archive/$sha.tar.gz" HEAD
    ln -sf "$sha.tar.gz" "$GH/archive/${sha:0:7}.tar.gz"
    echo "$sha"
}
# a fresh distribution checkout (no recipes yet) whose sibling dir does not exist
newrepo() { rm -rf "$W/d"; mkdir -p "$W/d/repo/bootstrap"; cp "$SCRIPT" "$W/d/repo/bootstrap/"; echo "$W/d/repo"; }
run() { bash "$R/bootstrap/fetch-recipes.sh" "$@"; }
stamp() { sed -n "s/^$1=//p" "$R/.recipes-rev"; }

mkdir -p "$GH/recipes/base/foo" "$GH/recipes/extra/bar" "$GH/scripts"
git -C "$GH" init -q -b master
echo 'name = "foo"' > "$GH/recipes/base/foo/recipe.toml"
echo 'name = "bar"' > "$GH/recipes/extra/bar/recipe.toml"
echo 'not a recipe' > "$GH/scripts/x.py"
S1="$(publish one)"

# --- GitHub mode -------------------------------------------------------------
R="$(newrepo)"
check "fresh fetch succeeds"                 "run"
check "recipes unpacked"                     "[[ -s $R/recipes/base/foo/recipe.toml && -s $R/recipes/extra/bar/recipe.toml ]]"
check "only recipes/ is taken"               "[[ ! -e $R/recipes/x.py && ! -e $R/scripts ]]"
check "stamp records source and full rev"    "[[ \$(stamp source) == github && \$(stamp rev) == $S1 && \$(stamp ref) == master ]]"
check "no scratch dirs left behind"          "[[ -z \"\$(ls -A $R | grep -E '^\\.recipes-(new|fetch)')\" ]]"

echo 'name = "foo2"' > "$GH/recipes/base/foo/recipe.toml"
S2="$(publish two)"
check "second run keeps the fetched copy"    "run && [[ \$(stamp rev) == $S1 && \$(cat $R/recipes/base/foo/recipe.toml) == 'name = \"foo\"' ]]"
check "--update takes the newest master"     "run --update && [[ \$(stamp rev) == $S2 && \$(cat $R/recipes/base/foo/recipe.toml) == 'name = \"foo2\"' ]]"
check "RECIPES_REF=<commit> goes back"       "RECIPES_REF=$S1 run && [[ \$(stamp rev) == $S1 && \$(cat $R/recipes/base/foo/recipe.toml) == 'name = \"foo\"' ]]"
check "same RECIPES_REF again is a no-op"    "RECIPES_REF=$S1 run 2>&1 | grep -q 'already at'"
check "short commit id resolves to the full" "RECIPES_REF=${S2:0:7} run && [[ \$(stamp rev) == $S2 ]]"

g tag -a v1 -m v1 "$S1"
check "annotated tag resolves to its commit" "RECIPES_REF=v1 run && [[ \$(stamp rev) == $S1 ]]"
check "--resolve prints the full commit"     "[[ \$(RECIPES_REF=master run --resolve) == $S2 ]]"
check "--resolve defaults to master"         "[[ \$(run --resolve) == $S2 ]]"
before="$(stamp rev)"
check "--resolve touches nothing"            "run --resolve >/dev/null && [[ \$(stamp rev) == $before ]]"
check "unknown ref is an error"              "! RECIPES_REF=no-such-branch run"
check "unreachable repository is an error"   "! RECIPES_REPO=nobody/nothing run --update"
check "a failed fetch keeps the old recipes" "[[ -s $R/recipes/base/foo/recipe.toml && \$(stamp rev) == $before ]]"

# --- a recipes/ of your own is never overwritten -------------------------------
R="$(newrepo)"; mkdir -p "$R/recipes/base/mine"; echo mine > "$R/recipes/base/mine/recipe.toml"
check "unstamped recipes/ is left alone"     "run && [[ \$(cat $R/recipes/base/mine/recipe.toml) == mine && ! -e $R/.recipes-rev ]]"
check "...also with --update"                "run --update && [[ -s $R/recipes/base/mine/recipe.toml ]]"
check "...and RECIPES_DIR refuses to replace it" "! RECIPES_DIR=$GH run"
check "...it is still there afterwards"      "[[ \$(cat $R/recipes/base/mine/recipe.toml) == mine ]]"

# --- RECIPES_DIR ---------------------------------------------------------------
R="$(newrepo)"
check "RECIPES_DIR (checkout root) is copied" "RECIPES_DIR=$GH run && [[ -s $R/recipes/base/foo/recipe.toml ]]"
check "stamp: local source, commit"          "[[ \$(stamp source) == local:$GH/recipes && \$(stamp rev) == $S2 ]]"
echo 'name = "wip"' > "$GH/recipes/base/foo/recipe.toml"
check "RECIPES_DIR is re-copied every time"  "RECIPES_DIR=$GH/recipes run && [[ \$(cat $R/recipes/base/foo/recipe.toml) == 'name = \"wip\"' ]]"
check "uncommitted changes are flagged"      "[[ \$(stamp rev) == $S2+dirty ]]"
check "a dir without recipe.toml is rejected" "mkdir -p $W/empty && ! RECIPES_DIR=$W/empty run"
g checkout -q -- recipes

# --- sibling checkout ---------------------------------------------------------
R="$(newrepo)"; cp -a "$GH" "$W/d/faseela-repo"; rm -rf "$W/d/faseela-repo/archive"
check "a sibling ../faseela-repo is used"    "run && [[ \$(stamp source) == local:$W/d/faseela-repo/recipes ]]"
check "RECIPES_REF skips the sibling"        "RECIPES_REF=$S1 run && [[ \$(stamp source) == github && \$(stamp rev) == $S1 ]]"
check "a fetched copy beats the sibling"     "run && [[ \$(stamp source) == github ]]"
check "--update prefers the sibling again"   "run --update && [[ \$(stamp source) == local:* ]]"

echo; echo "fetch-recipes: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
