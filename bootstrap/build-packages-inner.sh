#!/usr/bin/env bash
# bootstrap/build-packages-inner.sh — runs INSIDE a rootfs (invoked by
# faseela-repo's .github/workflows/packages.yml via enter-root.sh): build the packages named
# in $PKGS with nawa and leave the archives in $BUILD/out.
#
# Differences from "just loop over the names":
#   * packages are built in DEPENDENCY order (nawa deps-all), whatever order
#     $PKGS lists them in, so a whole-tree build works;
#   * an archive that is already in $BUILD/out (the workflow pre-loads
#     everything already PUBLISHED there) is never rebuilt: its package is
#     up to date. A recipe bump (version/rel) changes the id, so it rebuilds;
#   * a published archive that a package needs is INSTALLED from the archive
#     instead of being compiled again;
#   * one failing package does not stop the run (KEEP_GOING=1): packages that
#     depend on it are skipped, everything else is still built and published;
#   * BUDGET_MIN: after that many minutes no NEW package is started, so the
#     workflow still has time to publish before the runner's 6 h limit. The
#     next run continues where this one stopped (published = done).
#
# Env:  PKGS         space-separated recipe names (required)
#       ISOLATION    none|env|sandbox|closure          (default sandbox)
#       NAWA_JOBS     parallel jobs per build           (default 4)
#       BUDGET_MIN   stop starting packages after N min (default 0 = no limit)
#       KEEP_GOING   1 = continue after a failure       (default 1)
#       REPO BUILD NAWA_BIN   overridable for tests (/mydistro, /build, /usr/bin/nawa)
#
# Writes $BUILD/report.txt (human readable) and $BUILD/status (KEY=value:
# BUILT FAILED SKIPPED UPTODATE INCOMPLETE). Exit 1 if anything failed.
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
REPO="${REPO:-/mydistro}"
BUILD="${BUILD:-/build}"
NAWA_BIN="${NAWA_BIN:-/usr/bin/nawa}"
: "${PKGS:?PKGS is empty}"
ISOLATION="${ISOLATION:-sandbox}"
BUDGET_MIN="${BUDGET_MIN:-0}"
KEEP_GOING="${KEEP_GOING:-1}"
OUT="$BUILD/out"

nawa() {
    "$NAWA_BIN" --recipes "$REPO/recipes" --profiles "$REPO/profiles" \
        --builddir "$BUILD" --jobs "${NAWA_JOBS:-4}" "$@"
}

