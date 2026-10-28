# Anti-Cheat Architecture Plan

**Status:** proposal · **Scope:** quiz economy, WP leaderboard, staked duels, referrals, prizes
**Goal:** make cheating *unprofitable and detectable*, not merely inconvenient.

---

## 0. TL;DR

The app is already unusually well hardened on the **write** side: scores are computed
server-side, Firestore denies economy writes, email verification gates money paths, and
daily caps exist. But the **read** side is wide open:

> Any signed-in client can read `questions/{id}.correctAnswerIndex` directly from
> Firestore. The client also chooses its own question set and declares its own
> difficulty, and the server trusts both.

That combination defeats almost every server-side control. A script can fetch the answer
key, pick 10 easy questions, claim `difficulty: "hard"`, and submit a perfect run — or
read the answers for a staked duel and take an opponent's stake.

**The single highest-leverage fix is a server-minted run:** the server picks the
questions, keeps the answer key server-side, returns sanitized questions, and scores
against its own record. Until that exists, everything else is cosmetic.

**There is no such thing as a non-bypassable client.** The realistic target is:

1. The client never possesses the answer key or the authority to choose a run.
2. Every reward is bounded, ledgered, and reversible.
3. Bypass attempts are visible and gate cash-out, not just gameplay.

---

## 1. What “non-bypassable” actually means

Absolute non-bypassability is impossible because the attacker controls the device and
there is a human in the loop. Three residuals survive every design:

| Residual | Why it can't be eliminated | Mitigation |
|---|---|---|
| Human looks up answers on a second device | The human is the answer source | 10s timer, server-timed windows, question rotation, behavioural signals |
| OCR/LLM overlay reads the screen and answers | Screen content is attacker-visible | Play Integrity strong verdict, timing/entropy signals, payout review |
| Compromised release signing key / Google account | Attacker becomes “the app” | Offline keystore, key rotation, cert pinning, 2FA/hardware keys on admin accounts |

What *is* achievable:

- **No client-side authority.** The server decides the question set, difficulty, score,
  and reward. A patched client gains nothing because there is nothing to patch.
- **No client-side secrets.** No HMAC keys, no “secret” headers, no obfuscation-as-security.
- **Bounded upside.** Even a successful cheat cannot extract more than the per-account
  cap, and cash-out requires identity + review.
- **Attribution.** Every run is attributable to a UID, an install, a device verdict, an
  IP/ASN, and a ledger trail, so abuse can be reversed and accounts banned.

Design rule: **if a control can be bypassed by editing the client, it is not a control.**
It is only a speed bump. Count only server-enforced invariants as security.

---

## 2. Threat model

| # | Attacker | Capability | Primary goal |
|---|---|---|---|
| T1 | Modified client / repackaged APK | Full control of Dart/UI, can call any endpoint | Free WP/AC, perfect scores |
| T2 | Direct API script | Valid Firebase ID token, no app at all | Farm runs, referrals, ads |
| T3 | Answer-key scraper | Read `questions` collection | 100% accuracy everywhere |
| T4 | Multi-account farmer | Many emails/devices | Referral + leaderboard + payout farming |
| T5 | Colluding pair | Two accounts, one human | Win-trade staked duels, split prizes |
| T6 | Emulator/automation farm | Rooted devices, ADB, accessibility bots | Volume farming |
| T7 | Account thief | Credential stuffing / SIM swap | Redirect a prize payout |
| T8 | Insider / compromised admin | Console + Admin SDK | Mint economy, edit payouts |

---

## 3. Current posture — what is already strong (preserve it)

- **Server-authoritative writes.** `firestore.rules` denies client writes to challenges,
  scores, `users` economy fields, questions, prize pool, payouts, telemetry, and fraud
  reviews. Most callables use the Admin SDK.
- **Server-side scoring.** `submitQuizAnswers`, `submitChallengeScore`,
  `submitQuickMatchResult`, `submitDailyGauntlet`, `saveGhostSession` all re-score
  submitted answers against real question docs.
- **Idempotency.** Solo runs use a server-minted session and a `quizSessions` result
  cache; ad sessions and gauntlet tickets are single-use.
- **Email verification gate.** Multiplayer, challenges, Quick Match, the paid leaderboard,
  payouts and referral rewards require `email_verified` (see §10, "Phone auth removed");
  `emailIdentities` enforces one account per normalized email.
- **Caps and decay.** Daily WP soft cap, solo decay tiers, weekly WP cap, stake limits,
  challenge volume limits, referral 3-quiz/2-day gate and 10-per-30-day cap.
- **App Check plumbing.** Play Integrity / App Attest / reCAPTCHA providers are wired and
  `onSecureCall` centralises enforcement. The code defaults to monitor mode; confirm the
  deployed `ENFORCE_APP_CHECK` env var and the runtime flag actually match.
- **Build gate.** `app_config/android.minBuild` blocks outdated Android clients from
  economy callables.
- **Audit trail.** `coinTransactions`, `payoutDetailAudit`, pending claims, admin marking.
- **Tests.** `functions/test/*.test.js` and the Firestore emulator rules suite already
  cover money, challenges, rules, email verification gate, and sessions.

Do **not** weaken any of the above to make a new feature work.

---

## 4. Findings — exploitable today

### F1 (Critical) — The answer key is client-readable

`firestore.rules` allows `questions/{id}` reads to any authenticated user, and the docs
contain `correctAnswerIndex`. `FirestoreService.fetchQuestions*` returns it to the UI.

**Impact:** a 20-line script dumps every answer. Every “server-validated” score is then a
formality. This also makes staked duels theft: read the answers, beat the opponent 10–0.

**Fix:** deny all client reads of `questions`; serve sanitized questions from a callable.

### F2 (Critical) — The client declares its own difficulty

`submitQuizAnswers` reads `soloDifficulty` from the request and uses it to select the
reward table (`hard` pays 35 AC and up to 480 raw WP). Nothing verifies that the run
actually used a hard question mix.

**Impact:** 10 easy questions + `soloDifficulty: "hard"` = maximum reward for minimum
effort.

**Fix:** difficulty is chosen when the server mints the run and is stored on the run doc;
the submit path never reads it from the client.

