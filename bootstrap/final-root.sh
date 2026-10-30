#!/usr/bin/env bash
# bootstrap/final-root.sh — helpers for the TWO-ROOT layout (sourced INSIDE
# the chroot by stage2-inner.sh and stage3.sh; not meant to be run directly).
#
#   build root   /          seed toolchain + everything nawa builds against.
#                           Packages are installed here so later builds can
#                           link against them (unchanged from the old layout).
#   final root   $FINAL_ROOT  (default /sysroot) a CLEAN system: only distro
#                           packages, no Debian/Ubuntu seed files, no /opt/seed,
#                           no build dirs. THIS is what mkiso packs.
#
# FINAL_ROOT empty/unset = legacy single-root mode: every helper is a no-op.

FINAL_ROOT="${FINAL_ROOT:-}"
# overridable so scripts/test-final-root.sh can run the helpers against a
# throwaway tree with a stub nawa; in the real chroot the defaults apply
NAWA_BIN="${NAWA_BIN:-/usr/bin/nawa}"
BUILD_ROOT="${BUILD_ROOT:-}"        # prefix of the build root ("" = "/")

final_root_enabled() { [ -n "$FINAL_ROOT" ]; }

# Install one built archive into the final root as well.
# `--force` mirrors the build-root install (stage 3 reinstalls over stage 2).
# The loader directories must be a real usr/lib64 plus a RELATIVE lib64 link.
# An absolute link (e.g. lib64 -> /usr/lib) resolves against the BUILD root
# while nawa runs inside the chroot, so an install into $FINAL_ROOT would write
# the loader link into the build root's /usr/lib. Repairs older sysroots too.
repair_final_layout() {
    final_root_enabled || return 0
    mkdir -p "$FINAL_ROOT/usr"
    if [ -L "$FINAL_ROOT/usr/lib64" ]; then rm -f "$FINAL_ROOT/usr/lib64"; fi
    mkdir -p "$FINAL_ROOT/usr/lib64"
    if [ -L "$FINAL_ROOT/lib64" ]; then
        [ "$(readlink "$FINAL_ROOT/lib64")" = usr/lib64 ] \
            || { rm -f "$FINAL_ROOT/lib64"; ln -s usr/lib64 "$FINAL_ROOT/lib64"; }
    elif [ -e "$FINAL_ROOT/lib64" ]; then
        echo "final-root: WARNING $FINAL_ROOT/lib64 is not a symlink — left alone" >&2
    else
        ln -s usr/lib64 "$FINAL_ROOT/lib64"
    fi
}

install_final() {
    final_root_enabled || return 0
    mkdir -p "$FINAL_ROOT"
    repair_final_layout
    "$NAWA_BIN" --root "$FINAL_ROOT" install --force "$1"
}

# Newest archive of package $1 from the known build dirs / the local cache.
find_archive() {
    local pkg="$1" d a
    for d in "$BUILD_ROOT/build3/out" "$BUILD_ROOT/build/out" "$BUILD_ROOT/var/cache/nawa"; do
        # `|| true`: with pipefail a missing dir makes `ls` fail; this only
        # works today because the sole caller invokes us inside a `||` list
        # (which disables set -e in here) — make that an implementation
        # detail, not a survival requirement
        a=$(ls "$d"/"$pkg"-[0-9]*.nawa.tar.zst 2>/dev/null | sort -V | tail -1 || true)
        if [ -n "$a" ]; then echo "$a"; return 0; fi
    done
    return 1
}

