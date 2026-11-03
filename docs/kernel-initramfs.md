# Kernel and initramfs lifecycle

## Goal

Faseela has two different boot-image use cases, and they must remain separate:

- `bootstrap/initramfs.sh` builds the Live ISO initramfs. It locates the ISO media,
  mounts the SquashFS image and starts the live root.
- [`saq`](https://github.com/mrdevmohamed/saq) builds disk-boot initramfs images
  for installed kernels. It is packaged by the `saq` recipe (in `faseela-repo`)
  and invoked by the Linux package hooks.

The installed system must not depend on a package manager such as dracut or
mkinitcpio merely to regenerate its own boot image.

## Implementation plan

1. **Generic kernel recipe** — broaden x86_64 platform support for graphics,
   network, wireless, audio, Type-C/USB4, sensors, storage and virtual machines.
   Keep boot-critical drivers built in where appropriate and use modules for
   hardware that can be loaded after the initramfs starts.
2. **Installed-system generator** — package `saq`, copy the dependency closure
   of common storage/filesystem modules, include firmware requested by those
   modules, and create a versioned image.
3. **Package lifecycle** — use Nawa's existing `post_install` and
   `post_remove` hooks in the Linux recipe. Nawa invokes `post_install` for
   both a fresh install and an upgrade.
4. **Bootloader integration** — preserve versioned kernel/initramfs pairs and
   use stable `/boot/vmlinuz` and `/boot/initramfs.img` aliases in the
   installer's GRUB configuration.
5. **Validation** — lint and smoke-test the generator (in the saq repository),
   verify the installer's versioned files and aliases, then boot-test the
   installed system under BIOS and UEFI.

## Package and commands

`saq` has its own repository, with its own tests and CI. The package recipe is
in `faseela-repo` and pins one saq commit by sha256:

```
faseela-repo/recipes/boot/saq/recipe.toml
```

The installed command is:

```sh
saq --all --update-default
saq --kernel 6.10 --update-default
saq --prune --update-default
saq --dry-run --all --update-default
saq --root /mnt --kernel 6.10 --update-default   # another root, e.g. a new install
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
A failed generation leaves the previous valid image and aliases intact. On a
filesystem without symlinks (a FAT `/boot`) saq copies the files instead.
The installer copies the Live ISO image as a fallback, then regenerates the
versioned image against the installed root when the root ships `saq`.

## Nawa hooks

The Linux recipe declares:

- `post_install`: `saq --all --prune --update-default` — build images for
  installed kernels and update the default. Nawa uses the same hook after
  upgrades.
- `post_remove`: `saq --prune --update-default` — prune initramfs images whose
  kernel payload is gone, then choose the newest remaining complete
  kernel/image pair.

With `--all`, saq builds each kernel in its own process: a broken old kernel
does not stop the new one from getting an image, but the exit status is then
non-zero so Nawa reports it. A lock keeps two hook runs from racing.

These hooks run after Nawa has committed the corresponding package operation.
A hook failure is reported by Nawa; package files may already have been
committed, so inspect `/boot` and rerun `saq` after resolving the reported
cause.

## What the generator includes

saq reads the target kernel's `modules.dep` and stages the dependency closure
of the modules listed in its `modules.list` (storage, USB, virtio, MMC,
filesystem, device mapper and RAID), decompressing `.ko` files for the BusyBox
`modprobe`. It then lets `depmod` describe exactly what is in the image. It
uses `modinfo -F firmware` to copy only firmware explicitly requested by the
staged modules (globs are expanded, compressed files unpacked) instead of
copying the entire firmware repository.

To add or remove modules on a system, put files in `/etc/saq/modules.d/*.list`
(module names, `#` comments, `!name` to drop a default).

The initramfs resolves `root=/dev/...`, `root=UUID=...` and `root=LABEL=...`
through BusyBox `findfs`; `PARTUUID=`/`PARTLABEL=` work only if that `findfs`
can resolve them, so prefer `UUID=`. It honors `rootfstype`, `rootflags`,
`ro`/`rw` (default `ro`), `rootdelay` (seconds to wait, default 30) and
`rootwait`, and `init=`. `break` / `break=postmount` open a shell before or
after mounting root. It then moves `/dev`, `/proc` and `/sys` and switches to
`/usr/bin/runit`.

The package uses a statically linked BusyBox and the host's cpio/gzip tools
when generating the image; saq refuses to build if BusyBox is not static or
lacks a required applet (`findfs`, `modprobe`, `switch_root`, ...). The same
applets are checked during the BusyBox package build. Images are
reproducible: equal inputs give byte-identical output.

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

The saq smoke test checks what an image contains; it cannot boot one. Boot
tests under QEMU are still required (see below).

## Validation checklist

- [ ] `make check` passes in the saq repository (shellcheck + smoke test).
- [ ] BusyBox is static and contains every required initramfs applet.
- [ ] `nawa build saq` produces an archive with `/usr/sbin/saq` and `/usr/share/saq`.
- [ ] Installing Linux creates `initramfs-VERSION.img` and updates aliases.
- [ ] Upgrading Linux creates the new image before changing the aliases.
- [ ] Removing Linux prunes only images whose matching kernel is absent.
- [ ] A failed generator run preserves the previous default pair.
- [ ] The installed system boots from ext4 by UUID in QEMU BIOS and UEFI.
- [ ] A second kernel can coexist and be selected from its versioned pair.
