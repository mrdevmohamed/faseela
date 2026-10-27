# Changelog

## Unreleased

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
