#!/usr/bin/env bash
# stage2-inner.sh — runs INSIDE the chroot (invoked by stage2.sh).
# 1. compile DPM (the package manager) with the seed rustc
# 2. install DPM into the target system
# 3. build + install the FULL recipe graph (without recipes/gui unless WITH_GUI=1)
#    in resolved order
set -euo pipefail

export PATH="/opt/cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Stand-in makeinfo, installed at /usr/bin/makeinfo (only while the real one
# is absent). Some tarballs (bc, ...) do not ship prebuilt .info files and
# run `makeinfo` during build/install, but the real texinfo package is built
# later (it needs perl). The stand-in used to live at /opt/seed/bin, LAST in
# PATH — but sandbox/closure isolation masks /opt/seed, so sandboxed build
# sections could not see it and bc died with "makeinfo: command not found".
# /usr/bin is visible to every isolation level, and the texinfo install later
# simply overwrites the stand-in in place. It only creates the requested
# output file (never truncates one).
if [ ! -e /usr/bin/makeinfo ]; then
cat > /usr/bin/makeinfo <<'EOF_MI'
#!/bin/sh
out=
while [ $# -gt 0 ]; do
    case "$1" in
        --version) echo "makeinfo (GNU texinfo) 7.3 (seed stand-in)"; exit 0 ;;
        --output=*) out="${1#--output=}" ;;
        -o)         shift; out="$1" ;;
    esac
    shift
done
if [ -n "$out" ]; then
    case "$out" in
        */) mkdir -p "$out" ;;
        *)  [ -e "$out" ] || : > "$out" ;;
    esac
fi
exit 0
EOF_MI
chmod 755 /usr/bin/makeinfo
fi
export DPM_JOBS="${DPM_JOBS:-4}"
REPO=/mydistro
# overridable so tests can drive this script with a stub dpm (same pattern
# as final-root.sh); in the real chroot /usr/bin/dpm is used
DPM_BIN="${DPM_BIN:-/usr/bin/dpm}"

# Seed fix-ups. dpkg -x never ran the Debian maintainer scripts, so the
# update-alternatives symlinks are missing from the seed. `c++` is needed by
# e.g. ninja's bootstrap (configure.py runs plain `c++`). Done here, not in
# stage1, so seeds built/stamped earlier are repaired on resume. Idempotent;
# harmless once our own gcc (which installs c++ itself) replaces it.
[ -e /usr/bin/c++ ] || { [ -x /usr/bin/g++ ] && ln -s g++ /usr/bin/c++; }
[ -e /usr/bin/cc  ] || { [ -x /usr/bin/gcc ] && ln -s gcc /usr/bin/cc; }

