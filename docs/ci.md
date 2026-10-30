# CI / CD workflows

| workflow | when | what |
|---|---|---|
| `ci.yml` | push, PR, weekly | script checks against the fetched recipes (nawa's own tests run in the nawa repository, recipe validation in faseela-repo) |
| `release.yml` | tag `v*`, manual | whole distribution -> ISOs + rootfs tarballs (+ container image, GitHub Release) |

`packages.yml` (build packages, publish them) lives in
[faseela-repo](https://github.com/mrdevmohamed/faseela-repo), see the end of this file.

## release.yml

```
recipes ─ ci ─ plan ─ core (seed → stage1 → stage2 → stage3 → rootfs) ─┬─ build[iso-nogui]  ─┐
                                                             ├─ build[iso-gui]    ─┼─ release (tags)
                                                             └─ build[rootfs-min] ─┴─ image → ghcr.io
                        boot-test[iso-nogui, iso-gui] (QEMU) ───────┘ gates the release
```

* `recipes` fixes the faseela-repo commit once for the whole run (`recipes_ref`
  input, default `master`); every job fetches exactly that commit with
  `bootstrap/fetch-recipes.sh`, and the release notes name it. To rebuild a
  release from the same recipes, run the workflow with that commit as
  `recipes_ref`.
* `core` is the only long job. Its result (`core-target`, a one-day workflow
  artifact) is what the matrix jobs start from, so GUI/no-GUI/min-rootfs never
  recompile gcc, glibc, rust or the kernel.
* `iso-gui` re-runs `stage2.sh` with `WITH_GUI=1` on a copy of the finished
  core (only `recipes/gui` is compiled), then `mkiso.sh`.
* `rootfs-min` = `bootstrap/mkrootfs-min.sh`: `base-devel` + `nawa` + git, curl,
  ca-certificates, assembled from the build's archives. No kernel, no rust, no GUI.
* `boot-test` boots each ISO in QEMU through grub (KVM when the runner has it)
  and waits for `login:` on the serial console (`scripts/qemu-boot-test.sh`).
  The live grub entries pass `console=ttyS0,115200 console=tty0` and runit's
  stage 1 starts a getty on ttyS0 only when that argument is present, so real
  hardware behaves as before. On failure the serial log and a VGA screenshot
  are uploaded as `qemu-boot-<variant>`. Remove `boot-test` from the `needs`
  of the `release` job if you do not want it to gate releases.
* Two rootfs tarballs, two jobs: `mydistro-x86_64-rootfs.tar.zst` (full, with
  rust) is the **seed** of the next build and keeps its name because
  `scripts/fetch-rootfs-seed.sh` looks for it; `-rootfs-min` is the **build
  environment** (also pushed as `ghcr.io/<owner>/mydistro-build`).
* Manual runs: choose `outputs` (all | iso-nogui | iso-gui | rootfs-min).
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
  (`mydistro-x86_64-rootfs[-min].tar.zst`);
* the shared tooling, checked out from `DISTRO_REF` (default `master`):
  `bootstrap/` (`enter-root.sh`, `sync-repo.sh`, `build-packages-inner.sh`, ...),
  `profiles/` and `scripts/fetch-rootfs-seed.sh`. A change to those files takes
  effect there on its next run.

Clients: `nawa upgrade --repo https://github.com/mrdevmohamed/faseela-repo/releases/download/stable`
(after `nawa trust nawa.pub`).

Limits to know: a release asset is at most 2 GiB and a release holds at most
1000 assets; reverse dependencies of a changed package are not rebuilt
automatically; packages that need rust must be built with `rootfs=seed`.
