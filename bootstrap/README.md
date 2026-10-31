# Bootstrap — building the distribution from nothing

The pipeline that turns an empty directory into a bootable ISO of the
distribution. Every stage after the seed is performed by the
distribution's own package manager (NAWA).

```
stage 0  seed/build-seed.sh   assemble prebuilt toolchain (gcc, glibc, rustc)
stage 1  stage1.sh            chroot + verify the seed toolchain (it is the temporary toolchain)
stage 2  stage2.sh            NAWA builds the FULL recipe graph into the target
stage 3  stage3.sh            self-hosting rebuild (toolchain, or STAGE3_WORLD=1 for all)
stage 4  mkrootfs.sh          final root -> mydistro-x86_64-rootfs.tar.zst (+ .sha256, .packages)
stage 5  mkiso.sh             squashfs + initramfs + grub -> bootable live ISO
```

The stage-4 rootfs is published next to the ISO and is the **seed of the next
build** — see "Self-hosting: the rootfs as the next seed" below.

## Boot flow (stage 5 output)

```
grub (hybrid BIOS+UEFI)
  └─ kernel + /boot/initramfs.img (static busybox, built by initramfs.sh)
       └─ /init: insmod storage modules → find the MYDISTRO media
                 (sr/sd/vd/nvme scan) → mount /live/rootfs.squashfs
                 → overlayfs with tmpfs upper → switch_root → /usr/bin/runit
                      └─ /etc/runit/1 (mount, udev coldplug)
                         /etc/runit/2 (runsvdir: getty tty1-4, udevd,
                         dhcpcd, sysklogd, crond) → login on tty1-4
```

## Host requirements

* root for chroot + bind mounts (stages 1-3); stages 4-5 work as non-root
  (the rootfs is best packed as root so ownership is recorded faithfully)
* stage 5 (ISO) tools: `squashfs-tools`, `grub-pc-bin`, `grub-efi-amd64-bin`,
  `xorriso`, `mtools` (Debian names) + gcc/make for the initramfs busybox
* ~10 GB free disk, decent network

## Quick start

One command drives the whole pipeline (seed → ISO) with resume, logging
and pre-flight checks:

```bash
cd bootstrap
sudo ./build-all.sh /mnt/mydistro            # seed + stage1-3 + ISO
sudo ./build-all.sh --isolation closure --stage3-world /mnt/mydistro
./build-all.sh --list-stages /mnt/mydistro     # progress after a failure
sudo ./build-all.sh /mnt/mydistro               # re-run: finished stages skipped
```

The equivalent manual invocation of each stage (what build-all.sh does
for you):

```bash
sudo ./seed/build-seed.sh              # -> seed/seed.tar.zst
sudo ./stage1.sh /mnt/mydistro         # unpack seed, chroot, verify seed toolchain
sudo ./stage2.sh /mnt/mydistro         # NAWA builds + installs all recipes
sudo ./stage3.sh /mnt/mydistro         # self-hosting rebuild, seed removed
sudo ./mkiso.sh /mnt/mydistro out.iso  # bootable image
```

### Where the recipes come from: `fetch-recipes.sh`

`recipes/` is not part of this repository: `fetch-recipes.sh` fills it from
faseela-repo (`build-all.sh`, `sync-repo.sh` and `mkrootfs-min.sh` call it, so
you rarely run it yourself). A sibling `../faseela-repo` checkout is copied as
it is, uncommitted changes included, every time; otherwise the default branch (`main`) is fetched
once and kept (`--update` for the newest, `RECIPES_REF=<branch|tag|commit>` for
a specific one, `RECIPES_DIR=<path>` for another local tree). The commit is
recorded in `.recipes-rev`. A `recipes/` without that stamp is your own copy
and is never touched.

### Iterating on a few recipes: `rebuild.sh`

`build-all.sh` fingerprints the WHOLE recipe tree, so editing one recipe
invalidates stage 2, stage 3 (toolchain/world rebuild) and the ISO. For the
edit-build-boot loop use the incremental path instead — it rebuilds and
reinstalls only the named recipes (build root + final root) and can repack
the ISO:

```bash
sudo ./rebuild.sh --iso out/test.iso /mnt/mydistro runit-services shadow
```

Dependents are not rebuilt (name them too after changing a library). No
stamps are touched, so a later full `build-all.sh` still rebuilds from the
changed recipe tree, as a release build should.

### build-all.sh specifics

* **state lives outside the target**: `$(dirname TARGET)/.<name>.build/`
  (`stamps/` per-stage completion + input fingerprints, `logs/` one
  timestamped log per run, `meta` per-stage timings, `layout`, `lock`) —
  nothing leaks into the squashfs/ISO
