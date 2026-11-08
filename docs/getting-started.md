# Getting started

This page separates two common goals: trying an available Faseela image and working on the distribution itself.

## Try a published image

1. Open the [Faseela releases](https://github.com/mrdevmohamed/faseela/releases).
2. Read the release notes and download an ISO asset that is actually attached to that release. The graphical and non-graphical images are separate outputs when both are published.
3. Boot the ISO on a test machine or in a virtual machine.
4. From the live system, use the installer described in [Booting and installing](boot-and-install.md).

Do not assume every workflow run publishes every image. The release page lists the assets produced by that release.

## Install from the live system

The live image includes `faseela-install`. Run it as root:

```sh
faseela-install
```

With no arguments, the installer guides you through disk selection, hostname, time zone, optional user creation, optional swap, and password setup. It displays the plan and asks you to confirm the target disk before writing to it.

The installer supports non-interactive arguments as well. See [Booting and installing](boot-and-install.md) for the complete example and current limitations.

**Use a disposable disk or virtual machine when testing an installer.** Selecting the wrong disk can destroy existing data.

## Work on the source repository

The commands below are the normal local entry points from the repository root:

```sh
git clone https://github.com/mrdevmohamed/faseela.git
cd faseela

make              # show available tasks
make recipes      # fetch the package recipes
make check        # lint scripts and run the test suite
make dry-run      # preview the build without compiling the distribution
sudo make build   # run the real build into /mnt/faseela
make stages       # inspect stage completion and failures
```

The real build needs root for chroot and mount operations, substantial free disk space (the project README currently estimates about 30 GB), and can take hours. `make check` and `make dry-run` are intended for routine development and do not perform a full distribution build.

The build driver records stage fingerprints and logs outside the target directory. Re-running the same command resumes from the first stage whose inputs are missing or have changed. See [Building Faseela](building-faseela.md) before changing build options or resuming a failed build.

## Understand the repositories

| Task | Repository |
|---|---|
| Add or fix a package recipe | [faseela-repo](https://github.com/mrdevmohamed/faseela-repo) |
| Change Nawa commands, dependency resolution, or package format | [nawa](https://github.com/mrdevmohamed/nawa) |
| Change bootstrap, root filesystem, ISO, installer, or release automation | [faseela](https://github.com/mrdevmohamed/faseela) |

See [Contributing](contributing.md) before opening a pull request.
