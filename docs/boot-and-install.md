# Booting the ISO and installing to disk

## Booting the ISO

```
grub (BIOS+UEFI)
  └─ kernel + initramfs (static busybox)
       └─ /init: root=UUID=<disk> ?  ── yes → mount disk → switch_root
                 │                        → /usr/bin/runit (installed system)
                 └─ no: load storage modules → find FASEELA media
                         → mount /live/rootfs.squashfs
                         → overlayfs (upper = tmpfs, or the
                           FASEELA_PERSIST partition if there is one)
                         → switch_root → /usr/bin/runit (live system,
                           boot media stays at /cdrom)
                              └─ /etc/runit/1 → runsvdir (getty, udevd,
                                 dhcpcd, sysklogd, crond) → login on tty1-4

### Persistence

Label an ext4 partition `FASEELA_PERSIST` (e.g. on the USB stick, after the ISO
image: `mkfs.ext4 -L FASEELA_PERSIST /dev/sdX3`) and the live system keeps its
changes there; the grub entry "without persistence" (or `nopersist` on the
kernel command line) ignores it. The live session unlocks root with an empty
password at every boot, so a root password set in a persistent session does not
stick.

live session → faseela-install → reboots into the installed disk
```

## Installing to disk (from the live system)

`mkiso.sh` puts the installer into the image as `/usr/sbin/faseela-install`
(it is `bootstrap/install.sh`; no package ships it).

```
# boot the ISO, log in as root, then:
faseela-install
```

With no arguments it asks, step by step: the disk (only whole disks without a
mounted partition are offered, so never the live medium), hostname, time zone
(`Africa/Cairo`, `UTC`, ... — the files under `/usr/share/zoneinfo`), an optional
normal user, and an optional swap file. It prints the plan, asks you to type the
disk name to confirm, and only then writes anything. Then it asks for the new
passwords (the user's, if one was created, and root's).

The same thing without questions:

```
faseela-install /dev/vda --hostname mybox --timezone Africa/Cairo \
    --user mohamed --swap 2G --yes
```

* **user**: created with a home and `/bin/bash`, in `wheel` (what `/etc/doas.conf`
  allows) and in `seat`, `video`, `input`, `audio` when they exist (the GUI's
  `gui-session` package creates the last four). Log in on a text console and run
  `start-sway`.
* **swap**: a file, `/swapfile`, made with `fallocate` + `mkswap` and listed in
  fstab. Hibernation needs a resume offset on the kernel command line, which the
  installer does not set — suspend works, hibernate does not yet.
* **firmware**: the image has `linux-firmware-lite` (GPU, wifi, bluetooth, NICs). The
  rest is `nawa install linux-firmware` once the machine is online.

The installer supports both UEFI (GPT + ESP, removable grub) and BIOS
(MBR), copies the live system with rsync, generates fstab from real
UUIDs, and writes a static grub.cfg whose `root=UUID=` cmdline makes the
initramfs boot straight off the disk. Both grub platforms (`i386-pc` and
`x86_64-efi`) are in the image: the `grub` recipe builds them (rel 2).

## Trying it in QEMU

```
scripts/qemu-run.sh faseela-gui-x86_64.iso --disk faseela.qcow2 --create-disk 20G
#   ... boot, run faseela-install, pick the disk, reboot ...
scripts/qemu-run.sh --boot-disk --disk faseela.qcow2          # from the installed disk
scripts/qemu-run.sh faseela-gui-x86_64.iso --disk faseela.qcow2 --create-disk 20G --uefi   # UEFI path (OVMF)
```

**If the GUI is slow**, it is almost always one of these (the script warns about the first):

| cause | effect | fix |
|---|---|---|
| no `/dev/kvm` | the whole CPU is emulated | run on a host with KVM (Linux: add yourself to the `kvm` group) |
| `-smp 1` | llvmpipe rasterizes on one thread | `--cpus 4` (the script's default is the host's CPUs, at most 4) |
| `-cpu qemu64` / default | llvmpipe cannot use SSE4/AVX2 | `-cpu host` (the script's default with KVM) |
| mesa without `llvmpipe` | all drawing on `softpipe`, a reference rasterizer | fixed: the `mesa` recipe (rel 2) builds llvmpipe against the new `llvm` recipe |

`--gl` switches to `virtio-vga-gl` (virgl: the host GPU draws). It is experimental here:
needs a QEMU built with OpenGL and the guest mesa's `virgl` driver, which is built.
