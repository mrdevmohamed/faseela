#!/usr/bin/env bash
# bootstrap/fetch-recipes.sh — put the recipe tree into <repo>/recipes.
#
# The recipes live in their own repository, github.com/mrdevmohamed/faseela-repo
# (the package repository of the distribution). There is no pin file to keep
# up to date: a build takes the newest commit of that repository's master
# branch and records WHICH commit it took in <repo>/.recipes-rev, so a release
# can be rebuilt from exactly the same recipes (RECIPES_REF=<commit>).
#
# Where the tree comes from (first match wins):
#   RECIPES_DIR=PATH     a recipes/ directory, or a faseela-repo checkout that
#                        contains one. Copied every time (it may have changed).
#   ../faseela-repo      a sibling checkout: the usual local setup. Copied
#                        every time, uncommitted changes included, and said so.
#   GitHub               RECIPES_REPO (default mrdevmohamed/faseela-repo) at
#                        RECIPES_REF (branch, tag or commit; default master).
#
# Refreshing. A build has several stages that may run hours apart, so the
# recipes are fetched ONCE and then kept, never silently moved to a newer
# master in the middle of a build. They are fetched again when
#   * there is no recipes/ yet,
#   * you pass --update,
#   * RECIPES_REF is set and differs from what is recorded.
#
# A recipes/ directory WITHOUT a .recipes-rev stamp is your own copy and is
# never overwritten (the same rule as for a hand-made nawa/ in fetch-nawa.sh).
#
# Usage: fetch-recipes.sh [--update]
#        fetch-recipes.sh --resolve     print the full commit RECIPES_REF
#                                       points to on GitHub; fetch nothing
# Env:   RECIPES_REF RECIPES_REPO RECIPES_DIR
#        RECIPES_GIT_BASE   default https://github.com (the tests point it at
#                           a local directory)
# Needs: git (to resolve the commit), curl or wget, tar.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/recipes"
STAMP="$REPO/.recipes-rev"
SLUG="${RECIPES_REPO:-mrdevmohamed/faseela-repo}"
BASE="${RECIPES_GIT_BASE:-https://github.com}"
REF="${RECIPES_REF:-}"
LOG="fetch-recipes:"

die() { echo "$LOG $*" >&2; exit 1; }
say() { echo "$LOG $*" >&2; }

update=0 resolve_only=0
for a in "$@"; do
    case "$a" in
        --update) update=1 ;;
        --resolve) resolve_only=1 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument '$a' (see --help)" ;;
    esac
done

stamp_get() { [[ -f $STAMP ]] && sed -n "s/^$1=//p" "$STAMP" | head -n1 || true; }

# Full 40-hex commit of $1 (branch, tag or commit) in the recipes repository.
resolve() {
    local ref="$1" out line
    if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then echo "$ref"; return 0; fi
    command -v git >/dev/null 2>&1 || die "git is required to resolve '$ref'"
    out="$(git ls-remote "$BASE/$SLUG" "refs/heads/$ref" "refs/tags/$ref^{}" "refs/tags/$ref")" \
        || die "cannot reach $BASE/$SLUG (is the repository public, and are you online?)"
    # prefer a branch, then the commit an annotated tag points to, then a light tag
    for name in "refs/heads/$ref" "refs/tags/$ref^{}" "refs/tags/$ref"; do
        line="$(awk -v n="$name" '$2 == n { print $1; exit }' <<< "$out")"
        if [[ -n $line ]]; then echo "$line"; return 0; fi
    done
    # a SHORT commit id cannot be listed: let the archive download resolve it
    if [[ $ref =~ ^[0-9a-f]{7,39}$ ]]; then echo "$ref"; return 0; fi
    die "no branch, tag or commit '$ref' in $SLUG"
}

if (( resolve_only )); then
    resolve "${REF:-master}"
    exit 0
fi

has_recipes() { [[ -n "$(find "$1" -name recipe.toml -print -quit 2>/dev/null)" ]]; }

# Replace $DEST by the tree in $1, atomically enough: build next to it, swap.
install_tree() {
    local src="$1" tmp
    has_recipes "$src" || die "no recipe.toml under $src"
    tmp="$(mktemp -d "$REPO/.recipes-new.XXXXXX")"
    cp -a "$src/." "$tmp/"
    rm -rf "$DEST"
    mv "$tmp" "$DEST"
}

