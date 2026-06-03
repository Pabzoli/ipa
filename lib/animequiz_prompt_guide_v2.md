# AnimeQuiz — Fix Prompt Guide (Revised v2)
### Master Strategy v3 · Full Economy · Logical Ad Placement · 30 Stages · Claude Sonnet 4.6

> **How to use this guide**
> Stages 01–13 are complete — see the summary table below. Continue from Stage 14.
> Work through stages in order. Each stage is a single focused prompt — copy it,
> attach the listed files, and send. Complete each stage fully before moving to the
> next. Stages within the same Phase can sometimes be parallelised (noted where
> relevant), but cross-Phase dependencies are hard — never skip ahead.

---

## ✅ PHASES 0–3 — COMPLETE (Stages 01–13)

| Stage | What | Key files touched |
|-------|------|-------------------|
| 01 | Firestore rules — lock weeklyPoints, remove totalScore loophole, add matchmaking + ghost rules | `firestore.rules` |
| 02 | Fix fetchQuestions to use `fromDoc` (populate question IDs) | `firestore_service.dart` |
| 03 | `submitQuizAnswers` Cloud Function — server-side scoring + idempotency | `index.js` |
| 04 | Rename bet/wager → stake language across all multiplayer files | `bet_screen.dart`, `challenge_model.dart`, `challenge_lobby_page.dart`, `challenge_result_page.dart`, `join_challenge_page.dart`, `multiplayer_hub_page.dart`, `anime_select_page.dart` |
| 05 | Rewarded ad rate → 10 AC, daily cap → 10/day | `index.js`, `ad_service.dart`, `user_data_provider.dart` |
| 06 | Streak milestones corrected → 3-day (+25 AC), 7-day (+60 AC) | `index.js` |
| 07 | Challenge wins → +15 AC win, +5 AC draw (flat, replaced by Stage 16) | `index.js` |
| 08 | `recordRewardedInterstitialWatch` CF → +5 AC (corrected to 0 AC in Stage 15) | `index.js`, `ad_service.dart` |
| 09 | Wire quiz completion to `submitQuizAnswers` (client) | `quiz_controller.dart`, `solo_summary_page.dart` |
| 10 | Login streak WP bonuses — 3-day (+30 WP), 7-day (+100 WP), 14-day (+200 WP) | `index.js`, `user_data_provider.dart` |
| 11 | Fix `weeklyReset` — top-3 prize split, WP cap, reset `lastStreakWPMilestoneAwarded` | `index.js` |
| 12 | Quick Match Cloud Functions — matchmaking, ghost sessions, `submitQuickMatchResult` | `index.js` |
| 13 | Quick Match UI wiring | `multiplayer_hub_page.dart`, `quick_match_result_page.dart`, `anime_select_page.dart`, `quiz_controller.dart` |

> **Note on Stage 07 and Stage 08:** Stage 16 replaces the flat +15 AC challenge win logic
> with the 80/20 house-fee stake model. Stage 15 removes the 5 AC interstitial reward.
> Both are corrections, not conflicts — completing them supersedes the earlier work.

---

## PHASE 3.5 — ECONOMY & AD CORRECTIONS v2
### Closes the gaps between what shipped in Phases 0–3 and the full Master Strategy.
### Complete all four of these before starting Phase 4 — earn rates, the stake model,
### and the QM token system all affect downstream stages.

---

### Stage 14 — Economy Corrections v2 (Earn Rates, QM Payouts, Streak Milestone)
**Effort: Medium | Thinking: OFF**
**Attach:** `index.js`, `user_data_provider.dart`

```
You are updating AnimeQuiz earn rates and Quick Match payouts to match the final
Master Strategy numbers. Stages 05, 07, and 12 shipped placeholder values.

CHANGE 1 — Daily login bonus: 5 → 20 AC
  Find where the daily login AC grant is awarded. It will be in one or both of:
    (a) checkAndAwardDailyLogin() in user_data_provider.dart
    (b) a recordDailyLogin or similar Cloud Function in index.js
  Update every instance of the awarded animeCoins amount to 20.
  The weeklyPoints daily login grant is separate — do NOT change it.
  The coinTransactions record delta should also update to 20.

CHANGE 2 — Rewarded ad rate: 10 → 15 AC (recordAdWatch CF, index.js)
  In the recordAdWatch Cloud Function:
    currentCoins + 10  →  currentCoins + 15
    FieldValue.increment(10)  →  FieldValue.increment(15)
    delta: 10  →  delta: 15
    coinsAwarded: 10  →  coinsAwarded: 15
  Log line: update to show '/10 ads' still, only the per-ad amount changes.
  Daily cap stays at 10 ads per day.

CHANGE 3 — Quick Match ghost-match AC payouts (submitQuickMatchResult CF, index.js)
  In the GHOST MATCH resolution block, update the flat AC awards only:
    Win  → acEarned = 35   (was 10)
    Draw → acEarned = 15   (was 5)
    Lose → acEarned = 0    (no change)
  WP payouts stay unchanged: Win=35 WP, Draw=15 WP, Lose=5 WP.

CHANGE 4 — 14-day streak AC milestone: +150 AC (awardStreakMilestone CF, index.js)
  Add a new tier BEFORE the existing >= 7 check (highest milestone must come first):
    if (newStreak >= 14 && lastAwarded < 14) {
      award = 150;
      milestone = 14;
      type = 'earn_streak_14';
    }
  Add 'earn_streak_14' to the coinTransactions type allowlist in firestore.rules.

CHANGE 5 — Referral bonuses (if a referral CF exists in index.js)
  If a referral Cloud Function exists: update the referrer reward from 80 → 100 AC.
  If new users currently receive no signup bonus: add +50 AC to the user document
  at the moment of account creation (write it wherever user docs are first created).
  If no referral CF exists, add a TODO comment at the top of index.js.

Return only the changed functions/methods with inline comments marking each line changed.
```

---

### Stage 15 — Ad System Overhaul (Placement, Timing, Zero Interstitial Reward)
**Effort: High | Thinking: ON**
**Attach:** `ad_service.dart`, `index.js`, `solo_summary_page.dart`,
`quick_match_result_page.dart`, `challenge_result_page.dart`,
`weekly_leaderboard_page.dart`, `multiplayer_hub_page.dart`, `earn_coins_screen.dart`

> **Ad Placement Reference — implement exactly this, nothing more:**
>
> | Ad type | Screen | Trigger | Notes |
> |---------|--------|---------|-------|
> | Interstitial | Solo result, QM result, Challenge result | Every 3rd result across all three screens combined | 90 s cooldown · max 5/session · skip for premium users |
> | Rewarded | Earn Coins screen | User taps "Watch Ad" button | 15 AC · max 10/day |
> | Rewarded (QM token) | Multiplayer Hub — active window, 0 tokens | User taps "Get extra token" button | Grants 1 QM token, NOT AC · max 1 ad-token per window (Stage 17 wires the token grant) |
> | Banner | Weekly Leaderboard, Multiplayer Hub, Earn Coins screen | Page load | Skip for premium users |

