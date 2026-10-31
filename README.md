# faseela

A from-scratch, source-based Linux distribution (Gentoo-style): glibc, gcc, runit, and its
own package manager written in Rust. This repository is the **distribution build system**:
it turns an empty directory into a bootable ISO and a self-hosting rootfs.

```
 nawa              faseela-repo                    faseela  (this repo)
 package manager   recipes + package publishing    build system + CI
 (Rust)            (TOML recipes, signed index)    (bootstrap scripts, ISO, release)
       \                  |                            /
        └── pinned in recipes ── fetched at build time ─┘
                              ▼
        ISO (no GUI / GUI) · rootfs (seed of the next build) · rootfs-min (container image)
```

| Repository | Holds |
|---|---|
| [faseela](https://github.com/mrdevmohamed/faseela) | this repo: the stages that build the system, the ISO, the installer, the release workflow |
| [faseela-repo](https://github.com/mrdevmohamed/faseela-repo) | every package recipe, and the workflow that builds + publishes signed packages |
| [nawa](https://github.com/mrdevmohamed/nawa) | the package manager (`nawa install/build/upgrade/sync/...`) |

## Quick start

```bash
make              # list the tasks
make recipes      # fetch the recipes from faseela-repo
make check        # lint every script + run every test (no root needed)
make dry-run      # plan the whole build at every isolation level, build nothing
sudo make build   # the real build (hours, root, ~30 GB): seed -> stage 1-3 -> rootfs -> ISO
make stages       # which stages are done / failed — re-run `make build` to resume
```

`bootstrap/build-all.sh` is what `make build` calls; use it directly for the full option list
(`--isolation`, `--stage3-world`, `--from-stage`, `--seed-rootfs`, ...). Details: [bootstrap/README.md](bootstrap/README.md).

## How it builds

```
seed ──► stage 1 ──► stage 2 ──► stage 3 ──► stage 4 ──► stage 5 ──► stage 6
Debian    chroot     nawa builds  rebuild     rootfs      ISO         installer
 or the   + verify   the whole    with its    .tar.zst    squashfs    (live → disk)
 previous the seed   recipe graph own tools,  = seed of   + grub
 rootfs   toolchain  into 2 roots seed removed the next    BIOS+UEFI
                                  + self-host  build
                                    proof
```

Each finished stage is stamped with a fingerprint of its inputs, so a re-run after a failure
resumes at the broken stage and never reuses a stale result. See [docs/architecture.md](docs/architecture.md).

## Repository layout

| Path | What lives there |
|---|---|
| `bootstrap/` | the pipeline: `build-all.sh` (driver), `stage1-3[-inner].sh`, `mkrootfs*.sh`, `mkiso.sh`, `initramfs.sh`, `install.sh`, `final-root.sh` (self-hosting checks), `fetch-recipes.sh`, `fetch-nawa.sh`, `seed/` |
| `scripts/` | small tools used by CI and the build: `fetch-rootfs-seed.sh`, `check-sources.py`, `rootfs-closure.py`, `qemu-boot-test.sh`, `ci-report.py` |
| `tests/` | one test script per bootstrap script (stubbed tools, no root), `run-all.sh` for the summary |
| `profiles/` | per-architecture build profiles (CFLAGS, jobs, isolation) |
| `dist/` | `nawa.pub`, the key that signs the published recipes and packages |
| `docs/` | [architecture](docs/architecture.md) · [CI/CD](docs/ci.md) · [NAWA usage](docs/nawa-usage.md) · [boot & install](docs/boot-and-install.md) · [roadmap](docs/roadmap.md) · [build isolation](docs/design/build-isolation.md) · [bootstrap audit (history)](docs/history/bootstrap-audit.md) |
| `.github/workflows/` | `ci.yml` (checks) and `release.yml` (the whole build + release), both ending in a report |
| `recipes/`, `nawa/` | *not in git*: fetched from faseela-repo / nawa by the build |

`bootstrap/` stays flat on purpose: [faseela-repo](https://github.com/mrdevmohamed/faseela-repo)'s package workflow
checks this repo out and calls `bootstrap/enter-root.sh`, `sync-repo.sh` and `build-packages-inner.sh` by path.

## CI / CD

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | push, PR, weekly | lint + every test + `build-all.sh` dry runs; ends with a pass/fail report |
| `release.yml` | tag `v*`, or *Run workflow* | CI, then the whole build, QEMU boot tests, container image, GitHub Release; **always ends with a run report** |

Every run finishes with a **report** on the run page (and as an artifact): verdict, each job with its time,
the failing step and the error lines from the failing build log, and the artifacts. See [docs/ci.md](docs/ci.md).

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

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md): how to run the checks, where a change belongs (this repo, faseela-repo or nawa), and what a PR needs.

## Changes

[CHANGELOG.md](CHANGELOG.md) · [roadmap](docs/roadmap.md)