write_stamp() { # source ref rev
    printf 'source=%s\nrepo=%s\nref=%s\nrev=%s\n' "$1" "$SLUG" "$2" "$3" > "$STAMP"
}

# A recipes/ with no stamp is somebody's own copy: leave it alone.
if [[ -d $DEST && ! -f $STAMP ]]; then
    [[ -z ${RECIPES_DIR:-} ]] || die "$DEST exists without a $STAMP stamp (your own copy?): move it away to use RECIPES_DIR"
    say "using your own $DEST (no .recipes-rev stamp) - not touching it"
    exit 0
fi

# --- local sources ---------------------------------------------------------
local_src=""
if [[ -n ${RECIPES_DIR:-} ]]; then
    local_src="$RECIPES_DIR"
elif [[ -z $REF && $update -eq 0 && -f $STAMP && -d $DEST && $(stamp_get source) == github ]]; then
    : # a fetched copy stays as it is
elif [[ -z $REF && -d $REPO/../faseela-repo/recipes ]]; then
    local_src="$REPO/../faseela-repo"
fi
if [[ -n $local_src ]]; then
    [[ -d $local_src/recipes ]] && local_src="$local_src/recipes"
    [[ -d $local_src ]] || die "RECIPES_DIR '$local_src' is not a directory"
    local_src="$(cd "$local_src" && pwd)"
    root="$(git -C "$local_src" rev-parse --show-toplevel 2>/dev/null || true)"
    rev="local"
    if [[ -n $root ]]; then
        rev="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo local)"
        [[ -z "$(git -C "$root" status --porcelain -- "$local_src" 2>/dev/null)" ]] || rev="$rev+dirty"
    fi
    install_tree "$local_src"
    write_stamp "local:$local_src" "-" "$rev"
    say "recipes copied from $local_src ($rev; uncommitted changes are included)"
    exit 0
fi

# --- GitHub ----------------------------------------------------------------
want="${REF:-master}"
if [[ -d $DEST && -f $STAMP && $update -eq 0 ]]; then
    if [[ -z $REF ]]; then
        say "recipes already fetched ($(stamp_get rev)); --update to fetch the newest"
        exit 0
    fi
    have_ref="$(stamp_get ref)"; have_rev="$(stamp_get rev)"
    if [[ $have_ref == "$REF" || $have_rev == "$REF" ]] && [[ $(stamp_get source) == github ]]; then
        say "recipes already at $REF ($have_rev)"
        exit 0
    fi
fi

rev="$(resolve "$want")"
if [[ -d $DEST && -f $STAMP && $(stamp_get rev) == "$rev" && $(stamp_get source) == github && $update -eq 1 ]]; then
    say "recipes already at $rev"
    exit 0
fi

url="$BASE/$SLUG/archive/$rev.tar.gz"
tmp="$(mktemp -d "$REPO/.recipes-fetch.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
say "downloading $SLUG@${rev:0:12} ($want)"
if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 -o "$tmp/src.tar.gz" "$url" || die "download failed: $url"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp/src.tar.gz" "$url" || die "download failed: $url"
else
    die "need curl or wget on the host to download the recipes"
fi
mkdir "$tmp/x"
tar -xzf "$tmp/src.tar.gz" -C "$tmp/x" --strip-components=1 --wildcards '*/recipes' \
    || die "the archive of $SLUG@$rev has no recipes/ directory"
# a commit archive unpacks into <repo>-<full sha>/: that is the full commit even
# when the ref was a short id
listing="$(tar -tzf "$tmp/src.tar.gz")"   # not `| head`: SIGPIPE + pipefail
top="${listing%%/*}"
if [[ ! $rev =~ ^[0-9a-f]{40}$ && $top =~ -([0-9a-f]{40})$ ]]; then rev="${BASH_REMATCH[1]}"; fi

install_tree "$tmp/x/recipes"
write_stamp github "$want" "$rev"
say "recipes ready: $SLUG@${rev:0:12} -> $DEST"
