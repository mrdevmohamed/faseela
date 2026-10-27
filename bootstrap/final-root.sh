#!/usr/bin/env bash
# bootstrap/final-root.sh — helpers for the TWO-ROOT layout (sourced INSIDE
# the chroot by stage2-inner.sh and stage3.sh; not meant to be run directly).
#
#   build root   /          seed toolchain + everything dpm builds against.
#                           Packages are installed here so later builds can
#                           link against them (unchanged from the old layout).
#   final root   $FINAL_ROOT  (default /sysroot) a CLEAN system: only distro
#                           packages, no Debian/Ubuntu seed files, no /opt/seed,
#                           no build dirs. THIS is what mkiso packs.
#
# FINAL_ROOT empty/unset = legacy single-root mode: every helper is a no-op.

FINAL_ROOT="${FINAL_ROOT:-}"
# overridable so scripts/test-final-root.sh can run the helpers against a
# throwaway tree with a stub dpm; in the real chroot the defaults apply
DPM_BIN="${DPM_BIN:-/usr/bin/dpm}"
BUILD_ROOT="${BUILD_ROOT:-}"        # prefix of the build root ("" = "/")

final_root_enabled() { [ -n "$FINAL_ROOT" ]; }

# Install one built archive into the final root as well.
# `--force` mirrors the build-root install (stage 3 reinstalls over stage 2).
install_final() {
    final_root_enabled || return 0
    mkdir -p "$FINAL_ROOT"
    "$DPM_BIN" --root "$FINAL_ROOT" install --force "$1"
}

# Newest archive of package $1 from the known build dirs / the local cache.
find_archive() {
    local pkg="$1" d a
    for d in "$BUILD_ROOT/build3/out" "$BUILD_ROOT/build/out" "$BUILD_ROOT/var/cache/dpm"; do
        a=$(ls "$d"/"$pkg"-[0-9]*.dpm.tar.zst 2>/dev/null | sort -V | tail -1)
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
        [ -d "$BUILD_ROOT/var/lib/dpm/local/$pkg" ] || continue  # not built yet
        [ -d "$FINAL_ROOT/var/lib/dpm/local/$pkg" ] && continue # already there
        archive=$(find_archive "$pkg") || {
            echo "final-root: no archive for $pkg to install into $FINAL_ROOT" >&2
            echo "final-root: rebuild it (delete /var/lib/dpm/local/$pkg and re-run stage 2)" >&2
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
    chmod 0750 "$FINAL_ROOT/root"
    # glibc's post_install hook (`ldconfig`) is SKIPPED by dpm for a non-"/"
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
    for d in usr/bin/bash usr/bin/dpm usr/lib/libc.so.6; do
        [ -e "$FINAL_ROOT/$d" ] || { echo "final-root: ERROR /$d missing in $FINAL_ROOT" >&2; bad=1; }
    done
    [ "$bad" -eq 0 ] || return 1
    echo "== final-root: $FINAL_ROOT is clean ($(ls "$FINAL_ROOT/var/lib/dpm/local" 2>/dev/null | wc -l) packages)"
}
