# recipes/gui — Wayland desktop (sway)

A minimal graphical session: **sway** (i3-compatible Wayland compositor) on
**wlroots 0.18**, **foot** terminal, DejaVu fonts, **seatd** for seat
management (no systemd/logind), supervised by runit. 33 packages.

> **Status: written offline, not yet built.** These recipes were authored
> without network access, so (a) every `sha256` is an all-zero placeholder and
> (b) versions, URLs and meson option names come from upstream knowledge, not
> from a test build. Expect to bump a version or fix an option here and there
> on the first build — see "First build" below.

## Opt-in

`recipes/gui` is **not** built by `stage2`/`stage3` unless you ask:

```
sudo WITH_GUI=1 ./stage2.sh /mnt/mydistro       # also builds the GUI stack
```

Or build it later on a running system:

```
python3 scripts/fill-sha256.py                          # pin the hashes
nawa --recipes recipes deps gui-session                  # show the build order
for p in $(nawa --recipes recipes deps gui-session); do  # build + install
    nawa --recipes recipes --builddir /build build "$p"
    nawa --root / install /build/out/$p-*.nawa.tar.zst
done
```

(`python3 scripts/check-recipes.py gui-session` prints the same order offline.)

## First build

1. `python3 scripts/fill-sha256.py --dry-run` — lists every URL.
2. `python3 scripts/fill-sha256.py` — downloads and pins hashes. A 404 means
   that version is gone upstream: bump `version` (and `rel`) and re-run.
   Compare the hashes with upstream's published checksums where they exist.
3. Build in order. If a meson option is rejected (`Unknown option`), check
   `meson configure` / the project's `meson_options.txt` and fix the recipe.

## Layout

| group | packages |
|---|---|
| text/fonts | libpng freetype fontconfig harfbuzz fribidi glib pixman cairo pango dejavu-fonts |
| wayland + input | libdrm wayland wayland-protocols xkeyboard-config libxkbcommon libevdev mtdev libinput seatd |
| graphics | mesa (+ python-mako python-markupsafe python-pyyaml python-packaging as build helpers) |
| compositor | hwdata libdisplay-info json-c wlroots sway |
| apps | tllist fcft foot swaybg |
| session | gui-session (seatd runit service, `start-sway`, group setup hook) |

## Using it

`gui-session` creates the `seat`, `video` and `input` groups (hook) and enables
the `seatd` service. Then:

```
usermod -aG seat,video,input <user>     # log out and in again
start-sway                               # from a text console
```

`start-sway` sets `XDG_RUNTIME_DIR`, `LIBSEAT_BACKEND=seatd` and
`WLR_RENDERER_ALLOW_SOFTWARE=1` (see limitations). The same variables are
exported for every login shell by `/etc/profile.d/gui-session.sh`, so a plain
`sway` works too. The kernel recipe enables
DRM (virtio-gpu, bochs, simpledrm) and evdev/HID input; to try it in QEMU use
`-device virtio-vga` (or `-vga std`) and a USB/PS2 keyboard and mouse.

## Limitations / next steps

* **Mesa is software + virgl only** (`softpipe`, `virgl`, built `-D llvm=disabled`).
  Real GPUs (Intel `iris`, AMD `radeonsi`, `llvmpipe`) need LLVM (and libclc)
  — add `llvm` (and `libpciaccess` for `libdrm`'s intel support) and extend
  `-D gallium-drivers`.
* No Xwayland/X11, no D-Bus, so no sway tray (`-D tray=disabled`) and no
  portals. No launcher (sway's default `wmenu-run`) or lock screen — add `wmenu`
  and `swaylock` recipes as needed.
* Wallpaper: `swaybg` is packaged (PNG and solid colours only, no gdk-pixbuf).
  sway's stock `output * bg ...` line is commented out by the sway recipe;
  `gui-session` installs `/usr/share/backgrounds/mydistro/default.png` and the
  drop-in `/etc/sway/config.d/10-wallpaper.conf` that sets it. To change it, edit
  that drop-in or use `~/.config/sway/config`.
* `foot` is built without grapheme clustering and without a utmp backend.
* pure-python helpers (`python-*`) are copied into `site-packages` without
  dist-info metadata, which is enough for mesa's build-time `import` checks.