```
You are overhauling the ad layer in AnimeQuiz. The current setup has two problems:
(1) rewarded interstitials incorrectly pay 5 AC (they shouldn't pay anything), and
(2) ads are placed inconsistently with no session frequency logic. Fix both.

────────────────────────────────────────────
PART A — index.js: zero out the interstitial reward
────────────────────────────────────────────
In the recordRewardedInterstitialWatch Cloud Function (added in Stage 08):
  Change the animeCoins increment from 5 to 0.
  Change delta: 5 to delta: 0.
  Change coinsAwarded: 5 to coinsAwarded: 0.
  Keep the function callable and keep writing the coinTransactions record for
  analytics (so we know how many interstitials fired), but the economic effect is
  now zero. Add a comment: "// Interstitials are revenue-only — no AC reward."

────────────────────────────────────────────
PART B — ad_service.dart: refactor the interstitial flow
────────────────────────────────────────────
Replace the existing showRewardedInterstitial() implementation with a standard
InterstitialAd (not RewardedInterstitialAd — the user gets nothing for watching).

Add a session-level counter (static fields, reset when app restarts):
  static int _sessionResultCount = 0;   // increments every time any result screen loads
  static int _sessionInterstitialsShown = 0;
  static DateTime? _lastInterstitialTime;

  static const int _interstitialEvery = 3;    // trigger every Nth result
  static const int _sessionMax = 5;           // hard cap per session
  static const int _cooldownSeconds = 90;     // minimum gap between interstitials

Add these public methods:
  /// Call this from every result screen as soon as it mounts.
  /// Internally decides whether to fire an interstitial.
  Future<void> recordResultAndMaybeShowInterstitial({required bool isPremium}) async {
    _sessionResultCount++;
    if (_shouldShowInterstitial(isPremium)) {
      await _showInterstitialAd();
    }
  }

  bool _shouldShowInterstitial(bool isPremium) {
    if (isPremium) return false;
    if (_sessionInterstitialsShown >= _sessionMax) return false;
    if (_sessionResultCount % _interstitialEvery != 0) return false;
    if (_lastInterstitialTime != null &&
        DateTime.now().difference(_lastInterstitialTime!).inSeconds < _cooldownSeconds) {
      return false;
    }
    return true;
  }

  Future<void> _showInterstitialAd() async {
    // Load InterstitialAd and show it.
    // On ad dismissed or failed: pre-load the next one.
    // Increment _sessionInterstitialsShown and stamp _lastInterstitialTime on show.
    // Remove the call to recordRewardedInterstitialWatch CF —
    //   interstitials no longer grant coins.
  }

Also update showRewardedAd() so that its per-ad reward callback still calls
recordAdWatch CF (now grants 15 AC — updated in Stage 14). No other changes to
the rewarded ad flow.

Add a prepareBannerAd() method and a BannerAdWidget (stateful widget) that:
  - Takes isPremium: bool parameter
  - Returns SizedBox.shrink() if isPremium == true
  - Otherwise loads and displays a standard AdMob BannerAd (320×50 or adaptive)
  - Disposes the ad in dispose()

────────────────────────────────────────────
PART C — result screens: wire up the interstitial trigger
────────────────────────────────────────────
In solo_summary_page.dart, quick_match_result_page.dart, and
challenge_result_page.dart:
  - In initState() (or the first frame callback after the result animation begins),
    call:
      adService.recordResultAndMaybeShowInterstitial(
        isPremium: context.read<UserDataProvider>().isPremium,
      );
  - Remove any existing calls to showRewardedInterstitial().
  - Do NOT show an interstitial if the user is navigating away immediately
    (guard with a mounted check before showing).

────────────────────────────────────────────
PART D — banner ads: add to three pages
────────────────────────────────────────────
In weekly_leaderboard_page.dart:
  Wrap the Scaffold body in a Column. At the BOTTOM (below the ListView, above the
  nav bar), add BannerAdWidget(isPremium: isPremium).

In multiplayer_hub_page.dart:
  Below the Quick Match button section (above any challenge list), add
  BannerAdWidget(isPremium: isPremium).

In earn_coins_screen.dart:
  At the very bottom of the scrollable content, add
  BannerAdWidget(isPremium: isPremium).

Read isPremium from UserDataProvider in all three pages.

────────────────────────────────────────────
PART E — earn_coins_screen.dart: update rewarded ad copy
────────────────────────────────────────────
Update the per-ad reward display from "10 AC" to "15 AC" wherever it appears in
the earn_coins_screen UI text.

Return all modified files in full.
```

---

### Stage 16 — Challenge House Fee + Stake Rules
**Effort: High | Thinking: ON**
**Attach:** `index.js`, `challenge_model.dart`, `bet_screen.dart`,
`challenge_lobby_page.dart`, `join_challenge_page.dart`

```
You are replacing the flat +15 AC challenge reward (Stage 07) with a proper stake
economy featuring a house fee. This is the most economically significant change in
the app — implement it carefully.

────────────────────────────────────────────
THE STAKE MODEL
────────────────────────────────────────────
  Win:  winner receives their own stake back PLUS 80% of the opponent's stake.
        The house retains 20% of the loser's stake.
  Draw: each player receives their own stake back MINUS a 5% fee.
        The house retains 5% of each player's stake.
  Lose: loser receives nothing (their stake was already deducted at join time).

Example at 200 AC stake:
  Win:  200 (own stake returned) + 160 (80% of opponent's 200) = 360 AC total received
  Draw: 200 - 10 (5% fee) = 190 AC received
  Lose: 0 AC

────────────────────────────────────────────
STAKE RULES (validate in every relevant CF)
────────────────────────────────────────────
  Minimum: 50 AC
  Maximum: 1,000 AC for standard users; 2,500 AC for premiumActive == true
  Increment: multiples of 50 only (validate: stakeAmount % 50 === 0)
  Daily limit: max 3 challenges CREATED per day; max 3 challenges JOINED per day
  Active cap: max 2 challenges per user simultaneously
    (active = status in ['waiting', 'opponent_joined',
                         'creator_submitted', 'opponent_submitted'])

NEW fields on the user document (add to wherever user docs are initialised):
  challengesCreatedToday: 0
  challengesCreatedDate: ''        // YYYY-MM-DD WAT
  challengesJoinedToday: 0
  challengesJoinedDate: ''

────────────────────────────────────────────
CLOUD FUNCTIONS
────────────────────────────────────────────

── createChallenge (onCall, us-central1) ──
  Input: { animeTitle, stakeAmount, opponentUid? (optional) }
  - Require auth.
  - Validate stakeAmount: positive number, >= 50, multiple of 50.
    Read user's premiumActive — if true, max is 2500, else max is 1000.
  - Helper: getWATDate(now) — returns YYYY-MM-DD string in UTC+1.
  - In a transaction:
    - Read users/{uid} for animeCoins, premiumActive, challengesCreatedToday,
      challengesCreatedDate, and count active challenges.
    - If animeCoins < stakeAmount: throw 'insufficient_coins'
    - If challengesCreatedDate != todayWAT: reset challengesCreatedToday = 0
    - If challengesCreatedToday >= 3: throw 'daily_challenge_limit_reached'
    - Count active challenges (query where creatorUid==uid OR opponentUid==uid
      with status in the active list). If >= 2: throw 'too_many_active_challenges'
    - Deduct stakeAmount from animeCoins.
    - Increment challengesCreatedToday. Set challengesCreatedDate = todayWAT.
    - Write coinTransactions: { type:'spend_challenge_stake', delta:-stakeAmount,
        balanceAfter, timestamp }
    - Create challenges/{autoId}:
        { creatorUid: uid, opponentUid: opponentUid||null, stakeAmount,
          animeTitle, status:'waiting', isQuickMatch:false,
          expiresAt: now+48h, createdAt: serverTimestamp }
  - Return { challengeId }

── joinChallenge (onCall, us-central1) ──
  Input: { challengeId }
  - Require auth. User must NOT be the creator.
  - In a transaction:
    - Read the challenge doc. Must have status:'waiting'.
    - Read users/{uid} for animeCoins, challengesJoinedToday, challengesJoinedDate.
    - If animeCoins < challenge.stakeAmount: throw 'insufficient_coins'
    - If challengesJoinedDate != todayWAT: reset challengesJoinedToday = 0
    - If challengesJoinedToday >= 3: throw 'daily_challenge_limit_reached'
    - Count active challenges for uid. If >= 2: throw 'too_many_active_challenges'
    - Deduct challenge.stakeAmount from user's animeCoins.
    - Increment challengesJoinedToday. Set challengesJoinedDate = todayWAT.
    - Write coinTransactions: { type:'spend_challenge_stake',
        delta:-challenge.stakeAmount, balanceAfter, timestamp }
    - Update challenge: { opponentUid: uid, opponentUsername: (read from user doc),
        status:'opponent_joined' }
  - Return { success: true, stakeAmount: challenge.stakeAmount }

── resolveChallengeOutcome (update the existing CF) ──
  Remove the flat +15 / +5 AC blocks added in Stage 07.
  Read stakeAmount from the challenge doc.
  
  After determining creatorWins / opponentWins / isDraw, inside the transaction:
  
  const stake = challenge.stakeAmount;
  const winnerBonus = Math.floor(stake * 0.8);  // 80% of loser's stake
  const winnerTotal = stake + winnerBonus;       // own stake returned + bonus
  const drawReturn = stake - Math.floor(stake * 0.05); // stake minus 5% fee
  const houseFee = isDraw
    ? Math.floor(stake * 0.05) * 2
    : Math.floor(stake * 0.2);

  if (creatorWins) {
    cUpdate.animeCoins = FieldValue.increment(winnerTotal);
    // loser (opponent) gets nothing — stake already deducted at joinChallenge
  } else if (opponentWins) {
    oUpdate.animeCoins = FieldValue.increment(winnerTotal);
  } else { // draw
    cUpdate.animeCoins = FieldValue.increment(drawReturn);
    oUpdate.animeCoins = FieldValue.increment(drawReturn);
  }

  Write coinTransactions for each player that receives coins (type:'earn_challenge_win').
  Write to house_fees/{autoId}: { challengeId, houseFee, stakeAmount,
    creatorUid, opponentUid, outcome:'win'|'draw', timestamp: serverTimestamp }

── expiredChallengeRefund (onSchedule '0 * * * *', us-central1) ──
  Every hour, query challenges where expiresAt < now AND status == 'waiting'.
  For each: refund the creator's stakeAmount (opponent never joined, so only the
  creator was charged). Update challenge status to 'expired_refunded'.
  Also query status == 'opponent_joined' AND expiresAt < now (both players joined
  but neither submitted). Refund both players. Update to 'expired_refunded'.

────────────────────────────────────────────
BET_SCREEN.DART (StakeScreen)
────────────────────────────────────────────
  Show the house fee clearly:
    - "Win: get back {stake} + {floor(stake×0.8)} = {stake + floor(stake×0.8)} AC"
    - "Draw: get back {stake - floor(stake×0.05)} AC"
    - "House fee: 20% of your opponent's stake on a win"
  Show the stake selector (multiples of 50, min 50, max based on premium status).
  Show: "X of 3 challenges remaining today" (read from user doc).
  If animeCoins < selectedStake: show warning chip "Not enough AC" and disable
  the Confirm button.

Return updated index.js (new/updated functions), updated challenge_model.dart
(add stakeAmount, challengesCreatedToday, challengesJoinedToday fields),
updated bet_screen.dart (StakeScreen), updated challenge_lobby_page.dart and
join_challenge_page.dart to use the new CFs instead of any client-side logic.
```