# Make the final root contain every package the build root has. Needed on a
# resumed build: stage 2 skips packages the BUILD-root db already records, so a
# package built before the two-root switch (or a run that died between the two
# installs) would otherwise never reach the final root.
#   $1 = file with the topological order (one name per line, GUI filtered)
sync_final_root() {
    final_root_enabled || return 0
    local order="$1" pkg archive n=0
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        [ -d "$BUILD_ROOT/var/lib/nawa/local/$pkg" ] || continue  # not built yet
        [ -d "$FINAL_ROOT/var/lib/nawa/local/$pkg" ] && continue # already there
        archive=$(find_archive "$pkg") || {
            echo "final-root: no archive for $pkg to install into $FINAL_ROOT" >&2
            echo "final-root: rebuild it (delete /var/lib/nawa/local/$pkg and re-run stage 2)" >&2
            return 1; }
        echo "== final-root: syncing $pkg into $FINAL_ROOT"
        install_final "$archive"
        n=$((n+1))
    done < "$order"
    [ "$n" -eq 0 ] || echo "== final-root: synced $n package(s)"
}

# Last step of a stage: skeleton, ld.so cache, sanity checks.
finalize_final_root() {
    final_root_enabled || return 0
    local d
    # mountpoints / scratch dirs (base-files ships them; belt and braces for a
    # root that is still half-populated)
    for d in dev proc sys run tmp root boot mnt media; do mkdir -p "$FINAL_ROOT/$d"; done
    chmod 1777 "$FINAL_ROOT/tmp"
    # PT_INTERP of every binary is /lib64/ld-linux-x86-64.so.2
    mkdir -p "$FINAL_ROOT/usr/lib64"
    [ -e "$FINAL_ROOT/usr/lib64/ld-linux-x86-64.so.2" ] || [ -L "$FINAL_ROOT/usr/lib64/ld-linux-x86-64.so.2" ] \
        || ln -s ../lib/ld-linux-x86-64.so.2 "$FINAL_ROOT/usr/lib64/ld-linux-x86-64.so.2"
    chmod 0750 "$FINAL_ROOT/root"
    # glibc's post_install hook (`ldconfig`) is SKIPPED by nawa for a non-"/"
    # root while the root has no shell yet (glibc installs before bash), and
    # later installs add libraries too — so regenerate the cache once, here.
    if command -v ldconfig >/dev/null 2>&1; then
        ldconfig -r "$FINAL_ROOT" || echo "final-root: WARNING ldconfig -r failed" >&2
    fi
    # the final root must stand on its own: nothing of the seed or of the build
    # may have leaked in
    local bad=0
    for d in opt/seed opt/cargo opt/rustup opt/cross-tools build build3 mydistro; do
        if [ -e "$FINAL_ROOT/$d" ]; then
            echo "final-root: ERROR /$d leaked into $FINAL_ROOT" >&2; bad=1
        fi
    done
    for d in usr/bin/bash usr/bin/nawa usr/lib/libc.so.6; do
        [ -e "$FINAL_ROOT/$d" ] || { echo "final-root: ERROR /$d missing in $FINAL_ROOT" >&2; bad=1; }
    done
    [ "$bad" -eq 0 ] || return 1
    echo "== final-root: $FINAL_ROOT is clean ($(ls "$FINAL_ROOT/var/lib/nawa/local" 2>/dev/null | wc -l) packages)"
}

