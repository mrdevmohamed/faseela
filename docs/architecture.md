# Architecture

faseela is a build system: a chain of scripts, each doing one stage, driven by
`bootstrap/build-all.sh`. This page shows how the pieces connect; the stage
contracts and every option are in [bootstrap/README.md](../bootstrap/README.md).

## The three repositories

```
 faseela-repo  ── recipes/ (TOML) ──┐
                                    ▼ bootstrap/fetch-recipes.sh (one commit per run, recorded in .recipes-rev)
 nawa          ── source, pinned ──► faseela ── build-all.sh ──► ISO, rootfs, rootfs-min
                  in a recipe        ▲   (this repo)
                  bootstrap/fetch-nawa.sh    │
 faseela-repo's packages.yml ────────┘ checks this repo out for bootstrap/*, profiles/, scripts/fetch-rootfs-seed.sh
```

## The pipeline

```
seed ─► stage 1 ─► stage 2 ─► stage 3 ─► stage 4 ─► stage 5 ─► (stage 6)
```

| Stage | Driver script | Runs | Produces |
|---|---|---|---|
| 0 seed | `bootstrap/seed/build-seed.sh` or `seed-from-rootfs.sh` | host | a toolchain tarball (Debian + rustup), or the previous release's rootfs turned into one |
| 1 chroot | `stage1.sh` → `stage1-inner.sh` | host → chroot | unpacked, verified seed in the target |
| 2 core | `stage2.sh` → `stage2-inner.sh` | host → chroot | nawa compiled with the seed, then the whole recipe graph built into **two roots** (build root + clean `/sysroot`) |
| 3 self-host | `stage3.sh` → `stage3-inner.sh` | host → chroot | toolchain (or world) rebuilt with the distro's own tools, seed removed, **self-hosting proof** |
| 4 rootfs | `mkrootfs.sh` (`mkrootfs-min.sh`) | host | `mydistro-x86_64-rootfs.tar.zst` (+ `.sha256`, `.packages`) — the seed of the next build |
| 5 ISO | `mkiso.sh` + `initramfs.sh` | host | hybrid BIOS+UEFI live ISO, validated structurally |
| 6 disk | `install.sh` | live system | an installed disk |

Shared helpers: `sync-repo.sh` (copy the repo into the chroot), `enter-root.sh` (run a command in a root),
`ensure-chroot-mounts.sh` / `umount-chroot.sh` (the bind mounts), `rebuild.sh` (incremental rebuild of some recipes),
`final-root.sh` (the two-root functions and the checks below).

## Two roots

Stage 2 installs every package twice: into the **build root** (where later packages compile) and into a clean
`/sysroot` that only ever receives the final packages. `/sysroot` is what is shipped, so a build-only dependency
cannot leak into the ISO by being present on the build machine.

## The self-hosting proof (stage 3)

After the seed toolchain is deleted, `final-root.sh` checks the shipped root:

1. the toolchain still compiles and runs a C program;
2. no ELF file references the seed (`/opt/seed`, `/opt/cargo`, ... in interpreter, `DT_NEEDED`, `RPATH`);
3. every `DT_NEEDED` soname exists inside the root (catches "built fine, `ar` fails at runtime" bugs).

`usr/lib/firmware` is skipped by checks 2 and 3: firmware blobs (e.g. Qualcomm `.mbn`) are ELF files for other
processors and are never run by the dynamic loader.

## Resume and state

The driver keeps its state **outside** the target (`<dir>/.<name>.build/`): a stamp per finished stage holding a
fingerprint of that stage's inputs (scripts, recipes, profiles, options), the run logs with an audit header, and a
lock. Re-running the same command resumes at the first stage whose stamp is missing or whose inputs changed; later
stages are invalidated with it. In CI the target is also cached, so a re-run of a failed job continues too.

## CI

`release.yml` mirrors the pipeline: `core` runs stages 0-4 once; a matrix then derives `iso-nogui`, `iso-gui` and
`rootfs-min` from the finished core; QEMU boots each ISO; the release publishes them. See [ci.md](ci.md).