---

### Stage 17 — Quick Match Time Windows + Token System
**Effort: Max | Thinking: ON**
**Attach:** `index.js`, `multiplayer_hub_page.dart`, `user_data_provider.dart`, `ad_service.dart`

```
You are implementing the Quick Match time windows system for AnimeQuiz.
Quick Match is only available during three daily windows. Each window gives players
3 tokens; tokens expire when the window closes. This creates urgency and
concentrates players online during overlapping periods — improving real match rates.

────────────────────────────────────────────
WINDOW SCHEDULE (all times WAT = UTC+1)
────────────────────────────────────────────
  Morning Rush  : 07:00–10:00 WAT  (06:00–09:00 UTC)
  Afternoon     : 13:00–16:00 WAT  (12:00–15:00 UTC)
  Night Battle  : 19:00–23:00 WAT  (18:00–22:00 UTC)

Window ID format: '{windowName}_{YYYY-MM-DD-WAT}'
  e.g. 'morning_2025-01-20' — changes every day, resets tokens

────────────────────────────────────────────
USER DOCUMENT FIELDS (new)
────────────────────────────────────────────
  qmWindowId: string       // ID of the last window tokens were granted for
  qmTokens: number         // tokens remaining for qmWindowId (0–4)
  qmAdTokenUsed: bool      // true if the ad-token was already claimed this window

────────────────────────────────────────────
CLOUD FUNCTIONS (index.js)
────────────────────────────────────────────

── consumeQMToken (onCall, us-central1) ──
  Input: none
  - Require auth.
  - Compute currentWindowId using server time:
      function getWATWindowId(now) {
        const watHour = (now.getUTCHours() + 1) % 24;
        const watDate = getWATDate(now); // YYYY-MM-DD in UTC+1
        if (watHour >= 7  && watHour < 10) return `morning_${watDate}`;
        if (watHour >= 13 && watHour < 16) return `afternoon_${watDate}`;
        if (watHour >= 19 && watHour < 23) return `night_${watDate}`;
        return null; // outside all windows
      }
  - If currentWindowId is null: throw 'outside_qm_window'
  - In a transaction:
    - Read users/{uid}: qmWindowId, qmTokens, qmAdTokenUsed
    - If qmWindowId !== currentWindowId:
        // New window — lazily grant 3 fresh tokens
        qmTokens = 3; qmAdTokenUsed = false; qmWindowId = currentWindowId
    - If qmTokens <= 0: throw 'no_qm_tokens'
    - Decrement qmTokens by 1
    - Write the updated fields to the user doc
  - Return { success: true, tokensRemaining: qmTokens - 1, windowId: currentWindowId }

── grantAdQMToken (onCall, us-central1) ──
  Input: none
  - Require auth.
  - In a transaction:
    - Compute currentWindowId (same helper as above)
    - If null: throw 'outside_qm_window'
    - Read users/{uid}: qmWindowId, qmTokens, qmAdTokenUsed
    - If qmWindowId !== currentWindowId:
        qmTokens = 3; qmAdTokenUsed = false; qmWindowId = currentWindowId
    - If qmAdTokenUsed == true: throw 'ad_token_already_used'
    - If qmTokens >= 4: throw 'already_at_max_tokens'  // 3 base + 1 ad max
    - Increment qmTokens by 1. Set qmAdTokenUsed = true.
    - Write the updated fields.
  - Return { success: true, tokensRemaining: qmTokens + 1 }

Update joinMatchmakingQueue (from Stage 12) to call consumeQMToken logic FIRST
before entering the queue. If consumeQMToken would throw 'outside_qm_window' or
'no_qm_tokens', reject the QM attempt with the appropriate error before any
queue writes happen.

────────────────────────────────────────────
CLIENT — user_data_provider.dart
────────────────────────────────────────────
Add a helper class QMWindowSchedule (can be a top-level utility):

  class QMWindow {
    final String name;       // 'Morning Rush', 'Afternoon', 'Night Battle'
    final int startUTC;      // start hour in UTC
    final int endUTC;        // end hour in UTC (exclusive)
    const QMWindow(this.name, this.startUTC, this.endUTC);
  }

  class QMWindowSchedule {
    static const List<QMWindow> windows = [
      QMWindow('Morning Rush',   6,  9),   // WAT 07:00–10:00
      QMWindow('Afternoon',     12, 15),   // WAT 13:00–16:00
      QMWindow('Night Battle',  18, 22),   // WAT 19:00–23:00
    ];

    /// Returns the currently active window, or null if outside all windows.
    static QMWindow? currentWindow() {
      final nowUTC = DateTime.now().toUtc();
      for (final w in windows) {
        if (nowUTC.hour >= w.startUTC && nowUTC.hour < w.endUTC) return w;
      }
      return null;
    }

    /// Returns the DateTime (UTC) when the next window opens.
    static DateTime nextWindowStart() {
      final nowUTC = DateTime.now().toUtc();
      for (final w in windows) {
        final start = DateTime.utc(nowUTC.year, nowUTC.month, nowUTC.day, w.startUTC);
        if (start.isAfter(nowUTC)) return start;
      }
      // All windows passed today — return tomorrow's first window
      final tomorrow = DateTime.utc(nowUTC.year, nowUTC.month, nowUTC.day + 1);
      return DateTime.utc(tomorrow.year, tomorrow.month, tomorrow.day, windows.first.startUTC);
    }
  }

Stream qmTokens and qmAdTokenUsed from the user document via the existing
UserDataProvider stream so the UI reflects real-time Firestore values.

────────────────────────────────────────────
CLIENT — multiplayer_hub_page.dart
────────────────────────────────────────────
Replace the existing Quick Match button section with a QMWindowWidget that:

INSIDE AN ACTIVE WINDOW:
  - Show the window name with a green indicator: "🟢 Night Battle — open"
  - Show a token counter: "🎟 {qmTokens} token{s} remaining"
  - Quick Match button: ENABLED if qmTokens > 0 and the window is active.
    On tap: call consumeQMToken CF first. If successful, proceed to matchmaking.
    If 'no_qm_tokens': show snackbar "No tokens left — watch an ad for one more."
  - "Watch ad for extra token" button: VISIBLE only when qmTokens == 0 AND
    qmAdTokenUsed == false. On tap: call adService.showQMTokenAd(). On the ad
    completion callback, call grantAdQMToken CF. On success, refresh the token
    display. If qmAdTokenUsed == true: hide this button.

OUTSIDE ALL WINDOWS:
  - Quick Match button: DISABLED (greyed out)
  - Show a countdown: "Next window: Morning Rush in {H}h {M}m"
    Use a Timer.periodic(Duration(seconds: 30), ...) to update the countdown.
    Calculate using QMWindowSchedule.nextWindowStart().

ad_service.dart — add showQMTokenAd():
  Add a method showQMTokenAd({required VoidCallback onTokenGranted}).
  It loads and shows a rewarded ad (same ad unit as showRewardedAd).
  In the onUserEarnedReward callback: call the grantAdQMToken CF via
  httpsCallable. If the CF succeeds: call onTokenGranted(). If the CF fails:
  show a snackbar "Something went wrong — try again." Wrap in try/catch.
  Important: showQMTokenAd does NOT call recordAdWatch — it does not grant AC,
  only a QM token.

Return updated index.js (new CFs + updated joinMatchmakingQueue), updated
multiplayer_hub_page.dart, updated user_data_provider.dart (with QMWindowSchedule
and qmTokens streaming), and the updated ad_service.dart showQMTokenAd() method.
```

