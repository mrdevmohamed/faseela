#!/usr/bin/env bash
# bootstrap/seed/build-seed.sh — STAGE 0: assemble the seed toolchain.
#
# Produces bootstrap/seed/seed.tar.zst containing a self-contained
# toolchain + rustc/cargo. The tarball is extracted into $LFS in stage1.
#
# Supported hosts:
#   * Debian/Ubuntu (apt-get download + dpkg -x)
#   * Any host with rustup (for the rust toolchain)
#
# Usage: ./build-seed.sh [seed-root-dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SEED_ROOT="${1:-$HERE/seed-root}"

# The seed's sanity gate runs `chroot` (needs root); an unprivileged build
# cannot produce a VERIFIED seed, so fail here instead of minutes later.
[[ $EUID -eq 0 ]] || { echo "seed: must run as root (the sanity check chroots into the seed)" >&2; exit 1; }
# Everything downstream (recipes arch=["x86_64"], profiles/x86_64.toml, the
# loader path below) targets x86_64 — fail with a precise message instead
# of a bogus "loader missing" on e.g. aarch64 hosts.
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) ;;
    *) echo "seed: unsupported host architecture '$ARCH'" >&2
       echo "seed: this distribution (and the seed loader check below) targets x86_64" >&2
       exit 1 ;;
esac

echo "== stage0: assembling seed in $SEED_ROOT (host: $(uname -srm))"
mkdir -p "$SEED_ROOT"

# --------------------------------------------------------------------------
# 1) Rust toolchain (minimal profile) — installed INSIDE the seed so the
#    result is self-contained.
# --------------------------------------------------------------------------
export RUSTUP_HOME="$SEED_ROOT/opt/rustup"
export CARGO_HOME="$SEED_ROOT/opt/cargo"
# rustup installs rustc/cargo into $CARGO_HOME/bin and does NOT touch PATH
# (--no-modify-path), so put it on PATH ourselves. Always install into the
# seed — a host rustc elsewhere on PATH is not part of the seed.
export PATH="$CARGO_HOME/bin:$PATH"
if [[ ! -x "$CARGO_HOME/bin/rustc" ]]; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
fi
echo "seed: rustc $("$CARGO_HOME/bin/rustc" --version)"

