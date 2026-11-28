# Booting the ISO and installing to disk

## Booting the ISO

```
grub (BIOS+UEFI)
  └─ kernel + initramfs (static busybox)
       └─ /init: root=UUID=<disk> ?  ── yes → mount disk → switch_root
                 │                        → /usr/lib/systemd/systemd (installed system)
                 └─ no: load storage modules → find FASEELA media
                         → mount /live/rootfs.squashfs
                         → overlayfs (upper = tmpfs, or the
                           FASEELA_PERSIST partition if there is one)
                         → switch_root → /usr/lib/systemd/systemd (live system,
                           boot media stays at /cdrom)
                              └─ systemd (udev, journald, networkd, resolved,
                                 timesyncd, getty) → login on tty1

### Trying it without installing: the `live` user

The live session has an ordinary user, **`live`**, with **no password**: at the login
prompt type `live` and press Enter (the banner says so). It is in `wheel` (and in `seat`,
`video`, `render`, `input`, `audio`, `cdrom` when they exist), `doas` asks it for nothing,
and its home is filled from `/etc/skel`. `root` also has an empty password in the live
session. `faseela-install` is `doas faseela-install` away.

Both accounts exist only in the live session's overlay (made by `/init`, see
`make_live_user` in `bootstrap/initramfs.sh`); the squashfs is untouched. The installer
**removes them from the installed system**: the `live` user, its home, its doas rule and
the banner are deleted and root is locked until you set its password, so an install never
carries a passwordless login over. A disk boot never creates them.

### Ventoy (and other "ISO as a file" boots)

Copy `faseela-*.iso` onto a [Ventoy](https://www.ventoy.net/) stick and pick it in the
Ventoy menu — no `dd`, and one stick holds many ISOs. It works because the initramfs finds
the medium two ways, on every pass of its 15-second wait:

1. **a device that is the ISO**: a CD, a `dd`-written stick, or a device-mapper device
   (`/dev/mapper/*`, `/dev/dm-*`) that Ventoy builds over the ISO file;
2. **an ISO file on a partition**: every partition is mounted read-only, the ISO is found
   (`iso-scan/filename=/path/faseela.iso` or `findiso=` on the kernel command line names it;
   otherwise `*.iso` up to three directories deep, the ones with `faseela` in the name
   first) and loop-mounted. Ventoy's data partition is exFAT by default, so the initramfs
   carries `exfat` and `ntfs3` next to `vfat`/`ext4`. The partition stays mounted at
   `/media/iso-host` in the live system, and `faseela-install` therefore never offers the
   stick as an install target.

**Only media of the same build are used.** `mkiso.sh` stamps one build id into the
initramfs (`/build-id`) and into the image (`/live/build-id`). The kernel and its modules come
from the ISO that Ventoy or GRUB booted, so `/init` mounts only a squashfs whose
`/live/build-id` matches; any other faseela ISO it meets while scanning (an older download in
`/home`, a stale copy on the stick, an ISO from before this check) is skipped with a
`initramfs: skipping ... another build` line. Before this, the first ISO the scan found won,
and a different build's squashfs under the booted kernel left the boot stalled right after
`switch_root -> systemd`. Pin the id with `FASEELA_BUILD_ID`; with `SOURCE_DATE_EPOCH` it is
reproducible, otherwise every build gets its own.

The ISO also carries `/boot/grub/loopback.cfg` (the standard hook for booting an ISO from
GRUB's `loopback`), and `grub.cfg` adds `iso-scan/filename=${iso_path}` when Ventoy sets
`iso_path` (GRUB2 mode). On the same Ventoy stick, from a GRUB prompt:

```
loopback loop (hd0,1)/faseela.iso
set iso_path=/faseela.iso ; set root=(loop) ; configfile /boot/grub/loopback.cfg
```

Persistence: Ventoy's own persistence files are not used; a partition labelled
`FASEELA_PERSIST` (below) still works if one is on another disk or partition of the stick.
Verify a new image the first time on your hardware (BIOS and UEFI, secure boot off — Ventoy
needs its own key enrolled with secure boot on).

Other distros: the saq repository's `saq-live-iso` builds the same kind of ISO (Ventoy,
`live` user) from any root filesystem — see `docs/kernel-initramfs.md`.

### Persistence

Label an ext4 partition `FASEELA_PERSIST` (e.g. on the USB stick, after the ISO
image: `mkfs.ext4 -L FASEELA_PERSIST /dev/sdX3`) and the live system keeps its
changes there; the grub entry "without persistence" (or `nopersist` on the
kernel command line) ignores it. The live session unlocks root and re-applies the
`live` user at every boot, so a root password set in a persistent session does not
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

* **live session leftovers**: removed (see "the `live` user"); root stays locked until the
  password prompt at the end.
* **user**: created with a home and `/bin/bash`, in `wheel` (what `/etc/doas.conf`
  allows) and in `seat`, `video`, `render`, `input`, `audio` when they exist (the GUI's
  `gui-session` package creates these groups). `render` grants access to DRM render
  nodes used by hardware Vulkan/OpenGL drivers. Log in on a text console and run
  `start-sway`.
* **swap**: a file, `/swapfile`, made with `fallocate` + `mkswap` and listed in
  fstab. Hibernation needs a resume offset on the kernel command line, which the
  installer does not set — suspend works, hibernate does not yet.
* **firmware**: the image has `linux-firmware-lite` (GPU, wifi, bluetooth, NICs). The
  rest is `nawa install linux-firmware` once the machine is online.

The installer supports both UEFI (GPT + ESP, removable grub) and BIOS
(MBR), copies the live system with rsync, generates fstab from real
UUIDs, and writes a static grub.cfg using the stable `/boot/vmlinuz` and
`/boot/initramfs.img` aliases. The kernel's normal init selection resolves
`/sbin/init` through merged `/usr` to systemd's `/usr/bin/init` entry point;
SAQ then hands off to `/usr/lib/systemd/systemd`. There is no alternate-init
parameter or legacy init fallback. The aliases point to versioned
kernel/initramfs files and are updated by the Linux package's Nawa hooks. See
[Kernel and initramfs lifecycle](kernel-initramfs.md) for regeneration, hooks
and the current initramfs limitations. Both grub platforms (`i386-pc` and
`x86_64-efi`) are in the image: the `grub` recipe builds them (rel 2).

### Boot screen

When the `faseela-branding` package is in the image, `mkiso.sh` puts its GRUB theme
(`/usr/share/grub/themes/faseela`) on the ISO, and the live menu and the installed
system show the Faseela logo, a night background and a centred menu (BIOS and UEFI alike).
The theme needs GRUB's `unicode.pf2` font: `grub-mkrescue` ships it on the ISO and the
installer copies it from the live media. If either the theme or the font is missing,
the plain text menu is kept and nothing else changes. The theme has no Arabic text,
because GRUB cannot shape Arabic.

## Trying it in QEMU

```
scripts/qemu-run.sh faseela-sway-x86_64.iso --disk faseela.qcow2 --create-disk 20G
#   ... boot, run faseela-install, pick the disk, reboot ...
scripts/qemu-run.sh --boot-disk --disk faseela.qcow2          # from the installed disk
scripts/qemu-run.sh faseela-sway-x86_64.iso --disk faseela.qcow2 --create-disk 20G --uefi   # UEFI path (OVMF)
```

### Automated installed-disk PID 1 acceptance

The ISO login-prompt test above verifies the Live system only. To test the actual
installer, GRUB on the installed disk, SAQ's generated initramfs, and the selected
PID 1, run this on a host with `qemu-system-x86_64`, `qemu-img`, and (for UEFI)
OVMF installed (both the code image and a writable variables template):

```sh
python3 scripts/qemu-installed-boot-test.py faseela-sway-x86_64.iso --firmware both
```

The harness creates two disposable qcow2 disks, boots the ISO in BIOS and UEFI,
logs in to the Live session, runs the real `faseela-install` command, synchronizes
each installed disk, then starts a fresh VM from that disk without the ISO. It
requires both
`FASEELA_BOOT_ACCEPTANCE pid1=systemd` and
`FASEELA_BOOT_ACCEPTANCE system-profile=systemd`. The first marker is read
from the running system's `/proc/1/comm`; the second is emitted only when the
installed Nawa client successfully parses the effective target profile and
reports `init-system = systemd`. This includes the administrator override
merge and rejects malformed profile data; the probe does not grep the TOML
file itself. Reaching a login prompt is not treated as acceptance.

This test sets both `FASEELA_QEMU_BOOT_TEST=1` and `NAWA_INSTALL_TEST=1`.
Only that explicit combination installs the temporary serial probe and skips
interactive password setup; the disposable test installation keeps root locked.
Normal installs do not create the probe, add a serial console, or skip passwords.
Artifacts and full serial logs are kept under `qemu-installed-boot/`. Remove
that directory when the test disks are no longer needed.

Use `--firmware bios` or `--firmware uefi` to isolate one firmware path.
The script locates OVMF_CODE and OVMF_VARS under `/usr/share/OVMF`; set
`OVMF_CODE` and `OVMF_VARS`, or pass `--ovmf-code` and `--ovmf-vars`, when
your host stores them elsewhere. It copies the writable variables template into
the test artifact directory and reuses that isolated copy for the installed-disk
boot. `--dry-run` prints both QEMU command lines without launching a VM.

**If the GUI is slow**, it is almost always one of these (the script warns about the first):

| cause | effect | fix |
|---|---|---|
| no `/dev/kvm` | the whole CPU is emulated | run on a host with KVM (Linux: add yourself to the `kvm` group) |
| `-smp 1` | llvmpipe rasterizes on one thread | `--cpus 4` (the script's default is the host's CPUs, at most 4) |
| `-cpu qemu64` / default | llvmpipe cannot use SSE4/AVX2 | `-cpu host` (the script's default with KVM) |
| mesa without `llvmpipe` | all drawing on `softpipe`, a reference rasterizer | fixed: the `mesa` recipe (rel 2) builds llvmpipe against the new `llvm` recipe |

`--gl` switches to `virtio-vga-gl` (virgl: the host GPU draws). It is experimental here:
needs a QEMU built with OpenGL and the guest mesa's `virgl` driver, which is built.
