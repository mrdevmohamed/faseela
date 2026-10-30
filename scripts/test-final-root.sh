#!/usr/bin/env bash
# test-final-root.sh — unit test of bootstrap/final-root.sh (two-root helpers)
# against a throwaway tree and a stub `nawa`; needs no root.
set -uo pipefail
REPO="${MYDISTRO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
W="$(mktemp -d /tmp/final-root-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0 FAIL=0
check(){ if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

B="$W/build"; F="$W/final"
mkdir -p "$B/var/lib/nawa/local"/{glibc,bash,nawa} "$B/build/out" "$F"
for p in glibc bash nawa; do : > "$B/build/out/$p-1.0-1.nawa.tar.zst"; done
mkdir -p "$B/build/out"; : > "$B/build/out/glibc-1.0-1.nawa.tar.zst"   # old name, must lose to newer
# stub nawa: `--root R install --force ARCHIVE` records the install in R's db
cat > "$W/nawa" <<'STUB'
#!/usr/bin/env bash
[[ $1 == --root && $3 == install ]] || exit 9
n=$(basename "$5" | sed 's/-[0-9].*//')
mkdir -p "$2/var/lib/nawa/local/$n"; echo "$5" >> "$2/.installed"
STUB
chmod +x "$W/nawa"

export FINAL_ROOT="$F" NAWA_BIN="$W/nawa" BUILD_ROOT="$B"
# shellcheck disable=SC1091
. "$REPO/bootstrap/final-root.sh"

check "enabled when FINAL_ROOT set"     "final_root_enabled"
printf 'glibc\nbash\nnawa\nnotbuilt\n' > "$W/order"
check "sync succeeds"                   "sync_final_root $W/order"
check "all built pkgs reached final"    "[[ -d $F/var/lib/nawa/local/glibc && -d $F/var/lib/nawa/local/bash && -d $F/var/lib/nawa/local/nawa ]]"
check "unbuilt pkg skipped"             "[[ ! -d $F/var/lib/nawa/local/notbuilt ]]"
before=$(wc -l < "$F/.installed")
sync_final_root "$W/order" >/dev/null
check "second sync is a no-op"          "[[ \$(wc -l < $F/.installed) -eq $before ]]"
rm -rf "$F/var/lib/nawa/local/bash"; rm -f "$B/build/out/bash-"*
check "missing archive is an error"     "! sync_final_root $W/order"

# finalize: leak + missing-file detection
mkdir -p "$F/usr/bin" "$F/usr/lib"; : > "$F/usr/bin/bash"; : > "$F/usr/bin/nawa"; : > "$F/usr/lib/libc.so.6"
check "finalize ok on a clean root"     "finalize_final_root"
check "skeleton dirs created"           "[[ -d $F/proc && -d $F/dev && -d $F/sys && -d $F/run ]]"
check "/tmp is 1777"                    "[[ \$(stat -c %a $F/tmp) == 1777 ]]"
mkdir -p "$F/opt/seed"
check "finalize rejects a seed leak"    "! finalize_final_root"
rm -rf "$F/opt/seed"; rm -f "$F/usr/bin/bash"
check "finalize rejects missing bash"   "! finalize_final_root"

# recipe snapshot + trust key
DS="$W/distro"; mkdir -p "$DS/recipes/base/hello" "$DS/dist"
echo '# r' > "$DS/recipes/base/hello/recipe.toml"; echo deadbeef > "$DS/dist/nawa.pub"
mkdir -p "$F/usr/lib"; : > "$F/usr/bin/bash"
check "finalize installs the snapshot"  "DISTRO_SRC=$DS finalize_final_root"
check "recipes copied to the final root" "[[ -s $F/usr/share/nawa/recipes/base/hello/recipe.toml ]]"
check "snapshot rev recorded"           "grep -q '^snapshot-[0-9a-f]\{12\}\$' $F/var/lib/nawa/recipes.rev"
check "repository key trusted"          "[[ -s $F/etc/nawa/trusted-keys/nawa.pub ]]"
rm -rf "$DS/dist"; rm -rf "$F/etc/nawa"
check "missing key warns, does not fail" "DISTRO_SRC=$DS finalize_final_root"
check "no key is trusted without dist/nawa.pub" "[[ ! -e $F/etc/nawa/trusted-keys/nawa.pub ]]"
echo '# changed' > "$DS/recipes/base/hello/recipe.toml"; r1=$(cat "$F/var/lib/nawa/recipes.rev")
DISTRO_SRC=$DS finalize_final_root >/dev/null 2>&1
check "snapshot rev follows the content" "[[ \$(cat $F/var/lib/nawa/recipes.rev) != $r1 ]]"

# legacy mode: everything is a no-op
FINAL_ROOT=""
check "disabled when FINAL_ROOT empty"  "! final_root_enabled"
check "install_final no-op"             "install_final /nonexistent"
check "sync no-op"                      "sync_final_root /nonexistent"
check "finalize no-op"                  "finalize_final_root"

# verify_final_root_no_seed_refs: the stage-3 self-hosting proof that scans a
# root's ELFs for interpreter/NEEDED/RPATH references into the deleted /opt/*
# seed dirs. Fixtures: a clean binary, one poisoned with DT_RUNPATH=/opt/seed,
# one whose interpreter points at /opt/cargo — plus non-ELFs that must not be
# flagged. Compiled here on purpose: readelf must parse REAL ELF metadata.
SR="$W/seedref"; mkdir -p "$SR/usr/bin" "$SR/usr/lib"
printf '#!/bin/sh\necho not-an-elf\n' > "$SR/usr/bin/a-script"
printf 'plain data, not an elf\n' > "$SR/usr/bin/notes.txt"
printf 'int main(void){return 0;}\n' > "$W/t.c"
gcc -o "$SR/usr/bin/clean" "$W/t.c" 2>/dev/null || echo "WARN: gcc unavailable — seedref checks degraded"
if [[ -x $SR/usr/bin/clean ]]; then
    gcc -Wl,-rpath,/opt/seed/lib -o "$SR/usr/bin/poisoned-rpath" "$W/t.c"
    gcc -Wl,--dynamic-linker=/opt/cargo/lib/ld.so -o "$SR/usr/bin/poisoned-interp" "$W/t.c"
    mkdir -p "$SR/cleanonly/usr/bin"
    cp "$SR/usr/bin/clean" "$SR/usr/bin/a-script" "$SR/cleanonly/usr/bin/"
    check "clean tree (script ignored) passes"  "verify_final_root_no_seed_refs $SR/cleanonly"
    out=$(verify_final_root_no_seed_refs "$SR" 2>&1); rc=$?
    check "poisoned tree fails the scan"        "[[ $rc -ne 0 ]]"
    check "rpath poison is named"               "printf '%s' \"\$out\" | grep -q poisoned-rpath"
    check "interpreter poison is named"         "printf '%s' \"\$out\" | grep -q poisoned-interp"
    check "the /opt path is shown"              "printf '%s' \"\$out\" | grep -q '/opt/seed/lib'"
    check "clean binary not accused"            "! printf '%s' \"\$out\" | grep -q 'bin/clean references'"
    out=$(READELF_BIN=/nonexistent-readelf verify_final_root_no_seed_refs "$SR/cleanonly" 2>&1) || true
    check "missing readelf warns, does not fail" "printf '%s' \"\$out\" | grep -q 'cannot scan'"
fi

# verify_final_root_needed_resolved: DT_NEEDED sonames must exist inside the
# root (the `ar: libfl.so.2: cannot open shared object file` class of bug).
if command -v gcc >/dev/null 2>&1; then
    NR="$W/needed"; mkdir -p "$NR/ok/usr/bin" "$NR/ok/usr/lib" "$NR/bad/usr/bin" "$NR/bad/usr/lib"
    printf 'int fl_yywrap(void){return 1;}\n' > "$W/fl.c"
    printf 'int fl_yywrap(void);\nint main(void){return fl_yywrap()-1;}\n' > "$W/m.c"
    gcc -shared -Wl,-soname,libfl.so.2 -o "$W/libfl.so.2.0.0" "$W/fl.c"
    gcc -o "$NR/ok/usr/bin/tool" "$W/m.c" "$W/libfl.so.2.0.0" -Wl,-rpath,'$ORIGIN/../lib'
    cp "$NR/ok/usr/bin/tool" "$NR/bad/usr/bin/tool"
    cp "$W/libfl.so.2.0.0" "$NR/ok/usr/lib/"; ln -s libfl.so.2.0.0 "$NR/ok/usr/lib/libfl.so.2"
    : > "$NR/ok/usr/lib/libc.so.6"; : > "$NR/bad/usr/lib/libc.so.6"
    # libc/ld.so come from the real glibc; give both roots the sonames the fixture needs
    for r in ok bad; do for l in $(readelf -d "$NR/$r/usr/bin/tool" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | grep -v '^libfl'); do : > "$NR/$r/usr/lib/$l"; done; done
    check "NEEDED present in root passes"       "verify_final_root_needed_resolved $NR/ok"
    out=$(verify_final_root_needed_resolved "$NR/bad" 2>&1); rc=$?
    check "missing libfl.so.2 fails the scan"   "[[ $rc -ne 0 ]]"
    check "offender and soname are named"       "printf '%s' \"\$out\" | grep -q 'usr/bin/tool needs libfl.so.2'"
    out=$(READELF_BIN=/nonexistent-readelf verify_final_root_needed_resolved "$NR/bad" 2>&1) || true
    check "missing readelf warns, does not fail" "printf '%s' \"\$out\" | grep -q 'cannot check'"
fi

echo; echo "  PASS: $PASS   FAIL: $FAIL"; [[ $FAIL -eq 0 ]]
