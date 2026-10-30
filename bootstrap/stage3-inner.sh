#!/usr/bin/env bash
# stage3-inner.sh — runs INSIDE the chroot (invoked by stage3.sh).
#
# Rebuilds the toolchain set (or the whole graph with STAGE3_WORLD=1) with
# the distro's own gcc, removes the seed toolchain, and then PROVES the
# result instead of trusting the exit code:
#   1. every rebuilt tool actually comes from the distro (db ownership of
#      /usr/bin/gcc and /usr/bin/nawa — seed files are owned by nobody)
#   2. the system can compile, link and run C code with its own toolchain
#      after the seed is gone
#   3. no ELF in the final root references the deleted /opt/* seed dirs
#      (interpreter, DT_NEEDED or RPATH/RUNPATH)
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export NAWA_JOBS="${NAWA_JOBS:-4}"
# overridable so tests can drive this script with a stub nawa (same pattern
# as final-root.sh); in the real chroot /usr/bin/nawa is used
NAWA_BIN="${NAWA_BIN:-/usr/bin/nawa}"
REPO=/mydistro

. "$REPO/bootstrap/final-root.sh"
if final_root_enabled; then
    echo "== stage3: two-root layout: build root=/  final root=$FINAL_ROOT"
fi
# Build isolation (docs/design/build-isolation.md §5.4): stage3 is the first
# fully hermetic pass — `closure` builds against assembled archives, never the
# live system, so the seed (deleted below) is provably unnecessary.
ISOLATION="${STAGE3_ISOLATION:-none}"
case "$ISOLATION" in
    none|env|sandbox|closure) ;;
    *) echo "stage3: STAGE3_ISOLATION must be none|env|sandbox|closure" >&2; exit 1 ;;
esac
echo "== stage3: isolation=$ISOLATION"

if [[ "${STAGE3_WORLD:-0}" == "1" ]]; then
    echo "== stage3: rebuilding the ENTIRE graph with the distro's own gcc"
    # --include-installed: every package IS installed at this point, and
    # deps-all skips what the db records — without the flag the order would
    # come back empty and nothing would be rebuilt
    ORDER=$("$NAWA_BIN" --recipes "$REPO/recipes" deps-all --include-installed) || {
        echo "stage3: deps-all --include-installed failed — the installed nawa" >&2
        echo "stage3: may predate the flag; re-run stage2 (it rebuilds nawa) first" >&2
        exit 1
    }
    if [[ "${WITH_GUI:-0}" != "1" && -d "$REPO/recipes/gui" ]]; then
        GUI_PKGS=" $(ls "$REPO/recipes/gui" | tr '\n' ' ') "
        ORDER=$(for p in $ORDER; do [[ "$GUI_PKGS" == *" $p "* ]] || echo "$p"; done)
    fi
else
    # The toolchain set is DEFINED by recipes/toolchain (not a hardcoded list
    # that silently stales): filter the full topological order down to its
    # members — dependencies between them keep their resolved order.
    echo "== stage3: rebuilding the toolchain set with the distro's own gcc"
    if [[ ! -d $REPO/recipes/toolchain ]]; then
        echo "stage3: $REPO/recipes/toolchain not found — nothing to self-host" >&2
        exit 1
    fi
    TOOLCHAIN_PKGS=" $(ls "$REPO/recipes/toolchain" | tr '\n' ' ') "
    ORDER=$("$NAWA_BIN" --recipes "$REPO/recipes" deps-all --include-installed \
        | while IFS= read -r p; do
              case "$TOOLCHAIN_PKGS" in *" $p "*) echo "$p" ;; esac
          done) || { echo "stage3: deps-all failed" >&2; exit 1; }
fi
COUNT=$(echo "$ORDER" | awk 'NF{n++} END{print n+0}')
[ "$COUNT" -gt 0 ] || { echo "stage3: rebuild found nothing to build" >&2; exit 1; }

mkdir -p /build3

# two-root: make sure the final root already holds every installed package
# (e.g. `--from-stage 3` after a build made before the two-root layout)
if final_root_enabled; then
    SYNC_ORDER=$("$NAWA_BIN" --recipes "$REPO/recipes" deps-all --include-installed) || SYNC_ORDER=""
    if [[ "${WITH_GUI:-0}" != "1" && -d "$REPO/recipes/gui" ]]; then
        GUI_PKGS=" $(ls "$REPO/recipes/gui" | tr '\n' ' ') "
        SYNC_ORDER=$(for p in $SYNC_ORDER; do [[ "$GUI_PKGS" == *" $p "* ]] || echo "$p"; done)
    fi
    printf '%s\n' "$SYNC_ORDER" > /build3/final-root.order
    sync_final_root /build3/final-root.order
fi

# `closure` needs the base-devel archive before anything else: it IS the
# base layer of every build root
if [ "$ISOLATION" = "closure" ]; then
    case " $ORDER " in
        *" base-devel "*) ;;
        *) ORDER="base-devel $ORDER"; COUNT=$((COUNT+1)) ;;
    esac

    # `closure` assembles each build root from archives in <builddir>/out, and
    # stage 3 builds in /build3 while stage 2 produced the archive set in
    # /build. Seed /build3/out with it (a real copy, never a hardlink: stage 3
    # rewrites same-named archives as it rebuilds, which must not touch
    # stage 2's files; -n keeps anything stage 3 already built on a resume).
    if ! compgen -G "/build/out/*.nawa.tar.zst" >/dev/null; then
        echo "stage3: closure needs stage 2's archives in /build/out — none found" >&2
        echo "stage3: re-run from stage 2: build-all.sh --from-stage 2 ..." >&2
        exit 1
    fi
    mkdir -p /build3/out
    cp -an --reflink=auto /build/out/. /build3/out/
    echo "== stage3: seeded /build3/out with stage 2's archives ($(ls /build3/out/*.nawa.tar.zst | wc -l))"
