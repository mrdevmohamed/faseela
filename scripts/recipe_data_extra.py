"""Recipe data for the extra/ set (v0.3.0) — 47 packages.
All sha256 values were computed from the exact URLs below at pinning time
(re-run scripts/fill-sha256.py to refresh one).
sub: extra1 = dev+archive tools, extra2 = networking+editors, extra3 = misc+libs+hw.
"""

EXTRA = [

# ───────────────────────── extra1: dev & build tools ─────────────────────────
dict(sub="extra1", name="autoconf", ver="2.72",
     url="https://mirrors.kernel.org/gnu/autoconf/autoconf-%{version}.tar.xz",
     sha="ba885c1319578d6c94d46e9b0dceb4014caafe2490e437a0dbca3f270a223f5a",
     summary="GNU autoconf — produce configure scripts",
     license=["GPL-3.0-or-later"], bdeps=["m4", "perl"], rdeps=["m4", "perl"],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra1", name="automake", ver="1.17",
     url="https://mirrors.kernel.org/gnu/automake/automake-%{version}.tar.xz",
     sha="8920c1fc411e13b90bf704ef9db6f29d540e76d232cb3b2c9f4dc4cc599bd990",
     summary="GNU automake — generate Makefile.in from Makefile.am",
     license=["GPL-2.0-or-later"], bdeps=["autoconf", "perl"], rdeps=["autoconf", "perl"],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra1", name="libtool", ver="2.5.4",
     url="https://mirrors.kernel.org/gnu/libtool/libtool-%{version}.tar.xz",
     sha="f81f5860666b0bc7d84baddefa60d1cb9fa6fceb2398cc3baca6afaa60266675",
     summary="GNU libtool — generic library support script",
     license=["GPL-2.0-or-later", "LGPL-2.1-or-later"], bdeps=[], rdeps=["autoconf", "automake", "m4"],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra1", name="patch", ver="2.7.6",
     url="https://mirrors.kernel.org/gnu/patch/patch-%{version}.tar.xz",
     sha="ac610bda97abe0d9f6b7c963255a11dcb196c25e337c61f94e4778d632f1d8fd",
     summary="GNU patch — apply diffs to files",
     license=["GPL-3.0-or-later"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra1", name="ninja", ver="1.12.1",
     url="https://github.com/ninja-build/ninja/archive/refs/tags/v%{version}.tar.gz",
     sha="821bdff48a3f683bc4bb3b6f0b5fe7b2d647cf65d52aeb63328c91a6c6df285a",
     summary="Ninja — small build system with a focus on speed",
     license=["Apache-2.0"], bdeps=["python"], rdeps=[],
     configure="python3 configure.py --bootstrap",
     install="install -Dm755 ninja %{pkgdir}/usr/bin/ninja"),

dict(sub="extra1", name="meson", ver="1.6.1",
     url="https://github.com/mesonbuild/meson/releases/download/%{version}/meson-%{version}.tar.gz",
     sha="1eca49eb6c26d58bbee67fd3337d8ef557c0804e30a6d16bfdf269db997464de",
     summary="Meson — fast and user friendly build system",
     license=["Apache-2.0"], bdeps=["python"], rdeps=["python", "ninja"],
     comment="# pure-python install: no setup.py in modern meson, stage manually",
     install="""
site=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
install -d "%{pkgdir}$site" "%{pkgdir}/usr/bin"
cp -r mesonbuild "%{pkgdir}$site/"
cat > "%{pkgdir}/usr/bin/meson" <<'EOF'
#!/usr/bin/python3
import sys
from mesonbuild.mesonmain import main
sys.exit(main())
EOF
chmod 755 "%{pkgdir}/usr/bin/meson"
"""),

dict(sub="extra1", name="cmake", ver="3.31.4",
     url="https://github.com/Kitware/CMake/releases/download/v%{version}/cmake-%{version}.tar.gz",
     sha="a6130bfe75f5ba5c73e672e34359f7c0a1931521957e8393a5c2922c8b0f7f25",
     comment="# bundled libs (curl/libuv/...) for a self-contained bootstrap-independent build",
     summary="CMake — cross-platform build system generator",
     license=["BSD-3-Clause"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr --parallel=%{jobs}",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra1", name="lz4", ver="1.10.0",
     url="https://github.com/lz4/lz4/archive/refs/tags/v%{version}.tar.gz",
     sha="537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b",
     summary="LZ4 — extremely fast compression algorithm",
     license=["BSD-2-Clause", "GPL-2.0-or-later"], bdeps=[], rdeps=[],
     configure="make -j%{jobs} PREFIX=/usr",
     install="make PREFIX=/usr DESTDIR=%{pkgdir} install"),

dict(sub="extra1", name="libarchive", ver="3.7.7",
     url="https://github.com/libarchive/libarchive/releases/download/v%{version}/libarchive-%{version}.tar.gz",
     sha="4cc540a3e9a1eebdefa1045d2e4184831100667e6d7d5b315bb1cbc951f8ddff",
     comment="# crypto/expat/xml2 disabled for determinism; zstd/lz4/xz/bz2/zlib from system",
     summary="libarchive — multi-format archive and compression library",
     license=["BSD-2-Clause"], bdeps=["zlib", "bzip2", "xz", "zstd", "lz4"],
     rdeps=["zlib", "bzip2", "xz", "zstd", "lz4"],
     configure="./configure --prefix=/usr --disable-static --without-openssl --without-xml2 --without-expat",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra1", name="zip", ver="3.0",
     url="https://deb.debian.org/debian/pool/main/z/zip/zip_3.0.orig.tar.gz",
     sha="f0e8bb1f9b7eb0b01285495a2699df3a4b766784c1765a8f1aeedf63c0806369",
     sdir="zip30",
     comment="# Info-ZIP zip — Debian .orig tarball (sourceforge unreachable); unix/Makefile build",
     summary="Info-ZIP zip — compressor/archiver for PKZIP archives",
     license=["Info-ZIP"], bdeps=["bzip2"], rdeps=[],
     compile="make -f unix/Makefile -j%{jobs} CC=\"gcc -std=gnu89\" generic",
     install="make -f unix/Makefile prefix=%{pkgdir}/usr MANDIR=%{pkgdir}/usr/share/man/man1 install"),

dict(sub="extra1", name="unzip", ver="6.0",
     url="https://deb.debian.org/debian/pool/main/u/unzip/unzip_6.0.orig.tar.gz",
     sha="036d96991646d0449ed0aa952e4fbe21b476ce994abc276e49d30e686708bd37",
     sdir="unzip60",
     comment="# Info-ZIP unzip — Debian .orig tarball (sourceforge unreachable)",
     summary="Info-ZIP unzip — extractor for PKZIP archives",
     license=["Info-ZIP"], bdeps=["bzip2"], rdeps=[],
     compile="make -f unix/Makefile -j%{jobs} CC=\"gcc -std=gnu89\" generic",
     install="make -f unix/Makefile prefix=%{pkgdir}/usr MANDIR=%{pkgdir}/usr/share/man/man1 install"),

dict(sub="extra1", name="pigz", ver="2.8",
     url="https://github.com/madler/pigz/archive/refs/tags/v%{version}.tar.gz",
     sha="2f7f6a6986996d21cb8658535fff95f1c7107ddce22b5324f4b41890e2904706",
     summary="pigz — parallel implementation of gzip",
     license=["Zlib"], bdeps=["zlib"], rdeps=["zlib"],
     compile="make -j%{jobs}",
     install="""
install -Dm755 pigz %{pkgdir}/usr/bin/pigz
ln -sf pigz %{pkgdir}/usr/bin/unpigz
install -Dm644 pigz.1 %{pkgdir}/usr/share/man/man1/pigz.1
"""),

dict(sub="extra1", name="brotli", ver="1.1.0",
     url="https://github.com/google/brotli/archive/refs/tags/v%{version}.tar.gz",
     sha="e720a6ca29428b803f4ad165371771f5398faba397edf6778837a18599ea13ff",
     summary="Brotli — generic-purpose lossless compression library",
     license=["MIT"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr --disable-static",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra1", name="p7zip", ver="17.05",
     url="https://github.com/p7zip-project/p7zip/archive/refs/tags/v%{version}.tar.gz",
     sha="d2788f892571058c08d27095c22154579dfefb807ebe357d145ab2ddddefb1a6",
     comment="# `all2` builds bin/7z (EXTERNAL_CODECS) but NOT 7za/7zr on 17.05, so build them explicitly",
     summary="p7zip — command line version of 7-Zip for POSIX",
     license=["LGPL-2.1-or-later", "BSD-3-Clause"], bdeps=[], rdeps=[],
     compile="make -j%{jobs} 7za && make -j%{jobs} 7zr",
     install="""
install -d %{pkgdir}/usr/bin %{pkgdir}/usr/share/man/man1
install -m755 bin/7za bin/7zr %{pkgdir}/usr/bin/
install -m644 man1/7z.1 man1/7za.1 man1/7zr.1 %{pkgdir}/usr/share/man/man1/
"""),

# ───────────────────────── extra2: networking & editors ─────────────────────────
dict(sub="extra2", name="openssh", ver="9.9p1",
     url="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-%{version}.tar.gz",
     sha="b343fbcdbff87f15b1986e6e15d6d4fc9a7d36066be6b7fb507087ba8f966c02",
     summary="OpenSSH — Secure Shell client and server",
     license=["BSD-2-Clause", "BSD-3-Clause", "ISC"],
     bdeps=["openssl", "zlib"], rdeps=["openssl", "zlib"],
     prepare="install -m700 -d %{pkgdir}/var/lib/sshd",
     configure="./configure --prefix=/usr --sysconfdir=/etc/ssh --with-privsep-path=/var/lib/sshd",
     compile="make -j%{jobs}",
     install="""
make DESTDIR=%{pkgdir} install
install -m755 contrib/ssh-copy-id %{pkgdir}/usr/bin/
""",
     hook="""
getent group sshd >/dev/null || groupadd -g 50 sshd
id sshd >/dev/null 2>&1 || useradd -c 'sshd PrivSep' -d /var/lib/sshd -g sshd -s /bin/false -u 50 sshd
install -d -m700 /var/lib/sshd
"""),

dict(sub="extra2", name="wget", ver="1.25.0",
     url="https://mirrors.kernel.org/gnu/wget/wget-%{version}.tar.gz",
     sha="766e48423e79359ea31e41db9e5c289675947a7fcf2efdcedb726ac9d0da3784",
     summary="GNU wget — network utility to retrieve files over HTTP(S)/FTP",
     license=["GPL-3.0-or-later"],
     bdeps=["openssl", "zlib", "libidn2", "libunistring", "pcre2", "libpsl"],
     rdeps=["openssl", "zlib", "libidn2", "libunistring", "pcre2", "libpsl"],
     configure="./configure --prefix=/usr --sysconfdir=/etc --with-ssl=openssl",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="rsync", ver="3.4.1",
     url="https://download.samba.org/pub/rsync/src/rsync-%{version}.tar.gz",
     sha="2924bcb3a1ed8b551fc101f740b9f0fe0a202b115027647cf69850d65fd88c52",
     summary="rsync — fast incremental file transfer",
     license=["GPL-3.0-or-later"],
     bdeps=["zstd", "lz4", "openssl", "zlib"], rdeps=["zstd", "lz4", "openssl"],
     configure="./configure --prefix=/usr --without-included-zlib --disable-xxhash",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="libpcap", ver="1.10.5",
     url="https://www.tcpdump.org/release/libpcap-%{version}.tar.gz",
     sha="37ced90a19a302a7f32e458224a00c365c117905c2cd35ac544b6880a81488f0",
     summary="libpcap — packet capture library",
     license=["BSD-3-Clause"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="tcpdump", ver="4.99.5",
     url="https://www.tcpdump.org/release/tcpdump-%{version}.tar.gz",
     sha="8c75856e00addeeadf70dad67c9ff3dd368536b2b8563abf6854d7c764cd3adb",
     summary="tcpdump — dump traffic on a network",
     license=["BSD-3-Clause"], bdeps=["libpcap", "openssl"], rdeps=["libpcap", "openssl"],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="libnftnl", ver="1.2.8",
     url="https://netfilter.org/projects/libnftnl/files/libnftnl-%{version}.tar.xz",
     sha="37fea5d6b5c9b08de7920d298de3cdc942e7ae64b1a3e8b880b2d390ae67ad95",
     summary="libnftnl — netlink library for nftables",
     license=["GPL-2.0-or-later"], bdeps=["libmnl"], rdeps=["libmnl"],
     configure="./configure --prefix=/usr --disable-static",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="iptables", ver="1.8.11",
     url="https://netfilter.org/projects/iptables/files/iptables-%{version}.tar.xz",
     sha="d87303d55ef8c92bcad4dd3f978b26d272013642b029425775f5bad1009fe7b2",
     summary="iptables — administration tool for IPv4/IPv6 packet filtering and NAT",
     license=["GPL-2.0-or-later"], bdeps=["libmnl", "libnftnl"], rdeps=["libmnl", "libnftnl"],
     configure="./configure --prefix=/usr --sysconfdir=/etc",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="nftables", ver="1.1.1",
     url="https://netfilter.org/projects/nftables/files/nftables-%{version}.tar.xz",
     sha="6358830f3a64f31e39b0ad421d7dadcd240b72343ded48d8ef13b8faf204865a",
     summary="nftables — packet filtering and classification (nft)",
     license=["GPL-2.0-or-later"],
     bdeps=["libmnl", "libnftnl", "gmp", "readline"], rdeps=["libmnl", "libnftnl", "gmp", "readline"],
     configure="./configure --prefix=/usr --sysconfdir=/etc --disable-python",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="ethtool", ver="6.11",
     url="https://kernel.org/pub/software/network/ethtool/ethtool-%{version}.tar.xz",
     sha="8d91f5c72ae3f25b7e88d4781279dcb320f71e30058914370b1c574c96b31202",
     summary="ethtool — display or change Ethernet card settings",
     license=["GPL-2.0-or-later"], bdeps=["libmnl"], rdeps=["libmnl"],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="libevent", ver="2.1.12-stable",
     url="https://github.com/libevent/libevent/releases/download/release-%{version}/libevent-%{version}.tar.gz",
     sha="92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb",
     summary="libevent — event notification library",
     license=["BSD-3-Clause"], bdeps=["openssl"], rdeps=["openssl"],
     configure="./configure --prefix=/usr --disable-static",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="vim", ver="9.1.1045",
     url="https://github.com/vim/vim/archive/refs/tags/v%{version}.tar.gz",
     sha="741fcd999bdcecb544fc231adc57bfdde426a008fce1e2586eb0b6be585ebee3",
     summary="Vim — Vi IMproved, a programmer's text editor",
     license=["Vim"], bdeps=["ncurses"], rdeps=["ncurses"],
     configure="./configure --prefix=/usr --with-features=huge --with-x=no --disable-gui",
     compile="make -j%{jobs}",
     install="""
make DESTDIR=%{pkgdir} install
ln -sf vim %{pkgdir}/usr/bin/vi
"""),

dict(sub="extra2", name="nano", ver="8.3",
     url="https://mirrors.kernel.org/gnu/nano/nano-%{version}.tar.gz",
     sha="0f63a784d61d230570f6fb9c86d6c7a98aa8e63ddac82d04bebdf7fc70d010d0",
     summary="GNU nano — small, friendly text editor",
     license=["GPL-3.0-or-later"], bdeps=["ncurses"], rdeps=["ncurses"],
     configure="./configure --prefix=/usr --sysconfdir=/etc",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="tmux", ver="3.5a",
     url="https://github.com/tmux/tmux/releases/download/%{version}/tmux-%{version}.tar.gz",
     sha="16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951",
     summary="tmux — terminal multiplexer",
     license=["ISC"], bdeps=["libevent", "ncurses"], rdeps=["libevent", "ncurses"],
     configure="./configure --prefix=/usr --sysconfdir=/etc",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="htop", ver="3.3.0",
     url="https://github.com/htop-dev/htop/releases/download/%{version}/htop-%{version}.tar.xz",
     sha="a69acf9b42ff592c4861010fce7d8006805f0d6ef0e8ee647a6ee6e59b743d5c",
     summary="htop — interactive process viewer",
     license=["GPL-2.0-or-later"], bdeps=["ncurses"], rdeps=["ncurses"],
     configure="./configure --prefix=/usr --sysconfdir=/etc",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra2", name="screen", ver="5.0.0",
     url="https://mirrors.kernel.org/gnu/screen/screen-%{version}.tar.gz",
     sha="f04a39d00a0e5c7c86a55338808903082ad5df4d73df1a2fd3425976aed94971",
     summary="GNU screen — full-screen window manager multiplexing a terminal",
     license=["GPL-3.0-or-later"], bdeps=["ncurses"], rdeps=["ncurses"],
     configure="./configure --prefix=/usr --sysconfdir=/etc --with-pty-mode=0620 --with-pty-group=5 --with-system_screenrc=/etc/screenrc --disable-pam",
     compile="make -j%{jobs}",
     install="""
make DESTDIR=%{pkgdir} install
install -Dm644 etc/screenrc %{pkgdir}/etc/screenrc
"""),

# ───────────────────────── extra3: misc, libs, hw ─────────────────────────
dict(sub="extra3", name="jq", ver="1.7.1",
     url="https://github.com/jqlang/jq/releases/download/jq-%{version}/jq-%{version}.tar.gz",
     sha="478c9ca129fd2e3443fe27314b455e211e0d8c60bc8ff7df703873deeee580c2",
     summary="jq — lightweight and flexible command-line JSON processor",
     license=["MIT"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="which", ver="2.21",
     url="https://mirrors.kernel.org/gnu/which/which-%{version}.tar.gz",
     sha="f4a245b94124b377d8b49646bf421f9155d36aa7614b6ebf83705d3ffc76eaad",
     summary="GNU which — shows the full path of shell commands",
     license=["GPL-3.0-or-later"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="time", ver="1.9",
     url="https://mirrors.kernel.org/gnu/time/time-%{version}.tar.gz",
     sha="fbacf0c81e62429df3e33bda4cee38756604f18e01d977338e23306a3e3b521e",
     summary="GNU time — run programs and summarize system resource usage",
     license=["GPL-3.0-or-later"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="cpio", ver="2.15",
     url="https://mirrors.kernel.org/gnu/cpio/cpio-%{version}.tar.gz",
     sha="efa50ef983137eefc0a02fdb51509d624b5e3295c980aa127ceee4183455499e",
     summary="GNU cpio — copy file archives in and out",
     license=["GPL-3.0-or-later"], bdeps=[], rdeps=[],
     configure="FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="tree", ver="2.2.1",
     url="https://deb.debian.org/debian/pool/main/t/tree/tree_%{version}.orig.tar.gz",
     sha="68ac45dc78c0c311ada06200ffc3c285e74223ba208061f8d15ffac25e44b2ec",
     comment="# Debian .orig tarball — upstream host unreachable",
     summary="tree — recursive directory listing in a tree view",
     license=["GPL-2.0-or-later"], bdeps=[], rdeps=[],
     compile="make -j%{jobs}",
     install="make prefix=%{pkgdir}/usr MANDIR=%{pkgdir}/usr/share/man install"),

dict(sub="extra3", name="popt", ver="1.19",
     url="https://deb.debian.org/debian/pool/main/p/popt/popt_1.19+dfsg.orig.tar.xz",
     sha="4cd0cd2963d0c4078f65949599d97135c15ee6c09cf3a36a9a1b2753025bb06b",
     comment="# Debian .orig (+dfsg) tarball; directory inside is plain popt-1.19",
     summary="popt — command-line option parsing library",
     license=["MIT"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr --disable-static",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="logrotate", ver="3.22.0",
     url="https://github.com/logrotate/logrotate/releases/download/%{version}/logrotate-%{version}.tar.xz",
     sha="42b4080ee99c9fb6a7d12d8e787637d057a635194e25971997eebbe8d5e57618",
     summary="logrotate — rotates, compresses and mails system logs",
     license=["GPL-2.0-or-later"], bdeps=["popt"], rdeps=["popt"],
     configure="./configure --prefix=/usr --sysconfdir=/etc",
     compile="make -j%{jobs}",
     install="""
make DESTDIR=%{pkgdir} install
install -d %{pkgdir}/etc/logrotate.d %{pkgdir}/var/lib/logrotate
cat > %{pkgdir}/etc/logrotate.conf <<'EOF'
weekly
rotate 4
create
include /etc/logrotate.d
EOF
"""),

dict(sub="extra3", name="cronie", ver="1.7.2",
     url="https://github.com/cronie-crond/cronie/releases/download/cronie-%{version}/cronie-%{version}.tar.gz",
     sha="f1da374a15ba7605cf378347f96bc8b678d3d7c0765269c8242cfe5b0789c571",
     summary="cronie — standard UNIX cron daemon (Vixie fork)",
     license=["GPL-2.0-or-later"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --without-selinux",
     compile="make -j%{jobs}",
     install="""
make DESTDIR=%{pkgdir} install
install -d %{pkgdir}/var/spool/cron
"""),

dict(sub="extra3", name="ca-certificates", ver="2025-02-25",
     url="https://curl.se/ca/cacert-2025-02-25.pem",
     sha="50a6277ec69113f00c5fd45f09e8b97a4b3e32daa35d3a95ab30137a55386cef",
     comment="# Mozilla CA bundle, single-file source (pinned dated snapshot from curl.se)",
     summary="ca-certificates — Mozilla root certificate authorities bundle",
     license=["MPL-2.0"], bdeps=[], rdeps=["openssl"],
     install="""
install -Dm644 cacert-2025-02-25.pem %{pkgdir}/etc/ssl/certs/ca-certificates.crt
ln -sf certs/ca-certificates.crt %{pkgdir}/etc/ssl/cert.pem
"""),

dict(sub="extra3", name="libxml2", ver="2.9.14",
     url="https://deb.debian.org/debian/pool/main/libx/libxml2/libxml2_2.9.14+dfsg.orig.tar.xz",
     sha="4fe913dec8b1ab89d13b489b419a8203176ea39e931eaa0d25b17eafb9c279e9",
     comment="# Debian .orig tarball (gitlab.gnome.org unreachable); dir inside is libxml2-2.9.14",
     summary="libxml2 — XML parsing library",
     license=["MIT"], bdeps=["zlib"], rdeps=["zlib"],
     configure="./configure --prefix=/usr --disable-static --without-python",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="libyaml", ver="0.2.5",
     url="https://pyyaml.org/download/libyaml/yaml-%{version}.tar.gz",
     sha="c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4",
     comment="# upstream tarball directory is yaml-0.2.5",
     summary="libyaml — YAML 1.1 parser and emitter library",
     license=["MIT"], bdeps=[], rdeps=[],
     sdir="yaml-%{version}",
     configure="./configure --prefix=/usr --disable-static",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="dosfstools", ver="4.2",
     url="https://github.com/dosfstools/dosfstools/releases/download/v%{version}/dosfstools-%{version}.tar.gz",
     sha="64926eebf90092dca21b14259a5301b7b98e7b1943e8a201c7d726084809b527",
     summary="dosfstools — utilities for FAT filesystems (mkfs.vfat, fsck.vfat)",
     license=["GPL-3.0-or-later"], bdeps=[], rdeps=[],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="parted", ver="3.6",
     url="https://mirrors.kernel.org/gnu/parted/parted-%{version}.tar.xz",
     sha="3b43dbe33cca0f9a18601ebab56b7852b128ec1a3df3a9b30ccde5e73359e612",
     summary="GNU parted — disk partition table manipulator",
     license=["GPL-3.0-or-later"],
     bdeps=["util-linux", "readline"], rdeps=["util-linux", "readline"],
     configure="./configure --prefix=/usr --disable-static --disable-device-mapper",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="mdadm", ver="4.3",
     url="https://kernel.org/pub/linux/utils/raid/mdadm/mdadm-%{version}.tar.xz",
     sha="416727ae1f1080ea6e3090cea36dd076826fc369151e36ab736557ba92196f9f",
     summary="mdadm — manage MD (software RAID) devices",
     license=["GPL-2.0-or-later"], bdeps=[], rdeps=[],
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} BINDIR=/usr/sbin MANDIR=/usr/share/man UDEVDIR=/usr/lib/udev/rules.d install"),

dict(sub="extra3", name="pciutils", ver="3.13.0",
     url="https://kernel.org/pub/software/utils/pciutils/pciutils-%{version}.tar.xz",
     sha="77f11f78298502634d1af50308f15a5788629f6cf45cba376f5009aea4cb4926",
     summary="pciutils — PCI bus utilities (lspci, setpci)",
     license=["GPL-2.0-or-later"], bdeps=["zlib", "kmod"], rdeps=["zlib", "kmod"],
     compile="make -j%{jobs} SHARED=yes PREFIX=/usr",
     install="make SHARED=yes PREFIX=/usr DESTDIR=%{pkgdir} MANDIR=/usr/share/man install"),

dict(sub="extra3", name="usbutils", ver="017",
     url="https://kernel.org/pub/linux/utils/usb/usbutils/usbutils-%{version}.tar.xz",
     sha="a6a25ffdcf9103e38d7a44732aca17073f4e602b92e4ae55625231a82702e05b",
     summary="usbutils — USB utilities (lsusb)",
     license=["GPL-2.0-or-later"], bdeps=["libusb", "eudev"], rdeps=["libusb", "eudev"],
     configure="./configure --prefix=/usr",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="libusb", ver="1.0.27",
     url="https://github.com/libusb/libusb/releases/download/v%{version}/libusb-%{version}.tar.bz2",
     sha="ffaa41d741a8a3bee244ac8e54a72ea05bf2879663c098c82fc5757853441575",
     summary="libusb — userspace USB library",
     license=["LGPL-2.1-or-later"], bdeps=["eudev"], rdeps=["eudev"],
     configure="./configure --prefix=/usr --disable-static",
     compile="make -j%{jobs}",
     install="make DESTDIR=%{pkgdir} install"),

dict(sub="extra3", name="kbd", ver="2.7.1",
     url="https://kernel.org/pub/linux/utils/kbd/kbd-%{version}.tar.xz",
     sha="f167d899d92b56ccf12f6f49355173f93870a95f15d8aeebf5fdcd28a621aca8",
     comment="# kbd >= 2.7 uses the meson build system",
     summary="kbd — Linux console keymaps, fonts and utilities",
     license=["GPL-2.0-or-later"], bdeps=["meson", "ninja"], rdeps=[],
     configure="meson setup build --prefix=/usr -D vlock=disabled -D tests=false",
     compile="ninja -C build",
     install="DESTDIR=%{pkgdir} meson install -C build"),
]