# <name>-<version>-<rel> of a recipe = the stem of its archive (Recipe::id).
rid() {
    local f
    f="$(ls "$REPO"/recipes/*/"$1"/recipe.toml 2>/dev/null | head -n1)" || true
    [[ -n $f ]] || return 1
    awk -v n="$1" '
        /^\[/ { insec = ($0 ~ /^\[package\][ \t]*$/); next }
        insec {
            line = $0; sub(/[ \t]*#.*$/, "", line)
            if (line ~ /^[ \t]*(version|rel)[ \t]*=/) {
                key = line; sub(/[ \t]*=.*/, "", key); gsub(/[ \t]/, "", key)
                val = line; sub(/^[^=]*=[ \t]*/, "", val); gsub(/["\t ]/, "", val)
                v[key] = val
            }
        }
        END { if (v["version"] == "") exit 1
              print n "-" v["version"] "-" (v["rel"] == "" ? 1 : v["rel"]) }' "$f"
}

mkdir -p "$OUT"
START=$SECONDS
: > "$BUILD/report.txt"
note() { echo "$*" | tee -a "$BUILD/report.txt"; }

# ---- what to build, in dependency order ----------------------------------
ALL_ORDER="$(nawa deps-all --include-installed)"
for want in $PKGS; do
    grep -qxF -- "$want" <<< "$ALL_ORDER" || {
        echo "build-packages: no recipe named '$want'" >&2; exit 1; }
done
ORDER=""
while IFS= read -r p; do
    [[ -n $p ]] || continue
    case " $PKGS " in *" $p "*) ORDER+="$p " ;; esac
done <<< "$ALL_ORDER"
total=$(wc -w <<< "$ORDER")
echo "== build-packages: $total package(s), isolation=$ISOLATION, budget=${BUDGET_MIN} min"

declare -A failed=()     # id -> 1  (failed, or skipped because a dependency failed)
built=() failed_l=() skipped_l=() uptodate=() deferred=()
incomplete=0
i=0
for p in $ORDER; do
    i=$((i + 1))
    id="$(rid "$p")" || { note "FAILED   $p (cannot read its recipe)"; failed_l+=("$p"); failed[$p]=1; continue; }

    if [[ -f $OUT/$id.nawa.tar.zst ]]; then
        uptodate+=("$id")
        continue
    fi

    if (( BUDGET_MIN > 0 && (SECONDS - START) / 60 >= BUDGET_MIN )); then
        incomplete=1; deferred+=("$p")
        continue
    fi

    echo "::group::[$i/$total] $id (isolation=$ISOLATION)"
    # ---- dependencies: reuse published archives, compile only the rest ----
    # `nawa deps` lists what is NOT installed yet, dependencies first, the
    # package itself last: "  3. name-1.2-1 (build deps: a, b)".
    need=()
    mapfile -t need < <(nawa deps "$p" 2>/dev/null \
        | sed -E 's/^[[:space:]]*[0-9]+\.[[:space:]]+//; s/[[:space:]]+\(build deps:.*$//' || true)
    missing=() depfail=""
    for d in "${need[@]}"; do
        [[ -n $d && $d != "$id" ]] || continue
        if [[ -n ${failed[$d]:-} ]]; then depfail="$d"; break; fi
        if [[ -f $OUT/$d.nawa.tar.zst ]]; then
            echo "-- dependency $d: installing the published archive"
            nawa install --yes --force --allow-unsigned "$OUT/$d.nawa.tar.zst" \
                || missing+=("$d")
        else
            missing+=("$d")
        fi
    done

    if [[ -n $depfail ]]; then
        echo "-- skipped: dependency $depfail failed"
        echo "::endgroup::"
        note "SKIPPED  $id (dependency $depfail failed)"
        skipped_l+=("$id"); failed[$id]=1
        continue
    fi

    ok=0
    if (( ${#missing[@]} )) && [[ ! -d /var/lib/nawa/local/$p ]]; then
        # `install` builds the package AND the dependencies nobody has built yet
        nawa install --build --yes --force --isolation "$ISOLATION" "$p" && ok=1
    else
        nawa build --install --force --isolation "$ISOLATION" "$p" && ok=1
    fi
    if (( ok )) && [[ ! -f $OUT/$id.nawa.tar.zst ]]; then
        echo "-- nawa succeeded but left no $id.nawa.tar.zst in $OUT"
        ok=0
    fi
    echo "::endgroup::"

    if (( ok )); then
        note "BUILT    $id  ($(( (SECONDS - START) / 60 )) min into the run)"
        built+=("$id")
    else
        note "FAILED   $id"
        failed_l+=("$id"); failed[$id]=1
        if [[ $KEEP_GOING != 1 ]]; then break; fi
    fi
done

for p in "${deferred[@]}"; do note "DEFERRED $p (time budget used up)"; done

{
    echo "BUILT=${#built[@]}"
    echo "FAILED=${#failed_l[@]}"
    echo "SKIPPED=${#skipped_l[@]}"
    echo "UPTODATE=${#uptodate[@]}"
    echo "INCOMPLETE=$incomplete"
} > "$BUILD/status"

if (( ${#built[@]} )); then
    echo "== built archives (new this run):"
    printf '   %s\n' "${built[@]}"
fi
echo "== built ${#built[@]}, up to date ${#uptodate[@]}, failed ${#failed_l[@]}, skipped ${#skipped_l[@]}, deferred ${#deferred[@]}"
if (( ${#failed_l[@]} + ${#skipped_l[@]} )); then
    echo "build-packages: FAILED: ${failed_l[*]} ${skipped_l[*]}" >&2
    exit 1
fi
