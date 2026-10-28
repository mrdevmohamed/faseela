# mydistro

A from-scratch, source-based Linux distribution (Gentoo-style) built around its own
package manager written in Rust.

This repository is a single monorepo with three cooperating components:

```
mydistro/
├── pkgmgr/      DPM — the package manager (Rust)
├── recipes/     Source recipes for every package in the distribution
├── bootstrap/   Stage 0-4 scripts that build the distribution from nothing
└── profiles/    Per-architecture build profiles (CFLAGS, toolchain choices)
```

## Design decisions (locked in)

| Decision        | Choice                                        |
|-----------------|-----------------------------------------------|
| Language (PM)   | Rust                                          |
| Model           | Source-based (Gentoo-style), binary cache     |
| libc            | glibc                                         |
| Init system     | runit                                         |
| Compiler        | gcc                                           |
| Recipe format   | Declarative TOML with shell build sections    |
| Package archive | `.dpm.tar.zst` (payload + .PKGINFO + file list) |
| Local database  | Plain text files under `/var/lib/dpm/local/`  |

## CI / CD (GitHub Actions)

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `.github/workflows/ci.yml` | push, pull request | `cargo build`, `clippy -D warnings`, `cargo test`; shell syntax + ShellCheck, recipe validation, the `build-all.sh` mock tests and a dry run |
| `.github/workflows/release.yml` | tag `v*`, or *Run workflow* | runs CI, then builds the whole distribution (`build-all.sh`) and uploads the ISO **and the rootfs** (`mydistro-x86_64-rootfs.tar.zst`) + sha256 files as artifacts; on a tag it also creates a GitHub Release. The rootfs of the previous release is the **seed of the build** (self-hosting; Debian seed only for the first release or with `seed: debian`) |

A full source build takes hours. GitHub-hosted runners stop after 6 h, so for
a complete ISO set the repository variable `ISO_RUNNER` (Settings > Variables)
to the label of a self-hosted Linux runner with sudo and >= 30 GB free disk.
Release assets are limited to 2 GiB; a bigger ISO or rootfs stays as the workflow artifact
(and a release without the rootfs cannot seed the next build).

## DPM — the package manager

```
cd pkgmgr
cargo build --release
cargo test
```

Commands (global flags work anywhere on the line — see the config section
below for making them unnecessary):

```
dpm install <name>...                          # build + install packages AND all missing dependencies
dpm install -n <name>                          # show that plan, change nothing (--dry-run)
dpm outdated                                   # installed packages whose recipe is newer
dpm update [name...]                           # rebuild + reinstall the outdated ones
dpm autoremove                                 # remove dependency packages nothing needs
dpm build --install <name>                     # build ONE recipe and install it (no dependency handling)
dpm install <archive.dpm.tar.zst>              # install a built archive into --root
dpm search <term>                              # find recipes by name/summary (--glob for patterns)
dpm info <name>                                # everything known about a package
dpm why <name>                                 # who depends on it (--tree also scans recipes)
dpm deps <name>                                # show dependency order
dpm list [pattern] [-e|-d]                    # installed packages; -e explicit only, -d dependencies only
dpm files <name>                               # files owned by package
dpm owner /usr/bin/foo                         # which package owns file
dpm remove --yes <name>                        # remove package (--yes skips the confirmation)
dpm repo-create <dir-of-archives> --out index.toml --sign  # signed repo index
dpm upgrade --yes --repo <dir-or-url>          # upgrade from a repo (repo also comes from dpm.toml)
dpm rollback <name>                            # restore previous version
dpm service list                               # runit services
dpm config show                                # effective config + where each value came from
dpm init                                       # write a commented dpm.toml template
dpm completions bash|zsh|fish                  # shell completion scripts
```

Any command accepts `--root` so everything can be tested safely against a
throwaway directory instead of `/`.

### Installing by name

```
dpm install curl          # shows the plan, asks, then builds + installs
```

`dpm install <name>` resolves `depends.build` **and** `depends.run`
transitively, skips whatever is already installed, and prints the order
before touching anything:

```
dpm: 3 package(s) to build and install into /:
    1. zlib                   1.3.1-1       dependency
    2. openssl                3.3.1-1       dependency
    3. curl                   8.9.1-1       explicit
```

Then each step is built and installed in turn (`[2/3] building ...`), the db
lock is held only around each install, and a failure in the middle says how
many packages already landed — re-running the same command continues, because
installed packages are skipped. Packages you named are recorded as `explicit`,
everything pulled in as `dependency`.

* `-n/--dry-run` prints the plan and stops; `-y/--yes` is required when stdin
  is not a terminal (same contract as `remove` and `upgrade`)
* `--no-deps` builds only the named packages
* `--isolation`, `--use-cache`, `--allow-degraded`, `--force`,
  `--allow-unsigned` work as for `dpm build` / `dpm install <archive>`
* a bare word is a package name; anything ending in `.dpm.tar.zst` or
  containing a `/` is an archive path (the two cannot be mixed in one call)

`dpm outdated` lists installed packages whose recipe has a newer
`version-rel`; `dpm update` plans and rebuilds exactly those (plus any missing
dependency they gained), keeping each package's explicit/dependency reason.
`dpm autoremove` removes `dependency` packages that no explicit package needs
any more, dependents first. Build-only dependencies of packages you keep
(compilers, headers) are **kept** unless you pass `--build-deps`, since the next
rebuild needs them.

### Configuration (dpm.toml)

dpm reads the nearest `dpm.toml` at or above the current directory (like git;
`DPM_CONFIG` names one directly) and merges it **under** the command-line
flags:

```toml
root      = "/"                                  # env: DPM_ROOT
recipes   = "recipes"                            # env: DPM_RECIPES
builddir  = "build"                              # env: DPM_BUILDDIR
profiles  = "profiles"                           # env: DPM_PROFILES
jobs      = 8                                    # env: DPM_JOBS
repo      = "https://mirror.example.com/stable"  # env: DPM_REPO — default for `dpm upgrade`
```

Precedence per key: **flag > env var > dpm.toml > default**. Relative paths
inside the file resolve against the file's own directory, so the config means
the same thing from any subdirectory. `dpm init` writes a commented template;
`dpm config show` prints the effective values annotated with where each one
came from.

### Confirmations, colors, suggestions

* `remove` and `upgrade` print exactly what they are about to do and ask
  `y/N`. Non-interactive runs (scripts, CI) must pass `--yes`; without it a
  piped stdin is **refused** rather than guessed at. `install` never asks —
  the bootstrap depends on it.
* Output is colored only on a real terminal; pipes and scripts get plain,
  byte-identical text. `NO_COLOR` disables colors, `DPM_COLOR=always|never|auto`
  overrides the detection.
* Mistyped package names get suggestions built from the recipe graph:
  `dpm build gzp` → *did you mean `gmp` or `gzip` or `gcc`?*

### Shell completions

```
dpm completions bash | sudo tee /etc/bash_completion.d/dpm   # then restart the shell
dpm completions zsh > "${fpath[1]}/_dpm"                     # zsh
dpm completions fish > ~/.config/fish/completions/dpm.fish   # fish
```

Package names complete dynamically — the scripts shell out to
`dpm __complete_pkgs`, which lists every recipe plus every installed package.

### Database locking

Every command that touches `<root>/var/lib/dpm` takes an `flock(2)` lock on
`<root>/var/lib/dpm/lock`: `install`, `remove`, `rollback` and `upgrade`
exclusively (held for the whole command, hooks included); `query`, `list`,
`files`, `owner`, `info`, `why`, `deps`, `deps-all` and `upgrade --dry-run`
shared, so readers never see a half-applied transaction and don't block each
other (`build --install` locks around the install step only, never through
the build itself). A second dpm waits
and prints who holds the lock; `DPM_LOCK_TIMEOUT=<seconds>` makes it give up
instead. The kernel releases the lock when the holder exits for any reason, so
there are no stale lock files to clean up. Package hooks get `DPM_LOCK_HELD=1`
so a hook that calls dpm does not wait on its own parent.