# The build root's /etc/group comes from the seed (stage1 writes only root and
# nogroup; base-files' own group file lands as /etc/group.dpm-new there).
# util-linux's install runs `chgrp tty .../wall`, which fails with
# "invalid group: 'tty'". Make sure the groups that install steps chgrp to
# exist. Idempotent; same gid as base-files.
for g in tty:5; do
    name=${g%%:*}; gid=${g##*:}
    grep -q "^$name:" /etc/group || echo "$name:x:$gid:" >> /etc/group
done

# Two-root layout: FINAL_ROOT (default /sysroot, set by stage2.sh) is the clean
# system every package is installed into IN ADDITION to the build root "/".
# Empty = legacy single-root mode. See bootstrap/final-root.sh.
. "$REPO/bootstrap/final-root.sh"
if final_root_enabled; then
    echo "== stage2-inner: two-root layout: build root=/  final root=$FINAL_ROOT"
else
    echo "== stage2-inner: single-root layout (legacy): installing into / only"
fi

echo "== [1/3] compiling DPM with seed rustc"
if command -v cargo >/dev/null 2>&1; then
    cd "$REPO/pkgmgr"
    cargo build --release
    install -Dm755 target/release/dpm /usr/bin/dpm
else
    # No cargo on PATH: stage 3 already removed the seed (a `--from-stage 2`
    # world rebuild with the distro's own toolchain). DPM itself is not
    # written in a language the distro rebuilds here (no rustc recipe yet),
    # so the installed seed-built binary keeps serving — verify it works.
    if [ ! -x /usr/bin/dpm ]; then
        echo "stage2-inner: no cargo (seed gone?) and no installed /usr/bin/dpm —" >&2
        echo "stage2-inner: run stage 1 first (unpack the seed), then re-run stage 2" >&2
        exit 1
    fi
    echo "stage2-inner: seed rustc not present (stage 3 removed it) — keeping the installed /usr/bin/dpm"
fi

echo "== [2/3] verifying DPM"
"$DPM_BIN" --version

echo "== [3/3] building + installing ALL recipes (resolved order)"
cd "$REPO"
# dpm deps-all prints the full-graph topological order (bare names, one
# per line), skipping anything already recorded in the local db.
ORDER=$("$DPM_BIN" --recipes "$REPO/recipes" deps-all)
# the optional GUI stack (recipes/gui) is opt-in: WITH_GUI=1
if [[ "${WITH_GUI:-0}" != "1" && -d "$REPO/recipes/gui" ]]; then
    GUI_PKGS=" $(ls "$REPO/recipes/gui" | tr '\n' ' ') "
    ORDER=$(for p in $ORDER; do [[ "$GUI_PKGS" == *" $p "* ]] || echo "$p"; done)
fi
COUNT=$(echo "$ORDER" | awk 'NF{n++} END{print n+0}')

# --------------------------------------------------------------------------
# Incremental mode (bootstrap/rebuild.sh): STAGE2_REBUILD="pkg1 pkg2 ..."
# rebuilds + reinstalls ONLY those recipes — even when already installed —
# in dependency order, instead of walking the whole graph. Everything else is
# left alone (the final-root sync below still runs, so the clean root gets the
# new archives). Dependents are NOT rebuilt: list them too if they must be.
# --------------------------------------------------------------------------
if [ -n "${STAGE2_REBUILD:-}" ]; then
    ALL_ORDER=$("$DPM_BIN" --recipes "$REPO/recipes" deps-all --include-installed)
    for want in $STAGE2_REBUILD; do
        case $'\n'"$ALL_ORDER"$'\n' in
            *$'\n'"$want"$'\n'*) ;;
            *) echo "stage2-inner: STAGE2_REBUILD: no recipe named '$want'" >&2; exit 1 ;;
        esac
    done
    ORDER=$(for p in $ALL_ORDER; do
        case " $STAGE2_REBUILD " in *" $p "*) echo "$p" ;; esac
    done)
    COUNT=$(echo "$ORDER" | awk 'NF{n++} END{print n+0}')
    echo "== stage2-inner: INCREMENTAL rebuild of $COUNT package(s): $(echo $ORDER)"
    # a stale build dir of the same name-version-rel must not be reused
    for p in $ORDER; do rm -rf /build/"$p"-[0-9]*; done
fi

# --------------------------------------------------------------------------
# The seed's Debian g++ searches /usr/include/x86_64-linux-gnu BEFORE
# /usr/include. Once DPM has installed OUR glibc (headers in /usr/include),
# Debian's own glibc headers there (bits/, sys/, gnu/, asm/, ...) would be a
# second, different glibc header set: g++ then fails on <memory>/<mutex>
# ("cannot convert '<brace-enclosed initializer list>' to 'unsigned int'").
# So, as soon as our glibc is installed, delete the seed's glibc headers from
# the multiarch dir. Keep c++/ (libstdc++ headers, not part of glibc).
# Idempotent: runs before every package build.
# --------------------------------------------------------------------------
purge_seed_libc_headers() {
    [ -d /var/lib/dpm/local/glibc ] || return 0     # our glibc not installed yet
    local d=/usr/include/x86_64-linux-gnu
    if [ -d "$d/bits" ] || [ -d "$d/sys" ] || [ -d "$d/gnu" ] || [ -d "$d/asm" ]; then
        echo "== stage2-inner: removing the seed's glibc headers from $d"
        rm -rf "$d/bits" "$d/gnu" "$d/sys" "$d/asm" \
               "$d/a.out.h" "$d/fpu_control.h" "$d/ieee754.h"
        local t; t="$(mktemp -d)"
        printf '#include <memory>\n#include <mutex>\n#include <condition_variable>\n#include <iostream>\nint main(){ std::cout << "ok"; }\n' > "$t/t.cc"
        if ! g++ -std=c++17 -pthread "$t/t.cc" -o "$t/t" || [ "$("$t/t")" != ok ]; then
            echo "stage2-inner: g++ still cannot build C++ after purging seed headers" >&2
            echo 'echo "#include <pthread.h>" | g++ -E -H -x c++ - 2>&1 >/dev/null | head -20' >&2
            echo "#include <pthread.h>" | g++ -E -H -x c++ - 2>&1 >/dev/null | head -20 >&2 || true
            rm -rf "$t"; exit 1
        fi
        rm -rf "$t"
    fi
}

