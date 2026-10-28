# Light Mode — Implementation Plan

Status: **Phases 1–2 in progress** (see the status table at the end).
Owner: app client only. No Firestore, rules, or Cloud Function changes.

---

## 1. Goal

Add a **System / Light / Dark** appearance control to Profile → Settings, persisted
device-locally, without touching the 1,470 `AppColors.*` call sites across 77 files.

Non-goals:

- No per-account sync (device-local preference).
- No changes to economy, auth, or `firestore.rules`.
- No migration of the app to `Theme.of(context)` / `ThemeExtension` in this pass
  (documented as a later option, §10).

---

## 2. Decisions (agreed)

| # | Decision |
|---|---|
| 1 | Control offers **System / Light / Dark**, default **System** for fresh installs. |
| 2 | **Existing installs stay dark** until the user opts in (seeded on first run, §5.3). |
| 3 | **Full coverage before the control is user-visible.** During build-out it is hidden behind a debug-only flag. |
| 4 | Persistence is **device-local `SharedPreferences`** (key `theme_mode`). |

---

## 3. What the codebase looks like today

| Fact | Number |
|---|---|
| Dart files / LOC under `lib/` | 116 / ~42,800 |
| `AppColors.*` references | **1,470 across 77 files** (80 import `app_theme.dart`) |
| `AppColors` declaration | every member is `static const` |
| `AppTypography.*` | `static final` — resolves `AppColors.textPrimary` **once**, at first access |
| `Theme.of(context)` in app code | **1** |
| Raw `Color(0x…)` literals | 110 (36 in `app_theme.dart`, 30 in `coin_earn_animation.dart`, ~44 elsewhere) |
| `Colors.white` / `Colors.black` | 49 |
| `const` lines referencing theme-varying tokens | **23** (11 are `Divider(color: AppColors.divider)`) |
| `MaterialApp` wiring | `theme: AppTheme.dark` only; no `darkTheme`, no `themeMode` |
| Status bar | `SystemChrome.setSystemUIOverlayStyle` called **once** in `main()` with `Brightness.light` |

Static-capture audit (requested during planning): a full scan of `lib/` for
`static final` / top-level `final` declarations whose initializer references
`AppColors` found **only `AppTypography` (11 styles)**. There are **no State
fields caching a colour** — the only `Color`-typed member found is the
`Color _accent(String)` method in `anime_select_page.dart`, which is a function.
Locals that capture `AppColors` live inside `build` and are re-derived on rebuild.

---

## 4. Architecture: brightness-aware token set

Keep every call site as `AppColors.surface`; swap the palette underneath.

```
ThemeProvider (SharedPreferences + platform brightness)
        │  resolvedBrightness
        ├──► AppColors.use(brightness) ──► kLightPalette | kDarkPalette
        │                                        │
        │        AppColors.*  AppTypography.*  AppDecorations.*  AppTheme.light/dark
        │                                        │
        └──► all 1,470 existing call sites (unchanged)
```

### 4.1 `AppPalette` + two const palettes

`lib/core/theme/app_theme.dart` gains:

- `AppPalette` — an immutable class holding only the values that change per theme:
  `surface`, `surfaceAlt`, `surfaceDim`, `divider`, `textPrimary`, `textSecondary`,
  `textMuted`, `locked`, `primaryText`, `successText`, `warningText`, `errorText`,
  `heroGradient`, `cardGradient`, `shadow`, `overlayScrim`.
- `kDarkPalette` / `kLightPalette` — `const` instances.
- `AppColors` becomes a thin façade: `static Color get surface => _palette.surface;`
  plus `AppColors.use(Brightness)`, `AppColors.reset()` (tests), `AppColors.isDark`.

**Brand tokens stay `static const`** — `primary`, `secondary`, `accent`, `correct`,
`wrong`, `amber`, the win/lose/draw gradients, and the extended palette. They are
identical in both themes, so the 20 `const` sites that use only those keep compiling,
and the diff stays at 23 mechanical `const` removals instead of a rewrite.

New tokens exist because a single colour cannot serve both fill and text roles:

| Token | Use | Dark | Light |
|---|---|---|---|
| `primaryText` | brand red as small text / link | `#E63946` | `#C21F30` |
| `successText` | green glyphs and labels | `#38EF7D` | `#0B7A45` |
| `warningText` | amber glyphs and labels | `#F4A261` | `#B45309` |
| `errorText` | red glyphs and labels | `#E63946` | `#C1121F` |

`#38EF7D` on white is ~1.8:1 — the vivid value stays for fills, tints and glows;
the `*Text` values are used wherever the colour is a glyph or label.