### Build profiles

`profiles/<arch>.toml` (selected by the recipe's first `arch`) sets the flags
every package is compiled with. The build engine exports them to all build
sections as `CFLAGS`, `CXXFLAGS` and `LDFLAGS` (empty values are not exported)
and uses the profile's `jobs` as the default job count:

```
--jobs N                  # highest priority
profile `jobs`            # next
number of CPUs            # fallback
```

A missing profile is fine (toolchain defaults); flags already present in dpm's
own environment win over the profile (`CFLAGS=-O3 dpm build foo`). `--profiles
<dir>` selects another directory (default `profiles`; the bootstrap stages pass
it explicitly).

Build output is streamed to the console as it is produced and also saved to
`<builddir>/<pkg>-<ver>-<rel>/build-<section>.log` (stdout and stderr merged,
in real order).

### Build isolation

`dpm build --isolation <level>` (or the profile's `[build] isolation`; default
`none`) controls what a build can see and do — see
`docs/design/build-isolation.md` for the full rationale:

| level | the build gets |
|-------|----------------|
| `none` | today's behaviour (dpm's environment, live filesystem) |
| `env` | only the whitelisted environment (LC_ALL=C, TZ=UTC, umask 022, ...), `SOURCE_DATE_EPOCH`, byte-reproducible archives; `--rebuild-check` verifies exactly that |
| `sandbox` | + user/mount/pid/net/ipc/uts namespaces: read-only root, private `/tmp` `/dev` `/proc`, no network, fake-root identity, per-section timeout |
| `closure` | + a build root assembled from built archives only (`base-devel` + the declared `depends.build`), so a missing declaration fails the build |

A post-build lint runs from `env` up: it warns about `DT_NEEDED` libraries
missing from `depends.run` and errors on leaked build paths or bad layout.
`dpm sandbox-probe` (hidden) tells you what this kernel allows; restricted
environments need `--allow-degraded` (loudly, never silently weaker).

On top of that:

- **Layer cache**: closure archives are extracted once into a content-addressed
  layer cache (`DPM_LAYER_CACHE`, default `<root>/var/cache/dpm/layers`) and
  the build root is an overlayfs over them (kernel ≥ 5.11; older kernels
  automatically fall back to extract-per-build).
- **`--use-cache`**: skip a build whose `build_id` (recipe + source sha256 +
  closure + profile flags) matches the recorded one.
- **Rootless**: `dpm build` up to `closure` works as a normal user — no root
  required at build time.

### Signing & trust (dpm-sig-v1)

Packages and repo indexes are signed with ed25519. The signed message is
`dpm-v1:sha256:<hash>`, so one verification covers both integrity and
authenticity. Signatures live in detached `<file>.sig` sidecars.

```
dpm keygen --out /etc/dpm/keys              # dpm.sec (0600) + dpm.pub
dpm sign <archive-or-index> --key dpm.sec   # writes <file>.sig
dpm --root / trust /etc/dpm/keys/dpm.pub    # copy key into the trust store
dpm verify <file>                           # trust store, else embedded key
```

Verification policy (`dpm install` / `dpm upgrade`):

| Trust store | Signature      | Result                                             |
|-------------|----------------|----------------------------------------------------|
| configured  | valid          | install                                            |
| configured  | missing        | refuse (`--allow-unsigned` overrides)              |
| configured  | bad / rogue    | refuse — always                                    |
| empty       | present        | verify against embedded key + loud warning         |
| empty       | missing        | pass (bootstrap mode)                              |

Remote repositories (`upgrade --repo http(s)://…`) are stricter: with an empty
trust store dpm refuses them outright (before any network access) unless
`--allow-unsigned` is passed, because bootstrap mode and embedded-key checks
cannot authenticate a mirror. Add the distribution key first:
`dpm --root / trust /path/to/dpm.pub`.