---

## PHASE 4 — DAILY CHALLENGE MODE

---

### Stage 18 — Daily Challenge Mode (1.5× WP Multiplier)
**Effort: High | Thinking: ON**
**Attach:** `home_page.dart`, `quiz_controller.dart`, `solo_summary_page.dart`, `firestore_service.dart`, `user_data_provider.dart`

```
You are implementing the Daily Challenge mode for AnimeQuiz, per Master Strategy v3:
"Daily Challenge session (1× per day) — 1.5× WP multiplier on all WP that session"

HOW IT WORKS:
  - Once per calendar day (WAT timezone), a player can mark one solo quiz session
    as their "Daily Challenge" — all WP earned in that session are multiplied by 1.5.
  - They can pay 40 AC to use a second Daily Challenge attempt (spend_retry).
  - If they haven't used it today, a prominent "Daily Challenge" badge/button
    appears on the anime selection area of home_page.dart.

IMPLEMENTATION:

firestore_service.dart:
  Add a field readers/writers for users/{uid}:
    dailyChallengeUsed: bool
    dailyChallengeDate: string (WAT date 'YYYY-MM-DD')
  Add method: Future<bool> isDailyChallengeAvailable()
    - Reads the user doc. Returns true if dailyChallengeDate != todayWAT
      OR dailyChallengeUsed == false.
  Add method: Future<void> markDailyChallengeUsed()
    - Sets dailyChallengeDate = todayWAT, dailyChallengeUsed = true.

home_page.dart:
  Add a "⚡ Daily Challenge" badge/button above the anime grid. When tapped, it
  sets a bool isDailyChallenge = true and starts the quiz. If isDailyChallenge
  was already used today, show an InsufficientCoinsSheet-style bottom sheet:
    "Daily Challenge already used — spend 40 AC for a second attempt?"
  If user confirms and has 40 AC, call userData.spendCoins(40, 'spend_retry'),
  then allow the quiz with isDailyChallenge = true.

quiz_controller.dart:
  Add constructor param: bool isDailyChallenge = false
  In _submitToServer() (built in Stage 09), if isDailyChallenge == true,
  multiply totalWP by 1.5 (round up) before sending to submitQuizAnswers CF,
  OR pass a isDailyChallenge flag to the CF and let it handle the multiplication.
  Prefer the CF approach — add an optional isDailyChallenge: bool field to the
  CF input and multiply totalWP by 1.5 there if true.
  After the CF returns success, call FirestoreService.markDailyChallengeUsed().

solo_summary_page.dart:
  If isDailyChallenge was active, show a "⚡ Daily Challenge" banner on the
  result card explaining the 1.5× WP multiplier was applied.

Return updated files in full.
```

---

## PHASE 5 — LEADERBOARD FEATURES

---

### Stage 19 — Leaderboard: Percentile Display
**Effort: Medium | Thinking: OFF**
**Attach:** `weekly_leaderboard_page.dart`, `firestore_service.dart`

```
You are adding percentile display to the weekly leaderboard page in AnimeQuiz,
per Master Strategy v3: show each player "You are in the top X% this week."

firestore_service.dart:
  Add method: Future<int> getWeeklyPlayerCount()
    - Counts documents in users collection where weeklyPoints > 0.
    - Use a count() aggregation query (Firestore SDK supports this).
    - Cache the result for the session (store in a static variable, refresh
      if > 5 minutes old).

weekly_leaderboard_page.dart:
  After fetching the user's rank (already available from the leaderboard stream),
  calculate: percentile = ((rank - 1) / totalPlayers * 100).ceil()
  But display as: "Top X%" where X = 100 - percentile clamped to [1, 99].
  (So rank 1 shows "Top 1%", rank 2/300 shows "Top 1%", rank 30/300 shows "Top 10%")

  Display this as a small chip/badge below the user's highlighted row in the list.
  Use the existing badge or chip pattern from your theme.

  Only show the percentile if the user has weeklyPoints > 0 (players with 0 WP
  have not competed this week — don't show "Top 100%").

Return updated files in full. Do not restructure the page layout.
```

---

### Stage 20 — Leaderboard: Campus Tab (Verify and Complete)
**Effort: Medium | Thinking: OFF**
**Attach:** `leaderboard_page.dart`, `weekly_leaderboard_page.dart`, `firestore_service.dart`

```
You are verifying and completing the Campus leaderboard tab in AnimeQuiz.
FirestoreService already has university-aware query methods. The leaderboard
pages reference initialTab: 1 for a "rivalry banner" but the third Campus tab
may not be fully wired up.

WHAT TO CHECK AND COMPLETE:

leaderboard_page.dart / weekly_leaderboard_page.dart:
  - There should be a TabBar with three tabs: Weekly 🏆 | All-Time ⭐ | Campus 🎓
  - If the Campus tab exists but is empty or shows a placeholder, build it out:
    - Query users where university == currentUserUniversity, ordered by
      weeklyPoints descending, limit 50.
    - Display as a list identical in structure to the Weekly tab.
    - At the top of the Campus tab, show a header:
      "Best at [University Name]" in large text.
    - The user's own row should be highlighted (isCurrentUser: true).

firestore_service.dart:
  - Ensure there is a campusLeaderboardStream(String university) method that
    streams the campus-filtered weekly points list. If it exists, verify it uses
    the correct field names. If it doesn't exist, add it.

If the three-tab structure already exists and Campus is complete, confirm this
and make no changes (return a description of what you found).

Return updated files or a confirmation of what was already in place.
```

