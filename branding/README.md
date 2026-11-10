# Faseela visual identity

A *faseela* is the offshoot of a date palm: a small shoot that grows into its own tree.
The mark is that young palm, leaning left (the direction Arabic is written), with a
gold dot at the heart of its crown. Tagline: **Grown from seed.**

| | |
|---|---|
| Night `#0E1A2B` / Dune `#14243A` | grounds, terminal, panels |
| Moon `#F4EBD3` / Sand `#EADFC8` | paper, text on dark |
| Gold `#E6B53A` (`#D9A21B` on light) | the dot, accents |
| Leaf `#5DBB63` (`#2F7D3E` on light) | the fronds, success |

Fonts: **Cairo** (Arabic and display), **Space Grotesk** (Latin headings and UI),
**JetBrains Mono** (terminal, package names).

## Sources

| File | What |
|---|---|
| `mark.tpl.svg` | the bare mark; `@INK@` `@LEAF@` `@GOLD@` are filled in per colour variant |
| `icon.tpl.svg` | the app icon: the mark on a rounded night square |
| `wallpaper.svg` | the default wallpaper (night dunes, crescent moon, the young palm) |
| `build.sh` | exports everything to `branding/out/` (git-ignored) |

```bash
branding/build.sh                       # needs rsvg-convert (librsvg)
branding/build.sh --sync ../faseela-repo   # also refresh faseela-repo's faseela-branding recipe
```

The installed system gets the icon (`hicolor/…/apps/faseela`), the marks and the
wallpaper from the **faseela-branding** package in
[faseela-repo](https://github.com/mrdevmohamed/faseela-repo). After changing a source
here, run `--sync` and bump that recipe's `rel`.

Use the dark mark on light backgrounds, the light mark on dark ones, and the mono mark
for stamps, favicons and anything below 24 px. Keep clear space around the mark of at
least the width of the gold dot, twice.
