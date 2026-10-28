# Email verification at login (replaces phone verification)

Status: **implemented locally, not deployed** · 2026-10-27
Hard constraint: `ENFORCE_APP_CHECK` and `server_config/play_integrity.enforce` stay **off**.
Release constraint: no `public/downloads/*` or `latest.json` changes, no
`app_config/android` change (`latestBuild=5`, `minBuild=5` stay as they are).
APK is built to `build/` only (see §8).

---

## 1. Decision

- **One gate, at login.** `AuthGate` (`lib/features/auth/login_page.dart`) routes:
  signed out → login/sign-up; signed in and `emailVerified == false` →
  `EmailVerificationPage`; verified without `termsAcceptedAt` → one-time
  `TermsAcceptancePage`; verified with terms → the app. No other screen checks
  verification or terms.
- Applies to new signups and existing accounts alike. An existing unverified user who signs
  in lands on the verification screen and cannot reach solo play either. An existing
  pre-terms user (verified, no `termsAcceptedAt`) lands on the acceptance screen once.
- **Per-feature gates on the five money paths only.** `submitPayoutDetails`,
  `savePayoutDetail`, `claimReferralCashout`, `requestPaymentLink` and
  `claimReferralBonus` (invitee) reject `request.auth.token.email_verified != true`
  (ID-token claim; `requestPaymentLink` checks the decoded bearer's
  `email_verified`). Nothing else checks verification.
- Phone verification is removed completely (see §7).

## 2. Behaviour

| Step | What happens |
| --- | --- |
| Sign up | Terms checkbox must be ticked (button is disabled until then). `createUserWithEmailAndPassword` → `ensureProfile` (server stamps `termsAcceptedAt` and `termsVersion`) → `sendVerificationEmail` (best-effort). |
| Verification screen | Shows the address, "I've verified" (`reload` → `getIdToken(true)` → `syncEmailVerification` mirror), resend with a server-driven countdown (`retryAfterSeconds`, 60 s, 5 per day), "Wrong email? Change it", sign out. |
| Change email | Sheet asks for the new address and the current password. `reauthenticateWithCredential` → `prepareEmailChange` (format, disposable list, uniqueness claim, same resend budget) → `verifyBeforeUpdateEmail(new)`. The sign-in email only changes after the link is opened. |
| Sign in, unverified | Lands on the verification screen. Nothing else is reachable. |
| Sign in, verified, no `termsAcceptedAt` | Lands on the one-time accept screen (same checkbox and links as signup). `acceptTerms` stamps `termsAcceptedAt`/`termsVersion` server-side. |
| Sign in, verified, terms accepted | The app. Daily login bonus runs as before. |
| Account deletion | Unverified accounts created after `UNVERIFIED_CLEANUP_EPOCH_MS` are deleted 7 days after creation (copy on the screen says so). Earlier accounts are never touched. |

## 3. Server (`functions/index.js`, `functions/abuse_config.js`)

Kept: normalization (`_normalizeEmail`), disposable blocklist, `emailIdentities` claim,
IP/device limits, rate limits, auth-failure counters, self-referral checks, pair cap, payout
account-age (7 days) and `_assertPayoutAllowed`, all cleanup jobs.

Changed:
- `ensureProfile` requires `termsAccepted === true` for a new profile; stamps
  `termsAcceptedAt` (server timestamp) and `termsVersion` (`TERMS_VERSION`, server constant).
- New `acceptTerms` for pre-terms accounts: requires `termsAccepted === true`,
  stamps `termsAcceptedAt`/`termsVersion` server-side, idempotent. Called once by
  the one-time accept screen; `firestore.rules` already denies client writes to
  those fields, so the callable is the only path.
- `_assertEmailVerified(request, fnName)` checks
  `request.auth.token.email_verified === true` and throws `failed-precondition`
  (`reason: email_not_verified`) otherwise. Enforced at the top of
  `submitPayoutDetails`, `savePayoutDetail`, `claimReferralCashout` and
  `claimReferralBonus` (the caller is the invitee, so the invitee is verified).
- `_verifyBearer` now also returns `emailVerified` from the decoded
  `email_verified` claim; `requestPaymentLink` returns 403
  (`reason: email_not_verified`) when it is not true.
- `syncEmailVerification` moves the uniqueness claim when the verified email changes (releases
  the old claim only if owned by this uid); refuses a claim owned by another uid; mirrors
  `users.email`.
- New `prepareEmailChange({ newEmail })` for unverified accounts (see §2).
- `requestEmailVerification` unchanged.

Removed: `confirmPhoneVerification`
and `adminMarkPhoneVerified`; the phone gate and its kill switch; `phoneNumbers` handling in
`deleteAccount`, `cleanupDeletedUser` and `cleanupUnverifiedAccounts`.
(The old `_assertEmailVerified` removal note is superseded: the check is back,
scoped to the five money paths above.)