---

### Stage 21 — Leaderboard: Rival System
**Effort: High | Thinking: ON**
**Attach:** `weekly_leaderboard_page.dart`, `firestore_service.dart`

```
You are building the Rival system for the weekly leaderboard in AnimeQuiz,
per Master Strategy v3:

"The player ranked directly above you gets a special Rival tag with a flame icon.
When you tap their profile, you see a direct 'Challenge Rival' button that creates
an async challenge immediately."

IMPLEMENTATION:

weekly_leaderboard_page.dart:
  - After the leaderboard list loads, find the entry ranked exactly one position
    above the current user. Tag it as the "Rival".
  - On that Rival's row, show a 🔥 flame icon and a "RIVAL" badge (small, orange).
  - Tapping the Rival's row opens a bottom sheet (not a full page) showing:
    - Rival's username, university, weekly points
    - A "⚔️ Challenge Rival" button
  - Tapping "Challenge Rival" navigates to the existing anime selection flow
    (AnimeSelectPage or equivalent) with opponentUid and opponentUsername
    pre-filled so the challenge is automatically directed at the Rival.
  - If the current user is rank 1, there is no Rival — show nothing extra.
  - If the user has 0 weeklyPoints (not on the leaderboard yet), no Rival.

firestore_service.dart:
  - Add method: Future<Map<String, dynamic>?> getRivalForUser()
    - Gets the current user's weeklyPoints rank, then fetches the user ranked
      one position above (query users ordered by weeklyPoints desc, use
      pagination to find rank N-1).

Return updated files in full.
```

---

## PHASE 6 — MONETISATION

---

### Stage 22 — IAP: Three Coin Packs (Updated Pricing)
**Effort: Max | Thinking: ON**
**Attach:** `earn_coins_screen.dart`, `user_data_provider.dart`, `firestore_service.dart`, `index.js`

```
You are implementing in-app purchases for Anime Coin packs in AnimeQuiz using
the in_app_purchase Flutter package (Google Play Billing). Add the package to
pubspec.yaml if it isn't there. Create these three products in Google Play Console.

THREE PRODUCTS (updated from any prior placeholder — these are the final prices):
  animequiz_coins_300   → 300 AC   for ₦500
  animequiz_coins_1000  → 1,000 AC for ₦1,500
  animequiz_coins_3000  → 3,000 AC for ₦4,000 + Champion badge (see below)

earn_coins_screen.dart:
  Add a "Buy Coins" section at the TOP (above the rewarded ads section).
  Show three product cards:
    - "Starter"  — 300 AC · ₦500   (good for 6 challenge entries)
    - "Value"    — 1,000 AC · ₦1,500
    - "Champion" — 3,000 AC · ₦4,000 + exclusive profile badge ⭐
  On Buy tap:
    1. Call InAppPurchase.instance.buyNonConsumable(PurchaseParam) for the
       selected product.
    2. Listen to InAppPurchase.instance.purchaseStream for the result.
    3. On PurchaseStatus.purchased: call verifyIAPPurchase CF with the
       purchaseToken and productId.
    4. Show a success animation (use existing CoinEarnAnimation) when CF confirms.
    5. On error: show a snackbar with the error message.

index.js — verifyIAPPurchase Cloud Function (onCall, us-central1):
  Input: { purchaseToken: string, productId: string }
  - Requires auth.
  - Idempotency: check users/{uid}/iapReceipts/{purchaseToken}.
    If it exists: return { success: true, alreadyClaimed: true }.
  - Determine acAmount and extras from productId:
      animequiz_coins_300   → acAmount = 300,  grantChampionBadge = false
      animequiz_coins_1000  → acAmount = 1000, grantChampionBadge = false
      animequiz_coins_3000  → acAmount = 3000, grantChampionBadge = true
    Throw 'invalid_product' if not in this list.
  - In a transaction:
    - Increment users/{uid}.animeCoins by acAmount
    - Write coinTransactions: { type:'iap', delta:acAmount, balanceAfter, timestamp }
    - If grantChampionBadge: set users/{uid}.hasChampionBadge = true
    - Write users/{uid}/iapReceipts/{purchaseToken}:
        { productId, acAmount, uid, claimedAt: serverTimestamp }
  - Return { success: true, coinsAwarded: acAmount, newBalance, championBadgeGranted }

Add a TODO comment in verifyIAPPurchase: where full Play Store server-side receipt
validation (Google Play Developer API) should be added post-launch.

Return all updated files.
```

---

### Stage 23 — Premium Pass (₦800/month + All Perks)
**Effort: Max | Thinking: ON**
**Attach:** `index.js`, `earn_coins_screen.dart`, `user_data_provider.dart`, `home_page.dart`, `weekly_leaderboard_page.dart`, `pi_page.dart`, `multiplayer_hub_page.dart`

```
You are implementing the Premium Pass subscription for AnimeQuiz at ₦800/month.
The premiumActive field is already streamed in UserDataProvider.

PRODUCT ID: animequiz_premium_monthly (auto-renewable subscription in Play Console)

PURCHASE FLOW — add a Premium card to earn_coins_screen.dart (or a new premium_screen.dart):
  Show all 8 perks (listed below) and a "Get Premium — ₦800/month" button.
  Use InAppPurchase for the subscription purchase (same pattern as Stage 22).
  On purchase confirmed, call verifyPremiumPurchase CF.

index.js — verifyPremiumPurchase (onCall, us-central1):
  Input: { purchaseToken: string }
  - Requires auth.
  - Idempotency: check users/{uid}/premiumReceipts/{purchaseToken}.
  - Set users/{uid}.premiumActive = true (server-side).
  - Write premiumReceipts/{purchaseToken}: { uid, activatedAt, expiresAt: now+31d }
  - Return { success: true }

index.js — awardPremiumMonday (onSchedule '1 23 * * 0', us-central1):
  Schedule: Sunday 23:01 UTC = Monday 00:01 WAT
  - Query all users where premiumActive == true (paginated, batch pattern).
  - For each in a batch:
    - Increment weeklyPoints by 30
    - Increment animeCoins by 30
    - Write coinTransactions: { type:'iap', delta:30, balanceAfter, timestamp }

THE 8 PREMIUM PERKS:

  Perk 1 — No interstitial ads:
    ALREADY DONE — ad_service.dart checks isPremium before showing interstitials
    and banners (implemented in Stage 15). Verify it still works.

  Perk 2 — 2× daily login bonus (40 AC instead of 20):
    In checkAndAwardDailyLogin() (user_data_provider.dart): if isPremium, grant
    40 AC instead of 20. Call the CF with a isPremium flag, or handle client-side
    after reading premiumActive.

  Perk 3 — +30 WP + 30 AC every Monday:
    Handled by the awardPremiumMonday CF above.

  Perk 4 — +1 extra base QM token per window (4 tokens instead of 3):
    In consumeQMToken CF (Stage 17): if user.premiumActive == true, grant 4 tokens
    on a new window instead of 3.
    In QMWindowSchedule on the client: premium users see "🎟 4 tokens" at window start.

  Perk 5 — Challenge stake limit raised to 2,500 AC:
    ALREADY DONE — Stage 16's createChallenge CF reads premiumActive to set the
    max stake. Verify the 2,500 cap is in place.

  Perk 6 — Gold "PRO" badge on leaderboard:
    weekly_leaderboard_page.dart: leaderboard entries with premiumActive == true
    show a small gold "PRO" chip next to the username. Ensure premiumActive is
    fetched in the leaderboard query.

  Perk 7 — Premium badge on player profile:
    pi_page.dart: show a gold "⭐ Premium" chip if the user's premiumActive == true.

  Perk 8 — Early anime access (1 week before free players):
    home_page.dart: if premiumActive == true, remove the unlock gate for anime
    titles marked comingSoon: true. Premium users see and can play them immediately.

Return all updated files and new CF functions.
```

