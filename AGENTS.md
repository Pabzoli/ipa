# AGENTS.md

Rules for AI coding agents. Priority: user's current message > this file > loaded skills > repo conventions > your habits.
Conflict rule: this file beats any skill; a skill's specifics apply where this file is silent.
Design skills: design-from-html-flutter when an HTML prototype exists, flutter-app-theme for project tokens; material-design-3-ui / frontend-design are references only and never override project token rules.
Responsive sizing: this repo uses flutter_screenutil (.w/.h/.sp/.r) — keep it in feature code.

## Bundled Flutter skills (aligned to this repo)
`.opencode/plugins/flutter-knowledge.js` injects the `flutter-knowledge` map and its sub-skills (`flutter-cubit`, `flutter-routing-di`, `flutter-app-theme`, `flutter-screen-ui`, `flutter-data-layer`, `add-translation`, …). These have been rewritten to describe **this** app — Provider + ChangeNotifier, `AppColors`/`AppTypography`, singleton services, plain-string copy — and no longer assume Cubit/get_it/AppSkin/LocaleKeys/freezed. If a skill ever drifts from the code, the code wins; these facts stay authoritative:
- State = `Provider` + `ChangeNotifier` (`lib/core/providers/*`), plus `setState` / `FutureBuilder` in screens. No bloc, no get_it, no freezed/json_serializable, no router.
- Services are singletons: `class X { static final X instance = X._(); }` under `lib/core/services/*` — call `X.instance.method()`. (One exception: `AdminPayoutService.instance`.)
- Visual tokens: `AppColors`, `AppTypography`, `AppSpacing`, `AppRadii`, `AppDecorations` in `lib/core/theme/app_theme.dart`. No `AppSkin` / `context.skin`. Theme is dark-only (`AppTheme.dark`).
- **No localization layer**: user-facing strings are plain Dart literals. `LocaleKeys`/`.tr()` do not apply (the `add-translation` skill documents this).
- Navigation is direct `MaterialPageRoute` / `AppPageRoute`; there is no `app_router.dart`.

## Repo map
- `lib/main.dart` — app entry, `ScreenUtilInit` (design size 390×844), `MultiProvider`, offline/update wall overlays.
- Two feature-layout eras coexist: legacy `lib/features/<feature>/*.dart` (flat pages) and newer `lib/feature/<feature>/{data,presentation}/...` (only `referral`). Match the neighbouring feature; use the `lib/feature/` shape for a brand-new feature.
- `lib/core/widgets/*` — shared wrappers (`AppButton`, `AppCard`, `AppSheet`, `AppDialog`, `AppPageRoute`, `AppTextField`-style, …). Prefer these over raw Material widgets.
- `functions/index.js` — **every** deployed Cloud Function in one file (callables, Firestore triggers, scheduled, HTTP/webhook). `functions/test/*.test.js` — Node suites; `money/friends/gate` use in-memory SDK fakes (`_fakes.js`, no emulator), `rules.test.js` is the only one that needs the Firestore emulator.
- `scripts/` — local admin scripts, never deployed; every one is a dry run unless `--execute`/`--commit` is passed. `public/` — Firebase Hosting static pages (marketing, Flutterwave success/refund, APK download).
- Firebase project `anime-quiz-1ab1b`; Firestore region `europe-west1`; Functions default region `us-central1`; hosting base `https://anime-quiz-1ab1b.web.app`.
- Do not hand-edit generated/config files: `lib/firebase_options.dart`, `docs/google-services.json`, `ios/Runner/GoogleService-Info.plist`.

## Commands
- Analyze: `flutter analyze` (must be clean). Tests: `flutter test` (`test/`, 6 suites).
- Functions tests, **from `functions/`**: `node --test test/*.test.js`. The `npm test` script is broken — `functions/test/*.test.js` resolves to nothing when npm runs it from `functions/`, so it silently reports 0 tests. Don't rely on it.
- Rules tests need the emulator: `firebase emulators:start --only firestore` (127.0.0.1:8080), then `node --test test/rules.test.js`.
- Seed quiz questions: `node scripts/seed_questions.js` (dry run) → add `--execute` to upload; input is `data/questions_input.json`.
- Forced-update gate config: `node scripts/set_android_config.js` (dry run) → `--commit`. Admin scripts resolve credentials as `--key=<path>` > `GOOGLE_APPLICATION_CREDENTIALS` > the path in `scripts/.service-account-key-path`.

## Domain invariants (money / prizes — server-authoritative)
- Coin, stake, prize and economy mutations go through Cloud Functions, not client writes: `spendCoins`, `createChallenge`/`joinChallenge`, `submitQuizAnswers`, `resolveChallengeOutcome`, `flutterwaveWebhook`, `submitPayoutDetails`, … `firestore.rules` is deliberately restrictive (clients write only a narrow, self-owned field set, e.g. their own challenge score, once).
- Keep economy constants in sync across the Dart mirror and `functions/index.js`: `lib/core/constants/{solo,rival,referral,blitz}_economy.dart`, and Quick Match AC/WP which appear both in `ChallengeModel` (Dart) and as `QM_*` in `index.js`.
- Never loosen `firestore.rules` "to make it work" — auth, payments and personal-data paths are hardened on purpose.
- Never log or commit secrets: Firebase secrets `FLW_SECRET_KEY`/`FLW_SECRET_HASH`/`RESET_SECRET`, `*service-account*.json`, `scripts/.service-account-key-path`, `/lib/passwords.txt` (already committed once — treat as compromised and rotate).
- Android forced-update gate: the `+<build>` in `pubspec.yaml` `version:` flows into Android `versionCode` and is compared against `app_config/android.minBuild`. Bump the `pubspec` version and `minBuild` together, never separately. Shipping moves `latestBuild` first; the wall only arms when `minBuild` is raised.

## Guardrails
- Don't commit, push, tag, or deploy unless asked. Deploy is `firebase deploy --only <functions|firestore:rules|hosting>`; state rollback in one line (`rollback/firestore.rules.bak` exists for rules).
- NEVER bulk-deploy functions (`firebase deploy --only functions` fails during source analysis on this single-file 16k-line codebase — observed 2026-10-29). Deploy only the named changed function(s), e.g. `firebase deploy --only functions:verifyIAPPurchase`.
- No destructive commands without explicit confirmation. `scripts/purge_users.js` and `scripts/purge_leaderboard_payouts.js` delete live data — dry run first, main agent only.
- Honesty: never claim a build/test/deploy passed unless you ran it and saw it; label claims Confirmed / Likely / Unsure.
- Flutter tests only when the user explicitly asks; a confirmed bug fix gets a regression test.
- Subagents: one owner per file; parallel read-only exploration is fine, writers only on disjoint files; a subagent never commits, pushes, deploys, or deletes.
- Definition of done for touched code: `flutter analyze` clean, and `node --test test/*.test.js` green when Functions changed.
