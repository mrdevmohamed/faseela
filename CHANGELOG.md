# Changelog

## Unreleased — the package manager moves out: dpm → nawa

- The package manager is no longer part of this repository. It lives in
  github.com/mrdevmohamed/nawa (1.0.0) and is checked out as the git submodule
  `nawa/` (`git clone --recurse-submodules`, or `git submodule update --init`).
  `pkgmgr/` is gone, together with the scripts and design note that moved with
  it (`vendor-dpm.sh`, `smoke-v05/v06.sh`, `test-isolation-matrix.sh`,
  `ci-no-skips.sh`, `spike-sandbox.sh`, `docs/design/build-isolation.md`).
- New recipe `recipes/base/nawa` (replaces `recipes/base/dpm`): `local:nawa`,
  version 1.0.0, built offline with the distro's `rust`.
- stage 2 compiles the bootstrap nawa from `nawa/`; stage 2/3, `final-root.sh`,
  `mkrootfs*.sh`, `seed-from-rootfs.sh`, `install.sh`, `sync-repo.sh` and the
  workflows use the new names everywhere.
- **Breaking, renamed with the binary**: `/usr/bin/nawa`, database
  `/var/lib/nawa`, cache `/var/cache/nawa`, archives `*.nawa.tar.zst`, config
  `nawa.toml`, env `NAWA_*` (was `DPM_*`), signing keys `nawa.sec`/`nawa.pub`,
  CI secret `NAWA_SIGN_KEY_B64` (was `DPM_SIGN_KEY_B64`), `/etc/*.nawa-new`.
  A system installed with dpm has to be rebuilt; its old db is not migrated.
- CI keeps only the `scripts` job; nawa's own tests/isolation matrix/smoke
  tests run in the nawa repository.

## Unreleased — fix: stage3 closure rebuild died at bc ("readline works only with flex")

- First real `--isolation closure` run (after the pre-flight fix the build now
  gets past stages 0-2 and the sandbox world build): the hermetic pass rebuilt
  m4, perl, autoconf, automake, bash, ncurses, readline cleanly, then
  `bc-1.08.2` failed at configure —
  `configure: error: readline works only with flex.`
- Root cause is a missing declaration, and closure isolation is designed to
  surface exactly those (docs/design/build-isolation.md §5.1: "a missing
  declaration fails the build ... instead of silently linking against
  whatever happens to be installed"). bc 1.08.2's configure hard-errors when
  readline is on but the lexer generator is flex-less; the sandbox pass had
  passed only because the Debian seed's flex leaked in (stage1-inner verifies
  `flex` among the seed tools).
- `bc` now declares `flex` in `depends.build` (flex is not part of
  base-devel), which also pins the build order (flex is closure-rebuilt
  before its dependent instead of whenever the world list happens to reach
  it).
- Latent bug fixed in the same class: `flex` execs `m4` at runtime to expand
  its skeleton (Debian/Arch/Fedora all mark flex as depending on m4), but
  `flex` declared `run = []`. Every flex-using build relied on the seed's
  m4; under closure, linux/grub/mesa/bc would have invoked a flex whose m4
  is absent. `flex` now declares `run = ["m4"]`, which `closure_of` pulls
  transitively into every build root that contains flex.
- Validated by the repo's own gates: `scripts/check-recipes.py` (parse,
  unique names, existing deps, no cycles) and TOML parsing.

## Unreleased — fix: --no-iso builds died in pre-flight ("iso stage misses host tool(s): xorriso")