# --------------------------------------------------------------------------
# 2) Native toolchain + tools from the host distro.
#    Debian/Ubuntu path: download .deb files and extract them into the seed.
#    (v0.1: other hosts should extend this branch.)
# --------------------------------------------------------------------------
DEB_PKGS=(
    binutils gcc g++ libc6-dev linux-libc-dev
    make bash coreutils tar gzip xz-utils zstd bzip2
    patch sed gawk m4 bison flex findutils diffutils file pkg-config
    curl ca-certificates python3 perl
    # Essential packages are NOT pulled in as dependencies — list them:
    grep libc-bin dash
    # gcc needs gmp/mpfr/mpc; with these dev packages its configure finds
    # them in /usr, so no prerequisite tarballs have to be downloaded.
    libgmp-dev libmpfr-dev libmpc-dev
)
if command -v apt-get >/dev/null 2>&1; then
    # `apt-get download` fetches ONLY the named packages, not their
    # dependencies. Without libc6, libgcc-s1, libtinfo6, libacl1, ... nothing
    # in the seed can run (the chroot fails with "No such file or directory"
    # because the ELF loader is missing). So resolve the full closure.
    #
    # CI images can contain stale APT indexes, and Ubuntu mirrors can be
    # between syncs. In that case apt-cache selects versions whose .deb files
    # have already moved (404). Refresh the indexes before resolving anything,
    # and retry the whole resolve/download transaction after a failed fetch.
    TMP_DEBS="$(mktemp -d)"
    chmod 755 "$TMP_DEBS"            # let the _apt user write when run as root
    cd "$TMP_DEBS"
    DOWNLOAD_OK=0
    MAX_ATTEMPTS=3

    for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
        echo "seed: refreshing APT indexes (attempt $attempt/$MAX_ATTEMPTS)"
        if ! apt-get \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=30 \
            -o Acquire::https::Timeout=30 \
            update; then
            echo "seed: WARNING: apt-get update failed (attempt $attempt/$MAX_ATTEMPTS)" >&2
            [[ "$attempt" -lt "$MAX_ATTEMPTS" ]] && sleep "$attempt"
            continue
        fi

        DEPS_FILE="$TMP_DEBS/dependencies.txt"
        if ! apt-cache depends --recurse --no-recommends --no-suggests \
            --no-conflicts --no-breaks --no-replaces --no-enhances \
            "${DEB_PKGS[@]}" > "$DEPS_FILE"; then
            echo "seed: WARNING: could not resolve the Debian package dependency graph" >&2
            [[ "$attempt" -lt "$MAX_ATTEMPTS" ]] && sleep "$attempt"
            continue
        fi

        mapfile -t ALL_PKGS < <(
            grep '^[A-Za-z0-9]' "$DEPS_FILE" | sort -u \
            | while IFS= read -r p; do
                # Drop virtual packages / names with no installable candidate.
                apt-cache show --no-all-versions "$p" >/dev/null 2>&1 && printf '%s\\n' "$p"
              done
        )
        if (( ${#ALL_PKGS[@]} == 0 )); then
            echo "seed: ERROR: APT resolved an empty dependency closure" >&2
            cd - >/dev/null
            rm -rf "$TMP_DEBS"
            exit 1
        fi

        # Remove partial downloads from a previous attempt before retrying.
        rm -f -- ./*.deb
        echo "seed: fetching ${#ALL_PKGS[@]} Debian packages"
        if apt-get \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=30 \
            -o Acquire::https::Timeout=30 \
            download "${ALL_PKGS[@]}"; then
            DOWNLOAD_OK=1
            break
        fi

        echo "seed: WARNING: package download failed; indexes will be refreshed before retry" >&2
        rm -f -- ./*.deb
        [[ "$attempt" -lt "$MAX_ATTEMPTS" ]] && sleep "$attempt"
    done

    if (( ! DOWNLOAD_OK )); then
        cd - >/dev/null
        rm -rf "$TMP_DEBS"
        echo "seed: ERROR: unable to download the Debian dependency closure after $MAX_ATTEMPTS refreshed APT attempts" >&2
        echo "seed: check the runner's Ubuntu mirrors and package index consistency" >&2
        exit 1
    fi

    # Record exactly what was downloaded (name_version_arch.deb carries the
    # resolved versions — the seed's provenance record).
    mapfile -t DOWNLOADED_DEBS < <(printf '%s\\n' ./*.deb | sed 's|^\./||' | sort)
    for deb in ./*.deb; do
        dpkg -x "$deb" "$SEED_ROOT"
    done
    cd - >/dev/null
    rm -rf "$TMP_DEBS"
else
    echo "ERROR: no supported host package manager found." >&2
    echo "v0.1 supports Debian/Ubuntu hosts. Extend build-seed.sh for yours." >&2
    exit 1
fi

# dpkg -x does not run maintainer scripts / base-files, so do their job:
# merged-/usr symlinks, alternatives symlinks, and the ld.so cache.
for d in bin sbin lib lib64; do
    [[ -e "$SEED_ROOT/$d" || -L "$SEED_ROOT/$d" ]] || ln -s "usr/$d" "$SEED_ROOT/$d"
done
[[ -e "$SEED_ROOT/usr/bin/sh" ]] || ln -s bash "$SEED_ROOT/usr/bin/sh"
[[ -e "$SEED_ROOT/usr/bin/cc" ]] || ln -s gcc  "$SEED_ROOT/usr/bin/cc"
# c++ is a Debian *alternatives* link (g++ postinst), also skipped by dpkg -x.
# Many build systems (ninja's bootstrap, cmake, meson...) call plain `c++`.
[[ -e "$SEED_ROOT/usr/bin/c++" ]] || ln -s g++  "$SEED_ROOT/usr/bin/c++"
[[ -e "$SEED_ROOT/usr/bin/awk" ]] || ln -s gawk "$SEED_ROOT/usr/bin/awk"
mkdir -p "$SEED_ROOT"/{etc,tmp,root,var,dev,proc,sys,run}
chmod 1777 "$SEED_ROOT/tmp"
# The loader needs /etc/ld.so.cache to find Debian's multiarch libraries —
# a missing cache used to be SILENT here and blow up later as cryptic link
# failures inside the chroot. Warn loudly; the chroot check below is the
# hard gate.
if ! ldconfig -r "$SEED_ROOT" 2>/dev/null; then
    echo "seed: WARNING: ldconfig -r $SEED_ROOT failed — the chroot sanity check below will decide" >&2
fi
if [[ ! -s "$SEED_ROOT/etc/ld.so.cache" ]]; then
    echo "seed: WARNING: $SEED_ROOT/etc/ld.so.cache is empty or missing" >&2
fi

# sanity: the seed must be able to run its own binaries. This is the seed's
# TRUST GATE: a seed that passes this actually executed its gcc-compiled
# binaries against its own loader and libraries.
LOADER="$(ls "$SEED_ROOT"/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
             "$SEED_ROOT"/lib64/ld-linux-x86-64.so.2 2>/dev/null | head -n1 || true)"
for t in grep sed awk make gcc ld ldconfig; do
    [[ -e "$SEED_ROOT/usr/bin/$t" || -e "$SEED_ROOT/usr/sbin/$t" || -e "$SEED_ROOT/sbin/$t" ]] || {
        echo "seed: ERROR — $t missing from seed" >&2; exit 1; }
done
[[ -n "$LOADER" && -x "$SEED_ROOT/usr/bin/env" ]] || {
    echo "seed: ERROR — loader or /usr/bin/env missing from seed" >&2; exit 1; }
chroot "$SEED_ROOT" /usr/bin/env -i /usr/bin/bash -c 'echo seed: chroot sanity check OK' || {
    echo "seed: ERROR — seed cannot run binaries in a chroot" >&2; exit 1; }

# --------------------------------------------------------------------------
# 3) Environment shim: a script sourced inside the chroot to put the seed
#    toolchain first in PATH.
# --------------------------------------------------------------------------
mkdir -p "$SEED_ROOT/opt/seed/bin"
cat > "$SEED_ROOT/opt/seed/env.sh" <<'EOF'
# sourced inside the chroot during stage1/2
export RUSTUP_HOME=/opt/rustup
export CARGO_HOME=/opt/cargo
export PATH="/opt/cargo/bin:$PATH"
export NAWA_JOBS="${NAWA_JOBS:-4}"
EOF

# --------------------------------------------------------------------------
# 4) Provenance manifest — everything the seed contains, where it came from
#    and what built it. Ships INSIDE the tarball (opt/seed/manifest.txt), so
#    stage1 prints it and any later audit can identify the seed exactly.
#    This is the honest record of the bootstrap trust boundary: the seed is
#    PREBUILT (Debian packages + a rustup-installed rustc), not source-built.
# --------------------------------------------------------------------------
{
    echo "# faseela bootstrap seed manifest"
    echo "built-utc = $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host = $(uname -srm)"
    echo "seed-builder = bootstrap/seed/build-seed.sh"
    echo "seed-manifest-spec = $(sha256sum "$HERE/seed.toml" 2>/dev/null | cut -d' ' -f1)"
    echo "rustc = $("$CARGO_HOME/bin/rustc" --version 2>/dev/null || echo unknown)"
    echo ""
    echo "# debian packages extracted into the seed (name_version_arch.deb):"
    printf '%s\n' "${DOWNLOADED_DEBS[@]-}"
} > "$SEED_ROOT/opt/seed/manifest.txt"

echo "seed: packing seed.tar.zst"
tar -cf - -C "$SEED_ROOT" . | zstd -3 -q -o "$HERE/seed.tar.zst"
# sidecar: lets build-all's seed adoption and stage1 verify the exact
# artifact this build produced (sha256, sha256sum -c compatible)
( cd "$HERE" && sha256sum seed.tar.zst > seed.tar.zst.sha256 )
echo "seed: done -> $HERE/seed.tar.zst ($(du -h "$HERE/seed.tar.zst" | cut -f1))"
echo "seed: manifest: $HERE/seed-root/opt/seed/manifest.txt (also inside the tarball)"