Identity Platform blocking functions (`beforeEmailSent`, `beforeUserSignedIn`) are unchanged.
They are exported only when `ENABLE_IDENTITY_BLOCKING=true` (set in the untracked
`functions/.env`). They still enforce the sign-in failure lock and email-send throttling.

## 4. Firestore rules (`firestore.rules`)

- `isVerified()` removed. Reads that used it are back to the signed-in condition:
  `challenges`, `rivalries`, `users` (cohort and admin reads), `users/{uid}/referrals`,
  `leaderboardCycles` and `pendingClaim`, `referralCashouts`.
- The `phoneNumbers` rule is removed.
- Deny-all rules for `abuse_log`, `rate_limits`, `authFailures`, `emailIdentities`,
  `emailResend`, `challengePairs` stay.

## 5. Client (`lib/`)

| File | Change |
| --- | --- |
| `features/auth/login_page.dart` | `AuthGate` routing (§1); sign-in form with inline errors, advisory lockout check (`checkAuthAttempt`, `reportAuthFailure`, `reportAuthSuccess`), password reset. New `_TermsGate`: verified accounts whose `users/{uid}` has no `termsAcceptedAt` see the accept screen once; fail-open on read errors / missing doc. |
| `features/auth/terms_acceptance_page.dart` (new) | One-time accept screen (same checkbox copy and Terms/Privacy links as signup); submit calls `acceptTerms`. |
| `features/auth/auth_service.dart` | Phone code removed. `signUp` takes `termsAccepted`. Adds `acceptTerms` and `changeUnverifiedEmail`. |
| `features/auth/register_form.dart` (new) | Sign-up form, required terms checkbox linking to the in-app pages, submit disabled until ticked. |
| `features/auth/auth_widgets.dart` (new) | Shared logo, text field, inline error. |
| `features/auth/email_verification_page.dart` | Rewritten as the login gate (§2). |
| `features/legal/legal_pages.dart` (new) | In-app Terms and Privacy summaries; link to the hosted full text. |
| Multiplayer hub, join challenge, stake screen, payout claim, referral screen | Gate wrappers removed. |
| `features/player/settings_page.dart` | Phone tile removed; email row is read-only. |
| `features/leaderboard/widgets/leaderboard_sheets.dart` | `phone_unverified` branch removed. |
| Deleted | `features/auth/phone_verification_page.dart`, `features/auth/email_verification_gate.dart`, `core/constants/feature_flags.dart`. |

`PlayIntegrityService` is kept: `quiz_controller.dart` uses it, and the server's log-only
`_verifyPlayIntegrity` remains on several money paths.

## 6. Tradeoffs (read this)

1. **The verification gate is two-layer.** The login screen is still client-side
   routing (a signed-in session exists before the email is verified). But every
   money path now enforces `email_verified` server-side on the ID-token claim
   (`submitPayoutDetails`, `savePayoutDetail`, `claimReferralCashout`,
   `requestPaymentLink`, `claimReferralBonus` for the invitee), so a hand-rolled
   client with an unverified session can still play solo/challenges but cannot
   move money. Non-money paths stay ungated (leaderboard reads, `createChallenge`,
   `redeemCode`, `spendCoins`). The server still enforces the non-email rules
   (account age and payout limits, rate limits, the disposable list, duplicate-email
   claims, same-device challenge rules).
2. **`beforeUserSignedIn` cannot be the gate.** Likely (not tested against the live service):
   it runs on sign-in attempts, not on account creation, and a rejected sign-in creates no
   session. Rejecting unverified sign-ins would therefore also stop an unverified user from
   reaching the verification screen, so they could never resend, change the email, or verify.
   That contradicts the requirement that existing unverified users land on the verification
   screen. The compromise is client-side routing plus the server-side rules above.
   If you want a true server-side gate later, the only shape that works is server-side
   enforcement on money callables with a token-claim check (`email_verified`), which is
   exactly what was removed.
3. **Referral reward** checks the invitee's email server-side (`claimReferralBonus`
   requires the caller's token to carry `email_verified: true`). The client also
   only reaches the app after verifying, so the practical effect is defense in
   depth against direct-call bypass.
4. **Existing accounts** created before the epoch are never deleted, but they are locked on
   the verification screen until they verify or change email. That is the requested behaviour.
5. **Accounts without `termsAcceptedAt`** (created before this change) see the
   one-time accept screen after login. `acceptTerms` stamps the server time and
   version; the client cannot write those fields (rules allowlist).

## 7. Phone removal

- App: phone sign-in, OTP screen, `phoneAuthErrorMessage`, `kPhoneVerificationEnabled`,
  the phone settings tile, and the phone checks in `index.html`/`shop-auth.js` are removed.
- Functions: `confirmPhoneVerification`, `adminMarkPhoneVerified`, the phone gate, and all
  `phoneNumbers` handling are removed.