- The release workflow's `core` job builds `build-all.sh --no-iso` on hosts
  that install no ISO tools ("No ISO host tools here: the ISOs are made by
  the matrix jobs"), but the pre-flight host-tool check still ran for the
  (switched-off) ISO stage, so the job died with exit 2 before stage 0 —
  `tar: mydistro: Cannot stat` in the later "pack" step was only the cascade.
- `preflight()` now skips stages disabled with `--no-iso` / `--no-rootfs`
  (`stage_skipped`) exactly like the start-point computation and the
  pipeline loop already did; the tool check still fires for every stage
  that will actually run, so a plain `build-all.sh` still fails fast when
  xorriso is missing.
- Regression tests (`scripts/test-build-all-mock.sh`, section G2): a
  `--no-iso` build must succeed with the ISO tools removed from PATH
  (mirrors the CI core job), while a full build on that PATH must still
  fail with `iso stage misses host tool` (negative control, vacuously
  skipped on hosts that happen to have all five ISO tools).

## Unreleased — fix: stage2 died at xz ("./configure: No such file or directory")

- `xz-5.8.1.tar.xz` is compressed with `--check=sha256`, which `lzma-rs` 0.3.0
  refused to decode. `detect_source_format` swallowed that error and answered
  "not a tarball", so build.rs staged the `.xz` as a single-file source and
  `./configure` was never extracted. Fixed twice over:
  - `lzma-rs` is replaced by `lzma-rust2` 0.15.8 (all xz check types incl.
    SHA-256; streaming `Read` adapter, so the socketpair + worker-thread
    shim is gone; still on `sha2` 0.10). `vendor/` was regenerated with
    `cargo vendor`: only `lzma-rs`, `byteorder`, `crc`, `crc-catalog` left
    and `lzma-rust2` came in. MSRV 1.77 -> 1.82 (lzma-rust2's requirement);
  - `detect_source_format` claims `TarXz` when the xz decoder fails before
    producing a tar header, so extraction surfaces the real error.
  Regression tests: `tar_xz_with_sha256_check_extracts`,
  `corrupt_xz_is_an_extraction_error_not_a_single_file`.

## Unreleased — dpm fetches and extracts without external commands

- dpm no longer shells out to `curl`, `tar`, `cp` or `chroot`; all of these
  run in-process now, so a build only needs bash and the recipes' own
  toolchain — not a host with GNU coreutils/tar and network tools installed:
  - `fetch.rs`: downloads go through `ureq` (rustls, bundled webpki roots,
    proxy from the environment). Behaviour parity with the old curl flags:
    http(s) only, redirects must stay on https (`--proto-redir =https`),
    retries on transient failures (`--retry 3`/`2`), 20s connect timeout,
    `download` still fails on 4xx (`-f`) while `download_opt` still treats
    404-class answers as "file absent" — with one deliberate tightening:
    5xx answers are retried and then reported as errors instead of looking
    like an unpublished `.sig`, so a broken mirror can no longer make an
    optional signature silently disappear. A per-read timeout (60s) keeps a
    stalled mirror from hanging a build forever, and interactive terminals
    get a MiB counter like curl's meter.
  - `fetch.rs`: source tarballs (tar / tar.gz / tar.bz2 / tar.xz / tar.zst)
    are detected by content (magic bytes + tar header check, incl. the v7
    checksum fallback) and extracted with the tar crate plus in-process
    flate2/lzma-rs/bzip2/zstd decoders. GNU tar `--no-same-owner` semantics
    are preserved by construction (ownership never restored, suid bits
    dropped, mtimes kept), `..` entries are skipped with a warning like
    bsdtar, and hard links are materialised even when their target appears
    later in the archive. This also removes the silent dependency on the
    host's gzip/xz/bzip2 binaries that the external `tar` call had.
  - `fetch.rs`: `local:` sources are copied by a pure-Rust `cp -a`
    equivalent (symlinks stay symlinks, modes/timestamps preserved, hard
    links kept, ownership preserved as root).
  - `install.rs`: hook chroots use `chroot(2)`+`chdir(2)` in the child's
    pre-exec hook — the external coreutils `chroot` binary is gone (which
    matters because those hooks are exactly what install/upgrade it).
  - `service.rs` still calls runit's `sv` for live service status: that is
    feature-detected, optional, and `sv` is part of the supervised system
    itself, not a host tool dpm depends on.
- New dependencies are vendored like everything else (`scripts/vendor-dpm.sh`);
  the bootstrap stays fully offline (`--offline --locked`).

## Unreleased — the layer cache survives `sudo` runs (§4.3 reachability)

- `recipes/base/base-files` rel 3: create `/usr/bin/sh -> bash`. Nothing in
  the package base ever created a `sh` (`dash`/`busybox` are not in the
  world either), so every `./configure` died with `bad interpreter: No such
  file or directory` the moment a build really used the assembled root
  (closure), and `bootstrap/seed-from-rootfs.sh` — which requires
  `/usr/bin/sh` — could never have accepted this rootfs as a seed. Stage
  builds never noticed: the Debian seed chroots always had a `/bin/sh`.
  bash is the `sh` on purpose: the stage2 scripts use bash constructs, so
  dash would break them.
- `recipes/base/ncurses` rel 2: with this configure set the term library is
  merged into `libncursesw` and upstream never installs a separate
  `libtinfo.so.6`, but binaries built elsewhere (or against seed hosts)
  load with `NEEDED libtinfo.so.6` — bash's package bash could not load
  inside a closure build root (`bash: error while loading shared
  libraries: libtinfo.so.6`, configure exit 127) and the finished rootfs'
  own `/usr/bin/bash` was equally dead. The recipe now installs
  `libtinfo.so.6` / `.so` as symlinks to the merged `libncursesw`
  (every tinfo entry point is exported by it). After this, rebuild ncurses
  (`dpm build ncurses --isolation sandbox`), then bash — the closure build
  root finds the symlink and the old bash layer loads again.
- Fixed the closure build failure
  `sandbox: overlay layer <rootfs>/var/cache/dpm/layers/layers/<sha> is
  missing` (exit 125) for `sudo dpm build` with `--root` under `$HOME`: the
  layer cache is reachable for dpm but the overlayfs lowerdirs are resolved
  *inside* the sandbox, whose §4.3 map covers only the caller's id — a home
  directory with mode 700 owned by that unmapped uid blocks every stat of
  the layers. `dpm build` now checks the cache's reachability up front
  (`sandbox::first_untraversable_ancestor`) and, when it cannot work,
  says so and falls back to extract-per-build instead of failing
  mid-configure; `mount_layers` reports `PermissionDenied` as "not
  reachable by the sandbox's mapped identity" instead of "is missing".
  The cache default was also fixed so the layers stop doubling:
  `<root>/var/cache/dpm` is the cache *root* (`DPM_LAYER_CACHE` overrides
  it) and the per-archive layers land at `<root>/var/cache/dpm/layers/<sha>`
  — previously the default passed the `layers` dir as the root, producing
  `.../dpm/layers/layers/<sha>` on disk. Existing doubled caches are simply
  stale (delete `layers/layers`); new layers are written to the documented
  layout.
  To keep the layer cache for root runs, keep the rootfs/builddir outside
  such trees (`DPM_LAYER_CACHE=/var/tmp/dpm/cache` is one way), or build
  as a normal user (rootless runs map their own identity).

## Unreleased — the rootfs is a build artifact and the next build's seed

- New stage 4 `rootfs` (`bootstrap/mkrootfs.sh`): the finished final root is
  packed into `mydistro-x86_64-rootfs.tar.zst` with a `.sha256` and a
  `.packages` inventory, validated after writing, and refused when it is not
  a clean finished root. The ISO stage is now stage 5 (`--from-stage iso` is
  unchanged; `--from-stage 4` now means the rootfs stage).
- `build-all.sh --seed-rootfs FILE [--seed-rootfs-sha256 HASH]`: build with a
  previous build's rootfs instead of the Debian seed (stage 0 is not needed).
  Stage 1 verifies and unpacks it and `bootstrap/seed-from-rootfs.sh` turns it
  into a seed (toolchain check, dpm db parked so stage 2 rebuilds everything,
  `/opt/seed/{env.sh,manifest.txt}`). The seed's checksum is part of stage 1's
  input fingerprint. New options `--no-rootfs`, `--rootfs-out`.
- `release.yml`: uploads the rootfs next to the ISO (workflow artifact and
  release asset) and builds each release from the previous release's rootfs
  (`scripts/fetch-rootfs-seed.sh`, checksum-verified; new input `seed:
  auto|rootfs|debian`). The first release still bootstraps from the Debian seed.
- Tests: `scripts/test-rootfs.sh` (new, run by CI) and an extended
  `scripts/test-build-all-mock.sh` (six stages, rootfs seed scenarios).

## Unreleased — dpm builds with the distro's own Rust

- Fixed the stage 2 failure `cargo: command not found` (exit 127) while
  building the `dpm` recipe: the sandbox PATH is `/usr/bin:/usr/sbin` and the
  seed's cargo lives in the hidden `/opt/cargo`.
- New recipe `rust` (official binary release, sha256-pinned; rustc, cargo and
  rust-std only). `dpm` now declares `build = ["rust"]`, so cargo is part of
  the dependency graph instead of an implicit seed tool.
- dpm's crates are vendored in `pkgmgr/vendor` (`scripts/vendor-dpm.sh`);
  stage 2 step 1 and the `dpm` recipe build with `--offline --locked`.
- `recipes/base/dpm` version corrected to 0.8.0 (it still said 0.7.0).
- `boot/busybox` (rel 2) installs only `/usr/bin/busybox`, no applet symlink
  farm. The symlinks (`/bin/tar -> busybox`, ...) shadowed GNU tar in the build
  root, and busybox's xz decoder rejected the large rust tarball.

## 0.8.0 — dependency-aware commands (pkgmgr)

The one thing 0.7 still made you do by hand was walk the dependency list:
`dpm deps X`, then build and install every entry yourself, in order.

- **`dpm install <name>...`** builds and installs the packages *and every
  missing dependency* (build + run, transitive) from the recipes. It prints
  the plan, asks (`--yes` for scripts), shows `[n/total]` progress and a total
  time, locks the db around each install only, and after a mid-plan failure
  says how many packages were installed and that re-running continues where it
  stopped. Named packages are recorded `explicit`, pulled-in ones `dependency`.
  `-n/--dry-run` shows the plan only; `--no-deps` skips dependencies.
  `dpm install <archive>` keeps working unchanged (any argument ending in
  `.dpm.tar.zst` or containing `/` is an archive; several may be given).
- **`dpm outdated`** / **`dpm update [name...]`** — compare installed versions
  with the recipes; update rebuilds the outdated ones in dependency order and
  keeps each package's install reason.
- **`dpm autoremove`** (`-n`, `-y`, `--build-deps`) — removes dependency
  packages nothing needs, dependents first. Build tools of kept packages stay
  unless `--build-deps` is given.
- **`dpm list -e` / `-d`** — only explicitly installed packages / only
  dependencies.
- Shell completions know the new commands; `install` completes package names
  as well as files.
- Internals: the planning logic lives in `src/plan.rs` as pure functions with
  unit tests; `prepare_build` is shared by `build`, `install <name>` and
  `update`.

## 0.7.0 — DPM UX overhaul (pkgmgr)

### Stop repeating yourself
- **`dpm.toml` config file**: dpm reads the nearest `dpm.toml` at or above the
  current directory (like git; `DPM_CONFIG` names one directly). Keys: `root`,
  `recipes`, `builddir`, `profiles`, `jobs`, `repo`. Per-key precedence:
  flag > env var > file > default; relative paths in the file anchor at the
  file's own directory; unknown keys fail loudly. `dpm init` writes a
  commented template; `dpm config show` prints the effective values with each
  one's source.
- **Environment variables**: `DPM_ROOT`, `DPM_RECIPES`, `DPM_BUILDDIR`,
  `DPM_PROFILES`, `DPM_JOBS`, `DPM_REPO`.
- **Global flags anywhere**: `--root --recipes --builddir --profiles --jobs`
  are accepted before or after the subcommand (`dpm install --root /x a.zst`
  works exactly like the old `dpm --root /x install a.zst`).
- `dpm upgrade` picks its repository from the config's `repo` key /
  `DPM_REPO` when `--repo` is absent.

### Explore before you act
- **`dpm search <term>`** — case-insensitive search over recipe names and
  summaries, with an installed-marker per hit and `--glob` for `*`/`?`
  patterns against the name.
- **`dpm info <name>`** — version, arch, summary, license, source (pinned or
  not), depends (build/run/check), sandbox policy, recipe path, and the
  installed state (reason, date, size, file count).
- **`dpm why <name>`** — reverse dependencies: which installed packages need
  it (so you know what breaks before removing), `--tree` scans the whole
  recipes tree too.
- **`dpm list [pattern]`** — `query` keeps its exact old output when piped,
  gains an optional name filter and a colored header on a terminal; `list`
  is an alias.

### One-step builds
- **`dpm build --install <name>`** — builds the recipe and installs the fresh
  archive into `--root` in a single command (`--force` passes through to the
  install). The db lock wraps only the install step, never the build itself.

### Safety and presentation
- **Confirmations**: `remove` shows version, file count and reverse
  dependencies before asking `y/N`; `upgrade` shows the plan and asks.
  Non-interactive runs REQUIRE `--yes` — a piped stdin without it is refused,
  never silently guessed (install never asks; the bootstrap is unaffected).
- **Smart colors**: names bold, versions cyan, installed green, warnings
  yellow — only on a real terminal. Pipes and scripts receive byte-identical
  plain text. Honors `NO_COLOR` and `DPM_COLOR=always|never|auto`.
- **Did-you-mean**: unknown package/recipe names get suggestions from the
  recipe graph (`dpm build gzp` → *did you mean `gmp` or `gzip` or `gcc`?*),
  both for `deps`/`build` targets and for missing dependency declarations.
  A missing archive path suggests the closest files that do exist.
- **Shell completions**: `dpm completions bash|zsh|fish` prints hand-written
  scripts (no new crates — the offline vendored self-hosting build stays
  dependency-free); package names complete dynamically via the hidden
  `dpm __complete_pkgs`.

### Compatibility notes (deliberate breaks, scripts updated in-tree)
- `dpm remove` and `dpm upgrade` in non-interactive scripts now need `--yes`.
  `scripts/smoke-v05.sh`, `scripts/smoke-v06.sh` and the bootstrap docs were
  updated; both smoke suites pass against the release build.
- 139 tests (was 113): new units cover config precedence/discovery, the
  suggestion ranking, the color policy, glob matching, date/size formatting
  and the confirmation contract; new e2e tests cover flags-after-subcommand,
  search/info/why/list, `build --install`, completions output and the
  non-interactive refusal.

## Unreleased

### Bootstrap audit: input-tracked resume, verified self-hosting, hardened gates
- **Resume is now input-tracked** (`build-all.sh`): every finished stage
  records a fingerprint of its inputs (stage scripts, recipe/profile trees,
  effective options, seed identity) in `<stage>.inputs`; a stamp whose inputs
  changed — or that predates input tracking — is invalidated together with
  everything downstream, with a notice naming the changed keys. This fixes
  the silent-skip class of bugs: `--with-gui` after a default build, a later
  `--stage3-world`, `--vol-id`/`--squash-comp` changes, recipe edits and
  stage-script edits used to be quietly ignored on re-run and report success.
- A stage that runs invalidates all later stamps (upstream-continuity
  invariant); `--from-stage S` re-runs S itself — including the seed when it
  would otherwise be adopted.
- **Concurrency**: the state dir is `flock`ed; a second concurrent
  `build-all` against the same target exits immediately. `--list-stages`
  reports `done` / `stale (inputs changed|not recorded)` / `FAILED` /
  `pending` / `done (adopted)`; failed stages leave a marker that is cleared
  on their later success.
- **`--wipe` safety**: refuses FHS top-level paths and their interiors, the
  repo and every ancestor of it, `$HOME`, mountpoints, and targets with
  `dev/proc/sys/run` still mounted; prints the size before deleting; a
  refused invocation creates nothing. All refusals now run BEFORE any state
  is created.
- **Seed provenance**: `build-seed.sh` gates on root + x86_64 up front,
  warns loudly on `ldconfig -r` failure, records `opt/seed/manifest.txt`
  (exact .deb names, rustc version, host, date) inside the tarball and
  writes a `seed.tar.zst.sha256` sidecar. Adoption and stage 1 verify the
  sidecar (a corrupt seed is rebuilt, not adopted) and stage 1 runs
  `zstd -t` before unpacking anything over the target.
- **Stage 3 proves self-hosting** instead of trusting exit codes: gcc and dpm
  must be db-owned (ours, not the seed's), a pthread C program must compile
  AND run after the seed is deleted, and no ELF in the final root may
  reference `/opt/{seed,cargo,rustup,cross-tools}` (interpreter, DT_NEEDED
  or RPATH — `verify_final_root_no_seed_refs` in `final-root.sh`). The
  toolchain set is derived from `recipes/toolchain/` instead of a hardcoded
  list.
- **ISO structural validation** (`mkiso.sh`): xorriso is required up front;
  after `grub-mkrescue` the image must actually contain
  `/boot/<kernel>`, `/boot/initramfs.img`, `/boot/grub/grub.cfg` and
  `/live/rootfs.squashfs` (verified via `xorriso -indev -ls`) or the stage
  fails — still not a boot test, and documented as such.
- **Fixed dead precondition checks** (found by the new mkiso test):
  `$(ls glob | sort | tail)` under `set -euo pipefail` killed the script
  silently (exit 2) on exactly the paths the friendly errors were written
  for — the kernel check in `mkiso.sh`, the per-package archive checks in
  `stage2-inner.sh`/`stage3-inner.sh`, the modules-dir warning in
  `initramfs.sh`, and `find_archive` in `final-root.sh` (which only survived
  by accident of its `||`-list call context). All now fail with their
  intended message and exit code; mkiso's fatal messages go to stderr.
- **Stage 2 can re-run after stage 3** (`--from-stage 2` world rebuild):
  `/opt/seed/env.sh` is sourced only when present and the installed
  `/usr/bin/dpm` is reused when the seed's cargo is gone (fail loudly if
  neither). The leftover one-time `REBUILD_AFTER_CHANGE="readline"` hack is
  gone; the documented procedures are `--from-stage 2` (everything) or
  `dpm --root / remove <pkg>` + re-run (one package).
- **Repo sync into the chroot** (`sync-repo.sh`, new): stages 1-3 copy the
  repo without the ~1 GB seed tarball, the multi-GB `seed-root` scratch and
  the host's `pkgmgr/target` cargo output (merge semantics preserved).
- **initramfs.sh**: scratch in `mktemp -d` (not the repo dir), option values
  are validated; **ensure-chroot-mounts.sh**: a failed resolv.conf copy now
  falls back to public resolvers instead of a silently dead DNS; every
  build log starts with an audit header (args, host, tool versions, seed
  identity, commit).
- **Pre-flight**: zstd/unshare/pivot_root/mount are checked for stages 1-3
  alongside the ISO tools (xorriso added).
- **Tests**: `scripts/test-build-all-mock.sh` extended to 131 checks
  (input invalidation, cascade, legacy stamps, failure markers, lock, seed
  sidecar adoption, `--from-stage seed` force, `--wipe` refusals, dry-run
  purity); new `scripts/test-mkiso.sh` (27 checks: gates, structural
  validation, failure propagation); `scripts/test-final-root.sh` extended
  with the seed-reference ELF scan against gcc-built poisoned binaries (22
  checks). All three are now actually wired into CI, plus
  `validate-install.sh` which had never been run in CI either.
- **Docs**: `bootstrap/README.md` gains the stage contracts, the seed trust
  boundary (the bootstrap is NOT source-only), the verified-vs-intended
  boundary, a test inventory and known limitations; the main README's
  "every recipe carries a sha256" claim is corrected (32 GUI placeholders
  by design) and the pipeline description matches the new resume semantics.

### Fix stage-2 ninja failure: `c++: not found`
- The Debian/Ubuntu seed lacked the `c++` symlink (an `update-alternatives` link
  that `dpkg -x` never creates), so ninja's bootstrap (`configure.py` runs plain
  `c++`) failed at stage2 [3/89]. `build-seed.sh` now links `c++ -> g++`;
  `stage1-inner.sh` checks for it; `stage2-inner.sh` repairs existing seeds on
  every run, so a resumed build needs no stage-1 rerun.

### Two-root build: clean final root separate from the build root
- Packages are now installed into the build root `/` (needed for later builds)
  **and** into a clean final root `TARGET/sysroot` (`/sysroot` in the chroot).
  The ISO is built from the final root only, so no Ubuntu seed files, `/opt/seed`
  or build directories can leak into the image.
- New `bootstrap/final-root.sh` (install/sync/seal helpers) used by stage2/stage3;
  `final root` sync makes resumed builds and `--from-stage 3` safe, and
  `ldconfig -r` is run once at the end (dpm skips glibc's hook in a shell-less root).
- `build-all.sh`: `--single-root` (legacy layout); a layout switch invalidates
  stage 2/3/iso stamps; the ISO stage refuses a missing final root.
- `mkiso.sh`: takes the final root; squashfs excludes are passed only if present.
- Tests: `scripts/test-final-root.sh` (new, in CI) and extended
  `scripts/test-build-all-mock.sh` (layout cases A11-A13, L, M, N, O).

### Fix stage-2 glibc build failure on Ubuntu seed compiler
- `recipes/toolchain/glibc`: configure with `CC="gcc -U_FORTIFY_SOURCE"`.
  The seed gcc (Ubuntu 24.04, gcc 13) defines `_FORTIFY_SOURCE=3` by default and
  glibc's `-Wp,-U_FORTIFY_SOURCE` does not cancel it, so `misc/syslog.c` failed
  with `inlining failed in call to 'always_inline' 'syslog'` (stage2, 12/115).

### Stage scripts enter the target with pivot_root instead of chroot
- New `bootstrap/enter-root.sh TARGET CMD...`: private mount namespace +
  `pivot_root`, then a lazy unmount of the host root (via `umount`, else
  `python3`, else `perl` inside the target). stage1/2/3 use it in place of
  `chroot`.
- Reason: the kernel refuses `unshare(CLONE_NEWUSER)` from a chrooted process,
  so `--isolation sandbox` could never work during the bootstrap
  ("cannot create a user namespace (Operation not permitted)").
- `build-all.sh --isolation closure` uses `sandbox` for stage 2 (closure needs
  the stage-3 archive set); `stage2.sh` stops early on an empty target.
- Sandbox: root-installed uid/gid map now includes the caller's own id
  (`0 <uid> 1` + `1 100000 65535`), fixing builds reading back as uid 65534.

### One-command pipeline driver: `bootstrap/build-all.sh`
- **`sudo bootstrap/build-all.sh /mnt/mydistro`** runs the entire pipeline
  (seed → stage1 → stage2 → stage3 → ISO) with the orchestration the
  individual stage scripts lack:
  - **stamp-based resume**: each finished stage is stamped; after a failure
    the same command re-runs and skips what already succeeded. The state
    directory (`$(dirname TARGET)/.<name>.build/` — stamps, one timestamped
    log per run, per-stage timings in `meta`) lives OUTSIDE the target, so
    nothing leaks into the squashfs/ISO.
  - **failure trap**: on failure prints the failed stage, the log path, the
    exact resume command (original arguments included) and the
    `umount-chroot.sh` hint; the target is kept for resume.
  - **pre-flight checks** before any stage starts: root (unless starting at
    stage 4), ~10 GB free space on the target filesystem, host tools for the
    stages that will actually run (`curl`, `mksquashfs`, `grub-mkrescue`,
    `gcc`, `make`), plus a network reachability warning.
  - **knobs**: `--from-stage seed|1|2|3|iso` (restart point; that stage and
    everything after it re-runs), `--fresh`, `--wipe` (guarded delete of a
    previous target), `--no-iso`, `--keep-mounts`, `--isolation
    none|env|sandbox|closure`, `--stage3-world`, `--with-gui`, `--jobs`,
    `--vol-id`, `--squash-comp`, `--out`, `--dry-run` (prints the commands,
    writes nothing), `--list-stages`.
  - a hand-built `seed/seed.tar.zst` is adopted on the first run instead of
    re-downloading the toolchain; a non-empty target without build state is
    refused unless `--wipe` is passed.
  - success epilogue: per-stage elapsed times, ISO path/size, automatic
    `umount-chroot.sh`, and next-step hints (validate-install.sh, boot,
    install.sh).
- Tested by `scripts/test-build-all-mock.sh` (mock stage scripts; 48
  assertions covering the full run, resume, `--from-stage` invalidation,
  failure trap, `--no-iso`, safety refusals, `--wipe`, side-effect-free
  dry-run and seed adoption).

### Build isolation — Phases 5 & 7 complete (the plan is fully implemented)
- **Layer cache (Phase 5, §5.3 v2)**: every closure archive is extracted
  once into `<cache>/layers/<archive-sha256>/` (`DPM_LAYER_CACHE` overrides,
  default `<root>/var/cache/dpm/layers`, `DPM_NO_LAYER_CACHE=1` disables)
  and the build root is mounted as an **overlayfs** over those layers inside
  the sandbox instead of being re-extracted per build. Requires overlayfs in
  a user namespace (kernel ≥ 5.11); `dpm build` probes it
  (`dpm sandbox-probe overlay`) and falls back to extract-per-build with a
  note — same result, same trust (the archive is signature-verified on every
  assembly, cache hits included). Paths containing `,` or `:` fall back to
  v1 (overlayfs data strings cannot express them).
- **`dpm build --use-cache`** (opt-in): an archive whose recorded
  `build_id` (sidecar `<out>/<archive>.buildid`) matches the id the current
  inputs produce — recipe bytes, source sha256, closure archive set, profile
  flags — is reused without running anything (the check happens before the
  source download). Recipe edits, version bumps or dependency changes force
  a rebuild. `--rebuild-check` always ignores the cache.
- **Rootless builds (Phase 7)**: `dpm build` up to and including
  `--isolation closure` works unchanged as a normal user — the sandbox
  self-writes its `0 → <caller-uid>` map and stages under its private
  `/tmp`; the archive still records uid/gid 0. New tests/rootless.rs runs
  the full closure dance unprivileged (as `nobody` via setpriv when the
  test runner is root, directly when the runner already is a normal user).
- `dpm sandbox-probe` gained the `overlay` probe (also listed in the
  full-probe output).

### Installer / initramfs
- **The disk-installed system now keeps the package cache**: install.sh
  copies `/var/cache/dpm` (minus the re-downloadable `remote/` subcache)
  onto the target after the main rsync, so `dpm rollback <pkg>` and offline
  reinstalls work there. Opt out with `--no-pkg-cache`.
- install.sh excludes `/build3` (stage3's build dir) from the system copy,
  and mkiso.sh excludes it from the squashfs — its archives are already
  installed and cached in `/var/cache/dpm`.
- **initramfs module loading is dependency-aware**: when the target root
  has `lib/modules/<kver>/modules.dep`, the initramfs stages the storage/
  HID/filesystem modules **with their full dependency closure** plus
  `modules.dep` itself, and /init loads them with busybox `modprobe`
  (correct load order, no hand-kept list). The flat `/modules` copy +
  `insmod` loop remain as the fallback for roots without `modules.dep`.

### Build isolation (docs/design/build-isolation.md — Phases 1–4 & 6)
- New isolation levels for `dpm build`, selected by `--isolation` or the
  profile's `[build] isolation` (default stays `none` — today's behaviour —
  until the tree is proven at each level):
  - **`env`** — the build section sees *only* the §6 whitelist (PATH, HOME,
    TMPDIR, LC_ALL=C, TZ=UTC, SHELL, SOURCE_DATE_EPOCH, the profile's
    CFLAGS/CXXFLAGS/LDFLAGS, DPM_JOBS/SRCDIR/PKGDIR) with umask 022.
    `SOURCE_DATE_EPOCH` is the newest source mtime (or the recipe's
    `[package] source_date_epoch` pin). Archives are normalised (uid/gid 0,
    empty uname/gname, `mtime = min(mtime, SDE)`) and `.PKGINFO` drops the
    wall-clock `build_date` in favour of `source_date_epoch` + `build_id`
    (sha256 of recipe ‖ source ‖ closure ‖ flags), so the same recipe + inputs
    always produce the same archive hash. `dpm build --rebuild-check` builds
    twice and verifies exactly that.
  - **`sandbox`** — the section runs inside user/mount/pid/net/ipc/uts
    namespaces created by dpm itself (new `libc` usage — already in
    Cargo.lock, so the offline vendored bootstrap is unchanged): read-only
    root (an accidental `make install` without DESTDIR fails loudly instead
    of writing into the running system), private size-limited `/tmp`,
    minimal `/dev` (binds, devpts, shm), fresh `/proc` for the new pid
    namespace (host processes invisible), masked `/home`, `/root`, `/run`,
    `/mydistro`, `/opt/seed`, the build dir and the package caches, loopback
    only networking (a host listener is unreachable), fake-root identity
    (uid 0 inside, an unprivileged id outside), `RLIMIT_CORE=0`,
    `PR_SET_NO_NEW_PRIVS`, all capabilities dropped, per-section timeout that
    kills the whole pid namespace (exit 124 like timeout(1)). When PID 1
    exits, the kernel kills leftover build daemons.
  - **`closure`** — like `sandbox`, but the root is **assembled from built
    archives** (`base-devel` ∪ the declared build deps ∪ their run deps,
    plus `depends.check` with `--check`), each signature-verified first.
    Nothing else exists, so a missing declaration fails as
    `command not found` / `cannot find -lfoo` — the failure is the audit.
- New `base-devel` meta recipe defines the base toolchain set; after it,
    `depends.build` means "beyond base-devel".
- New recipe surface: `[depends] check = [...]` (test-only tools),
  `[sandbox] network = true` (needs `--allow-network`; recorded as
  `impure = network` in `.PKGINFO`), `[sandbox] sysfs = true`, and
  `[package] source_date_epoch`.
- Post-build lint (`env` level and up): a pure-Rust ELF reader maps
  `DT_NEEDED` to owning packages and warns when `depends.run` misses one
  (Phase 6a), and **errors** on leaked build paths (`/build/src`,
  `/build/pkg`, the host build dir in rpath/`.la`/`.pc`), files outside the
  allowed trees, `/usr/local`, stray `/tmp`, and world-writable files.
- `dpm sandbox-probe` (hidden) reports which kernel features this host
  allows; a build refuses to weaken isolation silently and says to pass
  `--allow-degraded` when a restricted container is detected (masked `/proc`
  instead of a fresh one, etc.). Integration tests skip with a message on
  such hosts instead of failing.
- The kernel recipe now enables `USER_NS`, `PID_NS`, `NET_NS`, `IPC_NS`,
  `UTS_NS` explicitly (USER_NS defaults to n — without it the distro's own
  kernel cannot run its own build sandbox).
- Bootstrap stages accept `STAGE2_ISOLATION` (none|env|sandbox) and
  `STAGE3_ISOLATION` (none|env|sandbox|closure); stage3 with `closure`
  builds `base-devel` first, since it is the base layer of every build root.
- Unprivileged hosts that cannot create `/build` stage under the sandbox's
  private `/tmp` instead (recipes always see the path through
  `%{srcdir}`/`%{pkgdir}`, never hardcoded) — groundwork for the rootless
  Phase 7. The sandbox spec is TOML (not JSON) to avoid a new dependency
  in the offline vendored bootstrap.

### Package manager
- Fixed `dpm upgrade` with a recipe tree present: every upgrade target is
  installed by definition, and the dependency resolver treats "installed" as
  "done" — the plan order came back **empty**, so `dpm upgrade` reported
  success while applying nothing (foreign repo packages were still upgraded,
  which masked the bug). Targets are now ordered through the recipe graph
  regardless of installed state, and only planned names can appear in the
  order (a build-only dependency of a planned package can no longer leak
  into it).
- New `dpm deps-all --include-installed`: list every recipe even when the db
  already records it (the default stays "skip installed" so a resumed stage2
  rebuilds only what is missing). Without it a `STAGE3_WORLD=1` stage3
  silently rebuilt **nothing** for the same resolver reason; stage3 now uses
  the flag and fails loudly when the installed dpm is too old to know it.
- `dpm remove` is journaled like install: files move into a hidden
  `.dpm/rm-<stamp>/` dir first and are restored when anything fails (a file
  that cannot be moved, or the db update), instead of being unlinked
  directly — a crash or error could previously leave the db claiming a
  half-removed package. Removal failures now abort the command instead of
  being silently ignored.
- Local repository indexes are validated exactly like remote ones: an index
  entry's archive path may not contain `/`, `..` or start with a dot.
- Remote `.sig` downloads (index and archives) land in a `.part` file first:
  an interrupted transfer can no longer corrupt the cached signature, which
  would have made every later upgrade fail verification until removed by
  hand.
- `recipe::load_all` reports the actual duplicate package name in its error
  (it used to name the alphabetically-last recipe in the tree).
- Package database locking: writers (`install`, `remove`, `rollback`,
  `upgrade`) hold an exclusive `flock` on `var/lib/dpm/lock` for the whole
  command, readers (`query`, `files`, `owner`, `deps`, `deps-all`,
  `upgrade --dry-run`) a shared one. Concurrent runs wait (`DPM_LOCK_TIMEOUT`
  to give up); hooks run with `DPM_LOCK_HELD=1` so nested dpm calls don't
  deadlock. No new crate dependency (declares libc's `flock` directly).
- Build profiles are now used: `profiles/<arch>.toml` `cflags`/`cxxflags`/
  `ldflags` are exported as `CFLAGS`/`CXXFLAGS`/`LDFLAGS` to every build
  section, and its `jobs` is the default job count (`--jobs` still wins).
  New `--profiles <dir>` option; stage2/stage3 pass it explicitly. Note this
  changes the flags every bootstrap build gets (`-O2 -pipe`, no `-g`).
- `dpm build` streams build output live (stdout+stderr merged, in order) to
  the console and the per-section log instead of buffering until the end.
- `dpm build --check` runs the recipe's `check` section after `compile`
  (failure aborts); `--check-nonfatal` only warns. Default stays off.
- A recipe without `build.install` is rejected before anything is downloaded
  or compiled.
- `recipes/base/dpm` tracks the crate (0.6.1, GPL-3.0) and drops any stale
  `target/` copied in with the local source.

### Bootstrap
- stage2/stage3 pick the built archive with a glob instead of `grep -E "^$pkg-…"`
  — a package name containing regex metacharacters (e.g. a future `libstdc++`)
  would never have matched the pattern, aborting the bootstrap.
- install.sh: the generated fstab mounts `/run` as tmpfs (runtime state no
  longer persists on disk across boots) and rsync excludes the actual `$MNT`
  prefix, not only `/mnt` — a custom `MNT=` inside the live tree could
  previously be copied into itself.

### Scripts
- smoke-v05/v06 locate the repo relative to the script instead of hardcoding
  `/home/z/my-project/mydistro` (they failed on any other checkout).
- validate-install.sh asserts the new `$MNT` exclusion and the `/run` fstab
  row.

### GUI (recipes/gui, opt-in)
- New Wayland desktop stack: sway 1.10 on wlroots 0.18, foot, mesa (software +
  virgl), fonts and the supporting libraries, plus a `gui-session` meta package
  (seatd runit service, `start-sway`, group-setup hook). 33 recipes, hashes are
  placeholders until `scripts/fill-sha256.py` is run; not yet test-built.
- `stage2`/`stage3` skip `recipes/gui` unless `WITH_GUI=1`.
- `linux` recipe enables DRM (virtio-gpu, bochs, simpledrm), fbdev emulation and
  evdev/HID input (rel bump).
- New scripts: `check-recipes.py` (offline graph/consistency check) and
  `fill-sha256.py` (pin placeholder hashes).

## 0.6.1

Review fixes (security and bootstrap correctness).

### Security
- `archive::extract` rejects `..`/absolute paths, hard links and writes through
  symlinks (path traversal / symlink escape).
- Remote upgrades now download each archive's `.sig`; a signed index is
  required when a trust store is configured.
- The archive's `.PKGINFO` must match the index entry (name, version, rel) and
  the host architecture — an old signed archive can no longer be replayed as an
  "upgrade".
- Index carries signed `generated`/`expires` timestamps: an index older than one
  already seen is refused (rollback), an expired remote index is refused unless
  `--force` (freeze).
- `dpm keygen` creates the secret key with mode 0600 atomically; signature
  verification is `verify_strict`.
- `curl` restricted to http(s), redirects https-only, `--` before the URL.
- Service names are validated (no path separators / `..`).

### Package manager
- Hooks work: `.HOOKS` is written into archives (TOML); `post_install`,
  `pre_remove`, `post_remove` run on the live root, or in a chroot of `--root`
  when dpm runs as root and the target has a shell; otherwise they are skipped.
- `dpm remove` refuses when another installed package depends on the target
  (`--force` overrides).
- File placement is journaled and all-or-nothing: replaced files and files
  removed because they disappeared from the package are kept in `.dpm/bak-*`
  until the db entry is written; if any step (including `db.add`) fails, the
  previous state is restored. The staging dir is always cleaned up.

### Bootstrap
- `stage1.sh` copies `bootstrap/` into the chroot and refuses `/` as target.
- `stage2`/`stage3` pick the exact archive (`linux` vs `linux-headers`, `runit`
  vs `runit-services`).
- `install.sh`: correct `/etc/hosts` with `--hostname`, NVMe/mmcblk whole disks
  and partition names, hostname validation, `udevadm settle`, unmount on
  failure; now executable.
- New `bootstrap/umount-chroot.sh`.

### Tests
- New tests: traversal/symlink extraction, hooks round-trip, index/PKGINFO
  match, index freshness/expiry, reverse-dependency removal, placement rollback.
- `e2e` locates the binary via `CARGO_BIN_EXE_dpm`.