### 4.2 `AppTypography` becomes getters

`static final` bakes the dark colour in at first access, so it must become
`static TextStyle get heading1 => TextStyle(... AppColors.textPrimary ...)`.
No cache: `TextStyle` has value equality, so Flutter's text layout cache still hits,
and a palette swap can never leave a stale cached style behind.

### 4.3 `AppDecorations` stays getter-based

Already getters — only the inner `const` has to go so `heroGradient` /
`cardGradient` / `divider` resolve at call time.

### 4.4 `AppTheme.light` + `AppTheme.dark` from one builder

`AppTheme.dark` keeps its name (used by `test/app_card_test.dart`); `AppTheme.light`
is added and `AppTheme.forBrightness(b)` dispatches. Both come from a private
`_build(Brightness)` so the appBar / input / card / snackbar / button themes cannot
drift apart. `AppTheme.*` stays side-effect free; only the app root calls
`AppColors.use`, which keeps widget tests independent.

---

## 5. Theme state and wiring

### 5.1 `ThemeProvider`

New `lib/core/providers/theme_provider.dart`, modelled on `SoloDifficultyProvider`:

- `ChangeNotifier` + `WidgetsBindingObserver` (for `didChangePlatformBrightness`).
- `ThemeMode _mode`, `Brightness _platformBrightness`, `resolvedBrightness` getter.
- `setMode(ThemeMode)` → apply palette + system chrome → `notifyListeners()` →
  persist best-effort in `SharedPreferences` (failures are logged, in-memory wins).
- `static Future<ThemeProvider> load()` — reads the pref before `runApp`.
- `dispose()` removes the observer.

### 5.2 Root wiring (`lib/main.dart`)

1. Read the preference **before** `runApp` (main already awaits Firebase / App Check /
   AdMob), so the first Flutter frame is already in the right theme — no dark→light flash.
2. Register `ChangeNotifierProvider(create: (_) => themeProvider)` in the existing
   `MultiProvider`.
3. In `AnimeQuizApp.build`: `watch` the provider, resolve brightness,
   `AppColors.use(brightness)`, `theme: AppTheme.forBrightness(brightness)`,
   `themeAnimationDuration: Duration.zero` (the static palette cannot lerp with
   `AnimatedTheme`, so a 200 ms crossfade would visibly tear).
4. `SystemChrome` overlay style applied from the resolved brightness, at startup and
   on every change (§6).

### 5.3 Existing users stay dark

`ThemeProvider.load()`:

```
if prefs['theme_mode'] exists        -> parse it
else if prefs has any key at all     -> ThemeMode.dark   (existing install, seeded)
else if control is hidden (release)  -> ThemeMode.dark   (no way to switch back yet)
else                                 -> ThemeMode.system (fresh debug install, seeded)
```

The read happens as the **first** `SharedPreferences` access in `main()`, before any
service can write a key. Known limitation: a returning user who never triggered a
pref write (never changed difficulty, never seen a Monday announcement) is
indistinguishable from a fresh install and lands on System — but only in a debug
build, because the release branch above forces dark until the control ships. If the
heuristic ever matters after launch, replace it with an explicit install marker.

### 5.4 Hidden flag

```dart
const bool kThemeControlEnabled =
    kDebugMode && bool.fromEnvironment('THEME_CONTROL', defaultValue: true);
```

The Appearance section in Settings renders only when this is true, so it exists in
debug builds (where the pilot is verified) and can never appear in a release until
the flag is flipped in Phase 4. `--dart-define=THEME_CONTROL=false` hides it even in
debug.

### 5.5 Forcing a full rebuild on toggle

Most widgets read `AppColors` directly and never call `Theme.of(context)`, so a
provider notify rebuilds `AnimeQuizApp` and the `ThemeData`, but not the route
content below it.

**Why a keyed root does not work here.** Wrapping `MaterialApp` in
`KeyedSubtree(key: ValueKey(brightness))` does force the root subtree to be replaced,
but `MaterialApp` is configured with the app-wide `navigatorKey` (`appNavigatorKey`,
used by `NotificationService`). When the old subtree is deactivated and the new one
is inflated in the same frame, Flutter **re-takes the `Navigator` element through
that global key**, so `NavigatorState` and every mounted route survive. Route content
is then rebuilt only if something marks it dirty — and `const` screens
(`const HomePage()` and friends) are skipped by `updateChild` because the widget
instance is identical. Net effect: the theme changes but the visible screen keeps the
old palette.

