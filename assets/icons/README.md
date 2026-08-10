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

- `Actuali/Actuali/Assets.xcassets/AppIcon.appiconset/` — three copies of
  `actuali-appicon-1024.png`, one per appearance (see the gap below)
- `website/public/icon.png` — `actuali-appicon-1024.png` verbatim.
  apple-touch-icon and OpenGraph image
- `website/public/favicon.svg` — the master with `rx="230"` corner rounding
  added, since the web has no icon mask to do it for us
- `website/public/favicon.ico` — 16/32/48 rasterised from `favicon.svg`:
  `rsvg-convert -w $s -h $s website/public/favicon.svg -o $s.png` for each size,
  then `magick 16.png 32.png 48.png website/public/favicon.ico`
- `website/src/components/Logo.astro` — the same gradient and path inlined, so
  the header logo costs no extra request. Keep it in sync with `favicon.svg`.

## Known gap

**Dark and tinted appearances are unimplemented.** `AppIcon-Dark.png` and
`AppIcon-Tinted.png` are byte-identical copies of the light icon, which
predates this icon and carried over. Tinted is the one that shows: iOS maps the
image's luminance onto the user's chosen tint, so an opaque full-colour icon
ignores the tint and stands out on a tinted Home Screen. The fix is a grayscale
variant — cheap now that a vector master exists.

## Third-party marks

Do not add Actual Budget's own logo here or ship it in the app, including as an
alternate icon. Actual is MIT licensed, which covers the code but grants no
trademark rights, and Actuali is an unofficial client — using their mark would
imply an affiliation that doesn't exist. See #136 for the discussion.
