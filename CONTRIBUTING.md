# Contributing to faseela

faseela is the **build system** of the distribution. Before you change anything, find out
which repository the change belongs in:

| You want to… | It goes in |
|---|---|
| add or update a package, change a recipe, fix a package's build | [faseela-repo](https://github.com/mrdevmohamed/faseela-repo) |
| change `nawa install/build/upgrade/...` or the recipe format | [nawa](https://github.com/mrdevmohamed/nawa) |
| change how the system is assembled: stages, rootfs, ISO, installer, CI/release | **this repo** |

## Before you open a PR

```bash
make check      # bash -n + ShellCheck + every test; no root, no network needed for most of it
make dry-run    # plan the whole build at every isolation level, build nothing
```

`make check` is what CI runs. ShellCheck and actionlint are used when installed and skipped
otherwise, so install them locally to get the same coverage. `test-rootfs.sh` needs `zstd`.

A real build (`sudo make build`) takes hours and ~30 GB; you do not need to run it for most
changes, but say in the PR if you did.

## Rules of the repo

- **One test per bootstrap script.** A new or changed script in `bootstrap/` or `scripts/`
  gets a `tests/test-<name>.sh` (stubbed tools, no root) and is picked up by `tests/run-all.sh`.
- **`bootstrap/` stays flat.** faseela-repo's package workflow calls
  `bootstrap/enter-root.sh`, `sync-repo.sh` and `build-packages-inner.sh` by path, and
  `scripts/fetch-rootfs-seed.sh` is called by path too. Do not move or rename these without
  changing faseela-repo in the same step.
- **Stage inputs are fingerprinted.** If a script change should invalidate a stage, make sure
  the file is part of that stage's fingerprint in `build-all.sh`
  (see [docs/architecture.md](docs/architecture.md), "Resume and state").
- **Release asset and image names are an interface.** `faseela-x86_64-rootfs.tar.zst`, the ISO
  names and `ghcr.io/<owner>/faseela-build` are consumed by later builds and by other repos.
  Rename them only together with their consumers (the old rootfs name is still accepted by
  `fetch-rootfs-seed.sh` for old releases).
- **Scripts:** `bash`, `set -euo pipefail`, 4-space indent (see `.editorconfig`), quote your
  variables, and keep ShellCheck `--severity=error` clean.
- **Changelog:** add a line under the topmost `Unreleased` heading in
  [CHANGELOG.md](CHANGELOG.md) for anything a user of the ISO or the build would notice.
  Do not rewrite old entries.

## Docs

Architecture, stage contracts and the CI flow live in [docs/](docs/). If you change a stage's
inputs or outputs, update [docs/architecture.md](docs/architecture.md) and
[bootstrap/README.md](bootstrap/README.md) in the same PR.
