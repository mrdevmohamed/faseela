# Kernel and initramfs lifecycle

## Goal

Faseela has two different boot-image use cases, and they must remain separate:

- `bootstrap/initramfs.sh` builds the Live ISO initramfs. It locates the ISO media,
  mounts the SquashFS image and starts the live root.
- `faseela-mkinitramfs` builds disk-boot initramfs images for installed kernels.
  It is installed as `faseela-initramfs` and is invoked by the Linux package hooks.

The installed system must not depend on a package manager such as dracut or
mkinitcpio merely to regenerate its own boot image.

## Implementation plan

1. **Generic kernel recipe** — broaden x86_64 platform support for graphics,
   network, wireless, audio, Type-C/USB4, sensors, storage and virtual machines.
   Keep boot-critical drivers built in where appropriate and use modules for
   hardware that can be loaded after the initramfs starts.
2. **Installed-system generator** — package `faseela-mkinitramfs`, copy the
   dependency closure of common storage/filesystem modules, include firmware
   requested by those modules, and create a versioned image.
3. **Package lifecycle** — use Nawa's existing `post_install` and
   `post_remove` hooks in the Linux recipe. Nawa invokes `post_install` for
   both a fresh install and an upgrade.
4. **Bootloader integration** — preserve versioned kernel/initramfs pairs and
   use stable `/boot/vmlinuz` and `/boot/initramfs.img` aliases in the
   installer's GRUB configuration.
5. **Validation** — syntax-check the generator, verify the installer's
   versioned files and aliases, then boot-test the installed system under
   BIOS and UEFI.

## Package and commands

The package recipe is:

```
recipes/boot/faseela-initramfs/recipe.toml
```

The installed command is:

```sh
faseela-mkinitramfs --all --update-default
faseela-mkinitramfs --kernel 6.10 --update-default
faseela-mkinitramfs --prune --update-default
faseela-mkinitramfs --dry-run --all --update-default
```

Images are stored as:

```
/boot/vmlinuz-VERSION
/boot/initramfs-VERSION.img
```

The stable aliases are:

```
/boot/vmlinuz        -> vmlinuz-VERSION
/boot/initramfs.img  -> initramfs-VERSION.img
```

The aliases are switched only after a complete image is created and checked.
A failed generation leaves the previous valid image and aliases intact.
The installer copies the Live ISO image as a fallback, then regenerates the
versioned image against the installed root when the generator package exists.

## Nawa hooks

The Linux recipe declares:

- `post_install`: build images for installed kernels and update the default.
  Nawa uses the same hook after upgrades.
- `post_remove`: prune initramfs images whose kernel payload is gone, then
  choose the newest remaining complete kernel/image pair.

These hooks run after Nawa has committed the corresponding package operation.
A hook failure is reported by Nawa; package files may already have been
committed, so inspect `/boot` and rerun the generator after resolving the
reported cause.

## What the generator includes

The tool reads the target kernel's `modules.dep`, recursively stages the
dependency closure of common storage, USB, virtio, MMC, filesystem, device
mapper and RAID modules, and decompresses compressed `.ko` files for the
BusyBox initramfs modprobe applet. It uses `modinfo -F firmware` to copy only
firmware explicitly requested by the staged modules instead of copying the
entire firmware repository.

The initramfs resolves `root=/dev/...`, `root=UUID=...`,
`root=LABEL=...` and `root=PARTUUID=...`. It honors `rootfstype`,
`rootflags`, `rootdelay` and `rootwait`, mounts the real root, moves
`/dev`, `/proc` and `/sys`, and switches to `/usr/bin/runit`.

The package uses a statically linked BusyBox and the host's cpio/gzip tools
when generating the image. Required BusyBox applets are checked during the
BusyBox package build.

## Current limitations

This first disk-initramfs implementation loads device-mapper, dm-crypt and
software RAID modules, but it does **not** yet unlock LUKS volumes, activate
LVM volume groups or assemble degraded/complex mdraid arrays. Those need
their userspace tools and an explicit initramfs hook/configuration contract.
Network-root boot and encrypted-root recovery are also outside this first
implementation. Do not advertise those configurations as supported until
they have dedicated boot tests.

Firmware not present in the installed `linux-firmware` packages is reported
but cannot be synthesized by the generator. A driver may therefore load while
the hardware still remains unavailable until its firmware package is installed.

## Validation checklist

- [ ] `bash -n` passes for `faseela-mkinitramfs`.
- [ ] BusyBox is static and contains every required initramfs applet.
- [ ] `nawa build faseela-initramfs` produces an archive with the generator.
- [ ] Installing Linux creates `initramfs-VERSION.img` and updates aliases.
- [ ] Upgrading Linux creates the new image before changing the aliases.
- [ ] Removing Linux prunes only images whose matching kernel is absent.
- [ ] A failed generator run preserves the previous default pair.
- [ ] The installed system boots from ext4 by UUID in QEMU BIOS and UEFI.
- [ ] A second kernel can coexist and be selected from its versioned pair.