* **resume is input-tracked, not stamp-blind**: a stage is skipped only when
  its stamp exists AND the inputs recorded next to it still match — the stage
  scripts, the recipe/profile trees, and the effective options (`--with-gui`,
  `--stage3-world`, `--isolation`, `--vol-id`, `--squash-comp`, layout, and
  for stage 1 the seed identity). A stamp whose inputs changed (or that
  predates input tracking) is invalidated together with everything
  downstream; the notice names the changed keys. Changing `--vol-id` re-runs
  only the ISO stage; editing a recipe re-runs stage 2 onward; an unrelated
  stamp survives.
* **a stage that runs invalidates every later stamp** — a stamp is only
  valid while every upstream stamp stayed valid (the upstream-continuity
  invariant).
* **one build per target at a time**: the state dir is `flock`ed; a second
  concurrent `build-all` against the same target exits immediately with an
  explanation (`--dry-run` and `--list-stages` take no lock and create
  nothing).
* **`--from-stage S`** forces a restart point (stamps from S onward are
  invalidated — S itself re-runs, even the seed when adoptable);
  `--fresh` redoes everything, `--wipe` also deletes a previous target,
  `--dry-run` previews (writes nothing, invalidates nothing), `--no-iso` /
  `--no-rootfs` switch the ISO / rootfs stage off (both: stop after stage 3).
  Stage numbers: `seed|0, 1, 2, 3, rootfs|4, iso|5`
* **`--wipe` safety**: refuses FHS top-level system paths and their
  interiors, the repository itself and every ancestor of it (the target
  would swallow the repo), `$HOME`, mountpoints, and a target with
  `dev/proc/sys/run` still mounted — and prints the size of what it is
  about to delete
* **`--list-stages`** distinguishes `done` / `stale (inputs changed)` /
  `stale (inputs not recorded)` / `FAILED` / `pending` / `done (adopted)` /
  `skipped (--no-iso)`
* **pre-flight**: root check, ~10 GB free space, host tools for the stages
  that will actually run — stages switched off with `--no-iso` /
  `--no-rootfs` are not checked (zstd/unshare/pivot_root/mount for stages
  1-3; mksquashfs/grub-mkrescue/xorriso/gcc/make for the ISO) — so a
  missing xorriso cannot waste hours of gcc, and a `--no-iso` build works
  on a host without the ISO tools
* every log starts with an **audit header**: args, host, bash/tar/zstd
  versions, seed identity, git commit when the repo is a checkout
* a failed stage records a failure marker (shown by `--list-stages`, cleared
  when that stage later succeeds) and the trap prints the exact re-run
  command plus the `umount-chroot.sh` hint
* a hand-built `seed/seed.tar.zst` is adopted on the first run instead of
  re-downloading ~1 GB of toolchain — but only if it passes its `seed.tar.zst.sha256`
  sidecar when one exists (a sidecar mismatch means corrupt: rebuild). A
  hand-built seed without a sidecar is adopted with a notice (legacy
  behavior), and stage 1 always runs `zstd -t` plus the sidecar check before
  unpacking anything over the target.

### Stage contracts

| stage | consumes | produces | verifies before stamping |
|-------|----------|----------|--------------------------|
| seed | Debian `.deb`s via `apt-get download`, rustup | `seed.tar.zst` (+ `.sha256` sidecar, `manifest.txt` inside) | root + x86_64 host, `ldconfig -r` warns loudly, the seed chroots and runs its own gcc/make/ld on its own loader |
| stage 1 | seed tarball | chroot with seed + repo copy, mounts, DNS, CA bundle | seed zstd frame + sha256 sidecar BEFORE unpacking; seed toolchain compiles/runs C + Rust inside the chroot |
| stage 2 | seed toolchain, recipes | full graph installed into `/` and `/sysroot`, `nawa` built and installed | per-package archive exists; final root synced + sealed (no `/opt/*`, no build dirs, key files present) |
| stage 3 | distro's own toolchain | toolchain set (or world) rebuilt from `recipes/toolchain`, seed removed | **self-hosting proofs**: gcc/nawa are db-owned (ours, not the seed's), a pthread C program compiles AND runs with the seed gone, no ELF in the final root references `/opt/{seed,cargo,rustup,cross-tools}` |
| iso | final root | hybrid ISO | xorriso must exist up front; after `grub-mkrescue` the image is structurally validated: `/boot/<kernel>`, `/boot/initramfs.img`, `/boot/grub/grub.cfg`, `/live/rootfs.squashfs` must be IN the image |

## What lives where

