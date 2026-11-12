# CI / CD workflows

| workflow | when | what |
|---|---|---|
| `ci.yml` | push, PR, weekly | script checks against the fetched recipes (nawa's own tests run in the nawa repository, recipe validation in faseela-repo); ends with a pass/fail report |
| `release.yml` | tag `v*`, manual | whole distribution -> ISOs + rootfs tarballs (+ container image, GitHub Release); always ends with the run report |

`packages.yml` (build packages, publish them) lives in
[faseela-repo](https://github.com/mrdevmohamed/faseela-repo), see the end of this file.

## The run report

Both workflows end with a report, on the run's summary page and as an artifact:

* **verdict** — ✅ succeeded / ❌ failed / 🚫 cancelled (from the results of every job; skipped jobs are fine);
* **jobs** — each one with result and time, matrix jobs included;
* **where it failed** — the failing step of each failed job, linked to its log;
* **failure details** — for the long jobs, the stage that died, the `ERROR`/`FAILED` lines just before it and the
  last 30 log lines, so the cause is on the page instead of in a 60 MB log;
* **artifacts** — name and size; **facts** — recipes commit, seed, isolation, outputs.

How it is made: `core`, the matrix `build` jobs and `boot-test` write a small excerpt (`scripts/ci-report.py excerpt`)
into their own summary and upload it as `report-*` on failure; the last job `run report` (`needs` everything,
`if: always()`) downloads those and builds the page with `scripts/ci-report.py report` from the GitHub API
(`actions: read`) and `toJSON(needs)`. It is uploaded as the `run-report` artifact (30 days). `ci.yml` does the same
in its `CI passed` job when it runs on its own; inside `release.yml` the release's report covers it.
Tested by `tests/test-ci-report.sh`.

## release.yml

```
recipes ─ ci ─ plan (read flavors.toml) ─ core ─┬─ build[each selected flavor] ─┐
                                               └─ ISO-only boot-test (QEMU) ────┴─ release (tags)
                                                         rootfs-min ─ image → ghcr.io
```

* `recipes` fixes the faseela-repo commit once for the whole run (`recipes_ref`
  input, default: its default branch); every job fetches exactly that commit with
  `bootstrap/fetch-recipes.sh`, and the release notes name it. To rebuild a
  release from the same recipes, run the workflow with that commit as
  `recipes_ref`.
* `core` is the only long job and builds only the **bootstrap flavor**
  (`flavors.toml`: base-devel, nawa, curl, ca-certificates and what builds them).
  Its result (`core-target`, a three-day workflow artifact) is what the matrix
  jobs start from; they never compile anything.
* Every matrix leg runs `bootstrap/mkflavor.sh`: the flavor's packages are
  **installed from the package repository** (faseela-repo, `packages.yml`) into an
  empty root `sysroot-<flavor>`, which `mkiso.sh` / `mkrootfs.sh` then pack.
  `iso-sway` is `iso-nogui` plus `@gui`; `rootfs-min` is base-devel + nawa + git, curl,
  ca-certificates (no kernel, no rust, no GUI). A package the repository lacks stops
  the leg with the list; `plan` warns about it up front
  (`scripts/check-flavor-packages.py`). Fix: run faseela-repo's *Build packages*
  with `flavor:<name>`. Inputs: `pkg_repo`, `flavor_from` (`auto` compiles what is missing).
* **Releases without a tag.** A `v*` tag releases as before. A manual run with `release`
  ticked publishes a GitHub Release too, named `release_tag` (or `build-<date>-r<run>`;
  an existing name is refused). A failed `build` or `boot-test` blocks it, a skipped one
  (`outputs=core`) does not. The release notes list only what the run produced.
* **First setup (no release, no packages yet):** run *Build ISO (CD)* with `outputs=core`
  and `release` → a release holding the seed rootfs; run faseela-repo's *Build packages*
  with `rootfs=seed` and the desired `flavor:<name>` targets (for example
  `flavor:iso-nogui flavor:iso-sway flavor:iso-xfce flavor:rootfs-min`); then run
  *Build ISO (CD)* with `outputs=all` and `release`.
* `verify_reproducible` (dispatch only) rebuilds the core once more and compares
  stage 3 with stage 4 (`bootstrap/verify-reproducible.sh`), report only.
* `boot-test` boots each ISO in QEMU through grub (KVM when the runner has it)
  and waits for `login:` on the serial console (`scripts/qemu-boot-test.sh`).
  The live grub entries pass `console=ttyS0,115200 console=tty0` and runit's
  stage 1 starts a getty on ttyS0 only when that argument is present, so real
  hardware behaves as before. On failure the serial log and a VGA screenshot
  are uploaded as `qemu-boot-<variant>`. Remove `boot-test` from the `needs`
  of the `release` job if you do not want it to gate releases.
* The core job always publishes `faseela-x86_64-rootfs.tar.zst`, the **seed**
  of the next self-hosting build; its name is fixed because
  `scripts/fetch-rootfs-seed.sh` looks for it. Selected `rootfs-*` flavors create
  additional rootfs archives. The `rootfs-min` flavor keeps the established
  `faseela-x86_64-rootfs-min.tar.zst` name and is also pushed as
  `ghcr.io/<owner>/faseela-build`.
* Manual runs: `outputs` is a text input, not a fixed dropdown:
  * `all` discovers every `iso-*` and `rootfs-*` flavor in the pinned `flavors.toml`.
  * `core` builds only the bootstrap seed.
  * One or more exact names (space- or comma-separated), such as `iso-xfce` or
    `iso-xfce iso-sway`, build only those flavors. Any selected `iso-*` flavor is
    automatically packaged as an ISO and added to the QEMU boot-test matrix;
    other explicitly selected flavors are packed as rootfs archives.
  Adding an `iso-*` or `rootfs-*` entry to `flavors.toml` automatically includes
  it in `outputs=all`; no edit to this workflow is needed. GitHub Actions does not
  support choice inputs populated dynamically from a repository file, so the
  input accepts names as text.
  Dispatch runs save the build target to the Actions cache and `resume`
  continues from it after a timeout.

## packages.yml (in faseela-repo)

It lives next to the recipes it builds and publishes to that repository's own
releases (`stable`), with the workflow's `GITHUB_TOKEN`: no token or
`PKG_REPO` variable. Its one secret is `NAWA_SIGN_KEY_B64`
(`base64 -w0 nawa.sec` from `nawa keygen`); `PKG_TAG`, `DISTRO_REPO` and
`DISTRO_REF` are optional variables.

It still depends on THIS repository for

* the build environment: the newest release's rootfs
  (`faseela-x86_64-rootfs[-min].tar.zst`);
* the shared tooling, checked out from `DISTRO_REF` (default `master`):
  `bootstrap/` (`enter-root.sh`, `sync-repo.sh`, `build-packages-inner.sh`, ...),
  `profiles/` and `scripts/fetch-rootfs-seed.sh`. A change to those files takes
  effect there on its next run.

Clients: `nawa upgrade --repo https://github.com/mrdevmohamed/faseela-repo/releases/download/stable`
(after `nawa trust nawa.pub`).

Limits to know: a release asset is at most 2 GiB (ISOs: xz, and `profiles/skip-packages.txt` keeps the full firmware out of the system; the seed rootfs drops kernel/firmware/docs) and a release holds at most
1000 assets; reverse dependencies of a changed package are not rebuilt
automatically; packages that need rust must be built with `rootfs=seed`.
