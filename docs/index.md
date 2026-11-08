# Faseela Linux

Faseela is a source-based Linux distribution built around **glibc**, **GCC**, **runit**, and **Nawa**, its package manager written in Rust.

This repository contains the distribution build system: the bootstrap pipeline, root filesystem and ISO assembly, installer, and release automation. Package recipes and package publishing live in separate repositories.

## The project at a glance

| Repository | Responsibility |
|---|---|
| [faseela](https://github.com/mrdevmohamed/faseela) | Bootstrap and build pipeline, system assembly, installer, CI, and releases |
| [faseela-repo](https://github.com/mrdevmohamed/faseela-repo) | Package recipes, package builds, and signed package repository |
| [nawa](https://github.com/mrdevmohamed/nawa) | Rust package manager: source builds, repository installs, upgrades, and service commands |

The repositories are separate on purpose. A package recipe belongs in `faseela-repo`; a change to package-manager behavior belongs in `nawa`; a change to how Faseela is assembled belongs here.

## Core design

- **Source-based packages:** recipes describe how software is built; published binary archives can also be installed from the signed package repository.
- **glibc and GCC:** the current x86_64 toolchain profile uses the GNU C Library and GCC.
- **runit:** Faseela uses runit for system initialization and service supervision.
- **Nawa:** package operations and package lifecycle hooks are managed by Faseela's package manager.
- **Rebuildable images:** the build pipeline produces a full root filesystem and bootable live ISO images.

## Choose where to start

- **Trying Faseela:** read [Getting started](getting-started.md), then [Booting and installing](boot-and-install.md).
- **Managing software:** read [Nawa usage](nawa-usage.md).
- **Building the distribution:** read [Building Faseela](building-faseela.md) and the [architecture overview](architecture.md).
- **Understanding boot:** read [Kernel and initramfs](kernel-initramfs.md).
- **Contributing:** read [Contributing](contributing.md).

## Build outputs

Depending on the selected release workflow outputs, a release can include:

- `faseela-x86_64.iso` — live ISO without the graphical flavor.
- `faseela-gui-x86_64.iso` — live ISO with the graphical flavor.
- `faseela-x86_64-rootfs.tar.zst` — full root filesystem, used as the seed for a later build.
- `faseela-x86_64-rootfs-min.tar.zst` — smaller build/container root filesystem.

Check the assets attached to the specific [GitHub release](https://github.com/mrdevmohamed/faseela/releases). A manually dispatched run may publish only the outputs selected for that run.

## Project status

Faseela is actively developed. The [roadmap](roadmap.md) records implemented work and remaining items. A checked item describes the state recorded in the repository; it does not replace testing a particular release on your hardware.

## Bootstrap transparency

The build starts from a prepared seed toolchain. The current seed builder uses prebuilt Debian packages and Rust tooling; the seed itself is not a claim that every component is compiled from source starting with an empty machine. Subsequent bootstrap stages use the target system's package manager and perform self-hosting checks. See [the architecture](architecture.md) and the [bootstrap reference](https://github.com/mrdevmohamed/faseela/blob/master/bootstrap/README.md) for details.
