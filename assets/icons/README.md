# Brand icons

Masters for the Actuali icon. Everything else in the repo is a copy — change it
here first, then re-derive the consumers below.

Designed and contributed by Reddit user
[u/bdownz](https://www.reddit.com/user/bdownz/). Adopted in #136.

## Files

| File | What it is |
|-|-|
| `actuali-appicon.svg` | Vector master. 1024×1024, the mark centred on the purple gradient, square with no corner rounding. |
| `actuali-appicon-1024.png` | `actuali-appicon.svg` rendered at 1024×1024, sRGB, opaque, no alpha. What ships as the app icon. |
| `actuali-mark.svg` | The bare mark as supplied, 767.55×708.47, no fill specified — set `fill` at the point of use. |

The mark is an original design in the spirit of Actual's, not Actual's asset.
Their logo is a hairline-stroke asymmetric "A" with a tail; this is a thick,
rounded, symmetric one. See the note at the bottom.

## Consumers

Re-derive these after editing a master:

- `Actuali/Actuali/AppIcon.icon` — Icon Composer document, the app icon iOS
  renders. Holds the mark as SVG plus the gradient as two `display-p3` stops;
  iOS derives light/dark/clear/tinted from it at runtime. Keep the two stops
  equal to the master's endpoints (`#7534FF` → `#3514B4`), or the app icon and
  the website drift apart. Icon Composer allows exactly two stops, so the
  master's 18%/55% midpoints are dropped — they sit within 6/255 of the
  straight line between the endpoints, so the ramp is unchanged in practice.
- `website/public/icon.png` — `actuali-appicon-1024.png` verbatim.
  apple-touch-icon and OpenGraph image
- `website/public/favicon.svg` — the master with `rx="230"` corner rounding
  added, since the web has no icon mask to do it for us
- `website/public/favicon.ico` — 16/32/48 rasterised from `favicon.svg`:
  `rsvg-convert -w $s -h $s website/public/favicon.svg -o $s.png` for each size,
  then `magick 16.png 32.png 48.png website/public/favicon.ico`
- `assets/readme/icon.png` — 256×256 with rounded corners baked into the alpha,
  for the README header (GitHub strips `style`, so CSS can't round it). See
  [`assets/readme/README.md`](../readme/README.md)
- `website/src/components/Logo.astro` — the same gradient and path inlined, so
  the header logo costs no extra request. Keep it in sync with `favicon.svg`.

## Appearances

Closed by the move to Icon Composer. Previously `AppIcon-Dark.png` and
`AppIcon-Tinted.png` were byte-identical copies of the light icon, so tinted
Home Screens ignored the user's tint and the icon stood out. iOS now derives
all appearances from the layers in `AppIcon.icon`.

Render any of them to check a change — renditions are `Default`, `Dark`,
`TintedLight`, `TintedDark`, `ClearLight`, `ClearDark`:

```bash
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Actuali/Actuali/AppIcon.icon --export-image --output-file /tmp/out.png \
  --platform iOS --rendition Dark --width 1024 --height 1024 --scale 1
```

Dark renders the mark in brand purple on near-black rather than white. That is
the automatic derivation, and it is legible; add an explicit dark override in
Icon Composer if a white mark is wanted there.

## Third-party marks

Do not add Actual Budget's own logo here or ship it in the app, including as an
alternate icon. Actual is MIT licensed, which covers the code but grants no
trademark rights, and Actuali is an unofficial client — using their mark would
imply an affiliation that doesn't exist. See #136 for the discussion.