| File               | Runs     | Purpose                                            |
|--------------------|----------|----------------------------------------------------|
| `build-all.sh`     | host     | one-command driver: stages 0-4, resume + logs      |
| `seed/seed.toml`   | (docs)   | manifest of everything the seed must contain       |
| `seed/build-seed.sh` | host   | assembles + packs the seed (manifest, sha256 sidecar) |
| `stage1.sh`        | host     | unpack seed (verified), mounts, invoke chroot      |
| `stage1-inner.sh`  | chroot   | prepare chroot, verify seed toolchain (C/C++/Rust) |
| `sync-repo.sh`     | host     | copy repo into the chroot WITHOUT the ~1 GB seed   |
| `final-root.sh`    | chroot   | two-root helpers: install into / sysroot, sync, seal, seed-ref ELF scan |
| `stage2.sh`        | host     | chroot entry for stage2                            |
| `stage2-inner.sh`  | chroot   | compile NAWA with seed rustc, build the full graph  |
| `stage3.sh`        | host     | chroot entry for the self-hosting rebuild          |
| `stage3-inner.sh`  | chroot   | toolchain/world rebuild + self-hosting proofs      |
| `initramfs.sh`     | host     | static busybox + /init live-boot initramfs builder |
| `mkiso.sh`         | host     | squashfs + grub config + hybrid ISO + structural validation |

## Status

v0.4 — the target is a BOOTABLE system: base-files (FHS + /etc),
runit-services (init stages + supervised services), a live-boot
initramfs (squashfs + overlayfs) and a real stage-4 hybrid ISO.
Remaining: atomic upgrades + rollback, ed25519 package signing,
installer-to-disk (currently live-only).

After stage 2/3 (or a failed run) unmount the bind mounts that stage 1 left in the
target with `sudo bootstrap/umount-chroot.sh /mnt/mydistro`.

The optional Wayland desktop (`recipes/gui`) is skipped by default; build it with
`WITH_GUI=1 sudo ./stage2.sh /mnt/mydistro` (see `recipes/gui/README.md`).

## Two roots: build root vs. final root

By default the build uses **two roots** instead of installing everything over
the Ubuntu seed:

| root       | path (host)         | path (chroot) | contents |
|------------|---------------------|---------------|----------|
| build root | `TARGET`            | `/`           | seed toolchain + every package (later builds link against it) |
| final root | `TARGET/sysroot`    | `/sysroot`    | **clean** system: only distro packages — no seed files, no `/opt/seed`, no build dirs |

* Stage 2 and 3 install each archive into `/` **and** `nawa --root /sysroot`.
  At the end of each stage the final root is synced (resume-safe), its ld.so
  cache is regenerated, and it is checked for seed/build leaks.
* The rootfs (stage 4) and the ISO (stage 5) are packed from the **final
  root**; the build root is never shipped. Validate the result with `tests/validate-install.sh`.
* `--single-root` restores the old behaviour (one root, ISO from `TARGET`).
  Switching layouts between runs invalidates stage 2 onward automatically
  (recorded in `<state>/layout`).
* Extra disk: the final root adds roughly the size of the installed system
  (a few GB) on top of the build root.

## Self-hosting: the rootfs as the next seed

Stage 4 (`mkrootfs.sh`) packs the finished final root — the exact tree the ISO
squashes — into `mydistro-x86_64-rootfs.tar.zst`, with a `sha256sum -c`
compatible `.sha256` and a `.packages` inventory. Pseudo-fs content, build
scratch and seed leftovers are excluded, and a root that fails the sanity checks
(missing `bash`/`nawa`/`gcc`/libc/db, or `/opt/seed`, `/build`, ... leaked in) is
refused. The archive is re-read after writing and must contain what a consumer
needs.

The next build can use it instead of the Debian-based seed:

```bash
sudo ./build-all.sh --seed-rootfs out/mydistro-x86_64-rootfs.tar.zst \
                    [--seed-rootfs-sha256 <hash from the release notes>] /mnt/mydistro
```

* stage 0 is not needed (the Debian seed is neither built nor used);
* stage 1 verifies the file (zstd frame, `.sha256` sidecar, optional pin),
  unpacks it with numeric ids/xattrs and runs `seed-from-rootfs.sh`, which
  checks the toolchain is really there (gcc, make, python, perl, curl,
  rustc/cargo, ...), **parks the nawa database** (`/var/lib/nawa/seed-local`;
  without that, stage 2 would see every package as installed and build
  nothing), drops stale rollback records, and writes `/opt/seed/env.sh` +
  `/opt/seed/manifest.txt` (which rootfs seeded this build);
* stage 2 then rebuilds the whole graph with the previous build's own
  toolchain and stage 3 proves it again (db ownership of `gcc`/`nawa`, compile +
  run test, ELF scan) — the files left over from the seed are exactly the ones
  *no package owns*, as with the Debian seed;
* the seed's identity (its checksum) is part of stage 1's input fingerprint:
  a different rootfs invalidates stage 1 and everything after it, the same file
  re-downloaded does not.

