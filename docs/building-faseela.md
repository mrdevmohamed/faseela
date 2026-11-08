# Building Faseela

Faseela's build pipeline is driven by `bootstrap/build-all.sh`. The Makefile provides short entry points for common checks and builds; the [bootstrap README](https://github.com/mrdevmohamed/faseela/blob/master/bootstrap/README.md) remains the detailed reference for every option and stage contract.

## Before a full build

From the repository root:

```sh
make recipes
make check
make dry-run
```

- `make recipes` fetches the package recipes from [faseela-repo](https://github.com/mrdevmohamed/faseela-repo).
- `make check` runs shell syntax checks, available lint tools, and the repository test suite.
- `make dry-run` plans the pipeline at each supported isolation level without compiling the distribution.

## Run the build

The Makefile defaults to `TARGET=/mnt/faseela` and `ISOLATION=env`:

```sh
sudo make build
```

To choose another target or isolation level:

```sh
sudo make build TARGET=/mnt/faseela-test ISOLATION=sandbox
```

The supported isolation levels are `none`, `env`, `sandbox`, and `closure`. The selected level is passed to the bootstrap build driver for the stages that support isolation.

Inspect progress or resume after a failure:

```sh
make stages TARGET=/mnt/faseela
sudo make build TARGET=/mnt/faseela
```

The build driver stores stamps, input fingerprints, logs, and its lock outside the target directory. A stage is skipped only when its stamp and recorded inputs are still valid. A changed stage invalidates later stages; re-running the same command is the normal resume path.

## Pipeline stages

| Stage | Purpose | Main result |
|---|---|---|
| 0 — seed | Assemble the temporary build toolchain used to enter the target system | Verified seed archive |
| 1 — chroot | Unpack and verify the seed, prepare mounts, and enter the target | Seed-equipped build root |
| 2 — core | Build Nawa with the seed toolchain, then use it to build the bootstrap flavor into the build root and clean `/sysroot` | Bootstrap toolchain and core packages |
| 3 — self-host | Rebuild the toolchain with Faseela's own tools; optional world rebuilds are controlled separately | Self-hosting checks and rebuilt packages |
| 4 — rootfs | Pack the final root filesystem | `faseela-x86_64-rootfs.tar.zst` and checksum metadata |
| 5 — ISO | Build and structurally validate the live image | Hybrid BIOS/UEFI ISO |

Disk installation is a separate step performed from the live image with `faseela-install`; it is not another host-side bootstrap stage.

## Recipes and pinned sources

Package recipes are not maintained in this repository. `bootstrap/fetch-recipes.sh` obtains a specific revision of [faseela-repo](https://github.com/mrdevmohamed/faseela-repo) and records it in `.recipes-rev`. CI resolves the revision once per release run so jobs use the same recipe set.

The Nawa source used during bootstrap is pinned in the Nawa package recipe in the fetched recipe tree. Bootstrap reads and verifies that pin; there is no separate bootstrap-only Nawa source manifest to keep synchronized.

## How release builds are split

The release workflow separates package creation from image assembly:

1. [faseela-repo](https://github.com/mrdevmohamed/faseela-repo) builds and publishes signed package archives.
2. This repository prepares the core root filesystem.
3. The release workflow assembles selected flavors from the package repository into ISO and rootfs outputs.
4. ISO outputs are boot-tested with QEMU before a tagged release is published.

The workflow can also run a slower core-build path when a suitable previous rootfs seed is not available or when a self-hosting build is requested. See [CI / CD](ci.md) for workflow inputs and behavior.

## Full bootstrap reference

The complete command-line options, host requirements, seed behavior, stage contracts, fingerprint rules, and recovery details are maintained in the [bootstrap README](https://github.com/mrdevmohamed/faseela/blob/master/bootstrap/README.md). Keep that reference in sync whenever the bootstrap interface changes.
