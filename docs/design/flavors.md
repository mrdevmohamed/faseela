# Flavors: one source of truth, every package built once

## The rule

* **Recipes** (`faseela-repo/recipes`) say how a package is built.
* **`flavors.toml`** (next to them) says which packages make an image.
* **Packages** are built **once**, by `faseela-repo`'s `packages.yml`, from the golden
  build root, and published as a signed repository (release `stable`).
* **faseela** builds only the bootstrap and then **installs** flavors from that repository.

## Pipeline

| step | where | builds / does |
|---|---|---|
| stage 1 | faseela | unpack the seed (Debian, or the previous release's rootfs) |
| stage 2 | faseela | the `bootstrap` flavor, with the seed toolchain |
| stage 3 | faseela | the same set again with our own toolchain, `closure` isolation, seed removed, self-host proofs |
| rootfs | faseela | the result is `faseela-x86_64-rootfs.tar.zst`: the **seed flavor**, seed of the next run |
| packages | faseela-repo | everything else, in the golden root (`packages.yml`, `flavor:<name>`) |
| flavors | faseela | `mkflavor.sh`: install the flavor's packages, then pack (`mkiso.sh` / `mkrootfs.sh`) |

`stage 2` vs `stage 3` differ by design (seed compiler vs ours); the fixed-point check is
`stage 3` vs `stage 4` (`verify-reproducible.sh`).

## First setup, and releases without tags

The pipeline needs a release that carries the seed rootfs before `packages.yml` can build
anything, and packages before a flavor can be installed. Break the circle once:

1. faseela, *Build ISO (CD)*: `outputs=core`, `release` ticked → release with the seed rootfs.
2. faseela-repo, *Build packages*: `rootfs=seed`, `packages = flavor:iso-nogui flavor:iso-sway flavor:iso-xfce flavor:rootfs-min`.
3. faseela, *Build ISO (CD)*: `outputs=all`, `release` ticked → the full release.

A release is made by a manual run (`release`, optional `release_tag`) or by a `v*` tag.

## Users

`nawa install foo` takes the binary from the repository; `nawa install --from build foo`
builds the same recipe locally (Gentoo style). There are no per-package options (no USE
flags): a package has one build, so the repository and the cache key stay simple.

## Known follow-ups

* nawa is Rust, so the bootstrap closure contains `rust` and `cmake`. A pinned static
  `nawa` release binary (musl) would shrink it; it needs a published nawa release.
* A package's archive is only as new as the recipes it was built from: after a change to
  `base-devel` (glibc, gcc) rebuild what depends on it before cutting a release.
