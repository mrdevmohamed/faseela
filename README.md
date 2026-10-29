# mydistro

A from-scratch, source-based Linux distribution (Gentoo-style) built around its own
package manager written in Rust.

The package manager, **nawa**, lives in its own repository
([mrdevmohamed/nawa](https://github.com/mrdevmohamed/nawa)) and is pulled in
here as a git submodule at `nawa/`. This repository holds everything else:

```
mydistro/
├── nawa/        git submodule → github.com/mrdevmohamed/nawa (package manager, Rust)
├── recipes/     Source recipes for every package in the distribution
├── bootstrap/   Stage 0-4 scripts that build the distribution from nothing
└── profiles/    Per-architecture build profiles (CFLAGS, toolchain choices)
```

Clone with `git clone --recurse-submodules` (or run
`git submodule update --init` afterwards): stage 2 compiles nawa from
`nawa/` with the seed's rustc.

## Design decisions (locked in)

| Decision        | Choice                                        |
|-----------------|-----------------------------------------------|
| Language (PM)   | Rust                                          |
| Model           | Source-based (Gentoo-style), binary cache     |
| libc            | glibc                                         |
| Init system     | runit                                         |
| Compiler        | gcc                                           |
| Recipe format   | Declarative TOML with shell build sections    |
| Package archive | `.nawa.tar.zst` (payload + .PKGINFO + file list) |
| Local database  | Plain text files under `/var/lib/nawa/local/`  |

## CI / CD (GitHub Actions)

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `.github/workflows/ci.yml` | push, pull request | shell syntax + ShellCheck, recipe validation, the `build-all.sh` mock tests and a dry run |
| `.github/workflows/release.yml` | tag `v*`, or *Run workflow* | runs CI, then builds the whole distribution (`build-all.sh`) and uploads the ISO **and the rootfs** (`mydistro-x86_64-rootfs.tar.zst`) + sha256 files as artifacts; on a tag it also creates a GitHub Release. The rootfs of the previous release is the **seed of the build** (self-hosting; Debian seed only for the first release or with `seed: debian`) |

A full source build takes hours. GitHub-hosted runners stop after 6 h, so for
a complete ISO set the repository variable `ISO_RUNNER` (Settings > Variables)
to the label of a self-hosted Linux runner with sudo and >= 30 GB free disk.
Release assets are limited to 2 GiB; a bigger ISO or rootfs stays as the workflow artifact
(and a release without the rootfs cannot seed the next build).

## nawa — the package manager

nawa is developed in its own repository,
[github.com/mrdevmohamed/nawa](https://github.com/mrdevmohamed/nawa); its
README documents every command, `nawa.toml`, signing/trust, build isolation,
atomic upgrades and rollback, remote repositories and runit service
management. Not repeated here. Quick reference for this distribution:

```
nawa install <name>...     # build + install packages and their dependencies
nawa upgrade --repo <url>  # upgrade from a signed repository
nawa rollback <name>       # restore the previous version
nawa --recipes recipes deps-all   # full recipe graph in build order
```

The distro-specific parts:

* `recipes/base/nawa` builds nawa itself from the `nawa/` submodule
  (`source = "local:nawa"`, offline from its vendored crates, with the
  distro's own `rust` package).
* Package archives are `*.nawa.tar.zst`; the database is `/var/lib/nawa/`.
* Build profiles are `profiles/<arch>.toml`; the build-isolation design is
  `nawa/docs/build-isolation.md`.

## Recipe format (example)

```toml
[package]
name    = "gzip"
version = "1.13"
rel     = 1
arch    = ["x86_64"]
summary = "GNU compression utility"
license = ["GPL-3.0"]
source  = "https://ftp.gnu.org/gnu/gzip/gzip-%{version}.tar.xz"
sha256  = "..."

[depends]
build = ["zstd"]     # recipe-level build deps (seed tools are implicit)
run   = []

[build]
configure = "./configure --prefix=/usr"
compile   = "make -j%{jobs}"
install   = "make DESTDIR=%{pkgdir} install"

[hooks]
post_install = ""    # runs after install (also used after upgrade)
pre_remove   = ""    # runs before `nawa remove`
post_remove  = ""    # runs after `nawa remove`
# hooks are stored in the archive (.HOOKS); they run on the live system, or in a
# chroot of --root when nawa runs as root and the target has /bin/sh; else skipped
```

Placeholders available in build sections: `%{name} %{version} %{rel} %{arch}
%{jobs} %{pkgdir} %{srcdir}`.

## Bootstrap pipeline (build the whole distro from nothing)

`bootstrap/build-all.sh` is the one-command driver for the pipeline below:

```bash
sudo bootstrap/build-all.sh /mnt/mydistro      # seed + stages 1-3 + ISO
sudo bootstrap/build-all.sh --isolation closure --stage3-world /mnt/mydistro
bootstrap/build-all.sh --list-stages /mnt/mydistro   # progress + resume
```

It stamps each finished stage together with a fingerprint of that stage's
inputs (scripts, recipes, profiles, effective options — state kept outside
the target), logs every run (with an audit header: host, tool versions,
seed identity, commit), runs pre-flight checks (root, disk space, host
tools) before starting, holds an exclusive lock per target, and after a
failure re-running the same command resumes from the broken stage. A stamp
whose recorded inputs no longer match (option change, recipe edit, script
edit) is invalidated together with everything downstream — resume never
silently reuses a stale result. See `bootstrap/README.md` for the full
option list, the stage contracts and the seed trust boundary.

| Stage      | Script                      | What it does                                        |
|------------|-----------------------------|-----------------------------------------------------|
| 0 — Seed   | `bootstrap/seed/build-seed.sh` | Assemble a prebuilt toolchain tarball (Debian .debs + rustup rustc — the bootstrap is NOT source-only), with a content manifest + sha256 sidecar |
| 1 — Chroot | `bootstrap/stage1.sh`       | verify the seed (zstd + sha256), unpack, chroot; seed toolchain verified (it IS the temporary toolchain) |
| 2 — Core   | `bootstrap/stage2.sh`       | Build & install core system with nawa from recipes (into the build root and the clean final root) |
| 3 — Self   | `bootstrap/stage3.sh`       | Rebuild the toolchain (or world) with the distro's own toolchain, remove the seed, PROVE self-hosting (compile+run test, db ownership, ELF /opt scan) |
| 4 — Rootfs | `bootstrap/mkrootfs.sh`     | final root → `mydistro-x86_64-rootfs.tar.zst` (+ `.sha256`, `.packages`), validated; published with the ISO and used as the seed of the next build (`build-all.sh --seed-rootfs`, `bootstrap/seed-from-rootfs.sh`) |
| 5 — ISO    | `bootstrap/mkiso.sh`        | squashfs + initramfs + grub → hybrid ISO, structurally validated (boot-critical members verified IN the image) |
| 6 — Disk   | `bootstrap/install.sh`      | run in the live system: partition, copy, grub → installed disk |

See `bootstrap/README.md` for details and host requirements.

## Status / roadmap

- [x] Project skeleton
- [x] nawa v0.1: recipe parser, version compare, local DB, dependency resolver,
      build engine, archive (tar.zst), install/remove/query, repo index
- [x] Build isolation (nawa/docs/build-isolation.md — **all phases**): env
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
- [x] nawa v0.7 UX overhaul: `nawa.toml` config file + `NAWA_*` env vars,
      global flags anywhere on the line, `search`/`info`/`why`/`list`,
      `build --install` in one step, `remove`/`upgrade` confirmations with
      `--yes` for scripts, smart terminal colors (plain when piped),
      did-you-mean suggestions for typos, shell completions (bash/zsh/fish)
- [ ] initramfs: LVM/LUKS (needs cryptsetup/lvm2 recipes — stretch)
- [ ] Remote repo mirrors list / repo priority

Every recipe outside `recipes/gui` carries a sha256 computed from the actual
upstream tarball (no copied-and-pasted hashes). The 32 GUI recipes ship a
zero placeholder instead and fail loudly at source verification until
`scripts/fill-sha256.py` pins them — an unpinned source is never silently
built. Full graph sanity check: `nawa --recipes recipes deps-all` — all 148
packages resolve in topological order (base-files #5, runit-services right
after runit).

## Booting the ISO

```
grub (BIOS+UEFI)
  └─ kernel + initramfs (static busybox)
       └─ /init: root=UUID=<disk> ?  ── yes → mount disk → switch_root
                 │                        → /usr/bin/runit (installed system)
                 └─ no: load storage modules → find MYDISTRO media
                         → mount /live/rootfs.squashfs
                         → overlayfs with tmpfs upper
                         → switch_root → /usr/bin/runit (live system,
                           boot media stays at /cdrom)
                              └─ /etc/runit/1 → runsvdir (getty, udevd,
                                 dhcpcd, sysklogd, crond) → login on tty1-4

live session → sudo install.sh /dev/vda → reboots into the installed disk
```

## Installing to disk (from the live system)

```
# boot the ISO, log in as root, then:
install.sh /dev/vda --hostname mybox
# review the plan, type the disk name to confirm, set the root password,
# reboot without the media
```

The installer supports both UEFI (GPT + ESP, removable grub) and BIOS
(MBR), copies the live system with rsync, generates fstab from real
UUIDs, and writes a static grub.cfg whose `root=UUID=` cmdline makes the
initramfs boot straight off the disk.
