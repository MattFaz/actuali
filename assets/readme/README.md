# README assets

Derived images used by the repo's top-level `README.md`. All are generated —
never edit them by hand, re-derive them from the masters instead.

GitHub strips `style` attributes from README HTML, so corner rounding can't be
done with CSS there; it has to be baked into the alpha channel. These copies are
also downscaled, so the README doesn't pull four 1320×2868 PNGs.

## Files

| File | Derived from | How |
|-|-|-|
| `icon.png` | `assets/icons/actuali-appicon-1024.png` | 256×256, 58px rounded corners |
| `view-accounts.png` | `website/public/screenshots/view-accounts.png` | 440×956, 32px rounded corners |
| `add-transactions.png` | `website/public/screenshots/add-transactions.png` | ditto |
| `view-budgets.png` | `website/public/screenshots/view-budgets.png` | ditto |
| `reports-dark-light.png` | `website/public/screenshots/reports-dark-light.png` | ditto |

## Regenerating

Re-run this after replacing a screenshot or the icon master:

```bash
round() {  # round <input> <output> <width> <radius>
  magick "$1" -resize "$3x" \
    \( +clone -alpha extract \
       -draw "fill black polygon 0,0 0,$4 $4,0 fill white circle $4,$4 $4,0" \
       \( +clone -flip \) -compose Multiply -composite \
       \( +clone -flop \) -compose Multiply -composite \) \
    -alpha off -compose CopyOpacity -composite -strip "$2"
}

round assets/icons/actuali-appicon-1024.png assets/readme/icon.png 256 58
for name in view-accounts add-transactions view-budgets reports-dark-light; do
  round "website/public/screenshots/$name.png" "assets/readme/$name.png" 440 32
done
```

The screenshots are the same ones the website and App Store listing use, so
update `website/public/screenshots/` first and re-derive from there.
</content>
