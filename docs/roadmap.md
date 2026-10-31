# Status / roadmap

- [x] Project skeleton
- [x] NAWA v0.1: recipe parser, version compare, local DB, dependency resolver,
      build engine, archive (tar.zst), install/remove/query, repo index
- [x] Build isolation (docs/design/build-isolation.md — **all phases**): env
      whitelist + reproducible archives (`--rebuild-check`), the nawa-owned
      namespace sandbox (`--isolation sandbox`), archive-assembled build roots
      (`--isolation closure`, `base-devel` meta package), post-build ELF lint,
      the overlayfs layer cache with extract-per-build fallback (Phase 5) and
      rootless builds as a normal user (Phase 7)
- [x] Toolchain recipes (linux-headers, glibc, binutils, m4, gmp,
      mpfr, mpc, gcc, make, pkgconf)
- [x] Bootstrap scripts (seed / stage1 / stage2 / stage3 / mkiso)
- [x] One-command pipeline driver (`bootstrap/build-all.sh`): input-tracked
      stamp resume (option/recipe/script changes invalidate exactly the
      affected stages and downstream), per-run logs with audit headers,
      pre-flight checks, exclusive per-target lock, failure markers,
      `--dry-run`/`--from-stage`/`--fresh`/`--wipe` (with protected-path
      refusals)/`--no-iso`
- [x] Base recipes (35): zlib, bzip2, file, ncurses, readline, pcre2, libffi,
      expat, gdbm, gperf, coreutils, bash, tar, gzip, xz, zstd, grep, gawk,
      sed, flex, bison, bc, diffutils, findutils, gettext, texinfo,
      util-linux, perl, python, openssl, sqlite, libunistring, libidn2, less,
      nawa (self-hosting build)
- [x] System recipes (17): libpsl, curl, git, shadow, procps-ng, psmisc,
      eudev, kmod, e2fsprogs, libpipeline, groff, man-db, libmnl, iproute2,
      dhcpcd, sysklogd, runit
- [x] Boot recipes (3): linux (6.10 defconfig), grub, busybox
- [x] Extra recipes (47): dev/build (autoconf, automake, libtool, patch,
      ninja, meson, cmake, lz4, libarchive, zip, unzip, pigz, brotli,
      p7zip), net/editors (openssh, wget, rsync, libpcap, tcpdump,
      libnftnl, iptables, nftables, ethtool, libevent, vim, nano, tmux,
      htop, screen), misc/libs/hw (jq, which, time, cpio, tree, popt,
      logrotate, cronie, ca-certificates, libxml2, libyaml, dosfstools,
      parted, mdadm, pciutils, usbutils, libusb, kbd)
- [x] `nawa deps-all` — full-graph topological order (stage2 consumes it;
      `--include-installed` also lists packages the db already records, for
      stage3 world rebuilds)
- [x] Single-file source support (pinned Mozilla CA bundle via curl.se)
- [x] base-files recipe — FHS skeleton, merged-usr symlinks, /etc population
- [x] runit-services recipe — /etc/runit stages + supervised services
- [x] Live-boot initramfs (static busybox, squashfs + overlayfs, runit)
- [x] Stage 4 — real hybrid ISO: squashfs + grub (BIOS+UEFI)
- [x] Package signing (ed25519): keygen / sign / verify / trust store,
      signed repo indexes, progressive trust policy
- [x] Atomic upgrades (`nawa upgrade`), rollback (`nawa rollback`),
      `.nawa-new` config protection with hash baselines
- [x] Disk installer (`bootstrap/install.sh`): UEFI + BIOS paths,
      UUID fstab, static grub.cfg, root=UUID disk boot in the initramfs
- [x] Remote repos: `nawa upgrade --repo https://…` with signature checks,
      per-URL archive cache and offline fallback
- [x] Native fetch/extract in nawa: HTTP through `ureq` (rustls, bundled
      roots, https-only redirects, retries), source tarballs unpacked by the
      tar crate with in-process gzip/xz/bzip2/zstd decoders, pure-Rust
      `cp -a` for `local:` sources, `chroot(2)` hooks — nawa needs no
      external curl/tar/cp/chroot binaries
- [x] `nawa service` — runit enable/disable/list/status UX
- [x] initramfs: USB3/HID (USB keyboards), virtio, and filesystem modules
      staged for live boot
- [x] NAWA v0.7 UX overhaul: `nawa.toml` config file + `NAWA_*` env vars,
      global flags anywhere on the line, `search`/`info`/`why`/`list`,
      `build --install` in one step, `remove`/`upgrade` confirmations with
      `--yes` for scripts, smart terminal colors (plain when piped),
      did-you-mean suggestions for typos, shell completions (bash/zsh/fish)
- [ ] initramfs: LVM/LUKS (needs cryptsetup/lvm2 recipes — stretch)
- [ ] Remote repo mirrors list / repo priority

Every recipe outside `recipes/gui` carries a sha256 computed from the actual
upstream tarball (no copied-and-pasted hashes). The 32 GUI recipes ship a
zero placeholder instead and fail loudly at source verification until
`scripts/fill-sha256.py` (in faseela-repo) pins them — an unpinned source is never silently
built. Full graph sanity check: `nawa --recipes recipes deps-all` — all 148
packages resolve in topological order (base-files #5, runit-services right
after runit).