fi

i=0
for pkg in $ORDER; do
    i=$((i+1))
    echo "== stage3: [$i/$COUNT] $pkg"
    "$NAWA_BIN" --recipes "$REPO/recipes" --profiles "$REPO/profiles" --builddir /build3 \
        --jobs "$NAWA_JOBS" build ${ISOLATION:+--isolation "$ISOLATION"} "$pkg"
    # match "<pkg>-<digit>..." with a glob (grep -E would misparse names
    # containing '+' etc. as regex metacharacters); e.g. `linux` never picks
    # up `linux-headers-*`
    # `|| true`: with pipefail a missing archive makes `ls` fail and the
    # assignment would kill the script silently (exit 2) before the
    # diagnostic below could run — the check must stay reachable
    ARCHIVE=$(ls /build3/out/"$pkg"-[0-9]*.nawa.tar.zst 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$ARCHIVE" ] || { echo "stage3: no archive built for $pkg" >&2; exit 1; }
    "$NAWA_BIN" --root / install --force "$ARCHIVE"
    install_final "$ARCHIVE"
done

echo "== stage3: removing seed toolchain"
rm -rf /opt/cross-tools /opt/cargo /opt/rustup /opt/seed

# ==========================================================================
# SELF-HOSTING PROOFS — a clean loop above only proves the packages built;
# it does NOT prove they came from us or that the system stands alone.
# ==========================================================================
echo "== stage3: verifying self-hosting"

# (1) attribution: the tools must be OURS. Files installed by nawa are
# recorded in the local db; anything the seed's dpkg -x left behind is owned
# by no package. If gcc/nawa are not db-owned, the "rebuild" never replaced
# the seed's copies and the claim below would be a lie.
for f in /usr/bin/gcc /usr/bin/nawa; do
    if ! "$NAWA_BIN" --root / owner "$f" 2>/dev/null | grep -q "is owned by"; then
        echo "stage3: SELF-HOST FAILED: $f is not owned by any package —" >&2
        echo "stage3: the seed's copy was never replaced by a distro build." >&2
        echo "stage3: check the rebuild order (recipes/toolchain) and re-run stage 3." >&2
        exit 1
    fi
done

# (2) the system can build software on its own: compile, link AND run a
# small C program with the distro's toolchain — with /opt gone and only
# /usr/bin on PATH, every tool involved is ours. PATH contains no /opt/*,
# so this cannot be satisfied by seed leftovers.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cat > "$T/t.c" <<'EOT'
#include <stdio.h>
#include <pthread.h>
static void *f(void *a){ return a; }
int main(void){ pthread_t t; pthread_create(&t,0,f,0); pthread_join(t,0);
  puts("selfhost-ok"); return 0; }
EOT
if ! cc -O2 -pthread "$T/t.c" -o "$T/t"; then
    echo "stage3: SELF-HOST FAILED: the distro's gcc cannot compile/link C after the seed was removed" >&2
    exit 1
fi
if [ "$("$T/t")" != "selfhost-ok" ]; then
    echo "stage3: SELF-HOST FAILED: compiled test binary did not run (loader/libc broken?)" >&2
    exit 1
fi
echo "   gcc $(gcc -dumpfullversion) compiled and ran the C test"

# (3) the final root must not reference the deleted seed: any ELF whose
# interpreter, DT_NEEDED or RPATH/RUNPATH points into /opt/{seed,cargo,
# rustup,cross-tools} would be broken now (or secretly host-dependent).
R="${FINAL_ROOT:-/}"
verify_final_root_no_seed_refs "$R" || {
    echo "stage3: SELF-HOST FAILED: the final root still references the deleted seed" >&2
    exit 1
}

# (4) every shared library an installed binary needs must itself be in the
# final root. A build-only package (flex's libfl, ...) linked into a shipped
# binary passes (3) yet leaves e.g. `ar` dead on the installed system.
verify_final_root_needed_resolved "$R" || {
    echo "stage3: SELF-HOST FAILED: binaries in the final root need libraries that are not installed" >&2
    echo "        (a build-only dependency leaked into a shipped binary — add it to that recipe's" >&2
    echo "         depends.run, or stop the recipe from linking it)" >&2
    exit 1
}

# (5) the proofs above ran against the BUILD root. The rootfs that gets
# published (and seeds the next build) is the FINAL root, so it must hold a
# real compiler too — not just the gcc driver. Fail here, with a listing,
# instead of publishing a rootfs whose next build dies in stage 1.
if [ -n "${FINAL_ROOT:-}" ]; then
    for cc in cc1 cc1plus; do
        if ! compgen -G "$FINAL_ROOT/usr/libexec/gcc/*/*/$cc" >/dev/null; then
            echo "stage3: FINAL ROOT BROKEN: gcc's $cc is missing in $FINAL_ROOT" >&2
            echo "stage3: build root has:  $(ls /usr/libexec/gcc/*/*/ 2>&1 | tr '\n' ' ')" >&2
            echo "stage3: final root has:  $(ls "$FINAL_ROOT"/usr/libexec/gcc/*/*/ 2>&1 | tr '\n' ' ')" >&2
            echo "stage3: files nawa recorded for gcc in the final root:" >&2
            "$NAWA_BIN" --root "$FINAL_ROOT" files gcc 2>&1 | grep -E 'libexec|cc1' >&2 || true
            exit 1
        fi
    done
fi

# the final root never contained the seed; verify that and refresh ld.so.cache
finalize_final_root
echo "== stage3: self-hosted (rebuilt with its own compiler, seed removed, proofs passed)"