---

### Stage 24 — Cosmetic Store (AC Sink)
**Effort: High | Thinking: ON**
**Attach:** `index.js`, `firestore_service.dart`, `earn_coins_screen.dart`, `pi_page.dart`

```
You are building a cosmetic store that gives high-AC users somewhere to spend
without affecting gameplay balance. Cosmetics are permanent one-time purchases.

────────────────────────────────────────────
COSMETIC CATALOG (hardcode in CF and client)
────────────────────────────────────────────
Profile frames (shown around the user avatar):
  frame_silver      → "Silver Aura"        150 AC
  frame_gold        → "Gold Aura"          300 AC
  frame_neon        → "Neon Burst"         400 AC
  frame_champion    → "Champion Crown"     500 AC  (also auto-granted with Champion IAP)

Username colours (tint the username in leaderboard and lobbies):
  color_crimson     → "Crimson"            150 AC
  color_sapphire    → "Sapphire"           150 AC
  color_emerald     → "Emerald"            150 AC
  color_gold        → "Gold"               200 AC

Title badges (displayed next to username):
  badge_otaku       → "Otaku" 🎌           200 AC
  badge_legend      → "Legend" ⚡          500 AC
  badge_godtier     → "God Tier" 👑       1000 AC

────────────────────────────────────────────
USER DOCUMENT FIELDS (new)
────────────────────────────────────────────
  ownedCosmetics: string[]     // list of cosmeticIds owned (array, default [])
  equippedFrame: string        // cosmeticId of equipped frame, or ''
  equippedColor: string        // cosmeticId of equipped username colour, or ''
  equippedBadge: string        // cosmeticId of equipped badge, or ''

────────────────────────────────────────────
CLOUD FUNCTIONS (index.js)
────────────────────────────────────────────

── purchaseCosmetic (onCall, us-central1) ──
  Input: { cosmeticId: string }
  - Require auth.
  - Hardcode a CATALOG map: { cosmeticId: { name, price } } for all items above.
  - If cosmeticId not in CATALOG: throw 'invalid_cosmetic'
  - In a transaction:
    - Read users/{uid}: animeCoins, ownedCosmetics
    - If cosmeticId is already in ownedCosmetics: throw 'already_owned'
    - If animeCoins < price: throw 'insufficient_coins'
    - Deduct price from animeCoins
    - Append cosmeticId to ownedCosmetics (FieldValue.arrayUnion)
    - Write coinTransactions: { type:'spend_cosmetic', delta:-price, balanceAfter, timestamp }
  - Return { success: true, cosmeticId, coinsSpent: price, newBalance }

── equipCosmetic (onCall, us-central1) ──
  Input: { slot: 'frame'|'color'|'badge', cosmeticId: string }
  - Require auth.
  - Validate slot value.
  - In a transaction:
    - Read users/{uid}.ownedCosmetics
    - If cosmeticId not in ownedCosmetics: throw 'not_owned'
    - Update the appropriate field:
        slot 'frame' → equippedFrame = cosmeticId
        slot 'color' → equippedColor = cosmeticId
        slot 'badge' → equippedBadge = cosmeticId
  - Return { success: true }

────────────────────────────────────────────
CLIENT — UI
────────────────────────────────────────────
Add a "Cosmetics" tab or section to earn_coins_screen.dart (or create a new
cosmetics_store_page.dart reachable from earn_coins_screen and pi_page).

Show each cosmetic as a card with:
  - Preview (use a placeholder icon/colour matching the cosmetic type)
  - Name and price in AC
  - State: "Own" button if not owned | "Equipped" chip if currently equipped |
           "Equip" button if owned but not equipped
  - If animeCoins < price: show the price in red and disable the buy button

pi_page.dart (profile page):
  Show the user's currently equipped frame, badge, and username colour.
  Add an "Edit" button that navigates to the cosmetics store.

Return updated index.js (purchaseCosmetic, equipCosmetic), updated
earn_coins_screen.dart or new cosmetics_store_page.dart, and updated pi_page.dart.
```

---

### Stage 25 — Anime Category Unlocks (AC Sink + Content Engagement)
**Effort: Medium | Thinking: OFF**
**Attach:** `index.js`, `home_page.dart`, `firestore_service.dart`

```
You are implementing locked anime categories that players permanently unlock with
Anime Coins. This creates spending events around new content drops and rewards
engaged players who have accumulated AC.

────────────────────────────────────────────
HOW IT WORKS
────────────────────────────────────────────
  - Some anime categories in the app can be marked as "locked" in Firestore.
  - Free players must spend 150 AC to permanently unlock a locked category.
  - Premium users automatically have access to all categories (no unlock required).
  - Once unlocked, the category is permanently available on that account.
  - Lock status and unlock price live in a Firestore config document, not in code.

────────────────────────────────────────────
FIRESTORE STRUCTURE
────────────────────────────────────────────
  app_config/categories (document):
    {
      "locked_categories": [
        { "animeTitle": "Attack on Titan", "unlockCost": 150 },
        { "animeTitle": "Chainsaw Man",    "unlockCost": 150 }
        // add more here as you launch new content
      ]
    }

  users/{uid}.unlockedCategories: string[]   // array of unlocked animeTitles

────────────────────────────────────────────
CLOUD FUNCTION (index.js)
────────────────────────────────────────────

── unlockCategory (onCall, us-central1) ──
  Input: { animeTitle: string }
  - Require auth.
  - Read app_config/categories to get the locked_categories list.
  - Find the entry for animeTitle. If not found: throw 'category_not_locked' (free category).
  - In a transaction:
    - Read users/{uid}: animeCoins, unlockedCategories, premiumActive
    - If premiumActive: throw 'premium_already_unlocked' (premium users can't spend AC here)
    - If animeTitle already in unlockedCategories: throw 'already_unlocked'
    - If animeCoins < entry.unlockCost: throw 'insufficient_coins'
    - Deduct unlockCost from animeCoins
    - Append animeTitle to unlockedCategories (FieldValue.arrayUnion)
    - Write coinTransactions: { type:'spend_unlock', delta:-unlockCost, balanceAfter, timestamp }
  - Return { success: true, unlockedCategory: animeTitle, coinsSpent: entry.unlockCost }

Add 'spend_unlock' to the coinTransactions type allowlist in firestore.rules.

────────────────────────────────────────────
CLIENT — home_page.dart + firestore_service.dart
────────────────────────────────────────────
firestore_service.dart:
  - Add: Future<List<Map<String,dynamic>>> getLockedCategories()
    Reads app_config/categories.locked_categories and returns the list.
  - Add: Stream<List<String>> unlockedCategoriesStream(String uid)
    Streams users/{uid}.unlockedCategories array.

home_page.dart:
  - When building the anime grid, check whether each tile's animeTitle appears
    in app_config locked_categories.
  - If it does and the user has NOT unlocked it AND user is not premium:
    - Show a lock overlay on the tile (semi-transparent with a 🔒 icon)
    - Show the unlock price: "150 AC to unlock"
    - On tap: show a bottom sheet: "Unlock [animeTitle] for 150 AC?"
        Confirm → call unlockCategory CF → on success, refresh the stream
        Cancel → dismiss
    - If user has insufficient AC: show "You need 150 AC. Earn more in the
      Coins screen." with a button to navigate to earn_coins_screen.
  - If premium: show all categories normally, no lock overlay.

Return updated index.js, home_page.dart, and firestore_service.dart.
```