# Scan the ELF files of a root for references to the bootstrap seed
# directories (/opt/seed, /opt/cargo, /opt/rustup, /opt/cross-tools) in
# their interpreter, DT_NEEDED or RPATH/RUNPATH. Called by stage3 AFTER the
# seed was deleted: any such reference would now be a broken binary (or an
# undeclared host dependency that the ISO would ship).
#
# Reads only interpreter/dynamic entries via readelf — a binary that merely
# contains the string "/opt/seed" in a data section is NOT flagged.
#
# Overridables for tests: READELF_BIN, FILE_BIN and FINAL_ROOT_ELF_DIRS
# (default "usr/bin usr/sbin usr/lib usr/lib64").
verify_final_root_no_seed_refs() {
    local root="${1:?usage: verify_final_root_no_seed_refs ROOT}"
    local readelf="${READELF_BIN:-readelf}"
    local filebin="${FILE_BIN:-file}"
    local dirs="${FINAL_ROOT_ELF_DIRS:-usr/bin usr/sbin usr/lib usr/lib64}"
    command -v "$readelf" >/dev/null 2>&1 || {
        echo "final-root: WARNING: readelf not available — cannot scan $root for seed references" >&2
        return 0
    }
    local bad=0 found=0 f out d
    while IFS= read -r -d '' f; do
        # skip obviously-non-ELF files cheaply (scripts, data) — readelf
        # would just error on them
        if command -v "$filebin" >/dev/null 2>&1; then
            "$filebin" -b "$f" | grep -q ELF || continue
        fi
        out=$("$readelf" -l -d "$f" 2>/dev/null) || continue
        if printf '%s\n' "$out" | grep -qE '/opt/(seed|cargo|rustup|cross-tools)'; then
            echo "final-root: ERROR: $f references the seed (interpreter/NEEDED/RPATH):" >&2
            printf '%s\n' "$out" | grep -E '/opt/(seed|cargo|rustup|cross-tools)' | sed 's/^/    /' >&2
            bad=1
        fi
        found=$((found+1))
    done < <(
        # shellcheck disable=SC2086  # FINAL_ROOT_ELF_DIRS is a word list by design
        for d in $dirs; do find "$root/$d" -type f -print0 2>/dev/null; done
    )
    [ "$bad" -eq 0 ] || return 1
    echo "== final-root: no seed references in $found ELF file(s) under $root"
    return 0
}

# Verify that every DT_NEEDED soname of every ELF in a root is provided by a
# shared object that exists INSIDE that root. Catches the "build succeeded but
# the installed system is broken" class of bug, e.g. `ar: error while loading
# shared libraries: libfl.so.2` — binutils got linked against flex's libfl from
# the seed/build root, but flex is build-only and never reaches the final root.
# (verify_final_root_no_seed_refs cannot see this: the NEEDED entry is a bare
# soname, not a /opt path.)
#
# Overridables for tests: READELF_BIN, FILE_BIN, FINAL_ROOT_ELF_DIRS (as above)
# and FINAL_ROOT_LIB_DIRS (default "usr/lib usr/lib64 lib lib64").
verify_final_root_needed_resolved() {
    local root="${1:?usage: verify_final_root_needed_resolved ROOT}"
    local readelf="${READELF_BIN:-readelf}"
    local filebin="${FILE_BIN:-file}"
    local dirs="${FINAL_ROOT_ELF_DIRS:-usr/bin usr/sbin usr/lib usr/lib64}"
    local libdirs="${FINAL_ROOT_LIB_DIRS:-usr/lib usr/lib64 lib lib64}"
    command -v "$readelf" >/dev/null 2>&1 || {
        echo "final-root: WARNING: readelf not available — cannot check NEEDED sonames in $root" >&2
        return 0
    }
    local -A provided=()
    local f d n bad=0 found=0 out
    # every file or symlink named lib*.so* / ld-*.so* in the library dirs
    while IFS= read -r -d '' f; do provided["${f##*/}"]=1; done < <(
        # shellcheck disable=SC2086
        for d in $libdirs; do find "$root/$d" \( -type f -o -type l \) -name '*.so*' -print0 2>/dev/null; done
    )
    while IFS= read -r -d '' f; do
        if command -v "$filebin" >/dev/null 2>&1; then
            "$filebin" -b "$f" | grep -q ELF || continue
        fi
        out=$("$readelf" -d "$f" 2>/dev/null) || continue
        found=$((found+1))
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            case "$n" in */*) continue ;; esac     # path-style NEEDED: not a soname lookup
            if [ -z "${provided[$n]:-}" ]; then
                echo "final-root: ERROR: ${f#"$root"/} needs $n, which is not in the root" >&2
                bad=1
            fi
        done < <(printf '%s\n' "$out" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p')
    done < <(
        # shellcheck disable=SC2086
        for d in $dirs; do find "$root/$d" -type f -print0 2>/dev/null; done
    )
    [ "$bad" -eq 0 ] || return 1
    echo "== final-root: all NEEDED sonames resolve inside $root ($found ELF file(s))"
    return 0
}