### F3 (Critical) — The client chooses the question set, unbound to the run

`startSoloCooldowns` stores only `titles` on `users/{uid}.soloSession`; it does not store
the question IDs. `submitQuizAnswers` accepts any 10 existing, unique IDs. The gauntlet
path (`submitDailyGauntlet`) likewise accepts any 7 IDs. A 9–10 title lineup has zero
cooldown, so runs can be repeated freely.

**Impact:** choose questions you know, replay indefinitely, ignore the intended difficulty
mix. The run is “server-minted” in name only.

**Fix:** the run doc owns `questionIds`, `answerKey`, `difficulty`, `kind`, `refId`, state,
and expiry. Submit accepts a `runId`, not an arbitrary question list.

### F4 (High) — Fraud thresholds are readable by every player

`app_config/{docId}` allows authenticated reads, including `app_config/antifraud` (all
scoring weights and band thresholds) and `app_config/security`.

**Impact:** attackers tune cadence, volume, and pairing to stay under the exact
thresholds. It also reveals which switches are off.

**Fix:** move server-only tunables to `server_config/**` (`read: false, write: false`) or
explicitly deny `app_config/antifraud` and `app_config/security`. Keep only
`app_config/android` public.

### F5 (High) — App Check can still be in monitor mode

`ENFORCE_APP_CHECK` defaults to false and `app_config/security.enforceAppCheck` defaults to
false. If either is unset in the deployed environment, tokenless requests are logged but
accepted, and Firestore App Check enforcement is a separate console setting. **Verify the
live config before assuming this is closed.**

**Impact:** a script with a valid ID token can call every callable without an attested
app or device.

**Fix:** ship the attested client, watch the monitor logs for a full week, then turn on
both switches (functions env var + runtime flag + Firestore console enforcement). Keep a
kill switch for outages.

### F6 (High) — Ghost sessions can be poisoned

`saveGhostSession` accepts arbitrary `questionIds` and `answers` from any caller. It
re-scores them but does not require that the caller actually played that run. A cheater
can seed perfect ghosts into the pool, or flood low-quality ones.

**Impact:** griefing and economy distortion for other players; the ghost pool becomes
attacker-controlled content.

**Fix:** ghost creation only from a completed, server-minted run owned by the caller;
store the run ID; cap per UID/anime/day.

### F7 (High) — Multi-account farming has no device boundary

Signup is email/password, and the referral bonus and the free daily faucets do not
require a device or install identity. IP is captured but only
advisory, and `app_config/antifraud` is readable.

**Impact:** bot accounts farm referrals (3 quizzes over 2 days is scriptable), free
gauntlet entries, ad coins, and leaderboard slots.

**Fix:** install ID bound to an integrity verdict, accounts-per-install caps (as a risk
signal, not a hard block for shared devices), verified-email + retention gates for referral cash-out,
and a device/account graph in the risk engine.

### F8 (High) — The fraud score is advisory only

`scoreFraudForWeek` is admin-triggered, writes `fraudReviews`, and the admin payout page
shows it. Nothing in the award or payout path reads it. A high-risk account can still be
ranked and paid.

**Impact:** detection exists but has no teeth; enforcement depends on a human noticing.

**Fix:** make the risk score incremental and enforce an escalating ladder (shadow decay →
leaderboard exclusion → payout hold → suspension), with the human reviewing holds rather
than discovering fraud.

### F9 (Medium) — Ranked and casual runs are the same economy

Every solo run feeds the same `weeklyPoints` that decides real prize money, whether or not
it was played on an attested device or with server-verified timing.

**Impact:** one weak client destroys the integrity of the paid board.

**Fix:** split “ranked” (attested, server-timed, eligible for WP/prizes) from “casual”
(AC only, capped). A run that fails attestation still plays; it just cannot move the
leaderboard.

### F10 (Medium) — Client-supplied timings

`submitQuizAnswers`, `submitChallengeScore`, and `submitQuickMatchResult` trust `timings`
for fast/slow rewards and plausibility checks. A client can fabricate them.

**Impact:** reward-tier manipulation; timing signals become useless for detection.

**Fix:** derive elapsed time from server timestamps on the run (`answeredAt`/`submittedAt`);
ignore client timings for scoring. Keep them only as a diagnostic.

### F11 (Medium) — No general rate limiting or per-run concurrency

Only ad sessions, friend requests, redeem attempts, and payment endpoints are rate-limited.
There is no global per-UID/per-IP callable budget and no “one active run” lock.

**Impact:** a script can hammer submissions, start parallel runs, and probe endpoints.

**Fix:** a shared rate-limit helper (Firestore token bucket or in-memory + Firestore for
critical paths), one active run per user, and per-IP caps on account creation.

### F12 (Medium) — Payout destinations are not fingerprinted

`submitPayoutDetails` validates shape and writes an audit trail, but does not
check whether the same bank account is already used by another UID.

**Impact:** a multi-account ring can funnel many prizes to one account; account takeover
can redirect a payout within the claim window.

**Fix:** hash `(bankCode, accountNumber)` into `payoutAccounts/{hash}` → owning UID;
multiple UIDs is a hold + review signal, not a silent block. Add a re-auth step and a
cool-down for destination changes.

### F13 (Low) — Admin UID is hardcoded and single-factor

`ADMIN_UIDS` appears in functions, rules, and scripts; admin accounts can write
`app_config/android` from a client. Compromise of that Google account is a full economy
compromise.

**Fix:** 2FA/hardware key on admin Google accounts, audit all admin callables, consider
custom claims with short-lived admin sessions, and keep `ADMIN_UIDS` in one place.

### F14 (Low) — Web/client trust boundary

The Flutter project can build for web. If a web build ever earns WP/AC, reCAPTCHA is the
only attestation and it is human-farmable.

**Fix:** web is marketing/shop only. Earning requires a mobile client that passes Play
Integrity or App Attest. If web earning is a product requirement, cap it to casual AC.

---

## 5. Target architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│ Client (untrusted)                                                   │
│  • no answer key   • no question choice   • no difficulty choice     │
│  • receives sanitized questions + runId                              │
└───────────────┬──────────────────────────────────────────────────────┘
                │ HTTPS callable (App Check + Play Integrity/App Attest)