---

## PHASE 7 — COMPLIANCE
### All five items are required before Play Store submission.

---

### Stage 26 — Age Gate (18+ First Launch)
**Effort: Low | Thinking: OFF**
**Attach:** `main.dart`

```
You are adding an 18+ age confirmation gate to AnimeQuiz that appears once on
first launch, before the user sees the login screen.

In main.dart:
  - Use SharedPreferences key 'age_confirmed' (bool).
  - In the AuthGate or just before it, check SharedPreferences.
  - If 'age_confirmed' is not set or false, show a full-screen modal/page
    (not dismissable by back button) with:
      Title: "Age Verification"
      Body: "AnimeQuiz includes competitive prize features. You must be 18 or
             older to participate."
      Two buttons:
        "I am 18 or older" → sets 'age_confirmed' = true, proceeds to app
        "I am under 18"    → shows message "You must be 18+ to use AnimeQuiz."
                             and does NOT proceed (app stays on this screen)
  - Use WillPopScope or PopScope to prevent back-navigation from this gate.
  - The gate must appear BEFORE Firebase Auth initialisation completes (check
    SharedPreferences synchronously in main() or use a FutureBuilder).

Keep the existing SplashScreen and AuthGate logic intact — this gate is a
one-time overlay before them.

Return the updated main.dart.
```

---

### Stage 27 — Terms & Conditions and Privacy Policy Screens
**Effort: Medium | Thinking: OFF**
**Attach:** `main.dart`, `login_page.dart`

```
You are adding Terms & Conditions and Privacy Policy screens to AnimeQuiz as
required by Google Play and Master Strategy v3.

CREATE two new simple screens (can be in a single new file: legal_screens.dart):

TermsAndConditionsPage:
  Scaffold with AppBar "Terms & Conditions" and a scrollable body containing
  placeholder text with the following sections (use section headers + body text):
    1. Eligibility (must be 18+, one account per person, Nigeria only at launch)
    2. Prize Competition (skill-based, weekly reset, top 3 winners, payout via
       bank transfer within 5 business days of Monday)
    3. Prize Claim Process (winners must contact us via the in-app form/WhatsApp
       within 7 days or prize is forfeited)
    4. Prohibited Conduct (multiple accounts, cheating, manipulating scores)
    5. Anime Coins (AC has no cash value, cannot be transferred or withdrawn)
    6. Contact (placeholder email animequiz.ng@gmail.com)

PrivacyPolicyPage:
  Scaffold with AppBar "Privacy Policy" and scrollable body covering:
    1. Data collected (Firebase Auth email/phone, username, quiz scores, device info)
    2. How data is used (leaderboards, prize payouts, app improvement)
    3. Third parties (Firebase, AdMob, Google Play)
    4. Data deletion (email us to delete your account)

login_page.dart:
  Below the sign-in button, add a small text line:
  "By continuing, you agree to our [Terms & Conditions] and [Privacy Policy]"
  Make both underlined text tappable — navigate to the respective screens.

main.dart (or app router):
  Register routes for both screens so they can be reached from Settings / Profile
  page as well.

Return the new legal_screens.dart and updated login_page.dart.
```

---

### Stage 28 — Phone OTP at Signup (Anti-Fraud)
**Effort: High | Thinking: ON**
**Attach:** `login_page.dart`, `auth_service.dart`

```
You are adding phone OTP verification to AnimeQuiz signup to enforce one account
per phone number, per Master Strategy v3 (required for prize fraud prevention).

The app currently uses email/password or Google Sign-In (check auth_service.dart
to confirm). Add Firebase Phone Auth as a required step during new account creation.

FLOW:
  1. User signs in with email or Google (existing flow — unchanged).
  2. If it is a NEW account (user.metadata.creationTime within last 60 seconds,
     or users/{uid} doc does not exist yet), redirect to PhoneVerificationPage
     before proceeding to the home screen.
  3. PhoneVerificationPage:
     - Text field for phone number (include country code selector, default +234)
     - "Send Code" button → calls FirebaseAuth.instance.verifyPhoneNumber()
     - OTP input (6 digits) → verify with PhoneAuthCredential
     - On success: write users/{uid}.phoneNumber and users/{uid}.phoneVerified = true
       to Firestore. Then proceed to home.
  4. If phone number already exists in another user's document (check Firestore
     for phoneNumber field): show error "A different account already uses this
     phone number" and sign out the user.

firestore_service.dart:
  Add: Future<bool> isPhoneNumberTaken(String phone)
    - Queries users collection where phoneNumber == phone, limit 1.
    - Returns true if any doc found that is NOT the current user.

Add 'phoneNumber' and 'phoneVerified' to the Firestore rules blacklist in Stage 01
output (update your rules file to include these — they should only be writable
during the OTP flow, so actually they CAN be client-written here; just make sure
they can't be updated after verification by adding them to the update blacklist
but not the create blacklist).

Return updated login_page.dart, auth_service.dart, and a new phone_verification_page.dart.
```

---

### Stage 29 — FCM Push Notifications (All 9 Types)
**Effort: Max | Thinking: ON**
**Attach:** `index.js`, `main.dart`

```
You are implementing all push notification types for AnimeQuiz using Firebase
Cloud Messaging (FCM). The client stores each user's FCM token on login; the
server sends notifications from Cloud Functions using the Admin SDK's messaging API.

PART A — main.dart (FCM token registration):
  Add firebase_messaging package. On app start (after auth):
  - Request notification permission.
  - Call FirebaseMessaging.instance.getToken() to get the FCM token.
  - Write token to users/{uid}.fcmToken (allow this field to be client-written —
    remove from blacklist or ensure it's not blocked).
  - Listen to FirebaseMessaging.instance.onTokenRefresh and update Firestore.
  - Handle foreground messages with FirebaseMessaging.onMessage.listen() —
    show a local notification or an in-app banner (use flutter_local_notifications
    or a simple overlay).

PART B — index.js (9 notification functions):
  Import admin.messaging() at the top.

  Helper: async function sendToUser(uid, { title, body })
    - Reads users/{uid}.fcmToken
    - Sends via admin.messaging().send({ token, notification: {title, body} })
    - Catches and logs token-not-found errors silently

  Function 1 — dailyStreakReminder (onSchedule '0 9 * * *', us-central1)
    Query users where lastLoginDate != todayWAT AND currentStreak >= 1.
    sendToUser: title '🔥 Don\'t break your streak!',
      body `Your ${streak}-day streak ends at midnight. Tap to keep it alive.`

  Function 2 — mondayPrizePoolAnnouncement (onSchedule '0 8 * * 1', us-central1)
    Read prize_pool/{thisWeekId}.totalNaira. Query all users (paginated):
    title '⚔️ New week, new prize pool!',
      body `₦${total.toLocaleString()} up for grabs. The competition starts now.`

  Function 3 — thursdayNearMiss (onSchedule '0 19 * * 4', us-central1)
    Fetch top 50 users by weeklyPoints. For users ranked 4–20:
    title '📊 You\'re within reach!',
      body `You\'re rank ${rank} — ${gap} WP behind 3rd place. 3 days left.`

  Function 4 — sundayUrgency (onSchedule '0 18 * * 0', us-central1)
    title '⏰ 6 hours left!',
      body `Prize pool: ₦${total.toLocaleString()}. Don\'t let someone sneak past you.`

  Function 5 — challengeReceivedNotification:
    Trigger on challenges/{challengeId} creation where opponentUid is set:
    title '⚔️ You\'ve been challenged!',
      body `${creatorUsername} challenged you to ${animeTitle}. Accept before it expires!`

  Function 6 — streakEndingWarning (onSchedule '0 21 * * *', us-central1)
    Query users where currentStreak >= 3 AND lastLoginDate != todayWAT:
    title '💔 Your streak ends at midnight',
      body `Your ${streak}-day streak disappears in 3 hours. Open AnimeQuiz to save it.`

  Function 7 — weeklyWinnerAnnouncement (trigger at end of runWeeklyReset):
    For each winner: title '🏆 You won!', body `You finished #${rank} and won ₦${prize}. Claim in the app.`
    For all other users: title '🏆 This week\'s winner!', body `${winner} from ${uni} won ₦${prize}! Can you beat them?`

  Function 8 — qmWindowOpening (three scheduled functions, one per window):
    Schedule 1: '0 6 * * *'  (Morning Rush opens, 07:00 WAT)
    Schedule 2: '0 12 * * *' (Afternoon opens, 13:00 WAT)
    Schedule 3: '0 18 * * *' (Night Battle opens, 19:00 WAT)
    For each: query all users with fcmToken set (paginated):
    title `⚡ ${windowName} is open!`,
      body `You have 3 Quick Match tokens. Use them before the window closes.`

  Function 9 — qmWindowWarning (three scheduled functions, 30 min before close):
    Schedule 1: '30 8 * * *'  (Morning Rush closes in 30 min, 09:30 WAT)
    Schedule 2: '30 14 * * *' (Afternoon, 14:30 WAT)
    Schedule 3: '30 21 * * *' (Night Battle, 22:30 WAT)
    Send only to users with qmTokens > 0 for the current window (they still have tokens left):
    title `⏰ ${windowName} closes in 30 minutes`,
      body `You still have ${tokens} Quick Match token${s} left — use them now!`