In CI (`release.yml`) this is automatic: the rootfs is uploaded with every
release, and each run looks for the newest release that carries one
(`scripts/fetch-rootfs-seed.sh`: both assets required, checksum verified, a
mismatch fails the job), falling back to the Debian seed only when no release
has a rootfs yet. `seed: debian` in *Run workflow* breaks the chain on purpose
(e.g. to rebuild from the independent seed); `seed: rootfs` fails instead of
falling back.

## The seed trust boundary (read this before trusting the result)

The bootstrap is **not** a source-only build. The seed (`bootstrap/seed/`)
ships **prebuilt binaries from the host distro** — Debian `.deb` packages
extracted verbatim with `dpkg -x` (gcc, glibc, binutils, make, ...) plus a
**rustup-installed rustc** used to compile NAWA. Trust flows:

* Everything built in stages 2-3 is compiled by the seed's gcc, whose
  provenance is your Debian mirror, not this repository.
* Stage 3 removes `/opt/{seed,cargo,rustup,cross-tools}` and then *proves*
  independence (see the stage contract above) — but the toolchain that
  built the toolchain was still the seed. A trusted bootstrap would require
  a source-built seed (future work, LFS-style stages 0/1).
* A rootfs seed does not remove that boundary, it **moves** it: the first
  release is built from the Debian seed, every later one from the previous
  release's rootfs. The chain is only as trustworthy as the first link and
  every published rootfs (a compromised rootfs would reproduce itself into the
  next one — the classic "trusting trust" problem). Publish the checksums,
  pin them with `--seed-rootfs-sha256`, and rebuild from the Debian seed
  (`seed: debian`) now and then to compare.
* What IS verified today: the seed tarball's integrity (zstd frame + sha256
  sidecar) before it is unpacked; its content manifest
  (`opt/seed/manifest.txt`: exact `.deb` file names, rustc version, host,
  build date) ships inside the tarball and is printed by stage 1; the
  x86_64-only host restriction is checked up front.

## What is verified vs. what is only intended

**Verified by tests on every CI run** (see the test inventory below): resume
and invalidation semantics, the failure/resume contract, the lock, `--wipe`
refusals, `--dry-run` side-effect freedom, seed adoption checksums, the
final-root leak checks, the stage-3 self-hosting proofs against deliberately
poisoned fixtures, and the ISO structural validation (stubbed tooling).

**NOT verified here**: that the produced ISO actually boots. The structural
validation proves the boot-critical members are present in the image — a
boot test needs a VM (the author's runs booted it in QEMU; CI cannot).
A full source build (all 148 recipes, ~hours) is exercised only by the
release workflow, not by CI. The 32 GUI recipes with placeholder sha256
fail loudly at source verification until `scripts/fill-sha256.py` (in faseela-repo)
pins them (by design — never ship an unpinned source).

## Tests

All of these run in CI (`.github/workflows/ci.yml`) and need neither root
nor the real ISO tooling:

```bash
bash -n bootstrap/*.sh scripts/*.sh            # syntax
shellcheck --severity=error bootstrap/*.sh scripts/*.sh
bash tests/test-fetch-recipes.sh             # fetching the recipes from faseela-repo
                                                #  (local fake GitHub); recipe sanity
                                                #  itself runs in faseela-repo's CI
bash tests/test-build-all-mock.sh            # orchestration: 131 checks
                                                # (stamps, input invalidation,
                                                #  resume, lock, wipe, seed)
bash tests/test-final-root.sh                # two-root helpers + the
                                                #  seed-reference ELF scan (22)
bash tests/test-mkiso.sh                     # ISO gate + structural
                                                #  validation, stubbed (27)
bash tests/validate-install.sh               # installer dry validation
bash bootstrap/build-all.sh --dry-run /tmp/x   # end-to-end dry run
```

The real `stage1-3`/`mkiso` need root and a Debian-ish x86_64 host and are
NOT covered by CI — they are covered by the release workflow's full build
and by the author's VM runs.

## Known limitations

* No source-tarball cache across rebuilds (each stage-2/3 run re-downloads;
  `nawa` has a per-package retry, a shared cache is future work).
* Stage scripts other than `build-all.sh` keep no state: running them by
  hand bypasses stamps/input tracking (documented contract — use
  `build-all.sh --from-stage` instead).
* The ISO is structurally validated, never boot-tested in CI (no KVM).
* Stage 2 does not rebuild packages whose recipes changed after install
  (the db records names, not build ids); deliberate procedures:
  `build-all.sh --from-stage 2` for everything, or
  `nawa remove --yes --root / <pkg>` + re-run for one package.
* A seed adopted without a sidecar is trusted by size only (legacy path,
  announced in the log).
