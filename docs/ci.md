# CI / CD workflows

| workflow | when | what |
|---|---|---|
| `ci.yml` | push, PR, weekly | script and recipe checks (nawa's own tests run in the nawa repository) |
| `release.yml` | tag `v*`, manual | whole distribution -> ISOs + rootfs tarballs (+ container image, GitHub Release) |
| `packages.yml` | push touching `recipes/**`, manual | build packages, publish them to the separate package repo |

## release.yml

```
ci ─ plan ─ core (seed → stage1 → stage2 → stage3 → rootfs) ─┬─ build[iso-nogui]  ─┐
                                                             ├─ build[iso-gui]    ─┼─ release (tags)
                                                             └─ build[rootfs-min] ─┴─ image → ghcr.io
                        boot-test[iso-nogui, iso-gui] (QEMU) ───────┘ gates the release
```

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

## packages.yml

Setup (repository settings of THIS repo):

| kind | name | value |
|---|---|---|
| variable | `PKG_REPO` | `owner/name` of the packages-only repository |
| variable | `PKG_TAG` | optional, release tag used as the repo (default `stable`) |
| secret | `PKG_REPO_TOKEN` | fine-grained token, Contents read+write on `PKG_REPO` only |
| secret | `NAWA_SIGN_KEY_B64` | `base64 -w0 nawa.sec` from `nawa keygen` |

Clients: `nawa upgrade --repo https://github.com/<PKG_REPO>/releases/download/stable`
(after `nawa trust nawa.pub`).

Limits to know: a release asset is at most 2 GiB and a release holds at most
1000 assets; old versions stay in the repo until someone prunes them; reverse
dependencies of a changed package are not rebuilt automatically; packages
that need rust must be built with `rootfs=seed`.