- Rules: `phoneNumbers` rule removed.
- Config: `requirePhoneForMoney` removed from `scripts/seed_server_config.js`.
- Data: a one-off migration `scripts/strip_phone_fields.js` strips phone fields from
  `users/{uid}`, deletes `phoneNumbers/*`, and unlinks the phone provider from Auth accounts
  that also have another provider. Accounts whose only provider is phone are listed and left
  alone. The migration was tested against the Firebase emulator only. It has **not** been run
  against production.
- Docs: phone sections in `docs/anti-cheat-plan.md` are rewritten or marked as history.
- `PlayIntegrityService` stays (see §5).

Repo-wide grep results are recorded in §10.

## 8. Rollout — small named batches

Batches B1–B6 below, then the rules deploy, then the `strip_phone_fields`
migration. Order matters because `app_config/android.minBuild` gates old
clients, and old builds still have phone-based code paths. The release APK is
built to `build/` only (never copied to `public/downloads`, `latest.json`
untouched).

1. **B-client `email-login-gate`**: build and release the new APK from `build/`
   only. Requires a `pubspec.yaml` version bump (`+<build>`); `minBuild` stays
   untouched for this release.
2. **B-fn `email-login-gate-functions`**: `functions/` changes (callables, `ensureProfile`
   terms, `prepareEmailChange`, `syncEmailVerification`, phone callables removed).
   Deploy: `firebase deploy --only functions`. Deleting `confirmPhoneVerification` and
   `adminMarkPhoneVerified` requires confirming the deletion in the Firebase CLI prompt.
3. **B-rules `email-login-gate-rules`**: `firebase deploy --only firestore:rules`. This is a
   loosening back to signed-in reads (see §4). Deploy after B-client is live.
4. **B-web `web-phone-removal`**: `public/index.html`, `public/assets/shop-auth.js`,
   `public/terms.html`, `public/privacy.html`. Deploy: `firebase deploy --only hosting`
   (separate, after its own check). Until deployed, the live buy page still requires a phone
   number and will refuse buyers who have none.
5. **B-migrate `strip-phone`**: run `scripts/strip_phone_fields.js` **dry run first**, then
   `--execute`, only after B-client is live and `minBuild` is raised. Phone-only accounts are
   listed in the dry run and need an operator decision.

## 9. Test plan

- `functions/test/*.test.js` (`node --test test/*.test.js` from `functions/`): the
  five money paths reject `email_verified: false` (`reason: email_not_verified`);
  non-money callables (`createChallenge`, `redeemCode`) stay ungated. Covered:
  terms enforcement and stamping, `acceptTerms` cases, `syncEmailVerification`
  claim move and conflict, `prepareEmailChange` cases, normalization,
  disposable list, IP limits, resend limits, auth lockout, referral and farming
  protections, pair cap, payout account age.
- `functions/test/strip_phone_migration.emulator.test.js`: skipped unless the Firestore and
  Auth emulator env vars are set. Passed 3/3 against the emulator.
- `flutter analyze` and `flutter test`: run at the end of this work (see the hand-off note).
- Manual device checks before B-client release: sign up with the box unticked (button stays
  disabled); sign up and see the verification email; resend countdown; wrong-email sheet;
  existing unverified account lands on the verification screen; verified account reaches the
  app; sign out from the verification screen.

Open items:
- The in-app Terms and Privacy pages are summaries. They need legal review before release.

## 10. Repo grep (phone | otp | sms | 17028)

Final grep of the repo (excluding `node_modules`, lock files and `.agents/`). What remains and why:

| Location | Hit | Why it stays |
| --- | --- | --- |
| `functions/index.js`, `functions/abuse_config.js` | none | Clean. |
| `scripts/strip_phone_fields.js`, `functions/test/strip_phone_migration.emulator.test.js` | phone fields, claims, provider | Intentional: the one-off migration and its test. Delete after the migration has run. |
| `docs/anti-cheat-plan.md` | phone auth history, 17028 | Historical audit record, marked "removed 2026-10-27". The 17028 hit is in the removal note. |
| `docs/email-verification-plan.md` | this doc | Describes the removal. |
| `public/downloads/latest.json` | "Phone verification has been retired" changelog line | Release artifact, frozen per instruction. Still true. |
| `public/download.html` | "your phone is on an Android version" | Refers to the user's device, not phone auth. |
| `docs/passwords.txt` | `OTP: 12345` | Unrelated stored value. Flagged as a secret file (see AGENTS.md); not touched here. |
| `scripts/purge_users.js` | "Emails/phones are never printed" | Comment about logging; no phone data handled. |
| `lib/core/services/app_update_service.dart`, `lib/core/widgets/share_card.dart`, `test/*.dart`, `ios/**`, `docs/app_icon.md`, `docs/tiktok-finance-scripts.md`, `data/questions_input.json`, `.github/workflows/build-ios.yml` | "phone" as a device form factor, iOS `iphone` idiom, `IPHONEOS` build setting, "phone call", "Earphone Jack" | Not phone authentication. |
| `.agents/**` | external skill docs | Third-party skill text; not part of this repo's code. |

`lib/features/auth/delete_account_flow.dart` no longer lists "phone number" in the deletion copy.
