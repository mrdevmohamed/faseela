#!/usr/bin/env bash
# bootstrap/stage-set.sh — decide WHAT stages 2 and 3 build (sourced by
# stage2.sh / stage3.sh on the host; not meant to be run directly).
#
# The answer is a flavor of flavors.toml (faseela-repo), by default
# `bootstrap`: base-devel, nawa, curl and what builds them. The resolved,
# dependency-ordered list is written to <TARGET>/faseela/bootstrap.set, where
# final-root.sh's filter_stage_set reads it inside the chroot.
#
#   STAGE_SET=bootstrap   (default) build that flavor only
#   STAGE_SET=<flavor>    any flavor of flavors.toml
#   STAGE_SET=all         the whole recipe graph (the pre-flavor behaviour);
#                         also what happens when flavors.toml is not there
#                         (a faseela-repo commit older than flavors.toml)
#
# Needs python3 (>= 3.11) on the host, like the recipe tooling.

write_stage_set() {   # $1 = TARGET (the build root, e.g. /mnt/faseela)
    local target="$1" set="${STAGE_SET:-bootstrap}"
    local here repo dest flavors
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo="$(dirname "$here")"
    dest="$target/faseela/bootstrap.set"
    flavors="$repo/flavors.toml"
    rm -f "$dest"
    if [[ $set == all ]]; then
        echo "stage-set: STAGE_SET=all — building the whole recipe graph"
        return 0
    fi
    if [[ ! -f $flavors || ! -f $repo/scripts/flavor.py ]]; then
        echo "stage-set: WARNING: no flavors.toml / scripts/flavor.py (recipes older than the flavors) — building the whole recipe graph" >&2
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || { echo "stage-set: need python3 on the host" >&2; return 1; }
    mkdir -p "$target/faseela"
    if ! python3 -I "$repo/scripts/flavor.py" --flavors "$flavors" resolve "$set" \
            --recipes "$repo/recipes" > "$dest.part"; then
        rm -f "$dest.part"
        echo "stage-set: cannot resolve flavor '$set'" >&2
        return 1
    fi
    mv "$dest.part" "$dest"
    echo "stage-set: building flavor '$set' only: $(wc -l < "$dest") packages"
}
