# Bootstrap — building the distribution from nothing

The pipeline that turns an empty directory into a bootable ISO of the
distribution. Every stage after the seed is performed by the
distribution's own package manager (DPM).

```
stage 0  seed/build-seed.sh   assemble prebuilt toolchain (gcc, glibc, rustc)
stage 1  stage1.sh            chroot + verify the seed toolchain (it is the temporary toolchain)
stage 2  stage2.sh            DPM builds the FULL recipe graph into the target
stage 3  stage3.sh            self-hosting rebuild (toolchain, or STAGE3_WORLD=1 for all)
stage 4  mkiso.sh             squashfs + initramfs + grub -> bootable live ISO
```

## Boot flow (stage 4 output)

```
grub (hybrid BIOS+UEFI)
  └─ kernel + /boot/initramfs.img (static busybox, built by initramfs.sh)
       └─ /init: insmod storage modules → find the MYDISTRO media
                 (sr/sd/vd/nvme scan) → mount /live/rootfs.squashfs
                 → overlayfs with tmpfs upper → switch_root → /usr/bin/runit
                      └─ /etc/runit/1 (mount, udev coldplug)
                         /etc/runit/2 (runsvdir: getty tty1-4, udevd,
                         dhcpcd, sysklogd, crond) → login on tty1-4
```

## Host requirements

* root for chroot + bind mounts (stages 1-3); stage 4 works as non-root
* stage 4 tools: `squashfs-tools`, `grub-pc-bin`, `grub-efi-amd64-bin`,
  `xorriso`, `mtools` (Debian names) + gcc/make for the initramfs busybox
* ~10 GB free disk, decent network

## Quick start

One command drives the whole pipeline (seed → ISO) with resume, logging
and pre-flight checks:

```bash
cd bootstrap
sudo ./build-all.sh /mnt/mydistro            # seed + stage1-3 + ISO
sudo ./build-all.sh --isolation closure --stage3-world /mnt/mydistro
./build-all.sh --list-stages /mnt/mydistro     # progress after a failure
sudo ./build-all.sh /mnt/mydistro               # re-run: finished stages skipped
```

The equivalent manual invocation of each stage (what build-all.sh does
for you):

```bash
sudo ./seed/build-seed.sh              # -> seed/seed.tar.zst
sudo ./stage1.sh /mnt/mydistro         # unpack seed, chroot, verify seed toolchain
sudo ./stage2.sh /mnt/mydistro         # DPM builds + installs all recipes
sudo ./stage3.sh /mnt/mydistro         # self-hosting rebuild, seed removed
sudo ./mkiso.sh /mnt/mydistro out.iso  # bootable image
```

### build-all.sh specifics

* **state lives outside the target**: `$(dirname TARGET)/.<name>.build/`
  (`stamps/` per-stage completion, `logs/` one timestamped log per run,
  `meta` per-stage timings) — nothing leaks into the squashfs/ISO
* **resume**: finished stages are skipped on re-run; after a failure the
  trap prints the exact command to re-run and the `umount-chroot.sh` hint
* **`--from-stage S`** forces a restart point (stamps from S onward are
  invalidated — S itself re-runs); `--fresh` redoes everything,
  `--wipe` also deletes a previous target, `--dry-run` previews, `--no-iso`
  stops after stage 3
* **pre-flight**: root check, ~10 GB free space, host tools for the stages
  that will actually run (so a missing xorriso cannot waste hours of gcc)
* a hand-built `seed/seed.tar.zst` is adopted on the first run instead of
  re-downloading ~1 GB of toolchain

## What lives where

| File               | Runs     | Purpose                                            |
|--------------------|----------|----------------------------------------------------|
| `build-all.sh`     | host     | one-command driver: stages 0-4, resume + logs      |
| `seed/seed.toml`   | (docs)   | manifest of everything the seed must contain       |
| `seed/build-seed.sh` | host   | assembles + packs the seed                         |
| `stage1.sh`        | host     | unpack seed, mounts, invoke chroot                 |
| `stage1-inner.sh`  | chroot   | prepare chroot, verify seed toolchain (C/C++/Rust) |
| `stage2.sh`        | host     | chroot entry for stage2                            |
| `stage2-inner.sh`  | chroot   | compile DPM with seed rustc, build the full graph  |
| `stage3.sh`        | host     | chroot entry for the self-hosting rebuild          |
| `initramfs.sh`     | host     | static busybox + /init live-boot initramfs builder |
| `mkiso.sh`         | host     | squashfs + grub config + hybrid ISO image          |

## Status

v0.4 — the target is a BOOTABLE system: base-files (FHS + /etc),
runit-services (init stages + supervised services), a live-boot
initramfs (squashfs + overlayfs) and a real stage-4 hybrid ISO.
Remaining: atomic upgrades + rollback, ed25519 package signing,
installer-to-disk (currently live-only).

After stage 2/3 (or a failed run) unmount the bind mounts that stage 1 left in the
target with `sudo bootstrap/umount-chroot.sh /mnt/mydistro`.

The optional Wayland desktop (`recipes/gui`) is skipped by default; build it with
`WITH_GUI=1 sudo ./stage2.sh /mnt/mydistro` (see `recipes/gui/README.md`).
