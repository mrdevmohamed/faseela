#!/usr/bin/env bash
# test-final-root.sh — unit test of bootstrap/final-root.sh (two-root helpers)
# against a throwaway tree and a stub `dpm`; needs no root.
set -uo pipefail
REPO="${MYDISTRO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/final-root-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

B="$W/build"; F="$W/final"
mkdir -p "$B/var/lib/dpm/local"/{glibc,bash,dpm} "$B/build/out" "$F"
for p in glibc bash dpm; do : > "$B/build/out/$p-1.0-1.dpm.tar.zst"; done
mkdir -p "$B/build/out"; : > "$B/build/out/glibc-1.0-1.dpm.tar.zst"   # old name, must lose to newer
# stub dpm: `--root R install --force ARCHIVE` records the install in R's db
cat > "$W/dpm" <<'STUB'
#!/usr/bin/env bash
[[ $1 == --root && $3 == install ]] || exit 9
n=$(basename "$5" | sed 's/-[0-9].*//')
mkdir -p "$2/var/lib/dpm/local/$n"; echo "$5" >> "$2/.installed"
STUB
chmod +x "$W/dpm"

export FINAL_ROOT="$F" DPM_BIN="$W/dpm" BUILD_ROOT="$B"
# shellcheck disable=SC1091
. "$REPO/bootstrap/final-root.sh"

check "enabled when FINAL_ROOT set"     "final_root_enabled"
printf 'glibc\nbash\ndpm\nnotbuilt\n' > "$W/order"
check "sync succeeds"                   "sync_final_root $W/order"
check "all built pkgs reached final"    "[[ -d $F/var/lib/dpm/local/glibc && -d $F/var/lib/dpm/local/bash && -d $F/var/lib/dpm/local/dpm ]]"
check "unbuilt pkg skipped"             "[[ ! -d $F/var/lib/dpm/local/notbuilt ]]"
before=$(wc -l < "$F/.installed")
sync_final_root "$W/order" >/dev/null
check "second sync is a no-op"          "[[ \$(wc -l < $F/.installed) -eq $before ]]"
rm -rf "$F/var/lib/dpm/local/bash"; rm -f "$B/build/out/bash-"*
check "missing archive is an error"     "! sync_final_root $W/order"

# finalize: leak + missing-file detection
mkdir -p "$F/usr/bin" "$F/usr/lib"; : > "$F/usr/bin/bash"; : > "$F/usr/bin/dpm"; : > "$F/usr/lib/libc.so.6"
check "finalize ok on a clean root"     "finalize_final_root"
check "skeleton dirs created"           "[[ -d $F/proc && -d $F/dev && -d $F/sys && -d $F/run ]]"
check "/tmp is 1777"                    "[[ \$(stat -c %a $F/tmp) == 1777 ]]"
mkdir -p "$F/opt/seed"
check "finalize rejects a seed leak"    "! finalize_final_root"
rm -rf "$F/opt/seed"; rm -f "$F/usr/bin/bash"
check "finalize rejects missing bash"   "! finalize_final_root"

# legacy mode: everything is a no-op
FINAL_ROOT=""
check "disabled when FINAL_ROOT empty"  "! final_root_enabled"
check "install_final no-op"             "install_final /nonexistent"
check "sync no-op"                      "sync_final_root /nonexistent"
check "finalize no-op"                  "finalize_final_root"

echo; echo "  PASS: $PASS   FAIL: $FAIL"; [[ $FAIL -eq 0 ]]
