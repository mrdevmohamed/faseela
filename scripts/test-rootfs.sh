#!/usr/bin/env bash
# test-rootfs.sh — tests of the rootfs artifact and of the self-hosting seed:
#   bootstrap/mkrootfs.sh          final root -> rootfs.tar.zst (+ .sha256, .packages)
#   bootstrap/seed-from-rootfs.sh  unpacked rootfs -> bootstrap seed
#   scripts/fetch-rootfs-seed.sh   previous release's rootfs -> local seed file
# All against throwaway trees; needs tar and zstd, no root, no network
# (the release lookup runs against a fake `gh`).
#
# Usage: scripts/test-rootfs.sh   (from the repo root or anywhere)
set -uo pipefail

REPO="${MYDISTRO_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
MKROOTFS="$REPO/bootstrap/mkrootfs.sh"
SEEDPREP="$REPO/bootstrap/seed-from-rootfs.sh"
FETCH="$REPO/scripts/fetch-rootfs-seed.sh"
WORK="$(mktemp -d /tmp/rootfs-test.XXXXXX)"
PASS=0 FAIL=0
trap 'rm -rf "$WORK"' EXIT

say()  { printf '\n\033[1m== TEST: %s\033[0m\n' "$*"; }
ok()   { printf '\033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

for t in tar zstd sha256sum; do
    command -v "$t" >/dev/null || { echo "test-rootfs: needs $t"; exit 1; }
done

# a fake FINISHED root: everything the sanity checks and the seed check look for
mkroot() {  # mkroot DIR [--no-rust]
    local r="$1" f p
    rm -rf "$r"; mkdir -p "$r"
    for f in usr/bin/env usr/bin/bash usr/bin/sh usr/bin/nawa usr/bin/gcc usr/bin/g++ \
             usr/bin/make usr/bin/ld usr/bin/ldconfig usr/bin/python3 usr/bin/perl \
             usr/bin/curl usr/bin/pkg-config usr/lib/libc.so.6; do
        mkdir -p "$r/$(dirname "$f")"; printf '#!/bin/sh\n' > "$r/$f"; chmod 755 "$r/$f"
    done
    if [[ ${2:-} != --no-rust ]]; then
        for f in usr/bin/rustc usr/bin/cargo; do printf '#!/bin/sh\n' > "$r/$f"; chmod 755 "$r/$f"; done
    fi
    mkdir -p "$r/etc" "$r/usr/lib64" "$r/var/lib/nawa/local" "$r/dev" "$r/proc" "$r/sys" "$r/run" "$r/tmp" "$r/root" "$r/boot"
    echo 'root:x:0:0:root:/root:/bin/bash' > "$r/etc/passwd"
    ln -s usr/bin "$r/bin"; ln -s usr/lib64 "$r/lib64"
    for p in glibc-2.40 gcc-15.1 bash-5.3 nawa-1; do
        mkdir -p "$r/var/lib/nawa/local/$p"; echo "name=$p" > "$r/var/lib/nawa/local/$p/desc"
    done
    mkdir -p "$r/var/lib/nawa/undo/gcc-15.1"; echo old > "$r/var/lib/nawa/undo/gcc-15.1/desc"
    echo kernel > "$r/boot/vmlinuz-6.10"
    chmod 1777 "$r/tmp"
}

# ============================================================== mkrootfs.sh ==
say "A. mkrootfs: a finished root becomes a verified tar.zst"
mkroot "$WORK/rootA"
# things that must NOT travel: pseudo-fs content, scratch, nested final root
echo host-secret > "$WORK/rootA/proc/cpuinfo"; echo x > "$WORK/rootA/dev/null.fake"
echo x > "$WORK/rootA/run/pid"; echo x > "$WORK/rootA/tmp/scratch"
mkdir -p "$WORK/rootA/sysroot/usr" "$WORK/rootA/sources"; echo x > "$WORK/rootA/sources/a.tar"
OUTA="$WORK/out/mydistro-x86_64-rootfs.tar.zst"
bash "$MKROOTFS" "$WORK/rootA" "$OUTA" > "$WORK/a.log" 2>&1; RC=$?
check "A1 exit 0"                          "[[ $RC -eq 0 ]]"
check "A2 archive written"                 "[[ -s $OUTA ]]"
check "A3 zstd integrity"                  "zstd -t -q $OUTA"
check "A4 sha256 sidecar verifies"         "(cd $WORK/out && sha256sum -c --quiet mydistro-x86_64-rootfs.tar.zst.sha256)"
check "A5 sidecar uses the bare file name" "grep -q ' mydistro-x86_64-rootfs.tar.zst\$' $OUTA.sha256"
check "A6 package inventory lists the db"  "grep -qx 'glibc-2.40' $WORK/out/mydistro-x86_64-rootfs.packages && [[ \$(wc -l < $WORK/out/mydistro-x86_64-rootfs.packages) -eq 4 ]]"
zstd -dc "$OUTA" | tar -t > "$WORK/a.list"
zstd -dc "$OUTA" | tar -tv > "$WORK/a.vlist"   # verbose list (grep it from a file: grep -q on a pipe + pipefail = SIGPIPE race)
check "A7 system files are inside"         "grep -qxF ./usr/bin/bash $WORK/a.list && grep -qxF ./var/lib/nawa/local/gcc-15.1/desc $WORK/a.list && grep -qxF ./boot/vmlinuz-6.10 $WORK/a.list"
check "A8 merged-usr symlinks kept"        "grep -q 'lib64 -> usr/lib64' $WORK/a.vlist"
check "A9 /proc content NOT archived"      "! grep -q 'proc/cpuinfo' $WORK/a.list"
check "A10 /dev, /run, /tmp content NOT archived" "! grep -qE 'dev/null.fake|run/pid|tmp/scratch' $WORK/a.list"
check "A11 mountpoint dirs ARE archived"   "grep -qxF ./proc/ $WORK/a.list && grep -qxF ./tmp/ $WORK/a.list"
check "A12 nested sysroot/sources excluded" "! grep -qE '^\./(sysroot|sources)' $WORK/a.list"
check "A13 /tmp keeps its sticky bit"      "zstd -dc $OUTA | tar -tv | grep -E ' \./tmp/\$' | grep -q '^drwxrwxrwt'"
check "A14 summary printed"                "grep -q 'rootfs: OK' $WORK/a.log && grep -q 'sha256' $WORK/a.log"

say "B. mkrootfs: round trip is faithful"
mkdir -p "$WORK/unpackB"
zstd -dc "$OUTA" | tar -x -C "$WORK/unpackB" --numeric-owner 2>/dev/null
check "B1 file contents identical"         "cmp $WORK/rootA/usr/bin/bash $WORK/unpackB/usr/bin/bash"
check "B2 modes preserved"                 "[[ \$(stat -c %a $WORK/unpackB/usr/bin/bash) == 755 ]]"
check "B3 symlink target preserved"        "[[ \$(readlink $WORK/unpackB/lib64) == usr/lib64 ]]"
check "B4 the db is intact"                "[[ \$(ls $WORK/unpackB/var/lib/nawa/local | wc -l) -eq 4 ]]"
if [[ $EUID -eq 0 ]]; then
    chown 1234:5678 "$WORK/rootA/usr/bin/curl"
    bash "$MKROOTFS" "$WORK/rootA" "$WORK/out/owner.tar.zst" > /dev/null 2>&1
    check "B5 numeric ids preserved (root)" "zstd -dc $WORK/out/owner.tar.zst | tar -tv --numeric-owner | grep ' usr/bin/curl\$\\| ./usr/bin/curl\$' | grep -q '1234/5678'"
    chown 0:0 "$WORK/rootA/usr/bin/curl"
else
    echo "SKIP B5 (needs root)"
fi

say "C. mkrootfs refuses what must not be shipped"
mkroot "$WORK/rootC1"; rm "$WORK/rootC1/usr/bin/nawa"
bash "$MKROOTFS" "$WORK/rootC1" "$WORK/out/c1.tar.zst" > "$WORK/c1.log" 2>&1; RC=$?
check "C1 missing nawa refused"             "[[ $RC -eq 1 ]] && grep -q '/usr/bin/nawa missing' $WORK/c1.log"
check "C2 nothing was written"             "[[ ! -e $WORK/out/c1.tar.zst && ! -e $WORK/out/c1.tar.zst.sha256 ]]"
mkroot "$WORK/rootC2"; mkdir -p "$WORK/rootC2/opt/seed"
bash "$MKROOTFS" "$WORK/rootC2" "$WORK/out/c2.tar.zst" > "$WORK/c2.log" 2>&1; RC=$?
check "C3 seed leftover (/opt/seed) refused" "[[ $RC -eq 1 ]] && grep -q '/opt/seed .*is in' $WORK/c2.log"
mkroot "$WORK/rootC3"; mkdir -p "$WORK/rootC3/build"
bash "$MKROOTFS" "$WORK/rootC3" "$WORK/out/c3.tar.zst" > "$WORK/c3.log" 2>&1; RC=$?
check "C4 build scratch (/build) refused"  "[[ $RC -eq 1 ]]"
mkroot "$WORK/rootC4"; rm -rf "$WORK/rootC4/var/lib/nawa/local"
bash "$MKROOTFS" "$WORK/rootC4" "$WORK/out/c4.tar.zst" > "$WORK/c4.log" 2>&1; RC=$?
check "C5 root without a nawa db refused"   "[[ $RC -eq 1 ]] && grep -q 'no nawa database' $WORK/c4.log"
bash "$MKROOTFS" "$WORK/rootA" "$WORK/out/wrong.tgz" > "$WORK/c5.log" 2>&1; RC=$?
check "C6 wrong extension refused (exit 2)" "[[ $RC -eq 2 ]]"
bash "$MKROOTFS" "$WORK/no-such-root" "$WORK/out/c7.tar.zst" > "$WORK/c7.log" 2>&1; RC=$?
check "C7 missing root refused"            "[[ $RC -eq 1 ]]"
ROOTFS_ZSTD_LEVEL=99 bash "$MKROOTFS" "$WORK/rootA" "$WORK/out/c8.tar.zst" > "$WORK/c8.log" 2>&1; RC=$?
check "C8 bad compression level refused"  "[[ $RC -eq 2 ]]"
mkroot "$WORK/rootC9" --no-rust
bash "$MKROOTFS" "$WORK/rootC9" "$WORK/out/c9.tar.zst" > "$WORK/c9.log" 2>&1; RC=$?
check "C9 no rust: still packed, with a NOTE" "[[ $RC -eq 0 ]] && grep -q 'cannot be used as a build seed' $WORK/c9.log"

# ======================================================= seed-from-rootfs.sh ==
say "D. seed-from-rootfs: the unpacked rootfs becomes a seed"
rm -rf "$WORK/seedD"; mkdir -p "$WORK/seedD"
zstd -dc "$OUTA" | tar -x -C "$WORK/seedD" --numeric-owner 2>/dev/null
bash "$SEEDPREP" "$WORK/seedD" "$OUTA" > "$WORK/d.log" 2>&1; RC=$?
check "D1 exit 0"                          "[[ $RC -eq 0 ]]"
check "D2 db is EMPTY (stage 2 will rebuild everything)" "[[ -d $WORK/seedD/var/lib/nawa/local && -z \$(ls -A $WORK/seedD/var/lib/nawa/local) ]]"
check "D3 old db parked intact"            "[[ \$(ls $WORK/seedD/var/lib/nawa/seed-local | wc -l) -eq 4 && -f $WORK/seedD/var/lib/nawa/seed-local/glibc-2.40/desc ]]"
check "D4 env.sh written"                  "grep -q NAWA_JOBS $WORK/seedD/opt/seed/env.sh"
check "D5 env.sh sets no CARGO_HOME/RUSTUP_HOME/PATH (toolchain is in /usr)" "! grep -qE '^[[:space:]]*export (CARGO_HOME|RUSTUP_HOME|PATH)=' $WORK/seedD/opt/seed/env.sh"
check "D6 manifest: kind + rootfs name"    "grep -q '^kind = rootfs' $WORK/seedD/opt/seed/manifest.txt && grep -q '^rootfs = mydistro-x86_64-rootfs.tar.zst' $WORK/seedD/opt/seed/manifest.txt"
check "D7 manifest: sha256 from the sidecar" "grep -q \"^rootfs-sha256 = \$(cut -d' ' -f1 $OUTA.sha256)\" $WORK/seedD/opt/seed/manifest.txt"
check "D8 manifest lists the parked packages" "grep -qx 'gcc-15.1' $WORK/seedD/opt/seed/manifest.txt"
check "D9 files themselves untouched"      "cmp $WORK/rootA/usr/bin/gcc $WORK/seedD/usr/bin/gcc"
bash "$SEEDPREP" "$WORK/seedD" "$OUTA" > "$WORK/d2.log" 2>&1; RC=$?
check "D10 idempotent: second run exits 0" "[[ $RC -eq 0 ]]"
check "D11 ... and keeps the parked db"    "[[ \$(ls $WORK/seedD/var/lib/nawa/seed-local | wc -l) -eq 4 ]]"
check "D12 ... and the live db stays empty" "[[ -z \$(ls -A $WORK/seedD/var/lib/nawa/local) ]]"
check "D13 stale rollback records dropped" "[[ ! -e $WORK/seedD/var/lib/nawa/undo ]]"

say "E. seed-from-rootfs refuses roots that cannot seed a build"
mkroot "$WORK/seedE1" --no-rust
bash "$SEEDPREP" "$WORK/seedE1" > "$WORK/e1.log" 2>&1; RC=$?
check "E1 no rustc/cargo: refused"         "[[ $RC -eq 1 ]] && grep -q '/usr/bin/rustc' $WORK/e1.log"
check "E2 db NOT touched on refusal"       "[[ \$(ls $WORK/seedE1/var/lib/nawa/local | wc -l) -eq 4 && ! -e $WORK/seedE1/var/lib/nawa/seed-local ]]"
mkroot "$WORK/seedE2"; rm "$WORK/seedE2/usr/bin/gcc"
bash "$SEEDPREP" "$WORK/seedE2" > "$WORK/e2.log" 2>&1; RC=$?
check "E3 no compiler: refused, names it"  "[[ $RC -eq 1 ]] && grep -q '/usr/bin/gcc' $WORK/e2.log"
mkroot "$WORK/seedE3"; mkdir -p "$WORK/seedE3/opt/seed"
printf '# debian packages extracted into the seed (name_version_arch.deb):\nfoo.deb\n' > "$WORK/seedE3/opt/seed/manifest.txt"
bash "$SEEDPREP" "$WORK/seedE3" > "$WORK/e3.log" 2>&1; RC=$?
check "E4 the Debian seed is not a rootfs seed" "[[ $RC -eq 1 ]] && grep -q 'Debian seed' $WORK/e3.log"
bash "$SEEDPREP" "$WORK/not-a-dir" > "$WORK/e4.log" 2>&1; RC=$?
check "E5 missing directory refused"       "[[ $RC -eq 1 ]]"

# ===================================================== fetch-rootfs-seed.sh ==
say "F. fetch-rootfs-seed: newest release that carries a rootfs"
mkdir -p "$WORK/fakebin" "$WORK/rel/v3" "$WORK/rel/v2" "$WORK/rel/v1"
# v3 is the newest but has only an ISO; v2 carries a rootfs; v1 an older one
echo iso > "$WORK/rel/v3/mydistro-x86_64.iso"
cp "$OUTA" "$WORK/rel/v2/mydistro-x86_64-rootfs.tar.zst"
( cd "$WORK/rel/v2" && sha256sum mydistro-x86_64-rootfs.tar.zst > mydistro-x86_64-rootfs.tar.zst.sha256 )
echo old > "$WORK/rel/v1/mydistro-x86_64-rootfs.tar.zst"
( cd "$WORK/rel/v1" && sha256sum mydistro-x86_64-rootfs.tar.zst > mydistro-x86_64-rootfs.tar.zst.sha256 )
cat > "$WORK/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: releases live in $FAKE_REL/<tag>/ (newest first: $FAKE_TAGS)
case "$1 $2" in
  "release list")  for t in $FAKE_TAGS; do echo "$t"; done ;;
  "release view")  tag="$3"; for f in "$FAKE_REL/$tag"/*; do [ -e "$f" ] && basename "$f"; done ;;
  "release download")
      tag="$3"; shift 3; dir=. pat=
      while [ $# -gt 0 ]; do case "$1" in
          --pattern) pat="$2"; shift 2 ;; --dir) dir="$2"; shift 2 ;; --repo) shift 2 ;; *) shift ;; esac; done
      [ -n "$FAKE_FAIL_DOWNLOAD" ] && exit 1
      for f in "$FAKE_REL/$tag"/$pat; do [ -e "$f" ] && cp "$f" "$dir/"; done ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$WORK/fakebin/gh"
export FAKE_REL="$WORK/rel" FAKE_TAGS="v3 v2 v1" FAKE_FAIL_DOWNLOAD=
PATH="$WORK/fakebin:$PATH" bash "$FETCH" "$WORK/dlF" > "$WORK/f.out" 2> "$WORK/f.err"; RC=$?
check "F1 exit 0"                          "[[ $RC -eq 0 ]]"
check "F2 prints the path of the seed"     "[[ \$(cat $WORK/f.out) == $WORK/dlF/mydistro-x86_64-rootfs.tar.zst ]]"
check "F3 picked the NEWEST rootfs (v2, not v1)" "cmp $WORK/dlF/mydistro-x86_64-rootfs.tar.zst $OUTA"
check "F4 sidecar downloaded next to it"   "[[ -s $WORK/dlF/mydistro-x86_64-rootfs.tar.zst.sha256 ]]"
check "F5 names the release it used"       "grep -q 'v2' $WORK/f.err"
# corrupt download: the sidecar no longer matches
cp -r "$WORK/rel" "$WORK/rel2"; echo corrupt >> "$WORK/rel2/v2/mydistro-x86_64-rootfs.tar.zst"
FAKE_REL="$WORK/rel2" FAKE_TAGS="v2" PATH="$WORK/fakebin:$PATH" bash "$FETCH" "$WORK/dlF2" > "$WORK/f2.out" 2> "$WORK/f2.err"; RC=$?
check "F6 checksum mismatch: exit 4, no path printed" "[[ $RC -eq 4 && ! -s $WORK/f2.out ]] && grep -q 'sha256' $WORK/f2.err"
check "F7 the corrupt file is deleted"     "[[ ! -e $WORK/dlF2/mydistro-x86_64-rootfs.tar.zst ]]"
# a release without the .sha256 asset is not trusted
rm "$WORK/rel/v2/mydistro-x86_64-rootfs.tar.zst.sha256"
PATH="$WORK/fakebin:$PATH" bash "$FETCH" "$WORK/dlF3" > "$WORK/f3.out" 2> "$WORK/f3.err"; RC=$?
check "F8 no .sha256 asset: that release is skipped (falls back to v1)" "[[ $RC -eq 0 ]] && grep -q 'v1' $WORK/f3.err"
# nothing at all
FAKE_TAGS="v3" PATH="$WORK/fakebin:$PATH" bash "$FETCH" "$WORK/dlF4" > "$WORK/f4.out" 2> "$WORK/f4.err"; RC=$?
check "F9 no release has a rootfs: exit 3" "[[ $RC -eq 3 && ! -s $WORK/f4.out ]]"
FAKE_TAGS="" PATH="$WORK/fakebin:$PATH" bash "$FETCH" "$WORK/dlF5" > "$WORK/f5.out" 2> "$WORK/f5.err"; RC=$?
check "F10 no releases at all: exit 3"     "[[ $RC -eq 3 ]]"
PATH="$WORK/fakebin:$PATH" FAKE_FAIL_DOWNLOAD=1 bash "$FETCH" "$WORK/dlF6" > "$WORK/f6.out" 2> "$WORK/f6.err"; RC=$?
check "F11 download failure is an error (exit 5), not 'none found'" "[[ $RC -eq 5 ]]"

echo
printf '=====================\n  PASS: %d   FAIL: %d\n=====================\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
