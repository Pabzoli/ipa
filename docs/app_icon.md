# App icon

Master artwork: `docs/app_icon_1024.png` (1024×1024, opaque RGB).
Original generation: `docs/Designing_app_icons_for_platforms_2K_20261026215747.jpg` (2048×2048 JPG).
Store assets: `docs/play_store_icon_512.png`.

## Generated targets

| Target | Path | Sizes |
| --- | --- | --- |
| Android legacy | `android/app/src/main/res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | 48 / 72 / 96 / 144 / 192 |
| Android adaptive foreground | `mipmap-*/ic_launcher_foreground.png` | 108 / 162 / 216 / 324 / 432 (108dp canvas) |
| Android adaptive layer | `res/mipmap-anydpi-v26/ic_launcher.xml` | background `@color/ic_launcher_background`, foreground `@mipmap/ic_launcher_foreground` |
| iOS | `ios/Runner/Assets.xcassets/AppIcon.appiconset/*` | 20–1024, 24-bit RGB (no alpha — App Store rejects it) |
| Play Store | `docs/play_store_icon_512.png` | 512 |

macOS / web / Windows icons are intentionally **not** regenerated — the product ships to phones.

## Decisions

- **Adaptive icon, not just legacy PNGs.** Without one, Android 8+ wraps the legacy bitmap in a
  white rounded square and shrinks it. The adaptive foreground keeps the artwork inside the
  standard **72dp safe zone** of the 108dp canvas, so circle / squircle / teardrop masks never
  crop the burst. Verified: at the 66dp minimum visible mask the emblem still fits uncropped.
- **Background is flat `#190C28`**, sampled from the artwork's own edge so the layer edges are
  invisible (`res/values/ic_launcher_background.xml`).
- **Foreground edges are alpha-feathered** (outer 9%) because the artwork carries its own square
  background; the feather melts that square into the flat background instead of showing a seam.
- **iOS uses the full-bleed artwork.** Verified with a 22.37% corner-radius squircle test: 0 emblem
  pixels fall outside the mask.

## Regenerating

Any new master must be **1024×1024 or larger, square, opaque**. Then re-emit the same file sets
above; keep the adaptive foreground at 72dp content inside 108dp with a ~9% alpha feather, and keep
iOS icons alpha-free. `flutter_screenutil`/`flutter build` do not touch these files — a rebuild is
enough to pick them up (`flutter run`; uninstall first if a launcher caches the old icon).