**Mechanism used instead.** After the palette is swapped, a post-frame pass marks
every element dirty:

```dart
void rebuildAllElements() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return;
  void mark(Element e) {
    e.markNeedsBuild();
    e.visitChildren(mark);
  }
  mark(root);
}
```

Called from `addPostFrameCallback` (never during build, so
`markNeedsBuild`'s assertions hold). It rebuilds `const` widgets too, preserves the
navigator stack, scroll positions and provider state, and costs one full frame on a
rare user action. Ordering: `setMode` applies the palette **before** notifying (so the
frame that paints the new `ThemeData` already has the new palette), then the
post-frame pass fixes every widget that did not rebuild. The same pass runs after a
platform-brightness change in System mode.

If the app later migrates to `Theme.of(context)`, this pass and the static palette
both disappear.

---

## 6. System chrome (status bar, Android nav bar, splash)

- New `lib/core/theme/app_system_ui.dart`: `applySystemUiOverlay(Brightness)` sets
  `statusBarColor: transparent`, `statusBarIconBrightness` (Android) and
  `statusBarBrightness` (iOS, inverted) from the theme, plus
  `systemNavigationBarColor: palette.surfaceDim` and
  `systemNavigationBarIconBrightness`.
- Called (a) in `main()` right after the preference read, **before `runApp`**, so the
  splash frame has the correct icons and nav bar even though no provider exists yet;
  and (b) on every mode/brightness change.
- Native launch window (`android/app/src/main/res/drawable*/launch_background.xml`)
  still follows the **OS** theme, not the in-app setting. A user whose OS is light but
  who selects Dark sees a brief white launch window before the first Flutter frame.
  Accepted for this pass; optional native follow-up: pin both `values/` and
  `values-night/` launch backgrounds to `#16161F` (dark-branded launch, reverse flash
  for light-mode users), or add a native marker read.

---

## 7. Light palette (starting values — tune on device)

| Token | Dark | Light |
|---|---|---|
| `surfaceDim` (scaffold) | `#16161F` | `#F6F5F8` |
| `surface` (cards) | `#1E1E2E` | `#FFFFFF` |
| `surfaceAlt` | `#252535` | `#F1EFF6` |
| `divider` | `#2E2E42` | `#E4E1EC` |
| `textPrimary` | `#F8F8FF` | `#191923` |
| `textSecondary` | `#B0B0CC` | `#55556B` |
| `textMuted` | `#6B6B8A` | `#74748A` |
| `locked` | `#6B6B8A` | `#8A8AA0` |
| `heroGradient` | `#1D1D2C → #2D1B3D → #1A0A2E` | `#FDF4F5 → #F6F1FB → #FFF8F2` |
| `cardGradient` | `#1E1E2E → #252540` | `#FFFFFF → #FAF8FD` |
| `shadow` | `#33000000` | `#14000000` |
| `overlayScrim` | `#99000000` | `#66000000` |

Rules:

1. **Light mode is not inverted dark.** Off-white scaffold + white cards gives depth
   without the flat all-white look; hero gradients become a soft brand wash.
2. **Contrast ≥ 4.5:1** for every text and icon that carries meaning. Verify each
   `*Text` token with a checker before Phase 4.
3. **On-media stays dark.** White text and black scrims over anime artwork, share
   cards and exported images are brand-locked and must not be "fixed".

---

## 8. Phases

### Phase 1 — Token layer + theme state + hidden toggle (current)

- [x] `AppPalette`, `kDarkPalette`, `kLightPalette`, `AppColors` façade.
- [x] `AppTypography` → getters; `AppDecorations` → palette-driven.
- [x] `AppTheme.light` / `AppTheme.forBrightness` from one `_build`.
- [x] Fix the 23 `const` sites.
- [x] `ThemeProvider` (+ seeding, platform-brightness observer, rebuild pass).
- [x] `main.dart` wiring: pre-runApp read, provider, zero theme animation, chrome.
- [x] `app_system_ui.dart` for status bar + Android nav bar.
- [x] Hidden, debug-gated Appearance card in Settings.
- [x] Pilot: `home_page.dart` + the solo quiz question screen audited in light mode
      (`questions_page`, `question_card`, `option_tile`, `quiz_header`,
      `timer_section`). Shared `AppCard` shadow now has a light variant.

**Gate (go/no-go):** on a debug build, toggle System → Light → Dark from Settings and
confirm (a) the whole screen, including the bottom nav and pushed routes, repaints
immediately, (b) the Settings screen keeps its scroll position and route, (c) status
bar and nav bar icons flip, (d) restarting the app restores the last mode with no
flash. **Stop and report before Phase 3.**

### Phase 2 — Settings UI (unhide)

- Remove the `kThemeControlEnabled` gate once Phase 3 coverage is signed off.
- Final copy: section `Appearance`, options `System` / `Light` / `Dark`.

### Phase 3 — Screen-by-screen audit

Status: **complete** — every hit classified, `flutter analyze` at 0 errors, `flutter test`
140/140. Per-group gates were run (analyze + test after each group).

Cross-cutting fixes that came out of the audit:

1. **`AppColors.readable(Color)`** — maps a vivid fill/brand colour to its legible
   glyph variant (`correct`/`win` → `successText`, `wrong`/`lose` → `errorText`,
   `primary` → `primaryText`, `skyBright` → `secondary`, `silver` → `textMuted`,
   `amber`/`accent`/`gold`/`coinGold`/`draw`/`bronze`/`rival` → `warningText`).
   Identity in dark mode, so using it never changes the dark palette. This is how
   status colours that arrive through widget parameters (StatChip, RewardBlock,
   achievement defs, podium colours) stay readable without a second parameter.
   A debug-only `assert` logs (once per colour) any colour that reaches the
   function with **no** mapping while the light palette is active, so new call
   sites surface during QA instead of silently shipping a vivid glyph. The whole
   check is stripped from release builds.
2. **Snackbars are inverse-surface in both themes** — `snackBarTheme` now uses a
   fixed dark bar with white content. Without this, every
   `SnackBar(backgroundColor: AppColors.wrong)` inherited `textPrimary`
   (near-black in light mode) on brand red.
3. **`AppColors.successSurface`** (`#0E7A43`) for success snackbars — white on the
   vivid `correct` mint was ~1.8:1 in *both* themes; dark green fixes the pre-existing
   contrast bug.
4. **`withOpacity` → `withValues`** across the audited files (88 sites). No visual
   change; the deprecation count went 96 → 6 (the remaining 6 are `RawKeyboard`).
5. **Deliberately brand-locked** (verdict `brand` / `media`, no change):
   anime-poster gradients and scrims, image-overlay white text, main-(red)-button
   foregrounds, `share_card.dart`, `coin_earn_animation.dart`, `LinearGradient`
   stops, and `primarySoft`/`primaryBorder` pre-baked tints.

| # | Group | Files | Result |
|---|---|---|---|
| 1 | Shell | 2 | 5 status-as-glyph → `errorText`/`successText` |
| 2 | Auth | 2 | error-snackbar text white, link → `primaryText`, 2 → `errorText` |
| 3 | Home | 4 | 31 `withOpacity`, 11 amber/accent glyphs, shared shadow split |
| 4 | Quiz | 12 | 19 `withOpacity`, 15 glyphs, purple text variant, difficulty pill |
| 5 | Multiplayer | 10 | 44 glyph wraps, 3 success snackbars, gold/tag text |
| 6 | Leaderboard | 7 | 10 glyph wraps, podium `readable`, 2 mini-tags |
| 7 | Prizes | 4 | 16 `withOpacity`, 12 glyph wraps, 2 const fixes |
| 8 | Profile | 2 | 22 `withOpacity`, 36 glyph wraps (`item.color`), 5 const fixes |
| 9 | Referral | 13 | no changes needed |
| 10 | Support/Coins/Premium/Friends | 13 | 17 glyph wraps, 3 const fixes |
| 11 | Admin | 1 | 21 glyph wraps, 4 const fixes |
| 12 | Share/Animation | 2 | no changes (brand-locked by design) |


| # | Group | Files | Known light-mode issues |
|---|---|---|---|
| 1 | Shell | `main.dart` splash + offline wall, `update_required_screen.dart` | hero gradient, `surfaceDim` scaffold, pulsing dot |
| 2 | Auth | `login_page.dart`, `delete_account_flow.dart` | `AnimatedHeroBackground` orbs at 8–15% alpha |
| 3 | Home | `home_page.dart` (89 refs) | bottom-nav blur bar, free-entry gradient, art scrims (**keep dark**) |
| 4 | Quiz | `questions_page`, `question_card`, `option_tile`, `quiz_header`, `timer_section`, `solo_summary_page`, skeletons | correct/wrong as text, watermark alpha, card shadow |
| 5 | Multiplayer | `multiplayer_hub_page`, `challenge_lobby_page`, `join_challenge_page`, `stake_screen`, `my_challenges_page`, `rivalry_page`, `anime_select_page` | vivid gradients, disabled states |
| 6 | Leaderboard | `weekly_leaderboard_page` + `widgets/*`, `weekly_points_pill` | podium bronze on white, rank-row tints |
| 7 | Prizes | `my_prizes_page`, `payout_claim_page`, `bank_selector_sheet`, `winner_announcement_page` | status chips, 6 of the 23 `const` sites |
| 8 | Profile | `pi_page.dart` (149 refs) | stats cards, badges, rank pill |
| 9 | Referral | `lib/feature/referral/**` (13 files) | code card, section cards |
| 10 | Support / Coins / Premium / Friends | `support_screen`, `earn_coins_screen`, `premium_upsell_screen`, `friends/*` | pricing cards, gradients |
| 11 | Admin | `admin_payout_dashboard.dart` (136 refs) | internal; flip and eyeball |
| 12 | Share image | `share_card.dart`, `coin_earn_animation.dart` | **keep branded/vivid by design** |

**Per-file grep checklist** (no eyeballing):

```
rg -n 'Color\(0x'        <file>     # raw literals: on-surface -> token, on-media -> keep
rg -n 'Colors\.(white|black)' <file> # classify: on-media scrim (keep) vs on-surface text (token)
rg -n 'withOpacity\('    <file>     # prefer withValues; check tint strength on light
rg -n 'const .*AppColors' <file>    # remaining const captures
```

Every occurrence gets one of three verdicts recorded in the PR/commit notes:
`token` (replaced with a palette value), `brand` (stays, by design), or
`media` (stays, sits on artwork). A file is done only when every hit is classified.

### Phase 4 — QA and release

- Walk every screen in both themes; flip the OS dark toggle live in System mode.
- Cold start in each of the three modes: no flash, correct chrome.
- Contrast pass on every `*Text` token.
- `flutter analyze` clean; `flutter test` green (10 suites).
- Flip `kThemeControlEnabled` for release; bump `pubspec` version + `minBuild`
  together if this ships as a forced-update-worthy release.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| 23 `const` compile errors | Compiler-driven; 11 are the same `Divider` fix |
| `static final` staleness | Audit found only `AppTypography`; converted to getters. No State-cached colours exist |
| Keyed-root rebuild does not repaint route content | Documented in §5.5; explicit element-marking pass used instead |
| Const widgets skipped on parent rebuild | Same pass marks every element, not just the root |
| Blindly "fixing" white text | Three-verdict classification (§8, Phase 3) |
| Status-colour contrast | Separate `*Text` tokens; vivid values stay for fills |
| Theme animation tearing | `themeAnimationDuration: Duration.zero` |
| Missed screen out of 77 | Group table + per-file grep checklist are the acceptance list |
| Ads do not theme | Accepted — AdMob renders its own chrome |
| Static palette blocks per-subtree theming | Migration path in §10 |

---

## 10. Later option: `ThemeExtension`

If the app ever needs per-subtree theming (light Settings + dark Quiz), migrate to a
`ThemeExtension<AppPalette>` read via `Theme.of(context).extension<AppPalette>()`.
That replaces `AppColors` static access with a context lookup at ~1,470 sites, removes
both the static palette and the rebuild pass, and makes the theme animation correct.
It is a strictly larger change and is not required for this feature.

---

## 11. Status

| Phase | State |
|---|---|
| Plan | ✅ written |
| 1 — tokens, provider, wiring, hidden toggle | ✅ implemented, pilot done, `flutter analyze` 0 errors, `flutter test` 140/140 |
| 1 — gate | ✅ passed on device |
| 2 — unhide control | ⏳ one-line flip (`kThemeControlEnabled`), pending review |
| 3 — screen audit | ✅ complete — 0 analyzer errors, 140/140 tests, 12/12 groups |
| 4 — QA / release | ⏳ device walk in both themes |

### Gate procedure

Debug build only; the Appearance section is visible because
`kThemeControlEnabled = kDebugMode && THEME_CONTROL != false`.

1. Profile → Settings → Appearance → tap Light, then Dark, then System.
2. Expect: the entire visible screen (Settings card, section labels, dropdowns,
   scroll position) repaints immediately; the Settings route and its scroll offset
   survive; the status-bar icons flip dark/light; the Android nav bar matches.
3. Back out to Home, then open a solo quiz and check both themes.
4. Kill and relaunch: the last mode is restored, with no dark→light flash, and the
   splash/offline wall use the restored palette.
5. `flutter run --dart-define=THEME_CONTROL=false` hides the control again.

**Do not start Phase 3 until this passes.**