┌───────────────▼──────────────────────────────────────────────────────┐
│ Trust boundary — Cloud Functions (Admin SDK only)                    │
│                                                                      │
│  1. Attestation     verify app/device verdict + cert digest + nonce  │
│  2. Run minting     pick questions, store answerKey server-side       │
│  3. Answer intake   lock each answer, server timestamp, no re-answer  │
│  4. Scoring         score against run doc, not client claims          │
│  5. Economy          idempotent, capped, ledgered, reversible         │
│  6. Risk engine      incremental score → enforcement ladder          │
└───────────────┬──────────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────────┐
│ Server-only collections (rules: read:false, write:false)             │
│  quizRuns/{runId}      questionIds, answerKey, state, timings        │
│  riskProfiles/{uid}    score, signals, enforcement state             │
│  fraudEvidence/**      immutable snapshots                           │
│  server_config/**      thresholds (never client-readable)            │
└──────────────────────────────────────────────────────────────────────┘
```

### Invariants

1. A reward is only written by a function that read the run doc in the same transaction.
2. A run is payable exactly once, by the UID that owns it, before expiry.
3. No collection the client can read contains `correctAnswerIndex`.
4. No economy field is client-writable.
5. Every award has a ledger entry and a bounded cap.
6. Every high-value call is attributable to an install + verdict + IP + UID.

---

## 6. Component specifications

### 6.1 Server-minted runs (`getQuizRun` / `submitRun`)

**Run document** — `quizRuns/{runId}` (root collection, rules deny all clients):

```js
{
  uid, kind: 'solo' | 'gauntlet' | 'challenge' | 'quickmatch',
  refId: challengeId | null,          // challenge / QM only
  questionIds: [ ...10 or 7 ],
  answerKey: [0,2,1,3,...],           // never leaves the server
  difficulties: ['easy',...],         // server-chosen mix
  titles: ['naruto',...],             // solo/gauntlet
  difficulty: 'easy'|'medium'|'hard', // authoritative, server-chosen
  state: 'active'|'submitted'|'expired',
  startedAt, expiresAt,
  answers: [{ index, at }],           // filled by submitAnswer
  result: {...}                       // written once on settlement
}
```

**Mint (`startSoloRun`, `enterDailyGauntlet`, `getChallengeRun`):**

1. Auth + App Check + build gate (+ verified-email gate for WP-bearing).
2. Validate titles against the catalog, unlock list, and cooldowns.
3. Enforce **one active run per UID** (and one per challenge seat).
4. Select questions **server-side** using the weighted mix (port the mix logic from
   `FirestoreService.fetchQuestionsForTitles`; it is pure selection, not UI).
5. Write the run doc with the answer key; apply cooldown locks in the same transaction.
6. Return `{ runId, expiresAt, questions: [{ id, question, options, animeTitle, difficulty }] }`.
   **No `correctAnswerIndex`.**

**Answer intake (`submitAnswer(runId, index, choice)`):**

- Transaction: run belongs to caller, `state === 'active'`, not expired, question not
  already answered.
- Write `{ index, at: serverTimestamp }`.
- Return `{ accepted: true, correct: boolean }` — **never the correct option**.
- A second answer for the same question is rejected (`already_answered`).

**Settlement (`submitRun(runId)`):**

- Require all questions answered (timeouts are recorded explicitly).
- Reject if the run is expired, already settled, or owned by another UID.
- Score from the server-held `answerKey`; derive timings from `answeredAt` deltas.
- Apply decay, daily cap, daily/weekly counters, achievements, ledger, seen markers.
- Mark the run `submitted` and store `result`; return the per-question result **only after
  the run is settled** (and for challenges, only after the match is resolved).

**Why this is the core:** a patched client can lie about everything it sends, but it can
only send answers to questions the server chose, once each, within the server's window.
The best it can do is guess.

**Client changes this forces (don't discover these mid-sprint):**

| Current client use of `correctAnswerIndex` | Replacement |
|---|---|
| `quiz_controller.selectOption` increments `_correctCount` | Use `{correct}` from `submitAnswer` (or the settled result) |
| `option_tile.dart` highlights the right answer | Reveal only after the run settles; during play show “locked” |
| `progress_segments.dart` colours past answers | Drive from the server result, not the local key |
| `useHint` picks a random wrong option locally | New `useHint(runId)` callable returns one wrong index and deducts 10 AC atomically (server-capped at 2/run) |
| `_gauntletPerQuestionWP` computes per-question WP locally | Display-only; use the `perQuestionWP` returned by the server |
| `quiz_controller` comment/flow assumes local scoring | Rework to a thin “send answer, show ack” loop |
| `AnimeQuestion.correctAnswerIndex` is non-nullable | Split into `QuizQuestion` (wire, no key) and `AnimeQuestion` (seed/admin, key) |

The hint change is security-critical: with no key on the client, hints must come from the
server. A hint that reveals one wrong option is acceptable; a hint that reveals the right
option is not. Cap hints server-side and bind them to the run + question.

### 6.2 Answer-reveal policy

The current UI needs immediate right/wrong feedback. Three options:

| Option | UX | Security | Recommendation |
|---|---|---|---|
| A. Reveal at end | Summary shows all answers | Strongest; no oracle at all | Use for challenges and gauntlet |
| B. Per-answer check | Instant right/wrong, no correct option | Strong; answer is locked, so no in-run oracle | Use for solo |
| C. Client holds key | Current UX | Broken | Remove |

Rules:

- Never send `correctAnswerIndex` for a question the caller can still answer.
- Never send the key for a **challenge** until the match is resolved — otherwise the first
  player can hand answers to the second.
- If option B is used, the response is `{correct: bool}` only. Even a probing attacker
  learns only “that guess was wrong”, which is indistinguishable from playing.

### 6.3 Attestation

**App Check (baseline, required):**

- Ship the release build that calls `AppCheckService.activate()` before Firebase use.
- Monitor for 7 days; confirm no legitimate client is tokenless.
- Set `ENFORCE_APP_CHECK=true` at deploy **and** `app_config/security.enforceAppCheck=true`.
- Enable Firestore App Check enforcement in the Firebase console (rules cannot do this).
- Keep a documented outage valve: the runtime flag can be turned off without redeploying.

**Play Integrity (Android, high-value calls):**

App Check validates a token but does not expose the verdict to the function. For
create/join challenge, submit run, payouts, and referral cash-out, add a second gate:

1. Client requests a Play Integrity standard token with a server-issued nonce
   (`requestHash = sha256(nonce + uid + action)`, nonce single-use, 2-minute TTL).
2. Server calls `decodeIntegrityToken` and checks:
   - `requestDetails.requestHash` matches the stored nonce;
   - `appIntegrity.packageName` is ours;
   - `appIntegrity.certificateSha256Digest` equals the release signing cert;
   - `deviceIntegrity` includes `MEETS_DEVICE_INTEGRITY` (and `MEETS_STRONG_INTEGRITY`
     for payouts);
   - `appLicensingVerdict` is not required for a sideloaded APK — do not reject solely on
     `UNLICENSED`.
3. Sideload nuance: because the app is distributed as an APK, do **not** require
   `PLAY_RECOGNIZED`. Pin the certificate digest instead; that is what proves the binary
   is signed by us. Treat `UNEVALUATED` as failure for money paths.

**iOS:** App Attest is hardware-backed and stronger than a client check. Keep App Check as
the gate; add an App Attest assertion with a server nonce for payout and referral cash-out
if the iOS volume justifies the work.

**Web:** no earning. If a web client must exist, cap it to casual AC and exclude it from
WP/prizes.

### 6.4 Ranked vs casual (the “can't cash out a cheat” lever)

- **Ranked run:** attested device/app, server-timed, server-chosen questions, no integrity
  gaps. Counts for `weeklyPoints`, leaderboard entry, and prizes.
- **Casual run:** anything else (failed attestation, offline, emulator, web). Still earns a
  small, hard-capped AC amount so the game is playable; **cannot** affect WP or prizes.
- Surface this honestly in the UI (“Ranked — counts for the weekly prize” vs “Casual”).
- This converts an undetectable client compromise into “the cheat can't win money” rather
  than “we must detect every cheat”.

### 6.5 Risk engine and enforcement ladder

Replace the weekly, admin-triggered advisory score with an incremental score updated on
each high-value event (or lazily every N minutes).

Signals (server-observed only):

- answer latency distribution: rapid gaps, low variance, impossible totals;
- per-question accuracy across the population (leaked/too-easy questions);
- perfect-run rate over the last 20 runs vs the population;
- solo volume/day, gauntlet retries, ad claims, referral velocity;
- device/install graph: accounts per install, shared IP/ASN;
- staked-duel pair graph: repeated pairs, win-rate funnels, reciprocal staking;
- payout graph: shared bank account, shared beneficiary name, rapid destination changes;
- account age vs WP, new-account leaderboard entries;
- App Check / Play Integrity failures and denied Firestore reads.

**Enforcement ladder (silent first):**

| Score | Action |
|---|---|
| Low | Nothing |
| Moderate | Reward decay (0.5×), no upset bounty, softer matchmaking |
| High | Leaderboard exclusion + payout hold + manual review; still playable |
| Critical | Suspension pending review; evidence snapshot preserved |

Principles:

- **Shadow enforcement beats hard rejection.** A visible `cheat_detected` error teaches the
  attacker the threshold. Decay, exclusion, and holds do not.
- **Never auto-ban on a single signal.** Shared devices, shared IPs, and family accounts are
  normal in this market. Require corroboration.
- **Explain and appeal.** Store reasons as codes with inputs; support can review.
- **Preserve evidence before any destructive action** (`fraudEvidence/{uid}/{runId}`).

### 6.6 Identity and device integrity

- **Install ID:** generate on first launch, store in secure storage, send with high-value
  calls, bind to the integrity verdict. Hash before storage.
- **Accounts per install:** soft cap (e.g., 3) with review above; hard cap only for
  money-path eligibility. Shared devices are common — do not block gameplay.
- **Email:** already unique per normalized address (`emailIdentities`). Add disposable-domain
  risk flags on the verification event; keep an email hash server-side.
- **Referral:** require a verified email on the referee, a ranked run, and a 7-day account
  age/retention window before the inviter is paid; require distinct install and no
  reciprocal referral; cap per install/IP/day in addition to the existing 10/30-day cap.
- **Payout:** payout account must be ≥7 days old, email-verified, and not shared with
  another UID; destination changes trigger re-auth + a 24h hold before payment.

### 6.7 Payout integrity

- `payoutAccounts/{sha256(bankCode|accountNumber)}` → `{uid, firstSeenAt}`. A second UID
  using the same account is a **hold + review**, never a silent block.
- Beneficiary-name similarity across accounts is a signal.
- Keep the 3-day claim window and the immutable cycle snapshot.
- Re-check the destination immediately before `markLeaderboardPayout`; log the admin,
  timestamp, and before/after values.
- Enforce a per-account weekly prize ceiling and a per-bank-account ceiling.
- Require re-authentication for any payout above a threshold.

### 6.8 Economy containment and reconciliation

- **Hard ceiling** on WP/day (e.g., 2× the expected legit max): after it, award **zero**,
  not 20%. The current 20% tail still pays a bot forever.
- Keep the weekly clamp at reset (10k) and the per-share prize ceiling.
- **Ledger reconciliation** (daily): recompute balance from `coinTransactions` and compare
  to `users.animeCoins`; flag drift > 0 in `riskProfiles` and alert.
- **Idempotency keys** for every grant (referral, ad, gauntlet, redemption, purchase).
- **Freeze switches** in `app_config/security`: `economyFrozen`, `payoutsFrozen`,
  `referralsFrozen`; all faucets check them and return a friendly message.
- **Grant audit**: every minted AC/WP has a type, a source doc, and a function name.

### 6.9 Detection, response, and admin tooling

- Move `scoreFraudForWeek` to a scheduled job that runs **before** payouts and on demand;
  keep the admin-triggered path.
- Add an **admin fraud console**: risk score, reasons, run history, device/install graph,
  payout graph, evidence export, and one-click hold/clear/suspend.
- **Alerts** via Cloud Monitoring log-based metrics:
  - any denied read of `questions` (a client probing the locked collection);
  - App Check failure rate > 1%;
  - Play Integrity failure spike;
  - a new account entering the top 10;
  - >N accounts sharing an install/IP/bank account in 24h;
  - ledger drift;
  - a single question with >95% accuracy over ≥50 answers.
- **Question analytics:** track accuracy per question; rotate leaked or trivial questions.
  This is also a content-quality loop.
- **Red-team suite** in CI (see §8).

### 6.10 Supply chain and operations

- Rotate every secret that has ever been committed: `lib/passwords.txt` (already flagged as
  compromised), Flutterwave keys/hash, reset secret, any service-account key.
- Keep the Android release keystore offline; never in the repo or CI artifacts. Pin its
  SHA-256 in the server integrity check.
- 2FA/hardware key on the Firebase/Google accounts that can deploy functions or write
  `app_config`; review `ADMIN_UIDS` quarterly.
- CI: run `flutter analyze`, `node --test test/*.test.js`, and the rules emulator suite on
  every PR. Do not give untrusted PRs deploy credentials.
- Log and alert on admin callable use; keep an immutable admin audit collection.
- Document a rollback: functions + rules are deployable independently; keep the previous
  rules file (the repo already has `rollback/firestore.rules.bak`).

---

## 7. Phased roadmap

### P0 — Close the open door (target: 3–5 dev-days)

| # | Change | Files |
|---|---|---|
| P0.1 | Deny client reads of `questions`; add sanitized `getQuizRun`/`getChallengeRun`; move hint elimination server-side | `firestore.rules`, `functions/index.js`, `firestore_service.dart`, `quiz_controller.dart`, `option_tile.dart`, `progress_segments.dart` |
| P0.2 | Server-minted run doc with `questionIds` + `answerKey` + difficulty; bind solo and gauntlet submits to `runId` | `functions/index.js`, `quiz_controller.dart`, `questions_page.dart` |
| P0.3 | Stop trusting client `soloDifficulty` and `timings`; derive from run doc | `functions/index.js` |
| P0.4 | Lock `app_config/antifraud` + `security` reads (move to `server_config/**`) | `firestore.rules`, `app_update_service.dart` |
| P0.5 | Bind `saveGhostSession` to a completed run | `functions/index.js` |
| P0.6 | Enable App Check enforcement (functions env + runtime flag + Firestore console) | deploy config |
| P0.7 | Force update past the legacy submit paths | `app_config/android.minBuild`, `pubspec.yaml` |

**Acceptance:** a script with a valid token cannot obtain any `correctAnswerIndex`; cannot
submit a run with a question set or difficulty it chose; cannot replay a run; a normal
client plays unchanged.

### P1 — Make bypass unprofitable (target: 1–2 weeks)

- Ranked vs casual split; WP only from attested, server-timed runs.
- Play Integrity direct verification + certificate pinning on high-value calls.
- Incremental risk engine + enforcement ladder (shadow decay → exclusion → hold).
- Hard daily WP ceiling; ledger reconciliation job; freeze switches.
- Payout account fingerprinting + re-auth + hold on destination change.
- Referral device/verified-email/retention gates.
- Global rate-limit helper; one active run per UID; per-IP signup caps.

**Acceptance:** a fully patched client on a rooted device can still play, but its runs are
casual, its WP is zero, and any payout is held. A high-risk account cannot be paid without
a human clearing it.

### P2 — Detect and attribute (target: 2–4 weeks)

- Install ID + device/account graph, shared-device policy.
- Admin fraud console + evidence snapshots + appeal flow.
- Question accuracy analytics + rotation.
- Cloud Monitoring alerts.
- iOS App Attest assertions for payout/cash-out.
- Disable earning on web (or cap to casual).

**Acceptance:** an admin can trace any suspicious payout to runs, installs, IPs, and
accounts in under 5 minutes, and freeze it with one action.

### P3 — Continuous assurance

- Quarterly red-team exercise against staging (answer scrape, replay, difficulty spoof,
  ghost poisoning, referral ring, payout redirect).
- Key/secret rotation calendar.
- Rules regression suite grows with every new collection/callable.
- Re-score historical leaderboards offline; publish a corrections policy.

---

## 8. Red-team acceptance suite

Add `functions/test/anticheat.test.js` (in-memory fakes) and extend `rules.test.js`:

1. **Answer-key denial:** authenticated read of `questions/*` is denied; the sanitized
   callable response contains no `correctAnswerIndex`.
2. **Run binding:** submit with a different question set → `question_set_mismatch`;
   different difficulty → rejected; another user's runId → `not_found`/`permission_denied`.
3. **Replay:** second submit of the same run → returns the stored result, no second award.
4. **Expiry:** submit after `expiresAt` → `run_expired`, no award.
5. **Difficulty spoof:** request `hard`, run doc says `easy` → reward table is `easy`.
6. **Timing forgery:** client timings ignored; server-derived elapsed used.
7. **Parallel runs:** second mint while a run is active → `run_in_progress`.
8. **Ghost poisoning:** ghost save without a completed run → rejected; with another UID's
   run → rejected.
9. **Referral ring:** same install or same email identity → bonus held; reciprocal referral → held.
10. **Payout reuse:** same bank account from a second UID → hold flag set.
11. **Fraud ladder:** synthetic high score → leaderboard excluded, payout held.
12. **Ledger drift:** injected drift → reconciliation flags it.

These run without the emulator except the rules cases.

---

## 9. Metrics and alert thresholds (starting points)

| Metric | Target | Alert |
|---|---|---|
| App Check token coverage | >99.5% of calls | <98% for 15 min |
| Play Integrity pass rate (money calls) | >97% | <90% for 15 min |
| Perfect-run rate (population) | ~2–5% | >15% for a day |
| Runs/day per UID (p95) | <20 | >100 for 24h |
| Payout holds | <5% of claims | >15% in a week |
| Ledger drift accounts | 0 | any |
| Denied `questions` reads | ~0 | >10/min |
| Accounts per install (p99) | ≤3 | >10 |
| Same-bank-account UIDs | 1 | ≥2 |

Tune thresholds against real data; do not publish them.

---

## 10. Anti-patterns — do not do these

- **Obfuscation as security.** R8/Flutter obfuscation raises cost, nothing more. Never put
  a secret in the client and call it protected.
- **Root/emulator detection as a gate.** Trivially bypassed; use Play Integrity verdicts
  and behaviour, not `su` checks.
- **Hard `cheat_detected` errors.** They teach the attacker the threshold. Shadow-decay.
- **Trusting client timings, question IDs, difficulty, or “score”.** All are inputs, not
  facts.
- **Blocking shared devices/IPs outright.** Families and cybercafés are normal; use risk
  and review.
- **Loosening rules “to make it work”.** The rules are the last line of defence.
- **Keeping legacy unauth paths forever.** `requireAdSession`, legacy starter profile, and
  the old submit shape are all bypasses. Ship the new client and force-update.
- **Auto-banning on one signal.** False positives cost more than a delayed ban.

---

## 10a. P0 implementation status (2026-10-26)

Implemented in this tree:

- `getQuizRun` mints the authoritative run (server-chosen questions, server-held
  `answerKey`, difficulty, expiry) and returns sanitized questions only.
- `submitAnswer` locks solo answers and returns `{correct}` only.
- `submitRun` scores from the run doc and settles through the existing economy
  functions; `cancelRun` releases the one-active-run lock on quit.
- Solo is per-answer; Gauntlet and challenges are end-only. Hints moved to
  `useQuizHint` (server picks a wrong option and deducts 10 AC).
- `startSoloCooldowns`, `enterDailyGauntlet(runV2)`, and challenge/QM entry all
  refuse a second live run; Gauntlet mints its 7 questions **before** charging.
- The legacy `submitQuizAnswers` / `submitDailyGauntlet` paths are bound to the
  run's exact question set and server-chosen difficulty, so calling them
  directly cannot swap in an easier set or claim a harder reward table.
- **Legacy compatibility is verified end to end** for the shipped build: legacy
  solo start + direct submit, and legacy Gauntlet entry + direct submit, both
  settle correctly while `minBuild` is 1. `startSoloCooldowns` no longer
  requires a build stamp (the minBuild gate is the cutoff), so an unstamped
  shipped build can still play.
- **Legacy paths hard-reject after `minBuild` is raised.** The check is
  `minBuild > LEGACY_UNSTAMPED_BUILD` and needs no redeploy or extra flag:
  `startSoloCooldowns` / `enterDailyGauntlet` without `runV2`, `spendCoins`
  `spend_retry` without `runV2`, `submitQuizAnswers` on a session with no
  server-chosen question set, and `submitDailyGauntlet` with no run doc all
  return `App update required`. The new client sends `runV2` / always has a run,
  so it is unaffected. The 60s Android-config cache bounds the flip window.
- **`server_config/antifraud` + `server_config/security` are populated** with
  `scripts/seed_server_config.js` (dry run by default; `--commit` writes;
  `--check` verifies). The script merges any existing `app_config` copy and
  already-tuned `server_config` values, never silently lowering them. Functions
  log a one-time warning if a doc is missing instead of silently using defaults.
- **Free-Gauntlet re-entry cap:** `GAUNTLET_FREE_ENTRY_MAX = 3` per WAT day
  (`gauntletFreeEntryCount` / `gauntletFreeEntryDate`). Counts every free entry,
  so quit/re-enter cannot reroll the 7 questions indefinitely. Paid retries are
  unaffected.
- `saveGhostSession` requires a completed `quickmatch` run owned by the caller;
  arbitrary perfect ghosts are rejected.
- `app_config/antifraud` + `app_config/security` moved behind
  `server_config/**` (server-only); the client can no longer read the fraud
  thresholds.
- **`cleanupExpiredQuizRuns`** runs every 6 hours and deletes `quizRuns` docs
  whose `expiresAt` is more than 24h in the past. Bounded to 20 x 400-doc
  batches. Submitted results are retained long enough for a late retry; after
  that the challenge doc / `quizSessions` cache remains the result source.
- Rules lockdown (last step, deploy after the app): `questions`,
  `quizRuns`, `ghost_sessions`, `server_config` are sealed; `app_config`
  excludes `antifraud`/`security`.
- Tests: `functions/test/quiz_run.test.js` (23 cases), `server_config.test.js`
  (4 parity cases), `anticheat_p1.test.js` (11 cases), the updated rules suite
  (37 cases), the full Functions suite (260 tests), and the full Flutter suite
  (140 tests).

**Final deploy checklist (in order):**

0. **Pre-flight**
   - Confirm a service-account key is available (`--key`, env var, or
     `scripts/.service-account-key-path`).
   - Keep the rollback rules copy:
     `rollback/firestore.rules.pre-anticheat.bak` is the exact rules file from
     before this lockdown (including the referral/phone hardening (phone checks removed 2026-10-27, see §10) that was
     already in the working tree). `rollback/firestore.rules.bak` is the older
     baseline if you need it.
1. **Seed server-only config**
   - Dry run: `node scripts/seed_server_config.js`
   - Commit: `node scripts/seed_server_config.js --commit`
   - Verify: `node scripts/seed_server_config.js --check`
   - Expected: both `server_config/antifraud` and `server_config/security` exist
     with every required key. `enforceAppCheck` stays `false` (monitor) until
     the App Check soak is done; `requireAdSession` stays `false` until the old
     build is gone.
2. **Deploy Functions** — backward-compatible. The shipped build still uses the
   legacy solo/Gauntlet paths; `quiz_run.test.js` covers both end to end.
3. **Verify the shipped client** against the deployed Functions:
   - Legacy solo: `startSoloCooldowns` → direct questions → `submitQuizAnswers`.
   - Legacy Gauntlet: `enterDailyGauntlet` → direct questions →
     `submitDailyGauntlet`.
   - Both must pay. If either fails, stop and roll back Functions before
     shipping the app.
4. **Ship the new app build** that calls `getQuizRun` / `submitRun` and sends
   `runV2` on solo start, Gauntlet entry, and the paid retry.
5. **Raise `app_config/android.minBuild`** to that build:
   - `node scripts/set_android_config.js --min-build=<new> --latest-build=<new> --commit`
   - Within 60s the legacy paths hard-reject for clients that do not send
     `runV2` / have no run doc. The new client is unaffected.
   - Do **not** lower `minBuild` afterwards except for an emergency rollback;
     lowering it re-opens the legacy paths by design.
6. **Deploy the Firestore rules** (last):
   - `firebase deploy --only firestore:rules`
   - This is the step that breaks the old build's direct `questions` read. It
     must come after step 5 so old installs are already walled.
7. **Verify production**
   - A fresh solo/Gauntlet/challenge run returns `questions` with **no**
     `correctAnswerIndex`, and `quizRuns/{runId}` is unreadable from the client.
   - An authenticated client read of `questions`, `ghost_sessions`,
     `server_config/*`, `app_config/antifraud`, and `app_config/security` is
     denied.
   - `node scripts/seed_server_config.js --check` is green.
   - A 4th free Gauntlet entry in one WAT day returns
     `gauntlet_free_entry_limit`.
   - `cleanupExpiredQuizRuns` appears in Cloud Scheduler and logs a deletion
     count on its first run.

**Rollback**

- Rules: copy `rollback/firestore.rules.pre-anticheat.bak` over
  `firestore.rules`, then `firebase deploy --only firestore:rules`. This
  re-opens direct `questions`/`ghost_sessions` reads, so only do it together
  with a Functions rollback and a `minBuild` rollback.
- Functions: redeploy the previous commit
  (`firebase deploy --only functions`).
- Update gate: lower `minBuild` with
  `node scripts/set_android_config.js --min-build=<old> --latest-build=<current> --commit`.
  This deliberately re-opens the legacy paths; it is an emergency lever, not a
  routine operation.
- `server_config` docs can stay; the Functions fallback reads them, and the
  pre-anticheat Functions ignore them.

**P1 deployed (2026-10-27)**

- Seeded `server_config/antifraud`, `server_config/security`, and
  `server_config/play_integrity` via the REST path of
  `scripts/seed_server_config.js`; `--check` is green.
  Play Integrity is pinned to package `com.animequiz.app` and certificate digest
  `6edYv6JkZWefkzNwgx-1zO4Kh22eBnjQuHvRqp5r8QE`, **log-only** (`enforce:false,
  logOnly:true`).
- Deployed Functions in named batches:
  - Integrity/admin: `getIntegrityChallenge`, `scoreFraudForWeek`,
    `repairAntifraudConfig`, `listPayoutClaims`, `listReferralCashoutClaims`.
  - Run lifecycle: `getQuizRun`, `submitAnswer`, `useQuizHint`, `submitRun`,
    `cancelRun`, `cleanupExpiredQuizRuns`.
  - Quiz entry/settlement: `startSoloCooldowns`, `enterDailyGauntlet`,
    `spendCoins`, `submitQuizAnswers`, `submitDailyGauntlet`,
    `submitChallengeScore`, `submitQuickMatchResult`, `saveGhostSession`.
  - Money/prize + cleanup: `submitPayoutDetails`, `savePayoutDetail`,
    `claimReferralCashout`, `weeklyReset`, `triggerWeeklyReset`,
    `resolveChallengeOutcome`, `deleteAccount`, `cleanupDeletedUser`.
- Production verification used `scripts/verify_anticheat_prod.js` (throwaway
  Auth user, deleted afterwards):
  - `server_config` keys present in all three docs.
  - `getQuizRun`: 7 sanitized Gauntlet questions, **no `correctAnswerIndex`**.
  - 4th free Gauntlet entry: `FAILED_PRECONDITION gauntlet_free_entry_limit`.
  - `cleanupExpiredQuizRuns` scheduler: **ENABLED**, every 6 hours.
- Play Integrity API (`playintegrity.googleapis.com`) enabled.
- IAM repair: `getIntegrityChallenge`, `cancelRun`, and the recreated
  `saveGhostSession` needed public invoker bindings after creation. Granted
  `roles/cloudfunctions.invoker` and `roles/run.invoker` to `allUsers` on those
  services. `cancelRun` now flips `state=cancelled` and clears `activeRunId`
  (verified in the production run).
- Deploy capacity note: a Cloud Run CPU-quota error on the us-central1 project
  required deleting/recreating the `saveghostsession` and `cancelrun` services.
  `saveGhostSession` now runs at `cpu:0.5`, `maxInstances:1`. If a future batch
  hits the same quota, deploy one function at a time and free an unused
  service; do not delete player-facing functions.

**Still pending**

- **New app build with Play Integrity token support.** Contract:
  1. `getIntegrityChallenge({action})` → `{nonce}`.
  2. Request a standard Play Integrity token with `requestHash = nonce`.
  3. Send `{integrityToken, integrityNonce}` on the money call
     (`submitRun` / `submitPayoutDetails` / `claimReferralCashout`).
  Until then the mode stays log-only; flipping enforce would reject the shipped
  build with `integrity_required`.
- **`app_config/android.minBuild` was NOT raised.** Legacy quiz paths remain
  available. Raise it only after the new build is live; that is what retires
  the legacy start/submit/retry paths.
- **`firestore.rules` was NOT deployed.** The file contains the lockdowns for
  `questions`, `quizRuns`, `ghost_sessions`, `server_config`, `enforcement`,
  `flaggedAccounts`, `payoutAccounts`, and `integrityChallenges`, but the old
  build still reads `questions` directly until the rules deploy.
- The silent enforcement ladder is live for payout-account reuse, impossible
  server timings, repeated binding mismatches, and integrity failures once
  enforced. Integrity failures are **not** auto-suspending in log-only mode.
- `scripts/unban.js` is added but was not run; it requires a service-account
  key (`--key` / env / `.service-account-key-path`).

**Build 5 (2026-10-27, `1.2.1+5`)**

- Client Play Integrity: `lib/core/services/play_integrity_service.dart` calls
  `getIntegrityChallenge`, requests a standard token with `requestHash = nonce`
  through the native channel `com.animequiz.app/play_integrity`
  (`MainActivity.kt`, `com.google.android.play:integrity:1.4.0`), and attaches
  `{integrityToken, integrityNonce}` to `submitRun`, `submitPayoutDetails`,
  `savePayoutDetail`, and `claimReferralCashout`. Any failure sends the call
  without a token. Gameplay is never blocked client-side. Per-question
  `submitAnswer` and the legacy submit names are not client-called, so they
  carry no token.
- Release APK built (`flutter build apk --release`, 70,746,825 bytes). Verified
  with apksigner: signer SHA-256 `e9e758bf…6bf101`, the pinned cert. aapt2:
  `versionCode=5`, `versionName=1.2.1`.
- Published to `public/downloads/animequiz-5.apk`, and `latest.json` updated to
  build 5. Hosting deployed (`firebase deploy --only hosting`, release
  complete).
- Phone auth (production, checked via the Identity Toolkit and Firebase REST
  APIs; **removed 2026-10-27**): phone sign-in was **enabled** at that time. The release SHA-1 `5ea93d69…9284` and
  SHA-256 `e9e758bf…6bf101`, and debug SHA-1 `398d8f3c…4347`, are registered for
  `com.animequiz.app`. No test-phone numbers are configured. SMS delivery to
  `+2348114753969` has **not** been exercised from here; it needs a device run.
- `flutter analyze`: clean. `flutter test`: 140 passed.
- apkUrl reachability: the owner confirmed the APK loads in a browser. My own
  check from this machine was refused by the network, so that confirmation is
  the owner's.
- **Gate armed:** `app_config/android` is now `minBuild=5, latestBuild=5,
  apkUrl=https://anime-quiz-1ab1b.web.app/downloads/animequiz-5.apk`. Builds
  below 5 are walled. Applied via the Firestore REST API with an updateMask
  on those three fields, because `set_android_config.js` needs a service-account
  key that this machine does not have.
- **Rules deployed:** `firebase deploy --only firestore:rules` released
  `firestore.rules`. Rollback copy: `rollback/firestore.rules.pre-anticheat.bak`.
- **Production checks after deploy (`scripts/verify_anticheat_prod.js`, throwaway
  user, deleted):** server_config keys present and log-only; `getQuizRun` returned
  7 questions with no `correctAnswerIndex`; the 4th free Gauntlet entry was
  rejected with `gauntlet_free_entry_limit`. Anonymous read of `questions` is
  Forbidden. Anonymous read of `app_config/android` succeeds (minBuild 5,
  latestBuild 5).
- **Not yet tested (moot after 2026-10-27):** that a real build 4 client is walled by the
  gate, and SMS delivery to a test number on a device. Phone auth has since been removed,
  so the SMS test no longer applies.

**Phone auth removed (2026-10-27)**

- Phone sign-in and SMS verification were removed from the product. The app now uses
  email verification at login (`request.auth.token.email_verified`); see
  `docs/email-verification-plan.md` for the client and server changes.
- The `17028 Invalid app info in play_integrity_token` error was a symptom of the app being
  distributed as a sideloaded APK (`public/downloads/animequiz-5.apk`) that Play Integrity
  cannot attest. It is no longer relevant because phone auth is gone.
- Unverified accounts may play solo only; multiplayer, challenges, Quick Match, the paid
  leaderboard, payouts and referral rewards require a verified email.
- Email verification, abuse limits, device/self-referral checks, the pair reward cap and
  the 7-day unverified cleanup are covered by `functions/test/email_verification.test.js`,
  `abuse_limits.test.js`, `account_farming.test.js` and the rules suite.
- **App Check and Play Integrity enforcement remain OFF**
  (`ENFORCE_APP_CHECK` unset, `server_config/security.enforceAppCheck=false`,
  `server_config/play_integrity.enforce=false`). Do not flip either until a
  Play-distributed build has been tested end to end.
- App Check debug token `155a399a-9e51-4a3b-aed7-d7ca2e1be509` still needs to be
  registered in the console for local debug builds (non-fatal while monitor
  mode is on).
**Enforce-mode switch steps**

1. Ship the new build and confirm Play Integrity token coverage in log-only
   mode (no `integrity_*` failures).
2. Confirm the Cloud Functions runtime service account can call
   `decodeIntegrityToken` with a real token. If it cannot, grant the required
   Play Integrity access and retest before enabling.
3. Set `server_config/play_integrity` `{ enforce: true, logOnly: false }` via
   the console or Admin SDK. Do **not** use `seed_server_config.js --force`
   (it would write defaults); a normal `--commit` merge is safe.
4. Raise `app_config/android.minBuild` to the new build.
5. Deploy `firestore.rules` (last).
6. Watch `enforcement` / `flaggedAccounts`; review payout holds; clear false
   positives with `scripts/unban.js`.

---

## 11. Open decisions

1. **UX trade-off:** accept end-of-run reveal for solo, or per-answer `{correct}` checks
   (extra round-trip per question)? Recommendation: per-answer for solo, end-only for
   gauntlet/challenge.
2. **Play Integrity scope:** enforce strong integrity on all WP-bearing runs, or only on
   payouts/referrals? Recommendation: device integrity on runs, strong + cert pin on money.
3. **Web earning:** disabled entirely, or casual-AC only? Recommendation: disabled.
4. **Shared-device policy:** how many accounts per install before review (3 vs 5)?
5. **Payout review threshold:** value above which a human must clear a claim before payment.
6. **Ban policy:** suspension duration and appeal SLA.

---

## 12. First PR (concrete)

1. `firestore.rules`: change `questions` to `allow read: if false;` and add
   `server_config/**` denied; move `antifraud`/`security` there. Update `rules.test.js`.
2. `functions/index.js`: add `quizRuns` helpers (`_mintRun`, `_loadRun`, `_settleRun`),
   `startSoloRun`, and `submitRun`; keep the old callables temporarily behind a
   `legacySubmit` flag that reads `minBuild`.
3. `firestore_service.dart` + `quiz_controller.dart`: fetch sanitized questions from the
   callable, submit `runId`, stop sending `soloDifficulty`/`timings` as authority.
4. Tests: the new `anticheat.test.js` cases 1–7.
5. Deploy in monitor mode; verify no legitimate client breaks; then raise `minBuild`.

---

*Nothing in this document requires loosening `firestore.rules`, exposing a secret, or
trusting a client-supplied value. If a proposed fix does, it is the wrong fix.*