### Atomic upgrades & rollback

* every install stages into a hidden dir, conflict-checks against the db,
  then renames into place through an undo journal: files it replaces are
  first moved to `.dpm/bak-*`, and if any move fails everything is restored
  (all-or-nothing file placement); db writes are temp-file + rename
* replaced versions leave an undo record (`/var/lib/dpm/undo/<name>`) and
  their archive in the package cache (`/var/cache/dpm`) — `dpm rollback <name>`
  walks one step back, and keeps ping-ponging as long as there is history
* `dpm upgrade --repo <dir>`: verifies the index signature, checks sha256,
  resolves order through the recipe graph, then applies
* pacman-style config protection: `/etc` files are hashed at install time
  (`<pkg>/hashes` in the db). Untouched configs upgrade in place; locally
  modified ones are preserved and the new version lands next to them as
  `<path>.dpm-new`
* files dropped between versions are removed; obsolete-file deletion only
  touches paths the package still owns

### Remote repositories (http/https)

`dpm upgrade --repo` accepts a local directory **or** an http(s) URL:

```
dpm --root / upgrade --repo https://mirror.example.com/mydistro/stable
```

* the index (`index.toml` + optional `index.toml.sig`) is fetched fresh on
  every run; if the mirror is unreachable, the cached copy is used with a
  warning (so upgrades still run offline once a mirror was seen)
* the index signature goes through the same trust policy as local repos
* archives are downloaded on demand into a stable per-URL cache under
  `/var/cache/dpm/remote/<key>/`, sha256-checked against the index on every
  reuse (a corrupted cache entry is transparently re-downloaded)
* archive paths recorded in the index are validated — no `/`, no `..`, no
  dotfiles — so a compromised index cannot write outside the cache
* packages without a recipe in the local tree (third-party repo content)
  are applied in alphabetical order after the graph-ordered ones

### Service management (runit)

```
dpm service list                 # /etc/sv tree + enabled state
dpm service enable sshd          # link into /etc/runit/runsvdir/default
dpm service disable dhcpcd       # remove the link (runsvdir stops it live)
dpm service status [name]        # static state + live `sv status` when supervised
```

A service is *available* when `/etc/sv/<name>/run` exists and *enabled* when
`/etc/runit/runsvdir/default/<name>` links to it — runsvdir rescans that
directory every few seconds, so enable/disable take effect without a
supervisor restart. `disable` refuses to remove anything that is not a
symlink, and `enable` refuses services without a run script.

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
pre_remove   = ""    # runs before `dpm remove`
post_remove  = ""    # runs after `dpm remove`
# hooks are stored in the archive (.HOOKS); they run on the live system, or in a
# chroot of --root when dpm runs as root and the target has /bin/sh; else skipped
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
| 2 — Core   | `bootstrap/stage2.sh`       | Build & install core system with DPM from recipes (into the build root and the clean final root) |
| 3 — Self   | `bootstrap/stage3.sh`       | Rebuild the toolchain (or world) with the distro's own toolchain, remove the seed, PROVE self-hosting (compile+run test, db ownership, ELF /opt scan) |
| 4 — Rootfs | `bootstrap/mkrootfs.sh`     | final root → `mydistro-x86_64-rootfs.tar.zst` (+ `.sha256`, `.packages`), validated; published with the ISO and used as the seed of the next build (`build-all.sh --seed-rootfs`, `bootstrap/seed-from-rootfs.sh`) |
| 5 — ISO    | `bootstrap/mkiso.sh`        | squashfs + initramfs + grub → hybrid ISO, structurally validated (boot-critical members verified IN the image) |
| 6 — Disk   | `bootstrap/install.sh`      | run in the live system: partition, copy, grub → installed disk |

See `bootstrap/README.md` for details and host requirements.

## Status / roadmap

- [x] Project skeleton
- [x] DPM v0.1: recipe parser, version compare, local DB, dependency resolver,
      build engine, archive (tar.zst), install/remove/query, repo index