Return new and updated sections of index.js and updated main.dart.
```

---

### Stage 30 — Winner Announcement: Out-of-App Prize Claim Flow
**Effort: Low | Thinking: OFF**
**Attach:** `winner_announcement_page.dart`

```
You are updating the winner announcement page in AnimeQuiz to implement the
legally compliant out-of-app prize claim flow, per Master Strategy v3.

The strategy requires: "Winners see a button: 'Claim your prize → WhatsApp us
or fill this form.' They submit their bank details via a Google Form or WhatsApp."

IN winner_announcement_page.dart:

For the CURRENT USER if they are in the winners list (check if uid matches any
winner's uid):
  - Show a prominent green card/banner: "🎉 You won ₦[amount]!"
  - Below it, show two claim buttons:
      1. "📋 Claim via Form" → opens a URL (use url_launcher package):
         https://forms.gle/YOUR_GOOGLE_FORM_LINK (placeholder — replace before launch)
      2. "💬 Claim via WhatsApp" → opens:
         https://wa.me/234XXXXXXXXXX?text=Hi%2C+I+won+the+AnimeQuiz+prize.+My+username+is+[username].
         Replace XXXXXXXXXX with your WhatsApp number.
  - Below the buttons, add small text:
      "Winners must claim within 7 days. Bank transfer within 5 business days."

For ALL users (winner or not):
  - Keep the existing winner announcement display showing top 3 names/amounts.
  - Add a small note at the bottom:
      "Prizes are paid via bank transfer directly from AnimeQuiz. This is a
       skill-based trivia competition."

Ensure the app NEVER attempts an in-app money transfer. The claim buttons only
open external URLs.

Return the updated winner_announcement_page.dart in full.
```

---

## REFERENCE: Stage Order Summary

| Stage | What | Effort | Thinking | Status |
|-------|------|--------|----------|--------|
| 01 | Firestore rules — lock weeklyPoints, remove totalScore loophole | Medium | OFF | ✅ Done |
| 02 | Fix fetchQuestions to use fromDoc | Low | OFF | ✅ Done |
| 03 | submitQuizAnswers Cloud Function | Max | ON | ✅ Done |
| 04 | Rename bet/wager/stake language | Medium | OFF | ✅ Done |
| 05 | Fix rewarded ad rate (+10 AC, cap 10/day) | Low | OFF | ✅ Done |
| 06 | Fix streak milestones (3-day/7-day) | Low | OFF | ✅ Done |
| 07 | Challenge wins flat bonus (superseded by Stage 16) | Medium | OFF | ✅ Done |
| 08 | recordRewardedInterstitialWatch CF (zeroed in Stage 15) | Medium | OFF | ✅ Done |
| 09 | Wire quiz completion to submitQuizAnswers (client) | High | ON | ✅ Done |
| 10 | Login streak WP bonuses (3/7/14-day) | Medium | OFF | ✅ Done |
| 11 | Fix weeklyReset (top 3, 50/30/20, WP cap) | Medium | OFF | ✅ Done |
| 12 | Quick Match Cloud Functions (matchmaking + ghosts) | Max | ON | ✅ Done |
| 13 | Quick Match UI wiring | High | ON | ✅ Done |
| **14** | **Economy Corrections v2 (earn rates, QM payouts, streak day-14)** | Medium | OFF | ⬜ |
| **15** | **Ad System Overhaul (placement, timing, zero interstitial reward)** | High | ON | ⬜ |
| **16** | **Challenge House Fee + Stake Rules (80/20 model)** | High | ON | ⬜ |
| **17** | **Quick Match Time Windows + Token System** | Max | ON | ⬜ |
| 18 | Daily Challenge mode (1.5× WP, 40 AC retry) | High | ON | ⬜ |
| 19 | Leaderboard percentile display | Medium | OFF | ⬜ |
| 20 | Campus leaderboard tab (verify/complete) | Medium | OFF | ⬜ |
| 21 | Rival system | High | ON | ⬜ |
| 22 | IAP coin packs — ₦500/₦1,500/₦4,000 (updated pricing) | Max | ON | ⬜ |
| 23 | Premium Pass — ₦800/month + all 8 perks | Max | ON | ⬜ |
| **24** | **Cosmetic Store (AC sink — frames, colours, badges)** | High | ON | ⬜ |
| **25** | **Anime Category Unlocks (150 AC per category)** | Medium | OFF | ⬜ |
| 26 | Age gate (18+ first launch) | Low | OFF | ⬜ |
| 27 | T&C + Privacy Policy screens | Medium | OFF | ⬜ |
| 28 | Phone OTP at signup (anti-fraud) | High | ON | ⬜ |
| 29 | FCM push notifications (9 types, includes QM windows) | Max | ON | ⬜ |
| 30 | Winner announcement prize claim flow | Low | OFF | ⬜ |

> **Bolded rows** are new stages added in this revision. Stages 07 and 08 are superseded
> by Stages 16 and 15 respectively — they are complete but their economic effects
> are overwritten by the correction stages.

---

> **Economy Quick Reference (final target numbers)**
>
> | Source | Amount |
> |--------|--------|
> | Daily login | 20 AC (40 for Premium) |
> | Solo quiz completion | 8 AC + WP |
> | Rewarded ad | 15 AC · max 10/day |
> | Interstitial ad | 0 AC (revenue only) |
> | QM token ad | 1 QM token · no AC |
> | Streak day 3 | 25 AC |
> | Streak day 7 | 60 AC |
> | Streak day 14 | 150 AC |
> | QM win (ghost) | 35 WP + 35 AC |
> | QM draw (ghost) | 15 WP + 15 AC |
> | QM lose (ghost) | 5 WP + 0 AC |
> | Challenge win | own stake + 80% of opponent's stake |
> | Challenge draw | own stake − 5% |
> | Referral (referrer) | 100 AC |
> | New user signup bonus | 50 AC |
> | Premium Monday bonus | +30 WP + 30 AC |

---

> **Tip for each session:** Always paste the app summary (generated earlier) as
> the first message, then send the stage prompt. This gives the AI full context
> without needing to re-read all files from scratch.