# --------------------------------------------------------------------------
# Seed loader/libc switch. The seed's /usr/lib64/ld-linux-x86-64.so.2 points at
# the seed's (Debian/Ubuntu) loader. Our glibc installs its loader to
# /usr/lib but does not replace that link, so freshly built binaries
# (PT_INTERP=/lib64/ld-linux-x86-64.so.2) ran on the OLD loader with the NEW
# libc and segfaulted (e.g. `getent` in dhcpcd's post_install hook). As soon as
# our glibc is installed: point the link at our loader, make /usr/lib win in
# ld.so.conf and rebuild the cache. Idempotent; runs before every build, so a
# resumed build repairs an already-installed glibc without rebuilding it.
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# seed_glibc_relink: see the glibc recipe's post_install hook for the why.
# Repeated here so a resumed build (glibc already installed by an older
# recipe) is repaired too. Idempotent.
# --------------------------------------------------------------------------
seed_glibc_relink() {
    if [ -d /usr/lib/x86_64-linux-gnu ]; then
        for b in ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1 libresolv.so.2 libanl.so.1 libBrokenLocale.so.1 libmvec.so.1 libthread_db.so.1 libc_malloc_debug.so.0 libnss_files.so.2 libnss_dns.so.2 libnss_compat.so.2 libnss_hesiod.so.2 libnss_db.so.2; do
            new=/usr/lib/$b; old=/usr/lib/x86_64-linux-gnu/$b
            if [ -e "$new" ] && { [ -e "$old" ] || [ -L "$old" ]; }; then
                if [ "$(readlink -f "$old")" != "$(readlink -f "$new")" ]; then
                    ln -s "$new" "$old.dpm-tmp" && mv -T "$old.dpm-tmp" "$old"
                fi
            fi
        done
    fi
}

switch_to_new_glibc() {
    [ -d /var/lib/dpm/local/glibc ] || return 0
    [ -e /usr/lib/ld-linux-x86-64.so.2 ] || return 0
    local want=../lib/ld-linux-x86-64.so.2 cur
    cur=$(readlink /usr/lib64/ld-linux-x86-64.so.2 2>/dev/null || true)
    if [ "$cur" != "$want" ]; then
        echo "== stage2-inner: switching the build root to our glibc loader"
        mkdir -p /usr/lib64
        ln -sfn "$want" /usr/lib64/ld-linux-x86-64.so.2
    fi
    if [ -d /etc/ld.so.conf.d ] && [ "$(cat /etc/ld.so.conf.d/00-usrlib.conf 2>/dev/null)" != /usr/lib ]; then
        echo /usr/lib > /etc/ld.so.conf.d/00-usrlib.conf
        ldconfig
    fi
    seed_glibc_relink
    # fail early instead of 20 packages later. `expr` is the canary for the
    # RUNPATH problem described at seed_glibc_relink (it crashed configure
    # scripts 3000+ times in a 46-minute loop before this check existed).
    if ! timeout 20 expr a : '\(a\)' >/dev/null 2>&1 || ! timeout 20 expr 2 + 3 >/dev/null 2>&1; then
        echo "stage2-inner: expr (a seed binary) fails on our glibc — loader/libc mismatch" >&2
        for f in /usr/bin/expr /usr/bin/getent; do echo "--- ldd $f" >&2; ldd "$f" >&2 || true; done
        readelf -d /usr/bin/expr 2>/dev/null | grep -i 'rpath\|runpath' >&2 || true
        ls -l /usr/lib/x86_64-linux-gnu/libc.so.6 /usr/lib/libc.so.6 >&2 || true
        exit 1
    fi
    if ! getent passwd root >/dev/null; then
        echo "stage2-inner: getent fails after switching to our glibc loader" >&2
        ldd "$(command -v getent)" >&2 || true
        exit 1
    fi
}

