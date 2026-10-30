#!/usr/bin/env bash
# stage1-inner.sh — runs INSIDE the chroot (invoked by stage1.sh).
#
# The seed already contains a complete, working native toolchain (Debian's
# binutils/gcc/g++/glibc + make, bash, coreutils, python3, perl, rustc/cargo).
# That IS the temporary toolchain: stage2 uses it to build NAWA and then every
# recipe (including recipes/toolchain/*), and stage3 rebuilds without the seed.
#
# Cross-compiling a second glibc/gcc over the seed's /usr (LFS=/) mixes two
# glibc header sets and cannot work, so stage1 does NOT build one. It prepares
# the chroot and verifies that the seed toolchain can really compile, link and
# run C, C++ and Rust code, so any seed problem shows up here, not in stage2.
set -euo pipefail

LFS="${LFS:-/}"
LFS="${LFS%/}"

# ==========================================================================
# 0) essential directories + merged-usr symlinks + minimal /etc
# ==========================================================================
echo "== [1/3] essential dirs, merged-usr symlinks, minimal /etc"
for d in boot dev etc home media mnt opt proc root run srv sys tmp var/log var/spool var/cache var/lib var/local var/lock var/mail var/opt var/run usr/bin usr/include usr/lib usr/sbin usr/share usr/src; do
    mkdir -p "$LFS/$d"
done
chmod 1777 "$LFS/tmp"
link_usr() {  # link_usr <usr-subdir> <top-level-name>
    if [ -L "$LFS/$2" ]; then return 0; fi
    if [ -d "$LFS/$2" ] && [ -z "$(ls -A "$LFS/$2" 2>/dev/null)" ]; then
        rmdir "$LFS/$2"
    fi
    if [ -e "$LFS/$2" ]; then
        echo "stage1-inner: WARNING: $LFS/$2 is a populated real directory;" \
             "merged-usr symlinks not applied" >&2
        return 0
    fi
    ln -s "usr/$1" "$LFS/$2"
}
link_usr bin bin
link_usr bin sbin
link_usr lib lib
link_usr lib64 lib64
ln -sfn /proc/mounts "$LFS/etc/mtab"
# dpkg -x skipped base-passwd: give the chroot a minimal user database.
[ -e "$LFS/etc/passwd" ] || printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' > "$LFS/etc/passwd"
[ -e "$LFS/etc/group" ]  || printf 'root:x:0:\nnogroup:x:65534:\n' > "$LFS/etc/group"
[ -e "$LFS/etc/hosts" ]  || printf '127.0.0.1 localhost\n::1 localhost\n' > "$LFS/etc/hosts"

# ==========================================================================
# 1) verify the seed toolchain
# ==========================================================================
echo "== [2/3] verifying the seed toolchain"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T"
fail() { echo "stage1-inner: SEED CHECK FAILED: $*" >&2; exit 1; }

# Debian alternatives links that `dpkg -x` skipped (older seeds lack c++)
[ -e /usr/bin/c++ ] || { [ -x /usr/bin/g++ ] && ln -s g++ /usr/bin/c++; }

for t in bash sh env make gcc g++ cc c++ ld as ar ldconfig grep sed gawk awk tar gzip xz zstd bzip2 \
         patch m4 bison flex find diff file pkg-config python3 perl curl install sha256sum; do
    command -v "$t" >/dev/null 2>&1 || fail "'$t' not found in PATH"
done

cat > t.c <<'EOT'
#include <stdio.h>
#include <pthread.h>
static void *f(void *a){ return a; }
int main(void){ pthread_t t; pthread_create(&t,0,f,0); pthread_join(t,0);
  puts("c-ok"); return 0; }
EOT
if ! cc -O2 -pthread t.c -o tc; then
    # say WHY: the file may be missing, or present but not executable here
    # (loader / symlink / mount problem inside this chroot)
    {
        echo "---- seed C compile diagnostics ----"
        echo "PATH=$PATH"; echo "GCC_EXEC_PREFIX=${GCC_EXEC_PREFIX:-} COMPILER_PATH=${COMPILER_PATH:-}"
        command -v cc gcc; ls -l "$(command -v cc)" "$(command -v gcc)" 2>&1
        echo "cc -print-prog-name=cc1 -> $(cc -print-prog-name=cc1 2>&1)"
        echo "cc -print-search-dirs:"; cc -print-search-dirs 2>&1 | head -5
        echo "libexec dirs:"; ls -ld /usr/libexec /usr/libexec/gcc/*/* 2>&1
        ls -l /usr/libexec/gcc/*/*/ 2>&1 | head -20
        for c in /usr/libexec/gcc/*/*/cc1; do
            echo "== $c"; ls -lL "$c" 2>&1; file "$c" 2>&1
            readelf -l "$c" 2>&1 | grep -i interpreter
            "$c" --version 2>&1 | head -3
        done
        echo "loader: $(ls -lL /lib64/ld-linux-x86-64.so.2 2>&1)"
        ls -ld /lib64 /usr/lib64 2>&1
        mount | grep -E ' (/|/usr|/mnt[^ ]*) ' 2>&1 | head
        echo "---- end diagnostics ----"
    } >&2
    fail "cannot compile/link C"
fi
[ "$(./tc)" = "c-ok" ] || fail "C test binary did not run"

cat > t.cc <<'EOT'
#include <iostream>
#include <memory>
#include <mutex>
#include <condition_variable>
int main(){ auto p = std::make_shared<int>(7); std::mutex m; std::condition_variable cv;
  std::cout << "cxx-ok " << *p << "\n"; }
EOT
g++ -O2 -pthread t.cc -o tcc || fail "cannot compile/link C++"
[ "$(./tcc)" = "cxx-ok 7" ] || fail "C++ test binary did not run"

if [ -r /opt/seed/env.sh ]; then . /opt/seed/env.sh; fi
command -v rustc >/dev/null 2>&1 || fail "rustc not found (is /opt/seed/env.sh sourced?)"
command -v cargo >/dev/null 2>&1 || fail "cargo not found"
echo 'fn main(){ println!("rust-ok"); }' > t.rs
rustc -O t.rs -o trs || fail "rustc cannot compile/link (needs 'cc' linker)"
[ "$(./trs)" = "rust-ok" ] || fail "Rust test binary did not run"

python3 -c 'import sys; print("py-ok")' >/dev/null || fail "python3"
perl -e 'print "perl-ok\n"' >/dev/null || fail "perl"

# network (informational only: stage2 downloads source tarballs)
if curl -fsS -o /dev/null -I --max-time 20 https://mirrors.kernel.org/gnu/ 2>/dev/null; then
    echo "   network + TLS: ok"
else
    echo "   WARNING: cannot reach https://mirrors.kernel.org (DNS/TLS); stage2 downloads will fail" >&2
fi

echo "   gcc    $(gcc -dumpfullversion)"
echo "   glibc  $(ldd --version | head -n1)"
echo "   binutils $(ld --version | head -n1)"
echo "   $(rustc --version)"

echo "== [3/3] stage1-inner: seed toolchain verified — ready for stage2"
