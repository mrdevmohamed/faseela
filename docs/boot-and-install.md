# Booting the ISO and installing to disk

## Booting the ISO

```
grub (BIOS+UEFI)
  └─ kernel + initramfs (static busybox)
       └─ /init: root=UUID=<disk> ?  ── yes → mount disk → switch_root
                 │                        → /usr/bin/runit (installed system)
                 └─ no: load storage modules → find MYDISTRO media
                         → mount /live/rootfs.squashfs
                         → overlayfs with tmpfs upper
                         → switch_root → /usr/bin/runit (live system,
                           boot media stays at /cdrom)
                              └─ /etc/runit/1 → runsvdir (getty, udevd,
                                 dhcpcd, sysklogd, crond) → login on tty1-4

live session → sudo install.sh /dev/vda → reboots into the installed disk
```

## Installing to disk (from the live system)

```
# boot the ISO, log in as root, then:
install.sh /dev/vda --hostname mybox
# review the plan, type the disk name to confirm, set the root password,
# reboot without the media
```

The installer supports both UEFI (GPT + ESP, removable grub) and BIOS
(MBR), copies the live system with rsync, generates fstab from real
UUIDs, and writes a static grub.cfg whose `root=UUID=` cmdline makes the
initramfs boot straight off the disk.