- [x] Build isolation (docs/design/build-isolation.md — **all phases**): env
      whitelist + reproducible archives (`--rebuild-check`), the dpm-owned
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
- [x] Base recipes (39): zlib, bzip2, file, ncurses, readline, pcre2, libffi,
      expat, gdbm, gperf, coreutils, bash, tar, gzip, xz, zstd, grep, gawk,
      sed, flex, bison, bc, diffutils, findutils, gettext, texinfo,
      util-linux, perl, python, openssl, sqlite, libunistring, libidn2, less,
      dpm (self-hosting build), rust (vendored crates), elfutils, base-files,
      base-devel (the `closure` build-toolchain meta package)
- [x] System recipes (19): libpsl, curl, git, shadow, procps-ng, psmisc,
      eudev, kmod, e2fsprogs, libpipeline, groff, man-db, libmnl, iproute2,
      dhcpcd, sysklogd, runit, runit-services, libxcrypt
- [x] Boot recipes (3): linux (6.10 defconfig), grub, busybox
- [x] Extra recipes (47): dev/build (autoconf, automake, libtool, patch,
      ninja, meson, cmake, lz4, libarchive, zip, unzip, pigz, brotli,
      p7zip), net/editors (openssh, wget, rsync, libpcap, tcpdump,
      libnftnl, iptables, nftables, ethtool, libevent, vim, nano, tmux,
      htop, screen), misc/libs/hw (jq, which, time, cpio, tree, popt,
      logrotate, cronie, ca-certificates, libxml2, libyaml, dosfstools,
      parted, mdadm, pciutils, usbutils, libusb, kbd)
- [x] `dpm deps-all` — full-graph topological order (stage2 consumes it;
      `--include-installed` also lists packages the db already records, for
      stage3 world rebuilds)
- [x] Single-file source support (pinned Mozilla CA bundle via curl.se)
- [x] base-files recipe — FHS skeleton, merged-usr symlinks, /etc population
- [x] runit-services recipe — /etc/runit stages + supervised services
- [x] Live-boot initramfs (static busybox, squashfs + overlayfs, runit)
- [x] Stage 4 — real hybrid ISO: squashfs + grub (BIOS+UEFI)
- [x] Package signing (ed25519): keygen / sign / verify / trust store,
      signed repo indexes, progressive trust policy
- [x] Atomic upgrades (`dpm upgrade`), rollback (`dpm rollback`),
      `.dpm-new` config protection with hash baselines
- [x] Disk installer (`bootstrap/install.sh`): UEFI + BIOS paths,
      UUID fstab, static grub.cfg, root=UUID disk boot in the initramfs
- [x] Remote repos: `dpm upgrade --repo https://…` with signature checks,
      per-URL archive cache and offline fallback
- [x] `dpm service` — runit enable/disable/list/status UX
- [x] initramfs: USB3/HID (USB keyboards), virtio, and filesystem modules
      staged for live boot
- [x] DPM v0.7 UX overhaul: `dpm.toml` config file + `DPM_*` env vars,
      global flags anywhere on the line, `search`/`info`/`why`/`list`,
      `build --install` in one step, `remove`/`upgrade` confirmations with
      `--yes` for scripts, smart terminal colors (plain when piped),
      did-you-mean suggestions for typos, shell completions (bash/zsh/fish)
- [ ] initramfs: LVM/LUKS (needs cryptsetup/lvm2 recipes — stretch)
- [ ] Remote repo mirrors list / repo priority

Every recipe carries a sha256 computed from the actual upstream tarball (no
copied-and-pasted hashes; `scripts/fill-sha256.py` pins one, and a recipe
whose source is still unpinned fails loudly at source verification instead of
being built silently). Full graph sanity check: `dpm --recipes recipes
deps-all` — all 152 packages resolve in topological order (base-files #5,
runit-services right after runit), and `python3 scripts/check-recipes.py`
re-checks the whole tree (names, deps, cycles, hashes, required fields)
offline.

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