# Build isolation (docs/design/build-isolation.md §5.4): stage2 must build
# against the seed + what it has built so far, so only `sandbox` (or `none`
# while bringing it up) is valid here — `closure` needs the finished
# base-devel archive set, which only exists from stage3 on.
ISOLATION="${STAGE2_ISOLATION:-none}"
case "$ISOLATION" in
    none|env|sandbox) ;;
    *) echo "stage2-inner: STAGE2_ISOLATION must be none|env|sandbox (got: $ISOLATION)" >&2; exit 1 ;;
esac
echo "== stage2-inner: isolation=$ISOLATION"

# Build one recipe from the graph and install it over the live system.
# Archive match: "<pkg>-<digit>..." via glob (grep -E would misparse names
# containing '+' etc. as regex metacharacters); e.g. `linux` never picks up
# `linux-headers-*`
build_one() {
    local pkg="$1"
    purge_seed_libc_headers
    switch_to_new_glibc
    "$DPM_BIN" --recipes "$REPO/recipes" --profiles "$REPO/profiles" --builddir /build \
        --jobs "$DPM_JOBS" build ${ISOLATION:+--isolation "$ISOLATION"} "$pkg"
    local archive
    # `|| true`: with pipefail a missing archive makes `ls` fail and the
    # assignment would kill the script silently (exit 2) before the
    # diagnostic below could run — the check must stay reachable
    archive=$(ls /build/out/"$pkg"-[0-9]*.dpm.tar.zst 2>/dev/null | sort -V | tail -1 || true)
    if [ -z "$archive" ]; then
        echo "stage2-inner: no archive built for $pkg" >&2
        exit 1
    fi
    "$DPM_BIN" --root / install --force "$archive"
    switch_to_new_glibc
    install_final "$archive"
}

mkdir -p /build

# --------------------------------------------------------------------------
# NOTE on recipe changes during a build: deps-all skips packages the local db
# already records BY NAME — the db carries no per-package build-id history at
# stage2's isolation level, so editing a recipe does NOT rebuild an installed
# package here. Deliberate procedures (use one):
#   * rebuild everything from the current recipes:  build-all.sh --from-stage 2
#   * rebuild ONE package:  dpm --root / remove <pkg> && re-run stage 2
#     (deps-all then re-orders it, and stage 2's final-root sync picks it up)
# A proper build-id-driven world rebuild is stage3 --isolation closure
# territory (dpm's build cache already records build ids at `env` and above).
# --------------------------------------------------------------------------

i=0
while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    i=$((i+1))
    echo "== stage2-inner: [$i/$COUNT] $pkg"
    build_one "$pkg"
done <<< "$ORDER"

# Make sure the final root has EVERY package the build root has (resume after
# a layout switch or an interrupted run), then seal it.
if final_root_enabled; then
    ALL=$("$DPM_BIN" --recipes "$REPO/recipes" deps-all --include-installed)
    if [[ "${WITH_GUI:-0}" != "1" && -d "$REPO/recipes/gui" ]]; then
        GUI_PKGS=" $(ls "$REPO/recipes/gui" | tr '\n' ' ') "
        ALL=$(for p in $ALL; do [[ "$GUI_PKGS" == *" $p "* ]] || echo "$p"; done)
    fi
    printf '%s\n' "$ALL" > /build/final-root.order
    sync_final_root /build/final-root.order
    finalize_final_root
fi

echo "== stage2-inner: full system complete ($COUNT packages)"
