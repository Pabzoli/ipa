const { onSchedule }         = require('firebase-functions/v2/scheduler');
const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentUpdated, onDocumentCreated } = require('firebase-functions/v2/firestore');
const { defineSecret }       = require('firebase-functions/params');
const { initializeApp }      = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp, FieldPath } = require('firebase-admin/firestore');
const { getAuth }            = require('firebase-admin/auth');
const { getMessaging }       = require('firebase-admin/messaging');
const { randomInt, randomUUID, createHmac, createHash } = require('node:crypto'); // uniform, no modulo bias
const { GoogleAuth } = require('google-auth-library'); // Play Integrity server-side decode
const fs = require('node:fs');
const path = require('node:path');
const CFG = require('./abuse_config');

// ─── Manual test secret ───────────────────────────────────────────────────────
const RESET_SECRET = defineSecret('RESET_SECRET');

// ─── Flutterwave secrets ──────────────────────────────────────────────────────
// FLW_SECRET_KEY  = Flutterwave secret key (server-side only, never the browser).
// FLW_SECRET_HASH = the configured webhook secret/hash used for signature checks.
const FLW_SECRET_KEY  = defineSecret('FLW_SECRET_KEY');
const FLW_SECRET_HASH = defineSecret('FLW_SECRET_HASH');

// Hosting base URL used as Flutterwave's redirect_url and referenced by the
// static payment/success pages. Defaults to the project's Firebase Hosting
// default domain (anime-quiz-1ab1b). Change to your custom domain if one is set.
const HOSTING_BASE = 'https://anime-quiz-1ab1b.web.app';

// ─── Weekly WP cap (skill headroom) ────────────────────────────────────────
// Hard-clamped at the weekly reset: anyone above the cap is cut down to it
// before winners are snapshotted. Raised 2500 �?10000 so skilled Hard-mode
// players can separate from the pack instead of tying at the ceiling by
// mid-week (a perfect Hard run pays ~480 raw; ~6 runs hit the old cap).
// A hardcore grinder earns ~6-7k/week under the daily soft cap, so 10k
// binds almost nobody legit while still capping catastrophic exploit.
// Owner cost note: the prize pool is fixed-share (pool size is independent
// of WP totals), so a higher cap redistributes rank �?it never increases
// the owner's payout.
const WP_WEEKLY_CAP = 10000;
const WP_CAP_ACTIVE = true;

// ─── Daily WP soft cap (global, shared across every WP-awarding path) ───────
// Above this many WP earned in a WAT day, further awards drop to 20% of the
// computed amount (rounded down, never zero). Per-user tracking uses the
// wpEarnedToday / wpEarnedDate pair, mirroring the dailyAdWatched /
// lastAdWatchDate rollover pattern.
const WP_DAILY_SOFT_CAP = 300;

// ─── Non-QM challenge WP rewards ────────────────────────────────────────────
const CHALLENGE_WIN_WP  = 50;
const CHALLENGE_DRAW_WP = 25;

// Quick Match flat rewards �?mirrors ChallengeModel.quickMatchAcWin /
// quickMatchAcDraw / quickMatchAcLose / quickMatchWpWin / quickMatchWpDraw /
// quickMatchWpLose on the Dart side. Previously these were hardcoded as bare
// numbers (35/15/5/0) in four separate places across _resolveChallengeCore
// and submitQuickMatchResult �?two of which recomputed the exact same
// per-player AC amount independently within the same function, so a future
// balance change could easily update one spot and silently miss another.
// Centralizing here makes all four consumers read from one source.
const QM_AC_WIN  = 35;
const QM_AC_DRAW = 15;
const QM_AC_LOSE = 0;
const QM_WP_WIN  = 35;
const QM_WP_DRAW = 15;
const QM_WP_LOSE = 5;

// ─── Challenge constants ──────────────────────────────────────────────────────
const ACTIVE_CHALLENGE_STATUSES = [
  'waiting',
  'opponent_joined',
  'creator_submitted',
  'opponent_submitted',
];

// Statuses a challenge may still be JOINED from.
//
// 'waiting' is the normal invite state. The two *_submitted states are here
// because a creator may play IMMEDIATELY after creating (createChallenge pushes
// them straight into the quiz) before the invitee accepts �?resolveChallengeOutcome
// now promotes that score to creator_submitted, and the invite must stay takeable
// so the assigned opponent (or, for a code challenge, whoever holds the code) can
// still claim their seat. joinChallenge additionally requires the joiner's own
// score to be unset, so an already-played seat can never be taken twice.
const JOINABLE_CHALLENGE_STATUSES = [
  'waiting',
  'creator_submitted',
  'opponent_submitted',
];

// ─── WP staking limits ────────────────────────────────────────────────────────
// Raised with the Hard-mode economy (a perfect Hard run pays ~480 raw, so
// the old 150 daily cap was one duel): stakes need weight to stay
// meaningful now that the weekly cap is 10k.
const WP_MIN_STAKE = 5;
const WP_STEP = 5;
const WP_MAX_STAKE_FREE = 200;
const WP_MAX_STAKE_PREMIUM = 400;
const WP_DAILY_CAP_FREE = 300;
const WP_DAILY_CAP_PREMIUM = 500;
const WP_COOLDOWN_FREE_HOURS = 12;
const WP_COOLDOWN_PREMIUM_HOURS = 6;

// ─── AC Challenge stake limits ───────────────────────────────────────────────
const AC_MIN_STAKE = 20;
const AC_STAKE_STEP = 10;
const AC_MAX_STAKE_FREE = 2000;
const AC_MAX_STAKE_PREMIUM = 5000;

// ─── Challenge volume limits (free vs premium, premium gets more) ─────────────
// Active = a challenge in any of ACTIVE_CHALLENGE_STATUSES where the user is
// creator or opponent. Doubling the old uniform cap of 2 keeps the guardrail
// (no unlimited concurrent real matches) while letting players run more games.
const ACTIVE_CHALLENGES_FREE = 3;
const ACTIVE_CHALLENGES_PREMIUM = 5;

// Daily create / join budget (staked duels: rival + code). Raised 3/5 �?5/8
// with the rivalry overhaul: staked volume is self-limiting (balances +
// rake), and the old budget starved engaged fighters.
const DAILY_CHALLENGE_CREATE_FREE = 5;
const DAILY_CHALLENGE_CREATE_PREMIUM = 8;
const DAILY_CHALLENGE_JOIN_FREE = 5;
const DAILY_CHALLENGE_JOIN_PREMIUM = 8;

// ─── Sparring (frictionless unranked duels) ─────────────────────────────────
// Spars carry zero stakes, so they bypass the WP-staked cap and the
// same-rival cooldown entirely �?there is nothing to farm. Volume is
// throttled by its own daily budget (each side counts its own creates +
// joins), and WP rewards stop after the budget is exhausted (playing on
// for glory stays free). Spars never touch series score or gamesWon stats.
const SPAR_DAILY_FREE = 10;
const SPAR_DAILY_PREMIUM = 15;
const SPAR_WP_WIN = 5;
// Paid spar wins per friend pair per WAT day (single counter
// sparWinsDate/sparWinsCount on friendships/{pair}, shared by both winners).
// Unpaid spars stay unlimited (glory only).
const SPAR_PAID_PER_PAIR_PER_DAY = 3;

// ─── Rivalry series (best-of-5 arcs between named rivals) ───────────────────
// Ranked (challengeType 'rival') duels advance a first-to-3 series stored on
// rivalries/{sortedUidPair}. Winning a series pays a flat AC prize.
// No cooldown applies INSIDE an active series (the series is the container);
// starting a fresh series after one is decided respects the normal WP-staked
// rematch cooldown, so farming still can't loop.
//
// LOCKED RULES (see _resolveChallengeCore):
//   �?Draws replay: they change no winsA/winsB/seriesNo/status.
//   �?Series = first to SERIES_WINS_REQUIRED, staked ranked duels only.
//   �?Winner UID is compared against aUid/bUid (sorted pair), never assumed
//     from creator/opponent position.
const SERIES_WINS_REQUIRED = 3;
const SERIES_AC_PRIZE = 100;
// Anti-farm: a pair can be paid the +100 AC at most once per window. The
// series still decides/counts; only the AC is gated.
const SERIES_PRIZE_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;
// Stale-series expiry: active series with updatedAt older than this become
// 'expired' via expireStaleRivalries (daily). Next ranked duel starts
// seriesNo+1 at 0-0, same as after 'decided'.
const RIVALRY_EXPIRY_MS = 14 * 24 * 60 * 60 * 1000;
const RIVALRY_EXPIRY_BATCH = 200;

// ─── Upset bounty ───────────────────────────────────────────────────────────
// Ranked-duel win where the winner's pre-match weeklyPoints trailed the
// loser's by at least this gap pays a flat minted WP bonus on top. Bounded
// by the duel budget, so it can't be farmed at scale.
const BOUNTY_WP_GAP = 200;
const BOUNTY_WP_BONUS = 25;

// How long an unchallenged / half-finished challenge stays alive before the
// expiredChallengeRefund sweep settles it (see that function). Once expired,
// every participant gets their stakes back, so no one is penalised for a
// rival who never shows up to play.
//
// Unaccepted INVITES ('waiting') expire twice as fast (INVITE_EXPIRY_HOURS):
// a dead invite should not squat on the creator's active-challenge cap all
// day. Joining extends the deadline back to the full window (see
// joinChallenge), so in-play matches keep the full 24h.
const CHALLENGE_EXPIRY_HOURS = 24;
const INVITE_EXPIRY_HOURS = 12;

// Once ONE side has submitted a score and the other has stayed silent this
// long, forfeitStalePartialChallenges records the silent side's score as 0
// (the exact same math as a played-and-lost match) �?so the completer gets
// their result immediately instead of waiting out the 24h expiry, and the
// active-challenge slot is freed for both players right away.
const PARTIAL_FORFEIT_MINUTES = 15;

// Walkaway fee for quitting a live duel (challenge or Quick Match) before the
// score is recorded. Deducted in cancelRun on top of forfeiting the match,
// floored at zero so a broke player can still clear a stuck run. Mirrors
// kChallengeQuitFeeAc in lib/core/constants/rival_economy.dart.
const QUIT_FEE_AC = 100;

initializeApp();
const db = getFirestore();

// ─── App Check + callable hardening ─────────────────────────────────────────
// Enforcement has TWO switches. Both default OFF, so a deploy starts in
// monitor mode and can only get stricter from there:
//
//   1. ENFORCE_APP_CHECK=true (deploy-time env var) �?passed to onCall as
//      `enforceAppCheck`, so the Functions SDK rejects a request with no/invalid
//      App Check token before the handler runs at all.
//   2. app_config/security.enforceAppCheck (runtime, no redeploy) �?checked by
//      _assertAppCheck inside onSecureCall. Flip it to true once the monitor
//      logs show every real client is sending a token. Requires authenticated
//      read (already allowed for app_config/*) and CF-only write (already
//      denied �?set it from the console/Admin SDK).
//
// Monitor mode still logs a once-per-instance line per callable that receives
// no token, which is what you watch before flipping switch 2.
const APP_CHECK_ENFORCE_DEPLOY = process.env.ENFORCE_APP_CHECK === 'true';
const APP_CHECK_FLAG_TTL_MS = 60 * 1000;
let _securityFlagsCache = {
  enforceAppCheck: false,
  // Migration switch for the rewarded-ad session token. Starts FALSE so the
  // currently shipped APK (which sends no token) keeps earning coins. The new
  // client always mints + redeems a token. Flip app_config/security
  // .requireAdSession to true once the old build is gone.
  requireAdSession: false,
  at: 0,
};
let _appCheckLastMissLog = 0;
const APP_CHECK_MISS_LOG_MS = 60 * 1000;

// Server-only tunables live in server_config/** (rules: read:false,
// write:false). They used to live in app_config/**, which every authenticated
// client could read — leaking the exact fraud thresholds and security switches
// to the people being scored. The app_config fallback keeps a pre-migration
// deployment working; remove it once server_config is seeded.
const _serverConfigMissWarned = new Set();
async function _readServerConfig(name) {
  try {
    const snap = await db.collection('server_config').doc(name).get();
    if (snap.exists) return snap.data() || {};
    if (!_serverConfigMissWarned.has(name)) {
      _serverConfigMissWarned.add(name);
      console.warn(
        `[server_config] ${name} is missing; falling back to app_config/${name} ` +
        `or hardcoded defaults. Run scripts/seed_server_config.js --commit.`
      );
    }
  } catch (err) {
    console.warn(`[server_config] ${name} read failed: ${err.message}`);
  }
  try {
    const snap = await db.collection('app_config').doc(name).get();
    return snap.exists ? (snap.data() || {}) : {};
  } catch (err) {
    console.warn(`[server_config] app_config fallback ${name} failed: ${err.message}`);
    return {};
  }
}

async function _securityFlags() {
  const now = Date.now();
  if (now - _securityFlagsCache.at < APP_CHECK_FLAG_TTL_MS) {
    return _securityFlagsCache;
  }
  let enforceAppCheck = false;
  let requireAdSession = false;
  try {
    const data = await _readServerConfig('security');
    enforceAppCheck = data.enforceAppCheck === true;
    requireAdSession = data.requireAdSession === true;
  } catch (err) {
    // Fail OPEN in monitor mode: an unreadable flag must never lock players
    // out. The deploy-time switch still enforces where it was turned on.
    console.warn(`[security] flag read failed, treating as monitor: ${err.message}`);
  }
  _securityFlagsCache = { enforceAppCheck, requireAdSession, at: now };
  return _securityFlagsCache;
}

async function _appCheckRuntimeEnforced() {
  return (await _securityFlags()).enforceAppCheck;
}

async function _assertAppCheck(request, fnName) {
  const hasToken = !!request?.app;
  if (hasToken) return;
  const enforced = APP_CHECK_ENFORCE_DEPLOY || await _appCheckRuntimeEnforced();
  if (enforced) {
    throw new HttpsError('unauthenticated', 'App verification required.');
  }
  if (!hasToken) {
    const now = Date.now();
    if (now - _appCheckLastMissLog >= APP_CHECK_MISS_LOG_MS) {
      _appCheckLastMissLog = now;
      console.log(
        `[appcheck] ${fnName} monitor: request without App Check token ` +
        `uid=${request?.auth?.uid || 'anon'}`
      );
    }
  }
}

// Every exported callable is declared with this wrapper instead of onCall, so
// App Check enforcement exists in exactly one place and cannot be forgotten on
// a newly added function. The handler signature is unchanged, which keeps the
// in-memory test harness (`fn.run(request)`) working.
function onSecureCall(options, handler) {
  return onCall(
    { ...options, enforceAppCheck: APP_CHECK_ENFORCE_DEPLOY },
    async (request) => {
      await _assertAppCheck(request, handler.name || 'callable');
      return handler(request);
    }
  );
}

// ── Helper: _generateCode ─────────────────────────────────────────────────────
function _generateCode() {
  const CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  let code = '';
  for (let i = 0; i < 6; i++) {
    code += CHARS.charAt(Math.floor(Math.random() * CHARS.length));
  }
  return code;
}

// ── Helper: _watDateString ──────────────────────────────────────────────────
function _watDateString(date = new Date()) {
  const wat = new Date(date.getTime() + 60 * 60 * 1000);
  return wat.toISOString().slice(0, 10);
}

// ── Helper: _resolveDailyWPEarned ───────────────────────────────────────────
// Mirrors the dailyAdWatched / lastAdWatchDate rollover pattern: wpEarnedDate
// is a server timestamp whose WAT day must match today for wpEarnedToday to
// carry forward; otherwise today's earned counter resets to 0.
function _resolveDailyWPEarned(data, todayWAT) {
  const dateField = data.wpEarnedDate;
  const dateStr = dateField?.toDate ? _watDateString(dateField.toDate()) : null;
  return (dateStr === todayWAT) ? (data.wpEarnedToday || 0) : 0;
}

// ── Phase 1 antifraud helpers ───────────────────────────────────────────────
// Tunables live in app_config/antifraud (see Phase 4); every read falls back
// to the hardcoded defaults below so a missing/unreadable doc never blocks
// gameplay. The timings validity bounds and cooldown windows keep their
// existing semantics and are intentionally NOT configurable.
const SOLO_DECAY_THRESHOLD_DEFAULT = 100;
const SOLO_THRESHOLD_MAX = 500;
const RIVAL_COOLDOWN_MAP_MAX = 5;
const SOLO_TIMING_MIN_S = 0.5;
const SOLO_TIMING_MAX_S = 60;

// Default solo decay steps, expressed relative to the threshold T
// (app_config/antifraud.soloDailyCap, "full-reward games before decay"):
//   games 1..T         �?1.0 (full)
//   games T+1..T+50    �?0.5
//   games T+51..T+150  �?0.2
//   games beyond       �?0.05 (floor �?never zero)
// With T=100 this is exactly 1-100 full, 101-150 half, 151-250 fifth, rest
// twentieth. An explicit soloDecayTiers array in the config doc overrides
// these relative steps with absolute game numbers (see _parseSoloDecayTiers).
const SOLO_DECAY_DEFAULT_STEPS = [
  { addGames: 0,   factor: 0.5 },
  { addGames: 50,  factor: 0.2 },
  { addGames: 150, factor: 0.05 },
];
const SOLO_DECAY_TIERS_MAX = 8;

// Pure parser (kept side-effect-free for testability): absolute tiers win,
// otherwise build relative steps off the threshold. Never returns empty.
function _parseSoloDecayTiers(rawTiers, threshold) {
  if (Array.isArray(rawTiers)) {
    const parsed = rawTiers
      .map((t) => ({ afterGames: Number(t?.afterGames), factor: Number(t?.factor) }))
      .filter((t) =>
        Number.isInteger(t.afterGames) && t.afterGames >= 1 &&
        t.factor > 0 && t.factor <= 1)
      .sort((a, b) => a.afterGames - b.afterGames)
      .slice(0, SOLO_DECAY_TIERS_MAX);
    if (parsed.length > 0) return parsed;
  }
  return SOLO_DECAY_DEFAULT_STEPS.map((s) => ({
    afterGames: threshold + s.addGames,
    factor: s.factor,
  }));
}

// ── app_config/antifraud �?canonical schema (Phase 4 config catalog) ───────
// Single tunable doc for every "guessed" numeric threshold introduced by the
// antifraud passes. All reads fall back to the hardcoded defaults below when
// the doc is missing/unreadable/invalid, so gameplay and scoring never fail
// for config reasons. Tune post-launch WITHOUT a redeploy by writing this
// doc (admin-gated writes only �?add a setter if one doesn't exist yet).
//
//   {
//     "soloDailyCap": 100,            // full-reward solo games before WP/AC
//                                     // decay kicks in (default 100)
//     "soloDecayTiers": [             // optional ABSOLUTE override of the
//       {"afterGames": 100, "factor": 0.5},   // derived curve; when absent
//       {"afterGames": 150, "factor": 0.2},   // the curve is built relative
//       {"afterGames": 250, "factor": 0.05}   // to soloDailyCap (see
//     ],                              // SOLO_DECAY_DEFAULT_STEPS)
//     "fraud": {                       // suspicion-scoring weights/thresholds
//       "wCadence": 25, "rapidGapMs": 3000, "rapidFullRatio": 0.5,
//       "mechMinGaps": 15, "mechMaxCV": 0.15,
//       "wVolume": 10, "volumeFullPerDay": 100, "volumeMinPerDay": 40,
//       "wPair": 25, "pairFullCount": 5, "pairMinCount": 3,
//       "funnelMinGames": 4, "funnelMinWinRate": 0.8,
//       "wIp": 15,
//       "wAge": 15, "newbornDays": 7, "newbornWP": 1500,
//       "youngDays": 14, "youngWP": 2000, "toddlerDays": 3, "toddlerWP": 500,
//       "wWinRate": 20, "stakeMinGames": 10, "stakeHighRate": 0.9,
//       "stakeMidRate": 0.8, "baselineQmRate": 0.65, "qmMinGames": 5,
//       "bandModerate": 30, "bandHigh": 60
//     }
//   }
//
// DELIBERATELY HARDCODED (not in the doc �?safe to leave as code):
//   SOLO_TIMING_MIN/MAX_S (0.5/60) �?physical answer-time plausibility, not
//     an economy guess; changing it alters cheat-vs-legit classification.
//   WP cooldown windows (24h/12h) + WP daily stake caps (150/300) �?pre-
//     existing economy semantics, out of scope ("don't change scoring").
//   RIVAL_COOLDOWN_MAP_MAX (5), SOLO_DECAY_TIERS_MAX (8), SOLO_THRESHOLD_MAX
//     (500) �?storage/validation bounds, not behavior guesses.
//   QUIZ_CADENCE_MAX_EVENTS (300) / MAX_IPS (20) �?telemetry retention caps;
//     raising them only costs Firestore storage, not correctness.
//   Repair tripwire (<100 in repairAntifraudConfig) �?one-time migration for
//     the hard-cap-era 40 default, not ongoing behavior.
async function _getSoloDecayConfig() {
  let threshold = SOLO_DECAY_THRESHOLD_DEFAULT;
  let rawTiers = null;
  try {
    const d = await _readServerConfig('antifraud');
    if (d && Object.keys(d).length > 0) {
      const rawT = Number(d.soloDailyCap);
      if (Number.isInteger(rawT) && rawT >= 1 && rawT <= SOLO_THRESHOLD_MAX) threshold = rawT;
      rawTiers = d.soloDecayTiers;
    }
  } catch (err) {
    console.warn(`[_getSoloDecayConfig] config read failed, using defaults: ${err.message}`);
  }
  return { threshold, tiers: _parseSoloDecayTiers(rawTiers, threshold) };
}

// Factor for the Nth solo game of the day (1-indexed). Games at/below the
// first breakpoint pay full; the highest breakpoint strictly below N wins.
function _soloDecayFactor(gameNumber, tiers) {
  let f = 1.0;
  for (const t of tiers) {
    if (gameNumber > t.afterGames) f = t.factor;
    else break;
  }
  return f;
}

// ── app_config/android �?Android forced-update gate ───────────────────────────
// Distribution is website-only: users sideload an APK we host ourselves, so a
// stale install can linger forever and there is no store to auto-update it.
// This doc is the single switch that ends that.
//
//   {
//     "minBuild":    1,   // Android clients whose buildNumber is BELOW this
//                         //   are rejected by every gated callable below.
//                         //   THIS is the switch that arms the gate.
//     "latestBuild": 2,   // newest published build. Informational only �?used
//                         //   for "a new version is available" messaging.
//     "apkUrl": "https://anime-quiz-1ab1b.web.app/downloads/animequiz-2.apk"
//   }
//
// Deliberate failure mode, and it differs from the client wall on purpose:
//   �?Unreadable / missing / malformed config  -> gate OPEN (return null).
//     A Firestore blip must never be able to hard-block every Android player
//     from redeeming a code or claiming a prize money they already won. Same
//     fail-open posture as _getSoloDecayConfig above.
//   �?Client sends a PRESENT but unusable stamp -> gate CLOSED (throw).
//     A key is present but the value is null / 0 / negative / non-integer /
//     a boolean: that client tried to identify itself and failed, which is
//     either a bug in our own client or a hand-rolled caller. Neither may
//     transact past an armed gate.
//   �?Client sends NO stamp at all              -> treated as LEGACY_BUILD.
//     Builds shipped before the stamp existed cannot report themselves, and
//     the only one ever distributed is build 1, so that is exactly what it is.
//     It is compared against minBuild like any other build rather than being
//     rejected outright: a staged rollout (minBuild 1) therefore does not
//     break existing installs, and arming the gate (minBuild 2) catches them
//     without anyone having to cut a special case for them later.
const ANDROID_CONFIG_TTL_MS = 60 * 1000;

// The build number assumed for a client that sends no appBuild key at all.
// Matches the first (and, so far, only) build ever shipped, so the value stays
// correct for as long as build 1 is the oldest thing in the wild.
const LEGACY_UNSTAMPED_BUILD = 1;

let _androidConfigCache = { at: 0, value: null };

async function _getAndroidReleaseConfig() {
  const now = Date.now();
  // Only a SUCCESSFULLY-read gate is served from cache. A null (fail-open)
  // result is never cached, so the very next call retries the read instead of
  // letting one blip leave the gate open for the whole TTL window.
  if (_androidConfigCache.value !== null &&
      now - _androidConfigCache.at < ANDROID_CONFIG_TTL_MS) {
    return _androidConfigCache.value;
  }

  let value = null;
  try {
    const snap = await db.collection('app_config').doc('android').get();
    if (snap.exists) {
      const d = snap.data() || {};
      const minBuild = Number(d.minBuild);
      // Require a sane positive integer. A doc that exists but is unusable is
      // treated exactly like a missing one: gate open, loudly logged.
      if (Number.isInteger(minBuild) && minBuild >= 1) {
        const latest = Number(d.latestBuild);
        value = {
          minBuild,
          latestBuild: Number.isInteger(latest) && latest >= minBuild ? latest : minBuild,
          apkUrl: typeof d.apkUrl === 'string' && d.apkUrl.trim() ? d.apkUrl.trim() : null,
        };
      } else {
        console.warn(
          `[android gate] app_config/android has a non-integer minBuild ` +
          `(${JSON.stringify(d.minBuild)}) �?gate treated as OPEN.`
        );
      }
    }
  } catch (err) {
    console.warn(`[_getAndroidReleaseConfig] config read failed, gate OPEN: ${err.message}`);
  }

  _androidConfigCache = { at: now, value };
  return value;
}

// Callables that MUST refuse an outdated Android client. Anything that moves
// coins, WP, premium, or leaderboard eligibility goes through this.
//
// DELIBERATELY NOT INCLUDED:
//   deleteAccount �?the privacy policy promises deletion on request. An
//     outdated install is exactly the population most likely to be locked out
//     of the app, and it must not also be locked out of deleting its data.
//     Re-adding it here would silently break a published privacy commitment,
//     so the exclusion is a decision, not an oversight.
//   verifyIAPPurchase / verifyPremiumPurchase �?the legacy Play Billing paths.
//     Unreachable now that distribution is sideloaded-APK + web only.
async function _assertClientBuildAllowed(request, fnName, opts = {}) {
  const platform = request.data?.platform;

  // High-risk entry points (challenge create/join) REQUIRE the stamp:
  // a call with no platform key at all predates the stamp (old APK) and
  // must not sail through the web exemption below. New clients always send
  // platform (AppUpdateService.init runs at app start in main.dart), and
  // web sends platform 'web' which stays exempt.
  if (platform === undefined && opts.requireStamp) {
    throw new HttpsError(
      'failed-precondition',
      'App update required: please update to the latest version.',
      { reason: 'app_update_required', legacyUnstamped: true },
    );
  }

  // Web and any other non-Android client are exempt. The web build is served
  // straight from a CDN, so there is no build number to compare and no store
  // to send the user to; gating it would brick the site with no possible fix.
  if (platform !== 'android') return;

  // Distinguish "did not send a key" from "sent a key with a bad value".
  // request.data.appBuild is `undefined` only when the key is absent �?JSON has
  // no undefined, so an explicit JSON null arrives as `null` and is treated as
  // present-but-malformed below. A client that tried to identify itself and
  // failed is not the same thing as a client that predates the stamp.
  const raw = request.data?.appBuild;
  const isLegacyUnstamped = raw === undefined;
  let appBuild;

  if (isLegacyUnstamped) {
    appBuild = LEGACY_UNSTAMPED_BUILD;
  } else {
    // Accept a number, or a numeric string (a debug console or Postman can
    // send either; our own client always sends a number).
    const n = typeof raw === 'number'
      ? raw
      : (typeof raw === 'string' && raw.trim() !== '' ? Number(raw) : NaN);
    if (!Number.isInteger(n) || n < 1) {
      console.warn(
        `[android gate] ${fnName}: rejected call with a present-but-malformed ` +
        `appBuild (platform=android, appBuild=${JSON.stringify(raw)})`
      );
      throw new HttpsError('failed-precondition', 'App update required.');
    }
    appBuild = n;
  }

  const cfg = await _getAndroidReleaseConfig();
  if (!cfg) return;                                  // fail open on config error
  if (appBuild >= cfg.minBuild) return;             // at or above the floor

  console.warn(
    `[android gate] ${fnName}: rejected outdated client ` +
    `uid=${request.auth?.uid || 'anon'} build=${appBuild} minBuild=${cfg.minBuild}` +
    (isLegacyUnstamped ? ' (legacy unstamped client, assumed build 1)' : '')
  );
  throw new HttpsError(
    'failed-precondition',
    `App update required: build ${appBuild} is older than the minimum ` +
    `supported build ${cfg.minBuild}.` +
    (cfg.apkUrl ? ` Download the latest version from ${cfg.apkUrl}` : ''),
    // details lets the client render the download button without parsing the
    // human-readable message string.
    {
      reason:     'app_update_required',
      appBuild,
      minBuild:   cfg.minBuild,
      latestBuild: cfg.latestBuild,
      apkUrl:     cfg.apkUrl,
      // true when appBuild was assumed rather than reported, so the client can
      // log/label the case distinctly from a build that genuinely self-reported.
      legacyUnstamped: isLegacyUnstamped,
    },
  );
}

// ── Legacy quiz-path retirement ────────────────────────────────────────────
// The pre-run system (client-picked questions, client-declared difficulty) is
// kept only so the currently shipped build keeps working during rollout. The
// moment app_config/android.minBuild is raised above the oldest shipped build,
// those paths hard-reject: no redeploy, no extra flag. The new client always
// sends `runV2` on entry and submits through submitRun, so it is unaffected.
async function _legacyQuizPathsRetired() {
  const cfg = await _getAndroidReleaseConfig();
  return !!cfg && Number(cfg.minBuild) > LEGACY_UNSTAMPED_BUILD;
}

function _legacyPathRetiredError() {
  return new HttpsError(
    'failed-precondition',
    'App update required: this version is no longer supported.',
    { reason: 'app_update_required', legacyQuizPath: true },
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ─── P1: Play Integrity + silent enforcement ladder ─────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Play Integrity is verified SERVER-SIDE on money paths. The pinned value is the
// APK signing certificate SHA-256 (base64url), NOT Play recognition: sideloaded
// APKs are expected and pass on the cert pin. The mode defaults to log-only so
// the currently shipped build (which sends no token) is never blocked.
const INTEGRITY_CHALLENGES = 'integrityChallenges';
const ENFORCEMENT_COLLECTION = 'enforcement';
const FLAGGED_ACCOUNTS = 'flaggedAccounts';
const PAYOUT_ACCOUNTS = 'payoutAccounts';
const ENFORCEMENT_DECAY = 0.5;
const ENFORCEMENT_RANK = {
  clean: -1, cleared: -1, flagged: 0, restricted: 1, payout_hold: 2, suspended: 3,
};
const INTEGRITY_DEFAULT = {
  packageName: 'com.animequiz.app',
  // SHA-256 of the release signing certificate (animequiz-4.apk), base64url.
  certificateSha256Digest: ['6edYv6JkZWefkzNwgx-1zO4Kh22eBnjQuHvRqp5r8QE'],
  allowedDeviceVerdicts: ['MEETS_DEVICE_INTEGRITY', 'MEETS_STRONG_INTEGRITY'],
  enforce: false,
  logOnly: true,
};
const _integrityMissLogged = new Set();

function _integrityLogOnce(key, message) {
  if (_integrityMissLogged.has(key)) return;
  _integrityMissLogged.add(key);
  console.log(message);
}

async function _getPlayIntegrityConfig() {
  const data = await _readServerConfig('play_integrity');
  const digests = Array.isArray(data.certificateSha256Digest)
    ? data.certificateSha256Digest.filter((d) => typeof d === 'string' && d.trim())
    : INTEGRITY_DEFAULT.certificateSha256Digest;
  const verdicts = Array.isArray(data.allowedDeviceVerdicts) && data.allowedDeviceVerdicts.length
    ? data.allowedDeviceVerdicts.filter((v) => typeof v === 'string' && v.trim())
    : INTEGRITY_DEFAULT.allowedDeviceVerdicts;
  const enforce = data.enforce === true;
  return {
    packageName: typeof data.packageName === 'string' && data.packageName.trim()
      ? data.packageName.trim()
      : INTEGRITY_DEFAULT.packageName,
    certificateSha256Digest: digests,
    allowedDeviceVerdicts: verdicts,
    enforce,
    logOnly: !enforce && data.logOnly !== false,
  };
}

let _playIntegrityAuth = null;
async function _decodePlayIntegrityToken(packageName, token) {
  if (!_playIntegrityAuth) {
    _playIntegrityAuth = new GoogleAuth({
      scopes: ['https://www.googleapis.com/auth/playintegrity'],
    });
  }
  const client = await _playIntegrityAuth.getClient();
  const access = await client.getAccessToken();
  const bearer = typeof access === 'string' ? access : access?.token;
  if (!bearer) throw new Error('playintegrity_access_token_missing');

  const res = await fetch(
    `https://playintegrity.googleapis.com/v1/${encodeURIComponent(packageName)}:decodeIntegrityToken`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${bearer}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ integrity_token: token }),
    },
  );
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = body?.error?.message || `HTTP ${res.status}`;
    throw new Error(`playintegrity_decode_failed: ${String(detail).slice(0, 180)}`);
  }
  return body;
}

async function _consumeIntegrityNonce(uid, nonce, requestHash) {
  if (typeof nonce !== 'string' || !nonce.trim()) return false;
  if (typeof requestHash !== 'string' || requestHash !== nonce) return false;
  const ref = db.collection(INTEGRITY_CHALLENGES).doc(nonce.trim());
  let ok = false;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return;
    const d = snap.data() || {};
    if (d.uid !== uid || d.used === true) return;
    const exp = d.expiresAt?.toMillis ? d.expiresAt.toMillis() : 0;
    if (!exp || exp < Date.now()) return;
    tx.update(ref, { used: true, usedAt: FieldValue.serverTimestamp() });
    ok = true;
  });
  return ok;
}

async function _integrityFail(uid, cfg, type, action, detail) {
  const safeDetail = { ...detail, action, enforce: cfg.enforce };
  if (cfg.enforce) {
    await _recordAntiCheatSignal(uid, type, { hard: true, detail: safeDetail })
      .catch((err) => console.warn(`[integrity] signal failed: ${err.message}`));
    throw new HttpsError(
      'failed-precondition',
      'integrity_failed',
      { reason: 'integrity_failed', action },
    );
  }
  // Log-only: a token that was actually presented and failed is a soft signal.
  await _recordAntiCheatSignal(uid, type, { hard: false, detail: safeDetail })
    .catch((err) => console.warn(`[integrity] signal failed: ${err.message}`));
  _integrityLogOnce(
    `fail:${action}:${type}`,
    `[integrity] ${action} failed uid=${uid} type=${type} (log-only)`,
  );
  return { ok: false, reason: type };
}

async function _verifyPlayIntegrity(request, action) {
  const uid = request.auth?.uid;
  if (!uid) return { ok: false, reason: 'unauthenticated' };
  const cfg = await _getPlayIntegrityConfig();
  const token = typeof request.data?.integrityToken === 'string'
    ? request.data.integrityToken.trim()
    : '';
  const nonce = typeof request.data?.integrityNonce === 'string'
    ? request.data.integrityNonce.trim()
    : '';

  if (!token) {
    if (cfg.enforce) {
      await _recordAntiCheatSignal(uid, 'integrity_missing', {
        hard: true, detail: { action, enforce: true },
      }).catch((err) => console.warn(`[integrity] signal failed: ${err.message}`));
      throw new HttpsError(
        'failed-precondition',
        'integrity_required',
        { reason: 'integrity_required', action },
      );
    }
    _integrityLogOnce(
      `missing:${action}`,
      `[integrity] ${action} no token uid=${uid} (log-only; shipped build)`,
    );
    return { ok: false, reason: 'missing' };
  }

  let verdict;
  try {
    verdict = await _decodePlayIntegrityToken(cfg.packageName, token);
  } catch (err) {
    return _integrityFail(uid, cfg, 'integrity_verification_failed', action, {
      error: String(err?.message || err).slice(0, 180),
    });
  }

  const details = verdict?.tokenDetails || verdict || {};
  const app = details.appIntegrity || {};
  const device = details.deviceIntegrity || {};
  const req = details.requestDetails || {};
  const digests = Array.isArray(app.certificateSha256Digest)
    ? app.certificateSha256Digest
    : (app.certificateSha256Digest ? [app.certificateSha256Digest] : []);
  const deviceVerdicts = Array.isArray(device.deviceRecognitionVerdict)
    ? device.deviceRecognitionVerdict
    : (device.deviceRecognitionVerdict ? [device.deviceRecognitionVerdict] : []);

  const certOk = app.packageName === cfg.packageName &&
    digests.some((d) => cfg.certificateSha256Digest.includes(d));
  const deviceOk = deviceVerdicts.some((v) => cfg.allowedDeviceVerdicts.includes(v));
  let nonceOk = true;
  if (cfg.enforce || nonce) {
    nonceOk = await _consumeIntegrityNonce(uid, nonce, req.requestHash);
  }

  if (certOk && deviceOk && nonceOk) {
    return { ok: true };
  }

  const type = !certOk
    ? 'integrity_cert_failed'
    : (!deviceOk ? 'device_integrity_failed' : 'integrity_nonce_failed');
  return _integrityFail(uid, cfg, type, action, {
    packageName: app.packageName || null,
    certDigests: digests.slice(0, 3),
    deviceVerdicts: deviceVerdicts.slice(0, 4),
    requestHash: req.requestHash || null,
    nonceOk,
  });
}

// Issues the nonce the client passes as Play Integrity's requestHash. Single
// use, two-minute TTL. The current shipped build never calls this; the next
// build does before each money action.
exports.getIntegrityChallenge = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'getIntegrityChallenge', { requireStamp: true });
    const action = typeof request.data?.action === 'string' && request.data.action.trim()
      ? request.data.action.trim().slice(0, 48)
      : 'generic';
    const nonce = randomUUID().replace(/-/g, '');
    const ttlMs = 2 * 60 * 1000;
    await db.collection(INTEGRITY_CHALLENGES).doc(nonce).set({
      uid,
      action,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(Date.now() + ttlMs),
      used: false,
    });
    return { nonce, action, expiresAt: Date.now() + ttlMs };
  }
);

// ── Enforcement state ──────────────────────────────────────────────────────
async function _readEnforcement(uid) {
  try {
    const snap = await db.collection(ENFORCEMENT_COLLECTION).doc(uid).get();
    const d = snap.data() || {};
    return {
      level: typeof d.level === 'string' ? d.level : 'clean',
      decayFactor: Number.isFinite(Number(d.decayFactor)) ? Number(d.decayFactor) : 1,
      leaderboardExcluded: d.leaderboardExcluded === true,
      payoutHold: d.payoutHold === true,
      suspended: d.suspended === true,
    };
  } catch (err) {
    console.warn(`[enforcement] read failed uid=${uid}: ${err.message}`);
    return {
      level: 'clean', decayFactor: 1,
      leaderboardExcluded: false, payoutHold: false, suspended: false,
    };
  }
}

function _enforcementLevelForSignals(signals) {
  const hardTypes = new Set(
    signals.filter((s) => s.hard === true).map((s) => s.type),
  );
  const independent = new Set(signals.map((s) => s.type));
  const bindingCount = signals.filter((s) => s.type === 'run_binding_mismatch').length;

  let level = 'flagged';
  if (hardTypes.size >= 1 || bindingCount >= 3) level = 'payout_hold';
  if (hardTypes.size >= 2 ||
      hardTypes.has('integrity_cert_failed') ||
      (bindingCount >= 3 && hardTypes.size >= 1)) {
    level = 'suspended';
  } else if (hardTypes.size === 0 && bindingCount < 3 && independent.size >= 2) {
    level = 'restricted';
  }
  return level;
}

// Silent, reversible ladder. Never deletes, never returns a cheat message, and
// only acts on high-confidence signals. The caller decides whether to block;
// this only records and applies state.
async function _recordAntiCheatSignal(uid, type, opts = {}) {
  if (!uid || !type) return null;
  const hard = opts.hard === true;
  const detail = opts.detail && typeof opts.detail === 'object' ? opts.detail : {};
  const flagRef = db.collection(FLAGGED_ACCOUNTS).doc(uid);
  const enfRef = db.collection(ENFORCEMENT_COLLECTION).doc(uid);
  const userRef = db.collection('users').doc(uid);

  let result = null;
  await db.runTransaction(async (tx) => {
    const [flagSnap, enfSnap, userSnap] = await Promise.all([
      tx.get(flagRef),
      tx.get(enfRef),
      tx.get(userRef),
    ]);
    const flag = flagSnap.data() || {};
    const current = enfSnap.data() || {};
    const signals = Array.isArray(flag.signals) ? [...flag.signals] : [];
    signals.push({
      type,
      hard,
      detail,
      at: Date.now(),
    });
    const trimmed = signals.slice(-50);
    const computed = _enforcementLevelForSignals(trimmed);
    const currentLevel = typeof current.level === 'string' ? current.level : 'clean';
    const level = (ENFORCEMENT_RANK[computed] ?? 0) >= (ENFORCEMENT_RANK[currentLevel] ?? -1)
      ? computed
      : currentLevel;

    const rank = ENFORCEMENT_RANK[level] ?? 0;
    const restricted = rank >= ENFORCEMENT_RANK.restricted;
    const payoutHold = rank >= ENFORCEMENT_RANK.payout_hold;
    const suspended = rank >= ENFORCEMENT_RANK.suspended;
    const decayFactor = restricted ? ENFORCEMENT_DECAY : 1;

    const actions = Array.isArray(flag.actions) ? [...flag.actions] : [];
    if ((ENFORCEMENT_RANK[level] ?? 0) > (ENFORCEMENT_RANK[currentLevel] ?? -1)) {
      actions.push({
        type: level,
        at: Date.now(),
        source: 'auto',
        reversible: true,
      });
    }

    tx.set(flagRef, {
      uid,
      status: level,
      level,
      signals: trimmed,
      actions: actions.slice(-30),
      firstFlaggedAt: flag.firstFlaggedAt || FieldValue.serverTimestamp(),
      lastSignalAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    tx.set(enfRef, {
      uid,
      level,
      decayFactor,
      leaderboardExcluded: restricted,
      payoutHold,
      suspended,
      reasons: [...new Set(trimmed.map((s) => s.type))].slice(-20),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    if (restricted && userSnap.exists) {
      tx.update(userRef, { lbEligible: false });
    }

    result = {
      level, decayFactor, leaderboardExcluded: restricted, payoutHold, suspended,
    };
  });
  console.log(
    `[enforcement] uid=${uid} signal=${type} hard=${hard} level=${result.level}` +
    ` decay=${result.decayFactor} payoutHold=${result.payoutHold} suspended=${result.suspended}`,
  );
  return result;
}

async function _assertNotSuspended(uid, fnName) {
  const enf = await _readEnforcement(uid);
  if (enf.suspended) {
    console.log(`[${fnName}] uid=${uid} blocked: account_under_review`);
    throw new HttpsError(
      'failed-precondition',
      'account_under_review',
      { reason: 'account_under_review' },
    );
  }
  return enf;
}

async function _assertPayoutAllowed(uid, fnName) {
  const enf = await _readEnforcement(uid);
  if (enf.payoutHold || enf.suspended) {
    console.log(`[${fnName}] uid=${uid} blocked: payout_under_review`);
    throw new HttpsError(
      'failed-precondition',
      'payout_under_review',
      { reason: 'payout_under_review' },
    );
  }
  return enf;
}

function _applyDecay(amount, factor) {
  const n = Number(amount);
  if (!Number.isFinite(n)) return 0;
  const f = Number.isFinite(Number(factor)) ? Number(factor) : 1;
  return Math.max(0, Math.floor(n * f));
}

// ── Payout account fingerprinting ─────────────────────────────────────────
function _payoutAccountHash(bankCode, accountNumber) {
  return createHash('sha256')
    .update(`${String(bankCode || '').trim()}:${String(accountNumber || '').trim()}`)
    .digest('hex');
}

async function _recordPayoutAccount(uid, bankCode, accountNumber, fnName) {
  const hash = _payoutAccountHash(bankCode, accountNumber);
  const ref = db.collection(PAYOUT_ACCOUNTS).doc(hash);
  let shared = false;
  let uidCount = 0;

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const existing = snap.data() || {};
    const uids = Array.isArray(existing.uids) ? [...existing.uids] : [];
    const isNewUid = !uids.includes(uid);
    if (isNewUid) uids.push(uid);
    shared = isNewUid && uids.length >= 2;
    uidCount = uids.length;
    tx.set(ref, {
      hash,
      bankCode: String(bankCode || '').trim(),
      last4: String(accountNumber || '').trim().slice(-4),
      firstUid: existing.firstUid || uid,
      uids,
      firstSeenAt: existing.firstSeenAt || FieldValue.serverTimestamp(),
      lastSeenAt: FieldValue.serverTimestamp(),
      flagged: existing.flagged === true || shared,
    }, { merge: true });
  });

  if (shared) {
    await _recordAntiCheatSignal(uid, 'payout_account_multi_uid', {
      hard: true,
      detail: {
        hash,
        bankCode: String(bankCode || '').trim(),
        last4: String(accountNumber || '').trim().slice(-4),
        uidCount,
        fnName,
      },
    }).catch((err) => console.warn(`[payout] signal failed: ${err.message}`));
  }
  return { hash, shared, uidCount };
}

// Generic WAT-day lazy-reset counter read, mirroring _resolveDailyWPEarned but
// for count fields (no soft-cap math �?the caller enforces its own limit).
function _resolveDailyCounter(data, countField, dateField, todayWAT) {
  if ((data[dateField] || '') === todayWAT) return Number(data[countField] || 0);
  return 0;
}

// Rolling rival-cooldown record: { rivalUid: Timestamp }. Replaces the legacy
// single lastRivalUid/lastRivalChallenge pair (which an A→B→C→B rotation never
// tripped). Migrates legacy state in so pre-existing cooldowns keep enforcing.
function _getRivalCooldownMap(data) {
  const raw = data.rivalCooldowns;
  const map = (raw && typeof raw === 'object' && !Array.isArray(raw)) ? { ...raw } : {};
  if (Object.keys(map).length === 0 &&
      typeof data.lastRivalUid === 'string' && data.lastRivalUid &&
      data.lastRivalChallenge?.toDate) {
    map[data.lastRivalUid] = data.lastRivalChallenge;
  }
  return map;
}

function _rivalCooldownEntryMs(entry) {
  if (entry == null) return NaN;
  if (typeof entry.toDate === 'function') {
    try { return entry.toDate().getTime(); } catch (_) { return NaN; }
  }
  if (entry instanceof Date) return entry.getTime();
  const n = Number(entry);
  return Number.isFinite(n) ? n : NaN;
}

// Remaining whole hours before rivalUid may be re-challenged (0 = allowed).
function _rivalCooldownRemainingHours(map, rivalUid, cooldownHours, nowMs = Date.now()) {
  if (!rivalUid || !map) return 0;
  const ts = _rivalCooldownEntryMs(map[rivalUid]);
  if (!Number.isFinite(ts)) return 0;
  const hoursSince = (nowMs - ts) / (1000 * 60 * 60);
  if (hoursSince >= cooldownHours) return 0;
  return Math.ceil(cooldownHours - hoursSince);
}

// Return a pruned copy with rivalUid stamped at nowMs, bounded to the most
// recent RIVAL_COOLDOWN_MAP_MAX entries. Stale entries past the longest
// cooldown window (24h) are dropped so the map cannot grow unboundedly.
function _touchRivalCooldownMap(map, rivalUid, nowMs = Date.now()) {
  const next = { ...(map || {}) };
  next[rivalUid] = new Date(nowMs);
  const entries = Object.entries(next)
    .map(([uid, ts]) => ({ uid, ms: _rivalCooldownEntryMs(ts) }))
    .filter((e) => Number.isFinite(e.ms) && (nowMs - e.ms) < 24 * 60 * 60 * 1000)
    .sort((a, b) => b.ms - a.ms)
    .slice(0, RIVAL_COOLDOWN_MAP_MAX);
  const out = {};
  for (const e of entries) out[e.uid] = next[e.uid];
  // The just-touched rival always survives even if its clock is skewed.
  if (!out[rivalUid]) out[rivalUid] = next[rivalUid];
  return out;
}

// ── Phase 2 fraud-signal helpers (capture only, never block) ───────────────
// IPs are best-effort signal for Phase 3 suspicion scoring �?never a block
// criterion. X-Forwarded-For is client-spoofable; behind GCF the edge
// appends the real client IP, so the first entry is advisory-only. All
// signal docs live under telemetry/** which firestore.rules denies to ALL
// clients (read:false write:false, CF-only via Admin SDK); admins consume
// them exclusively through admin-gated callables (Phase 3).
function _clientIp(request) {
  try {
    const headers = request?.rawRequest?.headers || {};
    const h = headers['x-forwarded-for'];
    const fwd = Array.isArray(h) ? h[0] : h;
    if (typeof fwd === 'string' && fwd.trim()) {
      return fwd.split(',')[0].trim().slice(0, 64) || null;
    }
    const ip = request?.rawRequest?.ip;
    if (typeof ip === 'string' && ip.trim()) return ip.trim().slice(0, 64);
  } catch (_) { /* best-effort �?never throw */ }
  return null;
}

// ─── Email verification + abuse limits ─────────────────────────────────────
// Every threshold lives in ./abuse_config.js. The client is never trusted for
// any of these decisions: the ID-token claim, an Admin SDK re-read, or a
// transactional counter is the authority.
let _unverifiedCleanupEpochMs = CFG.UNVERIFIED_CLEANUP_EPOCH_MS;

const DISPOSABLE_EMAIL_DOMAINS = (() => {
  try {
    const raw = fs.readFileSync(
      path.join(__dirname, 'disposable_email_domains.txt'),
      'utf8'
    );
    const set = new Set();
    for (const line of raw.split(/\r?\n/)) {
      const domain = line.trim().toLowerCase();
      if (!domain || domain.startsWith('#')) continue;
      set.add(domain);
    }
    return set;
  } catch (err) {
    console.warn(`[abuse] disposable blocklist unavailable: ${err.message}`);
    return new Set();
  }
})();

function _msOf(value) {
  if (!value) return 0;
  if (typeof value === 'number') return value;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (typeof value.toDate === 'function') return value.toDate().getTime();
  const n = new Date(value).getTime();
  return Number.isFinite(n) ? n : 0;
}

// Lowercase, strip +tags, and collapse Gmail's dot-insensitivity. This is the
// value used for uniqueness, self-referral checks and rate-limit keys — never
// the raw address the client typed.
function _normalizeEmail(raw) {
  const trimmed = typeof raw === 'string' ? raw.trim().toLowerCase() : '';
  const at = trimmed.lastIndexOf('@');
  if (at < 1 || at === trimmed.length - 1) return '';
  let local = trimmed.slice(0, at);
  let domain = trimmed.slice(at + 1);
  const plus = local.indexOf('+');
  if (plus >= 0) local = local.slice(0, plus);
  if (domain === 'googlemail.com') domain = 'gmail.com';
  if (domain === 'gmail.com') local = local.replace(/\./g, '');
  local = local.replace(/\s+/g, '');
  if (!local || !domain) return '';
  return `${local}@${domain}`;
}

function _emailHash(normalized) {
  return createHash('sha256').update(String(normalized)).digest('hex');
}

function _abusePepper(envName) {
  const value = process.env[envName];
  if (typeof value === 'string' && value.length >= 16) return value;
  return 'animequiz-abuse-pepper-v1-dev-only';
}

function _ipHash(ip) {
  if (!ip) return null;
  return createHmac('sha256', _abusePepper('ABUSE_HASH_PEPPER'))
    .update(String(ip)).digest('hex');
}

function _deviceHash(rawDeviceId) {
  const id = typeof rawDeviceId === 'string' ? rawDeviceId.trim().slice(0, 160) : '';
  if (!id) return null;
  return createHmac('sha256', _abusePepper('DEVICE_HASH_PEPPER'))
    .update(id).digest('hex');
}

function _isDisposableEmail(normalized) {
  if (!normalized) return false;
  const domain = normalized.slice(normalized.lastIndexOf('@') + 1);
  if (!domain) return false;
  if (DISPOSABLE_EMAIL_DOMAINS.has(domain)) return true;
  for (const blocked of DISPOSABLE_EMAIL_DOMAINS) {
    if (domain.endsWith(`.${blocked}`)) return true;
  }
  return false;
}

async function _logAbuse({ uid = null, ip = null, reason, fnName = '', meta = null }) {
  if (!reason) return;
  try {
    await db.collection('abuse_log').doc().set({
      uid: uid || null,
      ipHash: _ipHash(ip),
      reason,
      fnName: fnName || '',
      meta: meta && typeof meta === 'object' ? meta : null,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(
        Date.now() + CFG.ABUSE_LOG_TTL_DAYS * CFG.DAY_MS
      ),
    });
  } catch (err) {
    console.warn(`[abuse] log failed: ${err.message}`);
  }
}

// Fixed-window transactional counter. One doc per key; the TTL field lets the
// hourly sweeper (and, once configured, Firestore TTL) reclaim stale rows.
async function _hitRateLimit(key, limit, windowMs) {
  if (!key) return { allowed: true, count: 0, retryAfterSeconds: 0 };
  const ref = db.collection('rate_limits').doc(key);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const d = snap.data() || {};
    const startedAt = Number(d.windowStartMs) || 0;
    const expired = !startedAt || now - startedAt >= windowMs;
    const count = expired ? 0 : (Number(d.count) || 0);
    if (count >= limit) {
      return {
        allowed: false,
        count,
        retryAfterSeconds: Math.max(
          1,
          Math.ceil((startedAt + windowMs - now) / 1000)
        ),
      };
    }
    tx.set(ref, {
      count: count + 1,
      windowStartMs: expired ? now : startedAt,
      updatedAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(
        now + Math.max(windowMs, CFG.RATE_LIMIT_TTL_HOURS * 3600 * 1000)
      ),
    }, { merge: true });
    return { allowed: true, count: count + 1, retryAfterSeconds: 0 };
  });
}

async function _emailVerifiedForUid(uid) {
  if (!uid) return false;
  try {
    const user = await getAuth().getUser(uid);
    return user?.emailVerified === true;
  } catch (err) {
    console.warn(`[email] getUser failed uid=${uid}: ${err.message}`);
    return false;
  }
}

// ── Verified-email gate (money paths only) ─────────────────────────────────
// Only these callables enforce it: submitPayoutDetails, savePayoutDetail,
// claimReferralCashout, requestPaymentLink, claimReferralBonus (invitee).
// Nothing else checks verification. The ID-token claim is authoritative: the
// client refreshes it after verifying (see AuthService.refreshEmailVerification),
// so a stale token fails closed until the next refresh.
//
// Test accounts bypass the link flow entirely (treated as verified).
const EMAIL_VERIFICATION_BYPASS = new Set(['1@gmail.com', '2@gmail.com']);
function _isEmailVerificationBypassed(rawEmail) {
  return EMAIL_VERIFICATION_BYPASS.has(_normalizeEmail(rawEmail));
}
function _assertEmailVerified(request, fnName) {
  if (request.auth?.token?.email_verified === true) return;
  if (_isEmailVerificationBypassed(request.auth?.token?.email || '')) return;
  throw new HttpsError(
    'failed-precondition',
    'Verify your email address to continue.',
    { reason: 'email_not_verified', fn: fnName },
  );
}

async function _assertAccountAge(uid, minDays, fnName) {
  const snap = await db.collection('users').doc(uid).get();
  const data = snap.data() || {};
  const createdMs = _msOf(data.createdAt) || _msOf(data.accountCreatedAt);
  const ageDays = createdMs > 0 ? (Date.now() - createdMs) / CFG.DAY_MS : 0;
  if (ageDays < minDays) {
    await _logAbuse({
      uid,
      reason: 'account_too_new',
      fnName,
      meta: { ageDays: Math.floor(ageDays), minDays },
    });
    throw new HttpsError(
      'failed-precondition',
      `Your account must be at least ${minDays} days old.`,
      { reason: 'account_too_new', minDays }
    );
  }
}

// Stores a peppered hash of the per-install device id, keeps a server-only
// account index, and FLAGS (never blocks) a device with too many accounts.
async function _touchDevice(uid, rawDeviceId) {
  const hash = _deviceHash(rawDeviceId);
  if (!uid || !hash) return null;

  await db.collection('users').doc(uid).set({
    deviceHash: hash,
    deviceUpdatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  const indexRef = db.collection('telemetry')
    .doc('devices').collection('accounts').doc(hash);
  let count = 0;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(indexRef);
    const d = snap.data() || {};
    const uids = Array.isArray(d.uids)
      ? d.uids.filter((v) => typeof v === 'string')
      : [];
    if (!uids.includes(uid)) uids.push(uid);
    count = uids.length;
    tx.set(indexRef, {
      uids: uids.slice(-100),
      count,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });

  if (count > CFG.DEVICE_ACCOUNT_FLAG_THRESHOLD) {
    await _recordAntiCheatSignal(uid, 'multi_account_device', {
      detail: { accounts: count },
    }).catch(() => {});
    await _logAbuse({
      uid,
      reason: 'multi_account_device',
      fnName: 'device',
      meta: { accounts: count },
    });
  }
  return hash;
}

async function _isSelfReferral(referrerUid, { normalizedEmail, deviceHash, ip }) {
  if (!referrerUid) return false;
  try {
    const snap = await db.collection('users').doc(referrerUid).get();
    const d = snap.data() || {};
    if (normalizedEmail && d.emailNormalized === normalizedEmail) return true;
    if (deviceHash && d.deviceHash === deviceHash) return true;
    if (ip) {
      const signal = await db.collection('telemetry').doc('account_signals')
        .collection('users').doc(referrerUid).get();
      if ((signal.data() || {}).createdIp === ip) return true;
    }
  } catch (err) {
    console.warn(`[self-referral] check failed: ${err.message}`);
  }
  return false;
}

const QUIZ_CADENCE_MAX_EVENTS = 300;
const QUIZ_CADENCE_MAX_IPS = 20;
// Fire-and-forget per-submit cadence/IP log. Races may drop an entry under
// concurrent submits �?acceptable for signal. NEVER awaited on gameplay
// paths; all failures swallowed so awards are unaffected.
async function _logQuizCadence(uid, ip, nowMs) {
  try {
    const ref = db.collection('telemetry').doc('quiz_cadence').collection('users').doc(uid);
    const snap = await ref.get();
    const d = snap.exists ? (snap.data() || {}) : {};
    let recent = Array.isArray(d.recentSubmits)
      ? d.recentSubmits.filter((t) => Number.isFinite(Number(t)))
      : [];
    recent.push(nowMs);
    if (recent.length > QUIZ_CADENCE_MAX_EVENTS) {
      recent = recent.slice(recent.length - QUIZ_CADENCE_MAX_EVENTS);
    }
    let ips = Array.isArray(d.ips) ? d.ips.filter((s) => typeof s === 'string') : [];
    if (ip && !ips.includes(ip)) {
      ips.push(ip);
      if (ips.length > QUIZ_CADENCE_MAX_IPS) ips = ips.slice(ips.length - QUIZ_CADENCE_MAX_IPS);
    }
    await ref.set({
      lastIp: ip || d.lastIp || null,
      ips,
      recentSubmits: recent,
      submitCount: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  } catch (err) {
    console.warn(`[_logQuizCadence] signal write failed (ignored): ${err.message}`);
  }
}

// ── Username + university invariants (server-authoritative) ────────────────
// These live on the server because the client can no longer write `username`
// or `university` directly (firestore.rules allows only `fcmToken`).
const USERNAME_MIN_LEN = 3;
const USERNAME_MAX_LEN = 20;
const USERNAME_CHANGE_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;

// EXACT mirror of `kNigerianUniversities` in
// lib/core/services/firestore_service.dart. Keep the two lists in sync.
const VALID_UNIVERSITIES = [
  'UNILAG',
  'UI (University of Ibadan)',
  'OAU',
  'FUTA',
  'UNIABUJA',
  'UNIBEN',
  'ABU Zaria',
  'UNIPORT',
  'NOUN',
  'Babcock',
  'Other',
];

const NEW_USER_TOTAL_SCORE = 500;
const NEW_USER_STATS = {
  gamesPlayed: 0,
  gamesWon:    0,
  gamesLost:   0,
  hseWon:      0,
  hseLost:     0,
  hseStaked:   0,
};

// Returns the trimmed display name, or null when it is not a valid username.
// 3-20 characters, no control characters (emoji and accents stay allowed).
function _sanitizeUsername(raw) {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (trimmed.length < USERNAME_MIN_LEN || trimmed.length > USERNAME_MAX_LEN) {
    return null;
  }
  if (/[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  return trimmed;
}

// Canonical uniqueness key: usernames are case-insensitive and whitespace-
// insensitive at the edges, so "Alice" and "alice " cannot coexist.
function _usernameKey(raw) {
  return String(raw).trim().toLowerCase();
}

// null = field absent; undefined = present but invalid; string = accepted.
function _normalizeUniversity(raw) {
  if (raw === undefined || raw === null || raw === '') return null;
  if (typeof raw !== 'string') return undefined;
  return VALID_UNIVERSITIES.includes(raw) ? raw : undefined;
}

// Bump when the Terms or Privacy Policy text changes materially. The app
// links to the same documents (lib/features/legal/).
const TERMS_VERSION = '2026-10-27';

// ── Phase 2: ensureProfile ─────────────────────────────────────────────────
// Called once after sign-up. It is now the ONLY way a `users/{uid}` doc can be
// created (firestore.rules denies client creates), which makes these
// invariants server-enforced rather than client-attested:
//   �?username is validated and claimed in `usernames/{lowercased}` so two
//     accounts can never share one (signup included),
//   �?totalScore / stats / animeCoins / weeklyPoints are seeded server-side,
//     so a client cannot create itself a 10,000-game profile,
//   �?university must be one of the canonical values,
//   �?referredBy is resolved and confirmed server-side.
// Idempotent: a retry (or a pre-hardening client that already wrote its own
// profile) never overwrites the existing doc; it only backfills the username
// claim if the name is still free.
exports.ensureProfile = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'ensureProfile');

    const username = _sanitizeUsername(request.data?.username);
    if (request.data?.username !== undefined && username === null) {
      throw new HttpsError(
        'invalid-argument',
        `Username must be ${USERNAME_MIN_LEN}-${USERNAME_MAX_LEN} characters.`
      );
    }

    const university = _normalizeUniversity(request.data?.university);
    if (university === undefined) {
      throw new HttpsError('invalid-argument', 'Unknown university.');
    }

    // Terms are accepted once, at profile creation. The version is stamped
    // here, never taken from the client, so the stored value is the server's
    // record of what the account agreed to.
    const isNewProfile = !(await db.collection('users').doc(uid).get()).exists;
    if (isNewProfile && request.data?.termsAccepted !== true) {
      throw new HttpsError(
        'failed-precondition',
        'Accept the Terms of Service and Privacy Policy to create an account.',
        { reason: 'terms_not_accepted' }
      );
    }

    // ── Pre-flight: normalized email, disposable check, per-IP limits ──────
    // Runs before the profile transaction so a rejected signup costs no
    // writes. The existing client rollback deletes the Auth account when this
    // callable throws.
    const ip = _clientIp(request);
    const rawEmail = request.auth.token?.email || request.data?.email || '';
    const normalizedEmail = _normalizeEmail(rawEmail);
    const emailHash = normalizedEmail ? _emailHash(normalizedEmail) : '';
    const userRef = db.collection('users').doc(uid);
    const preUserSnap = await userRef.get();
    const signupDeviceHash = _deviceHash(request.data?.deviceId);

    if (!preUserSnap.exists) {
      if (normalizedEmail && _isDisposableEmail(normalizedEmail)) {
        await _logAbuse({ uid, ip, reason: 'disposable_email', fnName: 'ensureProfile' });
        throw new HttpsError(
          'invalid-argument',
          'Use a permanent email address. Disposable inboxes are not accepted.',
          { reason: 'disposable_email' }
        );
      }
      const ipKey = _ipHash(ip) || 'no-ip';
      const hourly = await _hitRateLimit(
        `account_create:hour:${ipKey}`,
        CFG.ACCOUNT_CREATE_MAX_PER_HOUR_PER_IP,
        60 * 60 * 1000
      );
      const daily = await _hitRateLimit(
        `account_create:day:${ipKey}`,
        CFG.ACCOUNT_CREATE_MAX_PER_DAY_PER_IP,
        CFG.DAY_MS
      );
      if (!hourly.allowed || !daily.allowed) {
        await _logAbuse({
          uid, ip, reason: 'account_create_rate_limited', fnName: 'ensureProfile',
        });
        throw new HttpsError(
          'resource-exhausted',
          'Too many accounts from this network. Try again later.',
          {
            reason: 'too_many_accounts',
            retryAfterSeconds: Math.max(
              hourly.retryAfterSeconds,
              daily.retryAfterSeconds
            ),
          }
        );
      }
    }

    // Resolve before the transaction (a read outside it is fine) and never
    // trust a client-supplied uid: _resolveReferrerUid confirms the doc exists.
    let referrerUid = null;
    try {
      const resolved = await _resolveReferrerUid(request.data?.referredBy);
      if (resolved && resolved !== uid) referrerUid = resolved;
    } catch (_) {
      // Referral capture is best-effort; registration must not fail.
    }

    // Self-referral: same normalized email, same device, or the referrer's
    // signup IP. Dropping the referral (instead of failing signup) keeps the
    // registration path honest without leaking which signal matched.
    if (referrerUid && await _isSelfReferral(referrerUid, {
      normalizedEmail,
      deviceHash: signupDeviceHash,
      ip,
    })) {
      await _logAbuse({
        uid, ip, reason: 'self_referral', fnName: 'ensureProfile',
        meta: { referrerUid },
      });
      referrerUid = null;
    }
    let profileCreated = false;
    let claimedUsername = '';

    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      const existing = userSnap.data() || {};

      // An existing profile keeps its username: an attacker cannot re-run
      // ensureProfile with a different name to bypass the 7-day cooldown.
      const targetUsername = userSnap.exists
        ? (typeof existing.username === 'string' ? existing.username : '')
        : (username || '');

      if (!userSnap.exists && !targetUsername) {
        throw new HttpsError('invalid-argument', 'Username is required.');
      }

      const key = targetUsername ? _usernameKey(targetUsername) : '';
      const nameRef = key ? db.collection('usernames').doc(key) : null;
      const nameSnap = nameRef ? await tx.get(nameRef) : null;

      // Normalized-email uniqueness: Firebase Auth only compares the literal
      // address, so a.b@gmail.com / a+b@gmail.com / A.B@googlemail.com would
      // otherwise create three accounts. The claim is server-only.
      if (!userSnap.exists && emailHash) {
        const identityRef = db.collection('emailIdentities').doc(emailHash);
        const identitySnap = await tx.get(identityRef);
        if (identitySnap.exists && identitySnap.data()?.uid !== uid) {
          throw new HttpsError(
            'already-exists',
            'An account with this email already exists.',
            { reason: 'email_already_registered' }
          );
        }
        if (!identitySnap.exists) {
          tx.set(identityRef, {
            uid,
            emailNormalized: normalizedEmail,
            createdAt: FieldValue.serverTimestamp(),
          });
        }
      }

      if (!userSnap.exists) {
        if (nameSnap && nameSnap.exists && nameSnap.data()?.uid !== uid) {
          throw new HttpsError('already-exists', 'That username is already taken.');
        }
        tx.set(userRef, {
          username:       targetUsername,
          email:          rawEmail,
          emailNormalized: normalizedEmail || null,
          emailHash:      emailHash || null,
          emailVerified:  false,
          accountStatus:  'active',
          termsAcceptedAt: FieldValue.serverTimestamp(),
          termsVersion:    TERMS_VERSION,
          totalScore:     NEW_USER_TOTAL_SCORE,
          animeCoins:     0,
          weeklyPoints:   0,
          weeklyReset:    FieldValue.serverTimestamp(),
          createdAt:      FieldValue.serverTimestamp(),
          stats:          { ...NEW_USER_STATS },
          ...(university ? { university } : {}),
          ...(signupDeviceHash ? { deviceHash: signupDeviceHash } : {}),
          ...(referrerUid ? { referredBy: referrerUid } : {}),
        });
        profileCreated = true;
      }

      if (nameRef && (!nameSnap || !nameSnap.exists)) {
        tx.set(nameRef, {
          uid,
          username:  targetUsername,
          createdAt: FieldValue.serverTimestamp(),
        });
      } else if (nameRef && nameSnap.exists && nameSnap.data()?.uid !== uid) {
        // A legacy profile whose name is already claimed: never steal it.
        console.warn(`[ensureProfile] username already claimed uid=${uid} key=${key}`);
      }

      claimedUsername = targetUsername;
    });

    // Device identity is stored only after the profile exists (never as a
    // side-effect that could create a profile-less users doc).
    await _touchDevice(uid, request.data?.deviceId);

    const ref = db.collection('telemetry').doc('account_signals').collection('users').doc(uid);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        tx.set(ref, {
          createdAt: FieldValue.serverTimestamp(),
          createdIp: ip,
          lastIp: ip,
          lastSeenAt: FieldValue.serverTimestamp(),
        });
      } else {
        tx.set(ref, {
          lastIp: ip,
          lastSeenAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    });

    // ── Referral record (best-effort) ────────────────────────────────────
    // Creates users/{inviter}/referrals/{uid} for the Referrals page. NEVER
    // fails the callable: the profile and telemetry stay authoritative.
    try {
      const inviteeSnap = await userRef.get();
      const inviteeData = inviteeSnap.data() || {};
      const recordFor = referrerUid || await _resolveReferrerUid(inviteeData.referredBy);
      if (recordFor && recordFor !== uid) {
        const referralRef = db.collection('users').doc(recordFor)
          .collection('referrals').doc(uid);
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(referralRef);
          // Idempotent: an existing record is never reset (createdAt/status).
          if (snap.exists) return;
          tx.set(referralRef, _referralRecordDefaults(inviteeData.username));
        });
      }
    } catch (err) {
      console.log(`[ensureProfile] referral record skipped: ${err.message}`);
    }

    return {
      success: true,
      recorded: ip !== null,
      profileCreated,
      username: claimedUsername,
    };
  }
);

// ── acceptTerms: one-time re-acceptance for pre-terms accounts ───────────────
// Pre-terms profiles have no `termsAcceptedAt`. The client gates on that field
// and shows the acceptance screen once; this callable stamps the acceptance
// server-side (never from the client). Idempotent: a repeat call is a no-op.
exports.acceptTerms = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'acceptTerms');

    if (request.data?.termsAccepted !== true) {
      throw new HttpsError(
        'failed-precondition',
        'Accept the Terms of Service and Privacy Policy to continue.',
        { reason: 'terms_not_accepted' },
      );
    }

    const userRef = db.collection('users').doc(uid);
    const snap = await userRef.get();
    if (!snap.exists) throw new HttpsError('not-found', 'Profile not found.');
    const existing = snap.data() || {};
    if (existing.termsAcceptedAt) return { success: true, alreadyAccepted: true };

    await userRef.set({
      termsAcceptedAt: FieldValue.serverTimestamp(),
      termsVersion: TERMS_VERSION,
    }, { merge: true });
    return { success: true, termsVersion: TERMS_VERSION };
  }
);

// ── changeUsername �?server-enforced 7-day cooldown + uniqueness ───────────
// The old client path wrote `username` + `lastUsernameChange` directly and did
// the cooldown check in Dart, which a REST call could skip entirely. Both
// checks now happen here, inside one transaction, with the `usernames/{key}`
// claim moved atomically so two accounts can never end up with the same name.
exports.changeUsername = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'changeUsername');

    const username = _sanitizeUsername(request.data?.username);
    if (!username) {
      throw new HttpsError(
        'invalid-argument',
        `Username must be ${USERNAME_MIN_LEN}-${USERNAME_MAX_LEN} characters.`
      );
    }

    const userRef = db.collection('users').doc(uid);
    const newKey  = _usernameKey(username);

    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) throw new HttpsError('not-found', 'Profile not found.');
      const data = userSnap.data() || {};

      const lastChangeMs = data.lastUsernameChange?.toMillis
        ? data.lastUsernameChange.toMillis()
        : 0;
      const remainingMs = USERNAME_CHANGE_COOLDOWN_MS - (Date.now() - lastChangeMs);
      if (lastChangeMs && remainingMs > 0) {
        const days = Math.ceil(remainingMs / (24 * 60 * 60 * 1000));
        throw new HttpsError(
          'failed-precondition',
          `You can change your username again in ${days} day${days === 1 ? '' : 's'}.`
        );
      }

      const oldName = typeof data.username === 'string' ? data.username : '';
      const oldKey  = oldName ? _usernameKey(oldName) : '';
      if (oldKey === newKey) {
        throw new HttpsError('failed-precondition', 'That is already your username.');
      }

      const newRef  = db.collection('usernames').doc(newKey);
      const oldRef  = oldKey ? db.collection('usernames').doc(oldKey) : null;
      const newSnap = await tx.get(newRef);
      const oldSnap = oldRef ? await tx.get(oldRef) : null;

      if (newSnap.exists && newSnap.data()?.uid !== uid) {
        throw new HttpsError('already-exists', 'That username is already taken.');
      }

      if (oldRef && oldSnap && oldSnap.exists && oldSnap.data()?.uid === uid) {
        tx.delete(oldRef);
      }
      if (!newSnap.exists || newSnap.data()?.uid !== uid) {
        tx.set(newRef, {
          uid,
          username,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      tx.update(userRef, {
        username,
        lastUsernameChange: FieldValue.serverTimestamp(),
      });
    });

    // Auth displayName is cosmetic; a failure must not fail the change.
    try {
      await getAuth().updateUser(uid, { displayName: username });
    } catch (err) {
      console.warn(`[changeUsername] displayName update failed uid=${uid}: ${err.message}`);
    }

    console.log(`[changeUsername] uid=${uid} key=${newKey}`);
    return { success: true, username };
  }
);

// ── updateUniversity �?CF-only, canonical values only ──────────────────────
// `university` is used by the campus leaderboard and friend suggestions, so a
// free-text client write was both a spoofing vector and a way to move between
// campuses at will. The canonical list is validated here.
exports.updateUniversity = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'updateUniversity');

    const university = _normalizeUniversity(request.data?.university);
    if (!university) {
      throw new HttpsError('invalid-argument', 'Choose a university from the list.');
    }

    const userRef = db.collection('users').doc(uid);
    const snap = await userRef.get();
    if (!snap.exists) throw new HttpsError('not-found', 'Profile not found.');
    if (snap.data()?.university === university) {
      return { success: true, university };
    }

    await userRef.update({ university });
    console.log(`[updateUniversity] uid=${uid} university=${university}`);
    return { success: true, university };
  }
);


// ── deleteAccount (user self-service �?NDPA/GDPR right to erasure) ─────────
//
// Hard-deletes everything we can safely erase and ANONYMIZES records we must
// retain for financial/accounting or shared-history reasons. Returns a summary
// of what was deleted vs retained so the client and the Privacy Policy can be
// accurate about reality.
//
// HARD-DELETED
//   �?Firebase Auth account
//   �?users/{uid} AND every subcollection (recursiveDelete): matches,
//     quizSessions, gauntletEntries, coinTransactions, wpTransactions,
//     seenQuestions, questionPoolState, iapReceipts, premiumReceipts,
//     leaderboardReceipts, payoutDetails (bank details)
//   �?matchmaking_queue/{uid}
//   �?telemetry/**/{uid} (quiz_cadence, account_signals)
//   �?fraudReviews/{weekId}_{uid}
//
// ANONYMIZED BANK DETAILS (record kept �?pendingClaim IS the payout record)
//   �?leaderboardCycles/{weekId}/pendingClaim/{uid} �?accountNumber / bankCode /
//     beneficiaryName redacted, status set to 'anonymized'. Amount, timestamps
//     and markedBy survive for accounting. Refused outright above if any claim
//     is still 'pending' (money still owed).
//   �?referralCashouts/{uid} �?bank fields redacted, status/amount kept. Also
//     refused while still 'pending'.
//   �?users/{inviter}/referrals/{uid} �?the invitee's qualifying row is deleted
//     so it stops counting toward the inviter's cashout.
//
// ANONYMIZED (PII redacted, record kept)
//   �?leaderboardCycles.ranked[]  �?username/university/buyerEmail
//   �?challenges                  �?creator/opponent username (kept for the
//                                   OTHER player's match history)
//   �?ghost_sessions sessions[]   �?username
//   �?prize_pool.winners[]        �?username/university
//
// RETAINED UNCHANGED (legal/accounting obligation �?see Privacy Policy)
//   �?leaderboardCycles/*/pendingClaim/* (payout records; bank fields anonymized
//     below because nothing further is owed once status is 'marked')
//   �?processedTransactions/*, paymentIntents/* (purchase/accounting records:
//     code/amount/buyerEmail are kept for reconciliation, the account uid is
//     removed below so the record no longer points at the deleted person)
//   �?house_fees/* (house-rake accounting)
//   �?redemptionCodes/* (redeemed purchase records)
//
// GUARD: refuses deletion while a claim is still 'pending' (admin has not
// transferred the prize yet), so an outstanding prize and the bank details it
// depends on are never destroyed by an account deletion.
const _DELETE_BATCH = 400;

async function _deleteQueryInBatches(query, label) {
  let total = 0;
  for (;;) {
    const snap = await query.limit(_DELETE_BATCH).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    total += snap.size;
    if (snap.size < _DELETE_BATCH) break;
  }
  if (total > 0) console.log(`[deleteAccount] deleted ${total} ${label}`);
  return total;
}

exports.deleteAccount = onSecureCall(
  { region: 'us-central1', timeoutSeconds: 540, memory: '512MiB' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    // NOTE: deliberately NOT gated by _assertClientBuildAllowed. The privacy
    // policy promises deletion on request, and an outdated install is exactly
    // the population most likely to be stuck behind the update wall. Refusing
    // deletion there would turn a self-service privacy right into a support
    // ticket. See the exclusion list on _assertClientBuildAllowed.

    // ── 0. Guard: block while a prize is still owed to this account ───────
    // Payouts are manual, so there is no transfer to wait on �?the only thing
    // that matters is whether the admin still owes money. An unsubmitted or
    // pending claim means either a prize is unclaimed (which is forfeited, never
    // carried over into any later week's pool �?see checkPendingClaim) or the
    // admin is holding the destination account to send to.
    // Deleting now would destroy the bank details a pending transfer needs.
    const cycleSnaps = await db.collection('leaderboardCycles').get();
    for (const c of cycleSnaps.docs) {
      const claim = await c.ref.collection('pendingClaim').doc(uid).get();
      if (claim.exists && claim.data()?.status === 'pending') {
        throw new HttpsError(
          'failed-precondition',
          'You have a prize payout awaiting payment on this account. ' +
          'Wait for it to be paid before deleting your account.'
        );
      }
    }

    // Same rule for a submitted referral cashout: the admin is holding this
    // account's destination and owes the money, so deletion would destroy the
    // only record of where to send it.
    const cashoutSnap = await db.collection('referralCashouts').doc(uid).get();
    if (cashoutSnap.exists && cashoutSnap.data()?.status === 'pending') {
      throw new HttpsError(
        'failed-precondition',
        'You have a referral cashout awaiting payment on this account. ' +
        'Wait for it to be paid before deleting your account.'
      );
    }

    const deleted = {};
    const anonymized = {};
    const retained = [
      'leaderboardCycles/pendingClaim', 'processedTransactions',
      'paymentIntents', 'house_fees', 'redemptionCodes',
    ];

    // ── 1. Delete user-owned subcollections + the user doc ───────────────
    // recursiveDelete removes users/{uid} and every subcollection beneath it,
    // including payoutDetails (bank account details are destroyed).
    // Capture the username claim first: after recursiveDelete the profile is
    // gone, and leaving usernames/{key} behind would permanently reserve the
    // name of a deleted account.
    let removedUsernameKey = '';
    let referrerUid = null;
    try {
      const profileSnap = await db.collection('users').doc(uid).get();
      const profile = profileSnap.data() || {};
      const profileName = profile.username;
      if (typeof profileName === 'string' && profileName.trim()) {
        removedUsernameKey = _usernameKey(profileName);
      }
      // The invitee's row lives under the REFERRER's profile, so it survives
      // recursiveDelete below. Capture the referrer now so the qualifying
      // record is removed with the account instead of counting forever.
      const resolved = await _resolveReferrerUid(profile.referredBy);
      if (resolved && resolved !== uid) referrerUid = resolved;
    } catch (_) { /* best-effort */ }

    await db.recursiveDelete(db.collection('users').doc(uid));
    deleted.userDocAndSubcollections = true;

    if (referrerUid) {
      try {
        await db.collection('users').doc(referrerUid)
          .collection('referrals').doc(uid).delete();
        deleted.referralRecord = true;
      } catch (err) {
        console.warn(`[deleteAccount] referral record cleanup failed (ignored): ${err.message}`);
      }
    }

    if (removedUsernameKey) {
      try {
        const nameRef = db.collection('usernames').doc(removedUsernameKey);
        const nameSnap = await nameRef.get();
        if (nameSnap.exists && nameSnap.data()?.uid === uid) {
          await nameRef.delete();
          deleted.usernameClaim = true;
        }
      } catch (err) {
        console.warn(`[deleteAccount] username claim cleanup failed (ignored): ${err.message}`);
      }
    }

    // ── 2. Standalone user-keyed docs ────────────────────────────────────
    await db.collection('matchmaking_queue').doc(uid).delete().catch(() => {});
    deleted.matchmakingQueue = true;
    await db.collection('telemetry').doc('quiz_cadence')
      .collection('users').doc(uid).delete().catch(() => {});
    await db.collection('telemetry').doc('account_signals')
      .collection('users').doc(uid).delete().catch(() => {});
    deleted.telemetry = true;

    // ── 2b. Friends cleanup ────────────────────────────────────────────
    // Pair docs list both members, so both directions are queried. Counterpart
    // links are deleted per peer (bounded by the 50-friend cap + pending).
    // friendCodes docs are keyed by CODE, so they are queried by uid.
    try {
      const [asA, asB] = await Promise.all([
        db.collection('friendships').where('aUid', '==', uid).get(),
        db.collection('friendships').where('bUid', '==', uid).get(),
      ]);
      const peers = new Set();
      const batch = db.batch();
      for (const d of [...asA.docs, ...asB.docs]) {
        const data = d.data() || {};
        const peer = data.aUid === uid ? data.bUid : data.aUid;
        if (peer) peers.add(peer);
        batch.delete(d.ref);
      }
      for (const peer of peers) {
        batch.delete(db.collection('users').doc(peer).collection('friendLinks').doc(uid));
      }
      if (peers.size > 0 || asA.size + asB.size > 0) await batch.commit();
      deleted.friendships = asA.size + asB.size;
      deleted.friendCounterpartLinks = peers.size;
    } catch (err) {
      console.warn(`[deleteAccount] friends cleanup failed (ignored): ${err.message}`);
      deleted.friendships = 'error_ignored';
    }
    try {
      deleted.friendCodes = await _deleteQueryInBatches(
        db.collection('friendCodes').where('uid', '==', uid), 'friendCodes');
    } catch (err) {
      console.warn(`[deleteAccount] friendCodes cleanup failed (ignored): ${err.message}`);
    }
    // referralCodes is keyed by CODE too, so it needs the same by-uid query.
    // Erasing it releases the code for reuse and leaves no uid behind.
    try {
      deleted.referralCodes = await _deleteQueryInBatches(
        db.collection('referralCodes').where('uid', '==', uid), 'referralCodes');
    } catch (err) {
      console.warn(`[deleteAccount] referralCodes cleanup failed (ignored): ${err.message}`);
    }

    deleted.fraudReviews = await _deleteQueryInBatches(
      db.collection('fraudReviews').where('uid', '==', uid), 'fraudReviews');

    // Server-minted runs hold the player's question set and (server-side)
    // answer key. They are per-account data and must be erased with it.
    try {
      deleted.quizRuns = await _deleteQueryInBatches(
        db.collection(QUIZ_RUNS).where('uid', '==', uid), 'quizRuns');
    } catch (err) {
      console.warn(`[deleteAccount] quizRuns cleanup failed (ignored): ${err.message}`);
    }

    // Contact / bug reports carry the sender's uid, username and email, and
    // may quote personal details in the message body: wipe them with the
    // account rather than leaving them behind after erasure.
    try {
      deleted.feedback = await _deleteQueryInBatches(
        db.collection('feedback').where('uid', '==', uid), 'feedback');
    } catch (err) {
      console.warn(`[deleteAccount] feedback cleanup failed (ignored): ${err.message}`);
    }

    // pendingClaim/{uid} under every cycle.
    //
    // With manual payouts these docs ARE the payout record, so they are not
    // simply deleted. The guard above already refused deletion while any claim
    // was still 'pending', so nothing is owed at this point and no money is
    // lost by keeping the record. Bank fields are PII and are redacted; the
    // amount, timestamps and markedBy stay for accounting.
    //
    // ONLY documents that already exist are updated. A player who never won a
    // prize has no claim in most (or all) cycles; writing with set({merge:true})
    // used to CREATE an anonymized claim for every cycle, polluting the payout
    // ledger with phantom winners. update() is used instead, and a missing doc
    // is skipped.
    let anonymizedClaims = 0;
    for (const c of cycleSnaps.docs) {
      const claimRef = c.ref.collection('pendingClaim').doc(uid);
      try {
        const claimSnap = await claimRef.get();
        if (!claimSnap.exists) continue;
        await claimRef.update({
          accountNumber:   FieldValue.delete(),
          bankCode:        FieldValue.delete(),
          beneficiaryName: FieldValue.delete(),
          status:          'anonymized',
          anonymizedAt:    FieldValue.serverTimestamp(),
        });
        anonymizedClaims++;
      } catch (err) {
        // Never fail account erasure on a claim that cannot be updated; log so
        // a persistent PII-leftover can still be spotted in the logs.
        console.warn(
          `[deleteAccount] pendingClaim anonymize skipped ${c.id}: ${err.message}`);
      }
    }
    if (anonymizedClaims > 0) anonymized.pendingClaims = anonymizedClaims;

    // referralCashouts/{uid} is a financial record (amount/status stay for
    // accounting) but its bank fields are PII. A pending claim already blocked
    // deletion above, so only paid/rejected/anonymized rows reach this point.
    try {
      const cashoutRef = db.collection('referralCashouts').doc(uid);
      const freshCashout = await cashoutRef.get();
      if (freshCashout.exists) {
        await cashoutRef.update({
          accountNumber: FieldValue.delete(),
          bankCode: FieldValue.delete(),
          bankName: FieldValue.delete(),
          beneficiaryName: FieldValue.delete(),
          riskFlags: FieldValue.delete(),
          qualifiedInvitees: FieldValue.delete(),
          anonymized: true,
          anonymizedAt: FieldValue.serverTimestamp(),
        });
        anonymized.referralCashout = true;
      }
    } catch (err) {
      console.warn(
        `[deleteAccount] referral cashout anonymize skipped: ${err.message}`);
    }

    // ── 3. Anonymize shared / financial records ──────────────────────────
    const REDACTED_NAME = 'Deleted user';

    // leaderboardCycles.ranked[] �?redact PII, keep rank/share/paid (audit)
    for (const c of cycleSnaps.docs) {
      const data = c.data() || {};
      const ranked = Array.isArray(data.ranked) ? data.ranked : [];
      let touched = false;
      const updated = ranked.map((r) => {
        if (r && r.uid === uid) {
          touched = true;
          return {
            ...r,
            username: REDACTED_NAME,
            university: null,
            buyerEmail: null,
          };
        }
        return r;
      });
      if (touched) {
        await c.ref.set({ ranked: updated }, { merge: true });
        anonymized.leaderboardCycles = (anonymized.leaderboardCycles || 0) + 1;
      }
    }

    // Purchase records are retained for accounting, but the account link is not
    // needed for that purpose: drop the uid from the intent and the processed
    // audit row. `boundUid` on an unused code is deliberately KEPT — it is what
    // stops a bought code from becoming transferable once the account is gone.
    try {
      const [intents, processed] = await Promise.all([
        db.collection('paymentIntents').where('uid', '==', uid).get(),
        db.collection('processedTransactions').where('uid', '==', uid).get(),
      ]);
      const purchaseBatch = db.batch();
      for (const d of intents.docs) {
        purchaseBatch.set(d.ref, { uid: null }, { merge: true });
      }
      for (const d of processed.docs) {
        purchaseBatch.set(d.ref, { uid: null }, { merge: true });
      }
      if (intents.size + processed.size > 0) await purchaseBatch.commit();
      if (intents.size > 0) anonymized.paymentIntents = intents.size;
      if (processed.size > 0) anonymized.processedTransactions = processed.size;
    } catch (err) {
      console.warn(
        `[deleteAccount] purchase uid redaction failed (ignored): ${err.message}`);
    }

    // challenges �?redact usernames, keep the doc for the other player
    let chalAnon = 0;
    for (const field of ['creatorUid', 'opponentUid']) {
      const snap = await db.collection('challenges').where(field, '==', uid).get();
      for (const d of snap.docs) {
        const patch = {};
        if (d.data()?.creatorUid === uid) patch.creatorUsername = REDACTED_NAME;
        if (d.data()?.opponentUid === uid) patch.opponentUsername = REDACTED_NAME;
        if (Object.keys(patch).length > 0) {
          await d.ref.set(patch, { merge: true });
          chalAnon++;
        }
      }
    }
    anonymized.challenges = chalAnon;

    // ghost_sessions sessions[] �?redact username
    let ghostAnon = 0;
    const ghostSnaps = await db.collection('ghost_sessions').get();
    for (const g of ghostSnaps.docs) {
      const sessions = Array.isArray(g.data()?.sessions) ? g.data().sessions : [];
      let touched = false;
      const updated = sessions.map((s) => {
        if (s && s.uid === uid) {
          touched = true;
          return { ...s, username: REDACTED_NAME };
        }
        return s;
      });
      if (touched) {
        await g.ref.set({ sessions: updated }, { merge: true });
        ghostAnon++;
      }
    }
    anonymized.ghostSessions = ghostAnon;

    // prize_pool.winners[] �?redact username/university
    let poolAnon = 0;
    const poolSnaps = await db.collection('prize_pool').get();
    for (const p of poolSnaps.docs) {
      const winners = Array.isArray(p.data()?.winners) ? p.data().winners : [];
      let touched = false;
      const updated = winners.map((w) => {
        if (w && w.uid === uid) {
          touched = true;
          return { ...w, username: REDACTED_NAME, university: null };
        }
        return w;
      });
      if (touched) {
        await p.ref.set({ winners: updated }, { merge: true });
        poolAnon++;
      }
    }
    anonymized.prizePool = poolAnon;

    // ── 4. Delete the Firebase Auth account (last) ───────────────────────
    // Done last so a failure above leaves the account recoverable rather than
    // orphaned-but-unreachable.
    try {
      await getAuth().deleteUser(uid);
      deleted.authUser = true;
    } catch (err) {
      // If the auth user is already gone, treat as success; anything else is
      // surfaced so the client can retry the auth deletion.
      if (err.code === 'auth/user-not-found') {
        deleted.authUser = 'already-absent';
      } else {
        console.error(`[deleteAccount] auth delete failed uid=${uid}: ${err.message}`);
        throw new HttpsError('internal',
          'Your data was removed but the sign-in account could not be deleted. Please contact support.');
      }
    }

    console.log(`[deleteAccount] uid=${uid} deleted=${JSON.stringify(deleted)} ` +
      `anonymized=${JSON.stringify(anonymized)}`);

    return {
      success: true,
      deleted,
      anonymized,
      // Records retained for legal/accounting reasons �?mirrored in the
      // Privacy Policy so the wording matches reality.
      retained,
    };
  }
);

// ── Phase 2: repairAntifraudConfig (one-time stale-config cleanup) ─────────
// Resets hard-cap-era soloDailyCap values (<100, e.g. the Phase 1 default 40,
// now redefined as "full-reward games before decay") to the new default 100,
// or creates the doc with defaults when missing. Admin-gated, idempotent,
// auditable via repairedAt/repairedBy + previousSoloDailyCap.
function _antifraudRepairAction(data) {
  if (!data) return 'created';
  const v = Number(data.soloDailyCap);
  if (Number.isInteger(v) && v < 100) return 'reset';
  return 'ok';
}

exports.repairAntifraudConfig = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }
    const ref = db.collection('server_config').doc('antifraud');
    const snap = await ref.get();
    const data = snap.exists ? snap.data() : null;
    const action = _antifraudRepairAction(data);
    if (action === 'created') {
      await ref.set({
        soloDailyCap: SOLO_DECAY_THRESHOLD_DEFAULT,
        repairedAt: FieldValue.serverTimestamp(),
        repairedBy: request.auth.uid,
      }, { merge: true });
    } else if (action === 'reset') {
      await ref.set({
        previousSoloDailyCap: data.soloDailyCap,
        soloDailyCap: SOLO_DECAY_THRESHOLD_DEFAULT,
        repairedAt: FieldValue.serverTimestamp(),
        repairedBy: request.auth.uid,
      }, { merge: true });
    }
    console.log(`[repairAntifraudConfig] action=${action} by ${request.auth.uid}`);
    return {
      success: true,
      action,
      previous: data ? (data.soloDailyCap ?? null) : null,
      soloDailyCap: SOLO_DECAY_THRESHOLD_DEFAULT,
    };
  }
);

// ── Phase 3 fraud suspicion scoring (advisory only �?NEVER auto-blocks) ───
// A human reviews score + reasons in the admin payout page before approving.
// Every weight/threshold is tunable via app_config/antifraud.fraud (merged
// over the defaults below); missing/invalid entries fall back to defaults so
// scoring never fails for config reasons.
const FRAUD_DEFAULTS = {
  // 1. cadence regularity (rapid-fire + mechanical gaps)
  wCadence: 25, rapidGapMs: 3000, rapidFullRatio: 0.5,
  mechMinGaps: 15, mechMaxCV: 0.15,
  // 2. sustained solo volume (deliberately weak �?soft decay makes this legal)
  wVolume: 10, volumeFullPerDay: 100, volumeMinPerDay: 40,
  // 3. repeated stake pairing (max over pairs, not summed)
  wPair: 25, pairFullCount: 5, pairMinCount: 3,
  funnelMinGames: 4, funnelMinWinRate: 0.8,
  // 4. shared IP (deliberately weak �?households share IPs innocently)
  wIp: 15,
  // 5. account age vs WP earned
  wAge: 15, newbornDays: 7, newbornWP: 1500, youngDays: 14, youngWP: 2000,
  toddlerDays: 3, toddlerWP: 500,
  // 6. stake win-rate anomaly vs QM baseline
  wWinRate: 20, stakeMinGames: 10,
  stakeHighRate: 0.9, stakeMidRate: 0.8, baselineQmRate: 0.65, qmMinGames: 5,
  // bands
  bandModerate: 30, bandHigh: 60,
};

async function _getFraudConfig() {
  const cfg = { ...FRAUD_DEFAULTS };
  try {
    const data = await _readServerConfig('antifraud');
    const raw = data?.fraud || {};
    for (const k of Object.keys(FRAUD_DEFAULTS)) {
      const v = Number(raw[k]);
      if (Number.isFinite(v) && v >= 0) cfg[k] = v;
    }
  } catch (err) {
    console.warn(`[_getFraudConfig] config read failed, using defaults: ${err.message}`);
  }
  return cfg;
}

function _fraudBand(score, cfg) {
  if (score >= cfg.bandHigh) return 'high';
  if (score >= cfg.bandModerate) return 'moderate';
  return 'low';
}

// Pure scorer (kept side-effect-free for testability). Profile p:
//   submits: [epochMs], volumePerDay, pairs: [{games, wins}],
//   sharedWith: [{stakedAgainst}], accountAgeDays|null, weeklyPoints,
//   stakeGames, stakeWins, qmGames, qmWins.
// Returns { score (0-100), reasons: [code strings with brief detail] }.
function _scoreFraudProfile(p, cfg) {
  let score = 0;
  const reasons = [];
  const add = (pts, code) => {
    if (pts > 0) { score += pts; reasons.push(code); }
  };

  // 1. cadence: rapid-fire share + mechanical regularity (scripts are regular)
  {
    const ts = (Array.isArray(p.submits) ? p.submits : [])
      .map(Number).filter(Number.isFinite).sort((a, b) => a - b);
    const gaps = [];
    for (let i = 1; i < ts.length; i++) {
      const g = ts[i] - ts[i - 1];
      if (g >= 0) gaps.push(g);
    }
    if (gaps.length >= 5) {
      const rapid = gaps.filter((g) => g < cfg.rapidGapMs).length / gaps.length;
      const rapidPts = Math.round(cfg.wCadence * 0.6 * Math.min(rapid / cfg.rapidFullRatio, 1));
      add(rapidPts, `rapid_cadence:${Math.round(rapid * 100)}%_gaps_under_${cfg.rapidGapMs}ms`);
      if (gaps.length >= cfg.mechMinGaps) {
        const mean = gaps.reduce((a, b) => a + b, 0) / gaps.length;
        const variance = gaps.reduce((a, b) => a + (b - mean) * (b - mean), 0) / gaps.length;
        const cv = mean > 0 ? Math.sqrt(variance) / mean : 0;
        if (cv <= cfg.mechMaxCV) {
          add(Math.round(cfg.wCadence * 0.4), `mechanical_gaps:cv_${cv.toFixed(3)}_over_${gaps.length}_gaps`);
        }
      }
    }
  }

  // 2. sustained volume near/above the decay threshold (weak by design)
  {
    const v = Number(p.volumePerDay) || 0;
    if (v >= cfg.volumeMinPerDay && cfg.volumeFullPerDay > cfg.volumeMinPerDay) {
      const f = Math.min((v - cfg.volumeMinPerDay) / (cfg.volumeFullPerDay - cfg.volumeMinPerDay), 1);
      add(Math.round(cfg.wVolume * f), `high_solo_volume:${Math.round(v)}/day`);
    }
  }

  // 3. repeated pairing with the same opponent (max over pairs, not summed �?
  // sociable players with many rivals must not accumulate here)
  {
    let best = 0, bestCode = null;
    for (const pair of (Array.isArray(p.pairs) ? p.pairs : [])) {
      const games = Number(pair.games) || 0;
      if (games < cfg.pairMinCount) continue;
      let pts = Math.round(cfg.wPair * 0.6 * Math.min(games / cfg.pairFullCount, 1));
      let code = `repeated_pair:${games}_staked_games`;
      const wins = Number(pair.wins) || 0;
      if (games >= cfg.funnelMinGames && wins / games >= cfg.funnelMinWinRate) {
        pts += Math.round(cfg.wPair * 0.4);
        code += `_funnel_${wins}/${games}_wins`;
      }
      if (pts > best) { best = pts; bestCode = code; }
    }
    if (best > 0 && bestCode) add(Math.min(best, cfg.wPair), bestCode);
  }

  // 4. shared IP �?weak steps: sharing alone proves little (households)
  {
    const shared = Array.isArray(p.sharedWith) ? p.sharedWith : [];
    if (shared.length > 0) {
      let pts = 5;
      let code = `shared_ip:${shared.length}_account(s)`;
      if (shared.some((s) => s && s.stakedAgainst)) {
        pts += 5;
        code += '+staked_together';
      }
      if (shared.length >= 3) {
        pts += 5;
        code += '+multi_account_cluster';
      }
      add(Math.min(pts, cfg.wIp), code);
    }
  }

  // 5. brand-new account already near the cap
  {
    const age = p.accountAgeDays;
    const wp = Number(p.weeklyPoints) || 0;
    if (age != null && Number.isFinite(age)) {
      if (age <= cfg.newbornDays && wp >= cfg.newbornWP) {
        add(cfg.wAge, `new_account:${Math.round(age)}d_with_${wp}_WP`);
      } else if (age <= cfg.youngDays && wp >= cfg.youngWP) {
        add(Math.round(cfg.wAge * 0.67), `young_account:${Math.round(age)}d_with_${wp}_WP`);
      } else if (age <= cfg.toddlerDays && wp >= cfg.toddlerWP) {
        add(Math.round(cfg.wAge * 0.5), `toddler_account:${Math.round(age)}d_with_${wp}_WP`);
      }
    }
  }

  // 6. near-perfect stake record vs mediocre QM baseline (complicit opponent,
  // not skill). Without a QM baseline the award is halved �?a rival-only
  // specialist may simply be good at stakes.
  {
    const sg = Number(p.stakeGames) || 0;
    if (sg >= cfg.stakeMinGames) {
      const r = (Number(p.stakeWins) || 0) / sg;
      const qg = Number(p.qmGames) || 0;
      const qm = qg >= cfg.qmMinGames ? (Number(p.qmWins) || 0) / qg : null;
      const baselineOk = qm == null || qm <= cfg.baselineQmRate;
      const scale = qm == null ? 0.5 : 1;
      if (r >= cfg.stakeHighRate && baselineOk) {
        add(Math.round(cfg.wWinRate * scale),
          `stake_win_anomaly:${Math.round(r * 100)}%_over_${sg}_vs_qm_${qm == null ? 'unknown' : Math.round(qm * 100) + '%'}`);
      } else if (r >= cfg.stakeMidRate && baselineOk) {
        add(Math.round(cfg.wWinRate * 0.6 * scale),
          `stake_win_elevated:${Math.round(r * 100)}%_over_${sg}_vs_qm_${qm == null ? 'unknown' : Math.round(qm * 100) + '%'}`);
      }
    }
  }

  return { score: Math.min(100, Math.round(score)), reasons };
}

function _tsMs(v) {
  if (v == null) return NaN;
  if (typeof v.toDate === 'function') {
    try { return v.toDate().getTime(); } catch (_) { return NaN; }
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : NaN;
}

// Build one account's fraud profile from Firestore (bounded reads).
//
// PERIOD-SCOPING APPROXIMATION (read before "fixing" this): the signal logs
// feeding this profile are intentionally capped rolling buffers, NOT full
// week histories �?quiz_cadence keeps the last 300 submits, challenge
// signals are read newest-first capped at 60+60 events, matches at the last
// 100. In-week filtering uses each event's own timestamp against weekStartMs,
// so a heavy grinder's early-week activity may already have rolled out of the
// buffers by scoring time. Consequences: volumePerDay �?recent daily rate
// (not true weekly average), pair counts are a lower bound, and cadence gaps
// skew toward recent behavior. This is accepted because (a) collusion/farming
// is a sustained behavior �?recent windows still catch it, (b) scores are
// advisory with a human in the loop, and (c) full-history retention would
// multiply Firestore reads/storage for a pre-launch unknown. If post-launch
// data shows scorers missing early-week bursts, raise the caps (hardcoded,
// see catalog above) or persist per-week rollups instead of raising limits
// blindly.
async function _buildFraudProfile(uid, userData, weeklyPoints, weekStartMs) {
  const cadenceRef = db.collection('telemetry').doc('quiz_cadence').collection('users').doc(uid);
  const accountRef = db.collection('telemetry').doc('account_signals').collection('users').doc(uid);
  const sigCol = db.collection('telemetry').doc('challenge_signals').collection('events');
  const [cadSnap, accSnap, asCreator, asJoiner, matchSnap] = await Promise.all([
    cadenceRef.get(),
    accountRef.get(),
    sigCol.where('creatorUid', '==', uid).limit(60).get(),
    sigCol.where('joinerUid', '==', uid).limit(60).get(),
    db.collection('users').doc(uid).collection('matches').orderBy('timestamp', 'desc').limit(100).get(),
  ]);
  const cad = cadSnap.exists ? (cadSnap.data() || {}) : {};
  const acc = accSnap.exists ? (accSnap.data() || {}) : {};

  const submits = (Array.isArray(cad.recentSubmits) ? cad.recentSubmits : [])
    .map(Number).filter(Number.isFinite);
  const days = new Set(submits.map((t) => new Date(t).toISOString().slice(0, 10)));
  const volumePerDay = submits.length === 0 ? 0 : submits.length / Math.max(1, days.size);

  // Pair stats from in-week staked challenge signals.
  const pairMap = {};
  const inWeek = (d) => {
    const t = Math.max(_tsMs(d.resolvedAt), _tsMs(d.joinedAt), _tsMs(d.createdAt));
    return Number.isFinite(t) && t >= weekStartMs;
  };
  const staked = (d) => (Number(d.stakeAmount) || 0) > 0 || (Number(d.wpStake) || 0) > 0;
  for (const s of [...asCreator.docs, ...asJoiner.docs]) {
    const d = s.data() || {};
    if (!inWeek(d) || !staked(d)) continue;
    const opp = d.creatorUid === uid ? d.joinerUid : d.creatorUid;
    if (!opp || opp === uid) continue;
    const entry = pairMap[opp] || (pairMap[opp] = { games: 0, wins: 0 });
    entry.games++;
    const won = (d.outcome === 'creator_wins' && d.creatorUid === uid) ||
                (d.outcome === 'opponent_wins' && d.joinerUid === uid);
    if (won) entry.wins++;
  }

  // Stake vs QM win rates from match history.
  let stakeGames = 0, stakeWins = 0, qmGames = 0, qmWins = 0;
  for (const m of matchSnap.docs) {
    const d = m.data() || {};
    if (d.isQuickMatch === true) {
      qmGames++;
      if (d.outcome === 'win') qmWins++;
    } else if ((Number(d.stakeAmount) || 0) > 0) {
      stakeGames++;
      if (d.outcome === 'win') stakeWins++;
    }
  }

  // IP set for cross-account sharing (raw IPs never leave telemetry; only
  // overlap counts flow into the score/reasons).
  const ipSet = new Set();
  for (const ip of (Array.isArray(cad.ips) ? cad.ips : [])) if (typeof ip === 'string') ipSet.add(ip);
  if (typeof cad.lastIp === 'string') ipSet.add(cad.lastIp);
  if (typeof acc.createdIp === 'string') ipSet.add(acc.createdIp);
  if (typeof acc.lastIp === 'string') ipSet.add(acc.lastIp);
  for (const s of [...asCreator.docs, ...asJoiner.docs]) {
    const d = s.data() || {};
    const own = d.creatorUid === uid ? d.creatorIp : d.joinerIp;
    if (typeof own === 'string') ipSet.add(own);
  }

  let createdMs = _tsMs(userData.createdAt);
  if (!Number.isFinite(createdMs)) createdMs = _tsMs(acc.createdAt);
  const accountAgeDays = Number.isFinite(createdMs)
    ? (Date.now() - createdMs) / (24 * 60 * 60 * 1000)
    : null;

  return {
    submits, volumePerDay,
    pairs: Object.values(pairMap),
    pairOpponentUids: Object.keys(pairMap),
    ipSet, accountAgeDays, weeklyPoints,
    stakeGames, stakeWins, qmGames, qmWins,
  };
}

// ── Phase 3: scoreFraudForWeek (admin on-demand scoring) ───────────────────
// Scores every ranked account in leaderboardCycles/{weekId} and stores
// fraudReviews/{weekId}_{uid} {score, band, reasons, inputs, scoredAt}.
// Advisory output only �?writers never touch payouts, claims, or ledger.
exports.scoreFraudForWeek = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }
    const { weekId } = request.data || {};
    if (typeof weekId !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(weekId)) {
      throw new HttpsError('invalid-argument', 'weekId must be a YYYY-MM-DD string');
    }
    let { maxUsers } = request.data || {};
    maxUsers = Number(maxUsers);
    if (!Number.isInteger(maxUsers) || maxUsers < 1 || maxUsers > 500) maxUsers = 200;

    const cycleSnap = await db.collection('leaderboardCycles').doc(weekId).get();
    if (!cycleSnap.exists) throw new HttpsError('not-found', 'No leaderboard cycle for that week');
    const ranked = (Array.isArray(cycleSnap.data()?.ranked) ? cycleSnap.data().ranked : [])
      .filter((r) => r && r.uid)
      .slice(0, maxUsers);
    const weekStartMs = new Date(`${weekId}T00:00:00Z`).getTime();
    const cfg = await _getFraudConfig();

    // Phase 1: parallel profile reads (bounded per account).
    const profiles = {};
    await Promise.all(ranked.map(async (r) => {
      try {
        const uSnap = await db.collection('users').doc(r.uid).get();
        profiles[r.uid] = await _buildFraudProfile(
          r.uid, uSnap.exists ? (uSnap.data() || {}) : {},
          Number(r.weeklyPoints) || 0, weekStartMs);
      } catch (err) {
        console.warn(`[scoreFraudForWeek] profile read failed for ${r.uid} (scored thin): ${err.message}`);
        profiles[r.uid] = {
          submits: [], volumePerDay: 0, pairs: [], pairOpponentUids: [],
          ipSet: new Set(), accountAgeDays: null, weeklyPoints: Number(r.weeklyPoints) || 0,
          stakeGames: 0, stakeWins: 0, qmGames: 0, qmWins: 0,
        };
      }
    }));

    // Phase 2: cross-account IP overlap (counts only �?raw IPs never stored
    // in review docs).
    const ipOwners = {};
    for (const [uid, p] of Object.entries(profiles)) {
      for (const ip of p.ipSet) {
        (ipOwners[ip] || (ipOwners[ip] = new Set())).add(uid);
      }
    }

    // Phase 3: score + batch-write review docs.
    const scores = [];
    let batch = db.batch();
    let batchN = 0;
    const commits = [];
    const flush = async () => { if (batchN > 0) { commits.push(batch.commit()); batch = db.batch(); batchN = 0; } };
    for (const r of ranked) {
      const p = profiles[r.uid];
      const pairSet = new Set(p.pairOpponentUids);
      const others = new Set();
      for (const ip of p.ipSet) {
        for (const o of (ipOwners[ip] || [])) if (o !== r.uid) others.add(o);
      }
      const { score, reasons } = _scoreFraudProfile({
        submits: p.submits,
        volumePerDay: p.volumePerDay,
        pairs: p.pairs,
        sharedWith: [...others].map((o) => ({ uid: o, stakedAgainst: pairSet.has(o) })),
        accountAgeDays: p.accountAgeDays,
        weeklyPoints: p.weeklyPoints,
        stakeGames: p.stakeGames, stakeWins: p.stakeWins,
        qmGames: p.qmGames, qmWins: p.qmWins,
      }, cfg);
      const band = _fraudBand(score, cfg);
      const ref = db.collection('fraudReviews').doc(`${weekId}_${r.uid}`);
      batch.set(ref, {
        weekId, uid: r.uid,
        score, band, reasons,
        inputs: {
          submitCount: p.submits.length,
          volumePerDay: Math.round(p.volumePerDay * 10) / 10,
          pairCount: p.pairs.length,
          sharedWithCount: others.size,
          accountAgeDays: p.accountAgeDays == null ? null : Math.round(p.accountAgeDays * 10) / 10,
          stakeGames: p.stakeGames, stakeWins: p.stakeWins,
          qmGames: p.qmGames, qmWins: p.qmWins,
        },
        scoredAt: FieldValue.serverTimestamp(),
        scoredBy: request.auth.uid,
      }, { merge: true });
      batchN++;
      if (batchN >= 400) await flush();
      scores.push({ uid: r.uid, score, band });
    }
    await flush();
    await Promise.all(commits);

    console.log(`[scoreFraudForWeek] week=${weekId} scored=${scores.length} by ${request.auth.uid}`);
    return { success: true, weekId, scored: scores.length, scores };
  }
);
// so it does NOT route through the daily soft cap). Tracks granted tiers in
// achievementsGranted map so nothing fires twice.
//
// Returns { acGranted, framesToGrant, newAchievementsGranted } where:
//   acGranted            = total AC to add (0 if no new tier crossed)
//   framesToGrant        = array of cosmetic frame IDs to add to ownedCosmetics
//   newAchievementsGranted = updated achievementsGranted map (merged)
const ACHIEVEMENT_TIERS = {
  gamesPlayed: [
    { threshold: 10,  ac: 20,  frame: null },
    { threshold: 50,  ac: 75,  frame: null },
    { threshold: 100, ac: 150, frame: null },
    { threshold: 500, ac: 500, frame: null },
  ],
  gamesWon: [
    { threshold: 10,  ac: 30,  frame: null },
    { threshold: 50,  ac: 100, frame: null },
    { threshold: 200, ac: 400, frame: 'frame_victory' },
  ],
  perfectQuizzes: [
    { threshold: 5,   ac: 20,  frame: null },
    { threshold: 25,  ac: 80,  frame: null },
    { threshold: 100, ac: 300, frame: null },
  ],
  rivalWins: [
    { threshold: 10, ac: 50,  frame: null },
    { threshold: 50, ac: 250, frame: 'frame_rival_slayer' },
  ],
  careerWpEarned: [
    { threshold: 500,   ac: 30,  frame: null },
    { threshold: 2500,  ac: 150, frame: null },
    { threshold: 10000, ac: 600, frame: null },
  ],
};

function _checkAchievementTiers(userData, statDeltas) {
  const stats = userData.stats || {};
  const granted = { ...(userData.achievementsGranted || {}) };

  let acGranted = 0;
  const framesToGrant = [];

  for (const [statName, tiers] of Object.entries(ACHIEVEMENT_TIERS)) {
    const currentValue = stats[statName] || 0;
    const delta = statDeltas[statName] || 0;
    if (delta <= 0) continue; // Only check stats that incremented this call

    const newValue = currentValue + delta;
    const grantedTiers = granted[statName] || [];

    for (const tier of tiers) {
      // Tier crossed: newValue >= threshold AND oldValue < threshold
      if (newValue >= tier.threshold && currentValue < tier.threshold) {
        if (!grantedTiers.includes(tier.threshold)) {
          acGranted += tier.ac;
          if (tier.frame) framesToGrant.push(tier.frame);
          grantedTiers.push(tier.threshold);
        }
      }
    }

    if (grantedTiers.length > 0) granted[statName] = grantedTiers;
  }

  return { acGranted, framesToGrant, newAchievementsGranted: granted };
}

// ── Helper: _applyDailyWPSoftCap ────────────────────────────────────────────
// Wraps a single WP award through the shared daily soft cap. Below the cap the
// full amount is awarded; at/above the cap only 20% (rounded down, floor 1).
// Returns { award, newEarnedToday } where newEarnedToday is the running total
// for the day after this award.
function _applyDailyWPSoftCap(amount, earnedToday) {
  if (earnedToday < WP_DAILY_SOFT_CAP) {
    return { award: amount, newEarnedToday: earnedToday + amount };
  }
  const capped = Math.floor(amount * 0.2) || 1;
  return { award: capped, newEarnedToday: earnedToday + capped };
}

function getWATDate(now) {
  const wat = new Date(now.getTime() + 60 * 60 * 1000);
  return wat.toISOString().slice(0, 10);
}

// ── Quick Match 24/7 daily tokens ─────────────────────────────────────────
// QM is ghost-only (no live opponents to concentrate into time slots), so
// the WAT time windows are gone: QM is open around the clock and volume is
// throttled by DAILY tokens instead of per-window tokens. The stored
// `qmWindowId` field keeps its name (no migration) but now carries a WAT-day
// id (`qm_YYYY-MM-DD`), so every existing reset-on-change comparison keeps
// working with day granularity.
//
// Daily budget: free 5/day, premium 8/day, +1 bonus via rewarded ad (up to
// 6 / 9). At 35 AC per win this caps free QM farming well below ad income
// while letting engaged players play every day.
const QM_DAILY_TOKENS_FREE = 5;
const QM_DAILY_TOKENS_PREMIUM = 8;

/// WAT-day token bucket id for Quick Match. Replaces the old per-window ids
/// (morning_/afternoon_/night_) �?any change in this id means "new day,
/// reset tokens", exactly like the old window rollover did.
function getQMDayId(now = new Date()) {
  return `qm_${_watDateString(now)}`;
}

function _qmDailyTokens(isPremium) {
  return isPremium ? QM_DAILY_TOKENS_PREMIUM : QM_DAILY_TOKENS_FREE;
}

// ── Helper: currentWeekId ────────────────────────────────────────────────────
function currentWeekId() {
  const now    = new Date();
  const utcNow = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()
  ));
  const day    = utcNow.getUTCDay();
  const diff   = day === 0 ? -6 : 1 - day;
  const monday = new Date(utcNow);
  monday.setUTCDate(utcNow.getUTCDate() + diff);
  return monday.toISOString().slice(0, 10);
}

function nextWeekId() {
  const now    = new Date();
  const utcNow = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()
  ));
  const day    = utcNow.getUTCDay();
  const diff   = day === 0 ? -6 : 1 - day;
  const monday = new Date(utcNow);
  monday.setUTCDate(utcNow.getUTCDate() + diff + 7);
  return monday.toISOString().slice(0, 10);
}

// Top THREE paid entrants split the whole pool: 50 / 30 / 20. Must stay in
// lockstep with PrizePoolService.prizePercentages in the Flutter client, and
// must always sum to 1.0 �?rank 4+ gets a 0 share and cannot claim a payout.
function prizePct(rank) {
  const pcts = { 1: 0.50, 2: 0.30, 3: 0.20 };
  return pcts[rank] || 0;
}

// ── Helper: consume QM token in tx ──────────────────────────────────────────
async function _consumeQMTokenInTx(tx, userRef, currentWindowId) {
  const uSnap = await tx.get(userRef);
  const uData = uSnap.data() || {};
  let qmWindowId    = uData.qmWindowId   ?? null;
  let qmTokens      = uData.qmTokens     ?? 0;
  let qmAdTokenUsed = uData.qmAdTokenUsed ?? false;
  if (qmWindowId !== currentWindowId) {
    // Daily reset: a new WAT day id means a fresh daily token budget.
    qmTokens      = _qmDailyTokens(uData.premiumActive === true);
    qmAdTokenUsed = false;
    qmWindowId    = currentWindowId;
  }
  if (qmTokens <= 0) {
    const err = new Error('no_qm_tokens');
    err.isTokenError = true;
    throw err;
  }
  qmTokens -= 1;
  tx.update(userRef, { qmWindowId, qmTokens, qmAdTokenUsed });
  return qmTokens;
}

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 1: WEEKLY RESET & PRIZE POOL LOGIC ────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

async function runWeeklyReset() {
  const weekId    = currentWeekId();
  const newWeekId = nextWeekId();

  console.log(`[weeklyReset] Starting. weekId=${weekId} �?newWeekId=${newWeekId}`);

  const poolRef  = db.collection('prize_pool').doc(weekId);
  const poolSnap = await poolRef.get();
  const poolData = poolSnap.data() || {};

  if (poolData.status && poolData.status !== 'active') {
    console.log(`[weeklyReset] Skipping �?pool status is already '${poolData.status}'. Not re-running.`);
    return { skipped: true, reason: `status was ${poolData.status}` };
  }

  const total = poolData.totalNaira || 0;

  const newPoolRef  = db.collection('prize_pool').doc(newWeekId);
  const newPoolSnap = await newPoolRef.get();
  if (!newPoolSnap.exists) {
    await newPoolRef.set({
      weekId:      newWeekId,
      totalNaira:  0,
      adViewCount: 0,
      status:      'active',
      createdAt:   FieldValue.serverTimestamp(),
    });
    console.log(`[weeklyReset] New week doc created: ${newWeekId}`);
  } else {
    console.log(`[weeklyReset] New week doc already existed: ${newWeekId}`);
  }

  // ── Ghost sweep: admin accounts hold no player economy ──────────────────
  // Admin accounts must never be ranked, counted or paid. A redeemed weekly
  // entry code is the one thing that used to drag the admin into the prize
  // split, so clear the entry fields every reset (the state can never carry
  // into a week) and zero the points (a stale score can never leak into any
  // board or COUNT). The cycle/winner queries below exclude admins anyway �?  // this is the belt to that suspenders, and it self-heals a legacy admin doc
  // that still carries an old entry week.
  for (const adminUid of ADMIN_UIDS) {
    const adminRef  = db.collection('users').doc(adminUid);
    const adminSnap = await adminRef.get();
    if (!adminSnap.exists) continue;
    const a     = adminSnap.data() || {};
    const patch = {};
    if (a.leaderboardEntryWeekId !== undefined) {
      patch.leaderboardEntryWeekId = FieldValue.delete();
    }
    if (a.leaderboardEntryEmail !== undefined) {
      patch.leaderboardEntryEmail = FieldValue.delete();
    }
    if (a.weeklyPoints) patch.weeklyPoints = 0;
    if (Object.keys(patch).length > 0) {
      await adminRef.update(patch);
      console.log(`[weeklyReset] Ghost sweep: cleared admin ${adminUid} from the player economy.`);
    }
  }

  const BATCH_SIZE  = 200;
  const MAX_BATCHES = 500;

  if (WP_CAP_ACTIVE) {
    let capLastDoc  = null;
    let capBatchNum = 0;
    let capCount    = 0;

    console.log(`[weeklyReset] WP cap pass starting (cap=${WP_WEEKLY_CAP})`);

    do {
      if (capBatchNum >= MAX_BATCHES) {
        console.warn(`[weeklyReset] WP cap pass hit MAX_BATCHES (${MAX_BATCHES}). Stopping. ${capCount} users clamped so far.`);
        break;
      }

      let capQuery = db.collection('users')
        .where('weeklyPoints', '>', WP_WEEKLY_CAP)
        .orderBy('weeklyPoints', 'desc')
        .limit(BATCH_SIZE);

      if (capLastDoc) capQuery = capQuery.startAfter(capLastDoc);

      const capSnap = await capQuery.get();
      if (capSnap.empty) break;

      const capBatch = db.batch();
      capSnap.docs.forEach(doc => {
        // Ghost admin accounts are not part of the player economy.
        if (isAdminAccountUid(doc.id)) return;
        capBatch.update(doc.ref, { weeklyPoints: WP_WEEKLY_CAP });
      });

      await capBatch.commit();
      capCount    += capSnap.size;
      capLastDoc   = capSnap.docs[capSnap.docs.length - 1];
      capBatchNum++;

      console.log(`[weeklyReset] Cap batch ${capBatchNum}: clamped ${capSnap.size} users (total so far: ${capCount})`);


    } while (true);

    console.log(`[weeklyReset] WP cap pass complete. ${capCount} users clamped to ${WP_WEEKLY_CAP}.`);
  }

  // ── Paid leaderboard cycle snapshot (leaderboard_entry) ───────────────────
  // Runs AFTER the WP cap (final scores are locked) and BEFORE both the top-3
  // snapshot and the user reset, so it reads the FINAL eligible rankings before
  // any reset logic clears them. Records each week's pool split (70/30) and the
  // ranked eligible users with payout info for manual processing.
  //
  // `winners` is declared out here but filled INSIDE the block, because the
  // winners are now derived from `ranked`/`prizePool`, which only exist in the
  // block scope below.
  let winners = [];
  {
    const eligible = [];
    let lbLastDoc  = null;
    let lbBatchNum = 0;

    do {
      if (lbBatchNum >= MAX_BATCHES) {
        console.warn(`[weeklyReset] Eligible query hit MAX_BATCHES (${MAX_BATCHES}). Stopping. ${eligible.length} eligible users snapshotted so far.`);
        break;
      }

      let lbQuery = db.collection('users')
        .where('leaderboardEntryWeekId', '==', weekId)
        .orderBy('weeklyPoints', 'desc')
        .limit(BATCH_SIZE);

      if (lbLastDoc) lbQuery = lbQuery.startAfter(lbLastDoc);

      const lbSnap = await lbQuery.get();
      if (lbSnap.empty) break;

      lbSnap.docs.forEach(doc => {
        // Ghost admin accounts are never ranked and never share the pool.
        if (isAdminAccountUid(doc.id)) return;
        const d = doc.data();
        // Silent enforcement ladder: restricted+ accounts are excluded from
        // the paid board. They can still play; their WP does not win prizes.
        if (d.lbEligible === false) return;
        eligible.push({
          uid:          doc.id,
          username:     d.username            || 'Anonymous',
          university:   d.university          || null,
          weeklyPoints: d.weeklyPoints        || 0,
          buyerEmail:   d.leaderboardEntryEmail || null,
        });
      });

      lbLastDoc  = lbSnap.docs[lbSnap.docs.length - 1];
      lbBatchNum++;
    } while (true);

    // Total this week's leaderboard-entry code revenue (accrued by redeemCode).
    // Tracked for accounting only — it never sizes the pool.
    const entryRevenue = poolData.entryCodeRevenue || 0;

    // Pool sizing: admin-set only. The pool is the FIXED amount set for this
    // week via setPrizePool, or 0 (unset) when nothing was set. There is no
    // revenue share, no floor, and no rollover. Expired claims are forfeited,
    // not carried into a later week — see checkPendingClaim, which records
    // forfeited shares on the cycle as forfeitedNaira for accounting.
    const adminPool   = Number(poolData.adminPoolNaira);
    const isFixedPool = Number.isFinite(adminPool) && adminPool > 0;
    const prizePool   = isFixedPool ? adminPool : 0;

    const ranked = eligible.map((u, i) => ({
      rank:            i + 1,
      uid:             u.uid,
      username:        u.username,
      university:      u.university,
      weeklyPoints:    u.weeklyPoints,
      share:           parseFloat((prizePool * prizePct(i + 1)).toFixed(2)),
      buyerEmail:      u.buyerEmail,
      paid:            false,
      payoutMethod:    null,
      payoutReference: null,
    }));

    await db.collection('leaderboardCycles').doc(weekId).set({
      weekId,
      totalCodeRevenue: entryRevenue,
      prizePool:        parseFloat(prizePool.toFixed(2)),
      houseCut:         0,
      guaranteedFloor:  0,
      poolSource:      isFixedPool ? 'admin_fixed' : 'unset',
      adminPoolNaira:  isFixedPool ? prizePool : null,
      eligibleCount:    ranked.length,
      ranked,
      status:           'calculated',
      calculatedAt:     FieldValue.serverTimestamp(),
      paidAt:           null,
      notes:            isFixedPool
        ? `Pool fixed by admin at ${prizePool} naira (entry revenue ${entryRevenue}).`
        : 'No pool was set for this week — pool recorded as unset (₦0).',
    });

    if (ranked.length > 0) {
      console.log(`[weeklyReset] Leaderboard cycle snapshotted for ${weekId}: ${ranked.length} eligible, revenue=�?{entryRevenue}, pool=�?{prizePool}`);
    } else {
      console.log(`[weeklyReset] Leaderboard cycle snapshotted for ${weekId}: 0 eligible, no pool split.`);
    }

    // Winners are the PAID entrants from this cycle's `ranked` snapshot �?the
    // same list the payout system reads �?not the top-3 by raw points over every
    // user. The previous version announced non-entrants as winners and priced
    // the prize from the legacy `totalNaira` field (always 0), so the Monday
    // announcement showed a �? prize for a week that actually paid out.
    //
    // NOTE: this construction was MOVED inside this block (it used to run after
    // it) because `ranked` and `prizePool` are only in scope here. `winners` is
    // declared in the enclosing scope so the pool write below still works.
    winners = ranked.slice(0, 3).map((r) => ({
      rank:         r.rank,
      uid:          r.uid,
      username:     r.username,
      university:   r.university,
      weeklyPoints: r.weeklyPoints,
      prize:        r.share,
      pct:          r.rank <= 3 ? prizePct(r.rank) * 100 : 0,
      paid:         false,
    }));

    console.log(`[weeklyReset] ${winners.length} winners snapshotted from ${ranked.length} paid entrants. Pool: ${prizePool}`);
  }

  await poolRef.set({
    ...poolData,
    status:     'calculating',
    winners,
    snapshotAt: FieldValue.serverTimestamp(),
    totalNaira: total,
  }, { merge: true });

  try {
    await notifyWeeklyWinners(winners, weekId);
  } catch (err) {
    console.error('[weeklyReset] notifyWeeklyWinners failed (ignored):', err);
  }

  let lastDoc    = null;
  let resetCount = 0;
  let batchNum   = 0;

  do {
    if (batchNum >= MAX_BATCHES) {
      console.warn(`[weeklyReset] Hit MAX_BATCHES (${MAX_BATCHES}). Stopping pagination. ${resetCount} users reset so far.`);
      break;
    }

    let query = db.collection('users')
      .orderBy('__name__')
      .limit(BATCH_SIZE);

    if (lastDoc) query = query.startAfter(lastDoc);

    const userSnap = await query.get();
    if (userSnap.empty) break;

    const batch = db.batch();
    userSnap.docs.forEach(doc => {
      batch.update(doc.ref, {
        weeklyPoints:                  0,
        weeklyReset:                   FieldValue.serverTimestamp(),
        lastStreakWPMilestoneAwarded:   0,
      });
    });

    await batch.commit();
    resetCount += userSnap.size;
    lastDoc     = userSnap.docs[userSnap.docs.length - 1];
    batchNum++;

    console.log(`[weeklyReset] Batch ${batchNum}: reset ${userSnap.size} users (total so far: ${resetCount})`);

  } while (true);

  console.log(`[weeklyReset] All users reset. Total: ${resetCount}`);

  await poolRef.update({ status: 'pending_payment' });

  console.log(`[weeklyReset] Complete. ${weekId} �?pending_payment. ${newWeekId} �?active.`);

  return {
    weekId,
    newWeekId,
    total,
    resetCount,
    winnersCount: winners.length,
  };
}

exports.weeklyReset = onSchedule(
  {
    schedule:       '0 23 * * 0',
    timeZone:       'UTC',
    region:         'us-central1',
    timeoutSeconds: 540,
    memory:         '512MiB',
  },
  async () => {
    try {
      const result = await runWeeklyReset();
      console.log('[weeklyReset] Scheduled run finished:', JSON.stringify(result));
    } catch (err) {
      console.error('[weeklyReset] FATAL ERROR:', err);
      throw err;
    }
  }
);

exports.triggerWeeklyReset = onRequest(
  {
    region:         'us-central1',
    timeoutSeconds: 540,
    memory:         '512MiB',
    secrets:        [RESET_SECRET],
  },
  async (req, res) => {
    const secret = req.headers['x-reset-secret'];
    if (secret !== RESET_SECRET.value()) {
      console.warn('[triggerWeeklyReset] Unauthorized attempt');
      return res.status(401).json({ error: 'Unauthorized' });
    }

    console.log('[triggerWeeklyReset] Manually triggered');

    try {
      const result = await runWeeklyReset();
      return res.json({ success: true, ...result });
    } catch (err) {
      console.error('[triggerWeeklyReset] ERROR:', err);
      return res.status(500).json({ error: err.message });
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── setPrizePool �?admin sets the FIXED prize pool for the current week ───
// ─────────────────────────────────────────────────────────────────────────────
// REPLACES the old incrementPrizePool, which was broken: it accumulated ad
// revenue into prize_pool/{weekId}.totalNaira while runWeeklyReset computes the
// pool from entryCodeRevenue and never read totalNaira. Every naira it added
// since launch was silently discarded. It was also callable by any
// authenticated player with no admin gate. Both problems are gone.
//
// WHAT THIS DOES: the admin picks ONE number for the current week and that
// becomes the prize pool outright. Until this is set, the week's pool is
// unset. One source of truth, and you always know exactly what
// is at stake before the week closes.
//
// WRITE SCOPE: current week only. A closed cycle has already had shares
// assigned and possibly paid, so rewriting it retroactively would silently
// change what a winner was promised. That is refused rather than papered over.
//
// FIELDS WRITTEN:
//   adminPoolNaira : the fixed pool (integer NGN). This is what weeklyReset reads.
//   poolSetBy / poolSetAt : who set it and when, for the audit trail.
//
// CAVEAT: the pool is snapshotted into leaderboardCycles/{weekId} by
// runWeeklyReset when the week closes. Changing this value AFTER that point has
// no effect on the already-calculated cycle �?the amount above is what the
// winners' shares were based on.
// ─────────────────────────────────────────────────────────────────────────────

// Sanity ceiling. A typo should not create a nine-figure payout obligation.
const MAX_POOL_NAIRA = 50_000_000; // �?0,000,000

exports.setPrizePool = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const { amount } = request.data || {};

    if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0) {
      throw new HttpsError('invalid-argument', 'amount must be a positive number');
    }
    if (!Number.isInteger(amount)) {
      throw new HttpsError('invalid-argument', 'amount must be a whole naira amount');
    }
    if (amount > MAX_POOL_NAIRA) {
      throw new HttpsError('invalid-argument',
        `amount must not exceed �?{MAX_POOL_NAIRA.toLocaleString()}`);
    }

    const weekId = currentWeekId();

    // Refuse if this week has already been snapshotted by weeklyReset �?the
    // cycle doc is immutable once calculated.
    const cycleSnap = await db.collection('leaderboardCycles').doc(weekId).get();
    if (cycleSnap.exists) {
      throw new HttpsError('failed-precondition',
        'This week has already closed and its prize pool is fixed. ' +
        'It can no longer be changed.');
    }

    await db.collection('prize_pool').doc(weekId).set({
      weekId,
      adminPoolNaira: amount,
      poolSetBy:      request.auth.uid,
      poolSetAt:      FieldValue.serverTimestamp(),
      status:         'active',
    }, { merge: true });

    console.log(`[setPrizePool] week=${weekId} pool=�?{amount} by ${request.auth.uid}`);
    return {
      success: true,
      weekId,
      amount,
      message: `Prize pool for week ${weekId} set to �?{amount.toLocaleString()}.`,
    };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── clearPrizePool — admin unsets the prize pool for the current week ───
// ─────────────────────────────────────────────────────────────────────────────
// Removes the fixed amount, leaving the pool unset until a new amount is set.
// Same current-week-only restriction as setPrizePool.
exports.clearPrizePool = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const weekId = currentWeekId();

    const cycleSnap = await db.collection('leaderboardCycles').doc(weekId).get();
    if (cycleSnap.exists) {
      throw new HttpsError('failed-precondition',
        'This week has already closed. It can no longer be changed.');
    }

    await db.collection('prize_pool').doc(weekId).set({
      adminPoolNaira: FieldValue.delete(),
      poolSetBy:      FieldValue.delete(),
      poolSetAt:      FieldValue.delete(),
    }, { merge: true });

    console.log(`[clearPrizePool] week=${weekId} pool unset by ${request.auth.uid}`);
    return {
      success: true,
      weekId,
      message: 'Reverted. No pool is set for this week.',
    };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── getPrizePoolStatus �?live pool state for the admin UI ─────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Read-only. Returns the live figures for the CURRENT week: the fixed pool
// when one is set, otherwise unset (₦0). Nothing funds the pool
// automatically, so there is no projection to show.
exports.getPrizePoolStatus = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const weekId = currentWeekId();
    const [poolSnap, cycleSnap] = await Promise.all([
      db.collection('prize_pool').doc(weekId).get(),
      db.collection('leaderboardCycles').doc(weekId).get(),
    ]);

    const pool = poolSnap.exists ? (poolSnap.data() || {}) : {};
    const entryRevenue = Number(pool.entryCodeRevenue) || 0;
    const rawFixed = Number(pool.adminPoolNaira);
    const fixedAmount = Number.isFinite(rawFixed) && rawFixed > 0
      ? rawFixed
      : null;

    return {
      success:    true,
      weekId,
      // Entry sales — accounting only, never sizes the pool.
      entryCodeRevenue: entryRevenue,
      houseCutPotential: 0,
      // Retired fields, kept at 0 so older clients keep parsing.
      revenueBasedPool: 0,
      guaranteedFloor:  0,
      // What it WILL be: the fixed amount if set, otherwise unset (₦0).
      effectivePool:    fixedAmount != null ? fixedAmount : 0,
      isFixed:          fixedAmount != null,
      adminPoolNaira:   fixedAmount,
      poolSetBy:        pool.poolSetBy || null,
      poolSetAt:        pool.poolSetAt?.toDate?.().toISOString?.() || null,
      // Whether this week is still editable.
      weekClosed:      cycleSnap.exists,
      editableWeekId:  weekId,
      maxPoolNaira:    MAX_POOL_NAIRA,
    };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 2: STAKE CHALLENGE ECONOMY ────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// ─── createChallenge ─────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.createChallenge = onSecureCall(
  {
    region: 'us-central1',
  },
  async (request) => {
    try {
      const uid = request.auth?.uid;

      if (!uid) {
        throw new HttpsError(
          'unauthenticated',
          'Unauthenticated'
        );
      }

      await _assertClientBuildAllowed(request, 'createChallenge', { requireStamp: true });
    const creatorDeviceHash = await _touchDevice(uid, request.data?.deviceId);

      // ── Extract request data safely ────────────────────────────────────────
      const {
        animeTitle,
        stakeAmount,
        opponentUid = null,
        opponentUsername = null,
        wpStake = 0,
        challengeType = null,
      } = request.data || {};

      const cleanOpponentUid =
        typeof opponentUid === 'string'
          ? opponentUid.trim()
          : '';

      const cleanOpponentUsername =
        typeof opponentUsername === 'string'
          ? opponentUsername.trim()
          : '';

      const isRivalChallenge =
        cleanOpponentUid.length > 0;

      // Sparring: frictionless unranked duel vs a named rival. Zero stakes,
      // zero WP at risk �?so it bypasses the WP-staked cap and the
      // same-rival cooldown (there is nothing to farm). Spars have their
      // own daily budget and capped WP rewards (see SPAR_* constants).
      const isSparChallenge =
        typeof challengeType === 'string' &&
        challengeType.trim().toLowerCase() === 'spar' &&
        isRivalChallenge;

      console.log('[createChallenge] Incoming request:', {
        uid,
        animeTitle,
        stakeAmount,
        opponentUid: cleanOpponentUid || null,
        opponentUsername: cleanOpponentUsername || null,
        wpStake,
        isRivalChallenge,
        isSparChallenge,
      });

      // ── Basic validation ───────────────────────────────────────────────────

      if (
        typeof animeTitle !== 'string' ||
        animeTitle.trim().length === 0
      ) {
        throw new HttpsError(
          'invalid-argument',
          'invalid_anime_title'
        );
      }

      if (
        typeof stakeAmount !== 'number' ||
        !Number.isInteger(stakeAmount)
      ) {
        throw new HttpsError(
          'invalid-argument',
          'invalid_stake_amount'
        );
      }

      // Staked duels only: spars carry zero stakes and skip these checks
      // (their zero-stake shape is validated in the spar block below).
      if (!isSparChallenge) {
        if (stakeAmount < AC_MIN_STAKE) {
          throw new HttpsError(
            'invalid-argument',
            'stake_below_minimum'
          );
        }

        if (stakeAmount % AC_STAKE_STEP !== 0) {
          throw new HttpsError(
            'invalid-argument',
            'stake_invalid_step'
          );
        }
      }

      // ── Spar validation ──────────────────────────────────────────────────
      // Spars must carry zero stakes both ways; anything else is a staked
      // duel and goes through the normal (rival/code) validation below.
      if (isSparChallenge) {
        if (stakeAmount !== 0 || wpStake !== 0) {
          throw new HttpsError(
            'invalid-argument',
            'spar_must_be_unstaked'
          );
        }
      }

      // ── Rival validation ───────────────────────────────────────────────────

      if (isRivalChallenge) {
        if (cleanOpponentUid === uid) {
          throw new HttpsError(
            'invalid-argument',
            'cannot_challenge_yourself'
          );
        }

        if (cleanOpponentUsername.length === 0) {
          throw new HttpsError(
            'invalid-argument',
            'invalid_opponent'
          );
        }

        // Spars skip stake validation (zero-stake shape already enforced).
        if (!isSparChallenge) {
          if (
            typeof wpStake !== 'number' ||
            !Number.isInteger(wpStake)
          ) {
            throw new HttpsError(
              'invalid-argument',
              'invalid_wp_stake'
            );
          }

          if (wpStake < WP_MIN_STAKE) {
            throw new HttpsError(
              'invalid-argument',
              'wp_stake_below_minimum'
            );
          }

          if (wpStake % WP_STEP !== 0) {
            throw new HttpsError(
              'invalid-argument',
              'wp_stake_invalid_step'
            );
          }
        }
      } else if (wpStake > 0) {
        throw new HttpsError(
          'invalid-argument',
          'wp_stake_requires_opponent'
        );
      }

      // ── Active challenge cap ───────────────────────────────────────────────
      // Moved INSIDE the transaction below: a query run out here only reflects
      // state at read time, so two concurrent create/join calls could both
      // pass it and push a user past the cap. The in-tx read is serialized
      // against the other transaction's committed write.
      // ── Generate challenge ID ──────────────────────────────────────────────

      const now = new Date();
      const todayWAT = _watDateString();

      // Invites start with the SHORTER invite deadline (12h): a rival who
      // never answers should not squat on the creator's active-challenge
      // cap all day. joinChallenge extends this back to the full 24h once
      // the opponent accepts, so in-play matches keep the full window.
      const expiresAt = Timestamp.fromDate(
        new Date(
          now.getTime() + INVITE_EXPIRY_HOURS * 60 * 60 * 1000
        )
      );

      let shareCode;
      let codeSnap;

      do {
        shareCode = _generateCode();

        codeSnap = await db
          .collection('challenges')
          .doc(shareCode)
          .get();
      } while (codeSnap.exists);

      const challengeRef = db
        .collection('challenges')
        .doc(shareCode);

      const userRef = db
        .collection('users')
        .doc(uid);

      // ── Get questions (difficulty-tiered 3E/4M/3H, legacy-aware) ──────────
      //
      // Mix is fixed: 3 Easy + 4 Medium + 3 Hard for the 10-question session.
      // Picks carry {doc, slot} pairs (mirroring the client's _SlottedDoc in
      // lib/core/services/firestore_service.dart) so backfills can be
      // re-seated into deal order. The same questionIds are stored on the
      // challenge doc, so both players share the exact same set. Shortfalls
      // backfill from legacy untagged docs first (treated as medium), then
      // from tagged surpluses of any tier. Error codes are unchanged �?
      // clients already handle them.
      //
      // NOTE: per-tier pools are fetched whole (no limit) so the shuffle is
      // fair. At ~1k docs/tier this is ~3k small reads per challenge
      // creation �?acceptable for a stake-gated, user-initiated action, but
      // revisit with random-offset sampling if creation volume ever spikes.

      const CHALLENGE_MIX = [
        ['easy', 3],
        ['medium', 4],
        ['hard', 3],
      ];
      const CHALLENGE_COUNT = 10;
      const cleanTitle = animeTitle.trim().toLowerCase();

      const shuffleDocs = (docs) => [...docs].sort(() => Math.random() - 0.5);

      const taggedPools = {};
      for (const [tier] of CHALLENGE_MIX) {
        const tierSnap = await db
          .collection('questions')
          .where('animeTitle', '==', cleanTitle)
          .where('difficulty', '==', tier)
          .get();
        taggedPools[tier] = shuffleDocs(tierSnap.docs);
      }

      // Deal order: E,E,E,M,M,M,M,H,H,H.
      const slotOrder = CHALLENGE_MIX.flatMap(
        ([tier, n]) => Array(n).fill(tier)
      );

      const picked = [];
      const unfilledSlots = [];
      for (const slot of slotOrder) {
        if (taggedPools[slot].length > 0) {
          picked.push({ doc: taggedPools[slot].pop(), slot });
        } else {
          unfilledSlots.push(slot);
        }
      }

      let legacyPoolSize = 0;
      if (unfilledSlots.length > 0) {
        // Legacy fallback: pre-Step-1 docs with no difficulty field.
        const legSnap = await db
          .collection('questions')
          .where('animeTitle', '==', cleanTitle)
          .get();
        const legacyPool = shuffleDocs(
          legSnap.docs.filter((d) => {
            const data = d.data() || {};
            return !('difficulty' in data) || data.difficulty == null;
          })
        );
        legacyPoolSize = legacyPool.length;
        for (const slot of unfilledSlots) {
          if (legacyPool.length > 0) {
            picked.push({ doc: legacyPool.pop(), slot });
            continue;
          }
          const surplusTier = ['easy', 'medium', 'hard'].find(
            (t) => taggedPools[t].length > 0
          );
          if (surplusTier) {
            picked.push({ doc: taggedPools[surplusTier].pop(), slot });
          }
          // Else: seat dropped �?whole pool (tagged + legacy) exhausted.
        }

        // Re-seat backfills into deal order: bucket picks by slot, then walk
        // slotOrder dealing one pick per seat (mirrors _dealSlots client-side).
        const buckets = { easy: [], medium: [], hard: [] };
        for (const p of picked) buckets[p.slot].push(p);
        const cursors = { easy: 0, medium: 0, hard: 0 };
        const reseated = [];
        for (const slot of slotOrder) {
          const i = cursors[slot];
          if (i < buckets[slot].length) {
            reseated.push(buckets[slot][i]);
            cursors[slot] = i + 1;
          }
        }
        picked.length = 0;
        picked.push(...reseated);
      }

      const taggedTotal = Object.values(taggedPools)
        .reduce((n, p) => n + p.length, 0);
      if (picked.length === 0 && taggedTotal === 0 && legacyPoolSize === 0) {
        throw new HttpsError(
          'failed-precondition',
          'no_questions_for_anime'
        );
      }

      if (picked.length < CHALLENGE_COUNT) {
        throw new HttpsError(
          'failed-precondition',
          'not_enough_questions_for_anime'
        );
      }

      const questionIds =
        picked.slice(0, CHALLENGE_COUNT).map((p) => p.doc.id);

      // ── Transaction ────────────────────────────────────────────────────────

      await db.runTransaction(async (tx) => {
        const snap = await tx.get(userRef);

        if (!snap.exists) {
          throw new HttpsError(
            'not-found',
            'user_not_found'
          );
        }

        const data = snap.data() || {};

        const isPremium =
          data.premiumActive === true;

        // ── Active challenge cap (in-tx: race-safe) ───────────────────────────
        // The query runs inside the transaction so a concurrent create/join
        // cannot slip past a stale pre-read. Firestore serializes the reads,
        // so the second transaction observes the first's committed challenge.
        const capMaxActive = isPremium
          ? ACTIVE_CHALLENGES_PREMIUM
          : ACTIVE_CHALLENGES_FREE;
        const [capAsCreator, capAsOpponent] = await Promise.all([
          tx.get(db.collection('challenges')
            .where('creatorUid', '==', uid)
            .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)),
          tx.get(db.collection('challenges')
            .where('opponentUid', '==', uid)
            .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)),
        ]);
        if (capAsCreator.size + capAsOpponent.size >= capMaxActive) {
          throw new HttpsError('resource-exhausted', 'too_many_active_challenges');
        }

        // ── Validate AC ──────────────────────────────────────────────────────

        const animeCoins =
          Number(data.animeCoins || 0);

        const maxACStake =
          isPremium
            ? AC_MAX_STAKE_PREMIUM
            : AC_MAX_STAKE_FREE;

        if (stakeAmount > maxACStake) {
          throw new HttpsError(
            'invalid-argument',
            'stake_exceeds_limit'
          );
        }

        if (animeCoins < stakeAmount) {
          throw new HttpsError(
            'resource-exhausted',
            'insufficient_coins'
          );
        }

        // ── Daily challenge creation limit ───────────────────────────────────
        // Spars run on their own budget (never consume the staked budget).

        const createdDate =
          data.challengesCreatedDate || '';

        const createdToday =
          createdDate === todayWAT
              ? Number(data.challengesCreatedToday || 0)
              : 0;

        if (!isSparChallenge && createdToday >= (isPremium ? DAILY_CHALLENGE_CREATE_PREMIUM : DAILY_CHALLENGE_CREATE_FREE)) {
          throw new HttpsError(
            'resource-exhausted',
            'daily_challenge_limit_reached'
          );
        }

        let sparsCreatedToday = 0;
        // Friends-only spars: verified here so the same check also drives
        // the cooldown skip below (friends skip cooldown for spars only;
        // staked duels are unchanged). Blocked pairs have status 'blocked',
        // never 'active', so they are rejected with the same code.
        let sparFriendsSkip = false;
        if (isSparChallenge) {
          sparsCreatedToday =
            data.sparsCreatedDate === todayWAT
                ? Number(data.sparsCreatedToday || 0)
                : 0;
          const sparBudget =
            isPremium ? SPAR_DAILY_PREMIUM : SPAR_DAILY_FREE;
          if (sparsCreatedToday >= sparBudget) {
            throw new HttpsError(
              'resource-exhausted',
              'daily_spar_limit_reached'
            );
          }
          const pair = [uid, cleanOpponentUid].sort();
          const fSnap = await tx.get(
            db.collection('friendships').doc(`${pair[0]}_${pair[1]}`)
          );
          const f = fSnap.exists ? (fSnap.data() || {}) : {};
          if (f.status !== 'active') {
            throw new HttpsError('failed-precondition', 'not_friends');
          }
          sparFriendsSkip = true;
        } else if (cleanOpponentUid && cleanOpponentUid !== 'ghost') {
          // Staked duels don't need friendship, but a block stops them both ways.
          const pair = [uid, cleanOpponentUid].sort();
          const bSnap = await tx.get(
            db.collection('friendships').doc(`${pair[0]}_${pair[1]}`)
          );
          if ((bSnap.data() || {}).status === 'blocked') {
            throw new HttpsError('failed-precondition', 'blocked');
          }
        }

        // ── Validate WP inside transaction ───────────────────────────────────

        let currentWP =
          Number(data.weeklyPoints || 0);

        let wpStakedToday = 0;

        if (data.wpStakedDate === todayWAT) {
          wpStakedToday =
            Number(data.wpStakedToday || 0);
        }

        if (isRivalChallenge) {
          const maxWPStake = isPremium ? WP_MAX_STAKE_PREMIUM : WP_MAX_STAKE_FREE;

          const dailyWPCap =
            isPremium
                ? WP_DAILY_CAP_PREMIUM
                : WP_DAILY_CAP_FREE;

          if (wpStake > maxWPStake) {
            throw new HttpsError(
              'invalid-argument',
              'wp_stake_exceeds_limit'
            );
          }

          if (currentWP < wpStake) {
            throw new HttpsError(
              'resource-exhausted',
              'insufficient_wp'
            );
          }

          if (
            wpStakedToday + wpStake >
            dailyWPCap
          ) {
            throw new HttpsError(
              'resource-exhausted',
              'wp_daily_cap_exceeded'
            );
          }

          // ── WP Cooldown Check for creator ────────────────────────────
          // Rolling record of the last few rivals (rivalCooldowns map), not
          // just the single most recent one: the old lastRivalUid check let
          // an A→B→C→B rotation farm stakes without ever tripping the
          // cooldown. Legacy single-field state is migrated in by
          // _getRivalCooldownMap so existing cooldowns keep enforcing.
          // The client disables the "challenge rival" button via
          // canChallengeRival, but that's client-side only �?a crafted or
          // stale request could otherwise bypass it and re-challenge the
          // same rival before the cooldown elapses, letting the two accounts
          // farm WP stakes freely. Enforce it here server-side for parity.
          const rivalCooldownMap = _getRivalCooldownMap(data);
          {
            // Series-aware: no cooldown INSIDE an active series (winsA+winsB>0).
            // A fresh series after decided/expired respects the normal cooldown.
            // Friends skip: spars between active friends bypass the cooldown
            // entirely (sparFriendsSkip, verified above); staked duels never do.
            // Read inside this transaction so the decision is consistent.
            let inActiveSeries = false;
            try {
              const pair = [uid, cleanOpponentUid].sort();
              const rSnap = await tx.get(
                db.collection('rivalries').doc(`${pair[0]}_${pair[1]}`)
              );
              const r = rSnap.exists ? (rSnap.data() || {}) : {};
              const wA = Number(r.winsA) || 0;
              const wB = Number(r.winsB) || 0;
              inActiveSeries = r.status === 'active' && (wA + wB) > 0;
            } catch (_) { inActiveSeries = false; }
            if (!inActiveSeries && !sparFriendsSkip) {
              const cooldownHours = isPremium ? WP_COOLDOWN_PREMIUM_HOURS : WP_COOLDOWN_FREE_HOURS;
              const remainingHours = _rivalCooldownRemainingHours(
                rivalCooldownMap, cleanOpponentUid, cooldownHours);
              if (remainingHours > 0) {
                throw new HttpsError('resource-exhausted', `wp_cooldown_active_${remainingHours}h`);
              }
            }
          }
        }

        // ── Deduct AC ────────────────────────────────────────────────────────
        // Spars stake nothing: only the spar budget counter moves.

        if (isSparChallenge) {
          tx.update(userRef, {
            sparsCreatedToday:
              sparsCreatedToday + 1,

            sparsCreatedDate:
              todayWAT,
          });
        } else {
          const acBalanceAfter =
            animeCoins - stakeAmount;

          tx.update(userRef, {
            animeCoins:
              FieldValue.increment(-stakeAmount),

            challengesCreatedToday:
              createdToday + 1,

            challengesCreatedDate:
              todayWAT,
          });

          // AC transaction log

          const acTxLogRef =
            userRef
              .collection('coinTransactions')
              .doc();

          tx.set(acTxLogRef, {
            type: 'spend_challenge_stake',
            delta: -stakeAmount,
            balanceAfter: acBalanceAfter,
            timestamp:
              FieldValue.serverTimestamp(),
          });
        }

        // ── Deduct WP ────────────────────────────────────────────────────────

        if (isRivalChallenge && wpStake > 0) {
          const wpBalanceAfter =
            currentWP - wpStake;

          tx.update(userRef, {
            weeklyPoints:
              FieldValue.increment(-wpStake),

            wpStakedToday:
              wpStakedToday + wpStake,

            wpStakedDate:
              todayWAT,

            rivalCooldowns:
              _touchRivalCooldownMap(_getRivalCooldownMap(data), cleanOpponentUid),

            lastRivalChallenge:
              FieldValue.serverTimestamp(),

            lastRivalUid:
              cleanOpponentUid,
          });

          const wpTxLogRef =
            userRef
              .collection('wpTransactions')
              .doc();

          tx.set(wpTxLogRef, {
            type: 'spend_challenge_stake',
            delta: -wpStake,
            balanceAfter: wpBalanceAfter,
            timestamp:
              FieldValue.serverTimestamp(),
          });
        }

        // ── Create challenge ─────────────────────────────────────────────────

        tx.set(challengeRef, {
          creatorUid: uid,

          creatorUsername:
            data.username || 'Anonymous',

          opponentUid:
            isRivalChallenge
                ? cleanOpponentUid
                : null,

          // THIS WAS CAUSING YOUR INTERNAL ERROR
          opponentUsername:
            isRivalChallenge
                ? cleanOpponentUsername
                : null,

          stakeAmount,

          wpStake:
            isRivalChallenge
                ? wpStake
                : 0,

          betAmount: 0,

          animeTitle:
            animeTitle.trim().toLowerCase(),

          questionIds,

          status: 'waiting',

          isQuickMatch: false,

          creatorDeviceHash: creatorDeviceHash || null,

          challengeType: isSparChallenge
            ? 'spar'
            : (isRivalChallenge ? 'rival' : 'code'),

          expiresAt,

          createdAt:
            FieldValue.serverTimestamp(),
        });

        // ── Phase 2 fraud signal (in-tx merge, same commit �?never blocks) ──
        // Creator IP goes to telemetry/challenge_signals (server-only; the
        // challenge doc itself stays client-readable so it must NOT carry IPs).
        tx.set(
          db.collection('telemetry').doc('challenge_signals').collection('events').doc(challengeRef.id),
          {
            creatorUid: uid,
            creatorIp: _clientIp(request),
            createdAt: FieldValue.serverTimestamp(),
            challengeType: isSparChallenge
              ? 'spar'
              : (isRivalChallenge ? 'rival' : 'code'),
            stakeAmount,
            wpStake: isRivalChallenge ? wpStake : 0,
          },
          { merge: true }
        );
      });

      console.log(
        `[createChallenge] SUCCESS ` +
        `uid=${uid} ` +
        `challengeId=${challengeRef.id} ` +
        `anime=${animeTitle} ` +
        `stake=${stakeAmount}AC ` +
        `wpStake=${wpStake}WP` +
        (isSparChallenge ? ` spar` : ``)
      );

      // ── Invite notification (best-effort, never blocks) ──────────────────
      // Named-rival invites (ranked + spar) ping the invitee so duels don't
      // die in the inbox. Code challenges have no invitee yet �?nothing to do.
      if (isRivalChallenge && cleanOpponentUid) {
        const inviterName =
          (await db.collection('users').doc(uid).get()).data()?.username ||
          'Someone';
        sendToUser(cleanOpponentUid, {
          title: isSparChallenge
            ? `${inviterName} wants a spar!`
            : `${inviterName} challenged you!`,
          body: isSparChallenge
            ? `Friendly duel, nothing staked. Tap to play.`
            : `Stakes on the table. Tap to accept.`,
        }).catch((e) =>
          console.warn(`[createChallenge] invite notify failed (ignored): ${e.message}`)
        );
      }

      return {
        challengeId:
          challengeRef.id,

        questionIds,
      };

    } catch (error) {
      console.error(
        '[createChallenge] FAILED:',
        error
      );

      // Preserve intentional Firebase errors.
      if (error instanceof HttpsError) {
        throw error;
      }

      throw new HttpsError(
        'internal',
        'challenge_creation_failed'
      );
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── joinChallenge ──────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.joinChallenge = onSecureCall(
  {
    region: 'us-central1',
    cpu: 0.5,
    memory: '256MiB',
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'joinChallenge', { requireStamp: true });
    const joinerDeviceHash = await _touchDevice(uid, request.data?.deviceId);

    const { challengeId } = request.data;
    if (typeof challengeId !== 'string' || !challengeId.trim()) {
      throw new HttpsError('invalid-argument', 'invalid_challenge_id');
    }

    const now = new Date();
    const todayWAT = _watDateString();
    const challengeRef = db.collection('challenges').doc(challengeId);
    const userRef = db.collection('users').doc(uid);

    let stakeAmount, wpStake, creatorUid;

    await db.runTransaction(async (tx) => {
      const [challengeSnap, userSnap] = await Promise.all([
        tx.get(challengeRef),
        tx.get(userRef),
      ]);

      if (!challengeSnap.exists) {
        throw new HttpsError('not-found', 'challenge_not_found');
      }
      const challenge = challengeSnap.data();
      if (challenge.creatorUid === uid) {
        throw new HttpsError('invalid-argument', 'cannot_join_own_challenge');
      }
      // Two accounts on the same install must never oppose each other: that is
      // the cheapest possible win-trading setup.
      if (joinerDeviceHash && challenge.creatorDeviceHash
          && joinerDeviceHash === challenge.creatorDeviceHash) {
        throw new HttpsError(
          'failed-precondition',
          'same_device_challenge',
          { reason: 'same_device_challenge' }
        );
      }
      // Joinable from the plain invite state AND from a state where the creator
      // has already played. A creator is pushed straight into the quiz by
      // createChallenge and may finish before anyone accepts; their score is
      // promoted to creator_submitted, and the invite must stay takeable so the
      // assigned opponent (or, for a code challenge, whoever holds the code)
      // can still claim their seat.
      if (!JOINABLE_CHALLENGE_STATUSES.includes(challenge.status)) {
        throw new HttpsError('failed-precondition', 'challenge_not_waiting');
      }
      // A seat is only free while the joiner has not played: an already-written
      // opponent score means someone already took it.
      if (challenge.opponentScore != null) {
        throw new HttpsError('failed-precondition', 'challenge_not_waiting');
      }

      // ── Active challenge cap (in-tx: race-safe) ───────────────────────────
      // Queried inside the transaction so a concurrent create/join can't slip
      // past a stale pre-read and exceed the cap.
      const capIsPremium = (userSnap.data() || {}).premiumActive === true;
      const capMaxActive = capIsPremium
        ? ACTIVE_CHALLENGES_PREMIUM
        : ACTIVE_CHALLENGES_FREE;
      const [capAsCreator, capAsOpponent] = await Promise.all([
        tx.get(db.collection('challenges')
          .where('creatorUid', '==', uid)
          .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)),
        tx.get(db.collection('challenges')
          .where('opponentUid', '==', uid)
          .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)),
      ]);
      if (capAsCreator.size + capAsOpponent.size >= capMaxActive) {
        throw new HttpsError('resource-exhausted', 'too_many_active_challenges');
      }
      // Rival challenges are invite-locked: opponentUid is already set to
      // the specific person the creator challenged (see createChallenge).
      // Code challenges leave opponentUid null until someone joins, so
      // they stay open to whoever holds the code. Without this check,
      // anyone who obtained a rival challenge's ID could join a challenge
      // meant for someone else and take their invited opponent's spot.
      if (challenge.opponentUid && challenge.opponentUid !== uid) {
        throw new HttpsError('permission-denied', 'not_the_invited_opponent');
      }

      stakeAmount = challenge.stakeAmount;
      wpStake = challenge.wpStake || 0;
      creatorUid = challenge.creatorUid;
      const isSparJoin = challenge.challengeType === 'spar';

      // Spar invites must also be zero-stake (a crafted join can't upgrade
      // a friendly spar into a staked duel �?stakes are fixed at create).
      if (isSparJoin && (stakeAmount !== 0 || wpStake !== 0)) {
        throw new HttpsError('invalid-argument', 'spar_must_be_unstaked');
      }

      // Friends-only spars (join side): the pair must hold an active
      // friendship. Blocked pairs read as 'blocked', never 'active'.
      if (isSparJoin) {
        const pair = [creatorUid, uid].sort();
        const fSnap = await tx.get(
          db.collection('friendships').doc(`${pair[0]}_${pair[1]}`)
        );
        const f = fSnap.exists ? (fSnap.data() || {}) : {};
        if (f.status !== 'active') {
          throw new HttpsError('failed-precondition', 'not_friends');
        }
      } else if (creatorUid && creatorUid !== 'ghost') {
        // Staked duels: a block between the pair stops the join either way.
        const pair = [creatorUid, uid].sort();
        const bSnap = await tx.get(
          db.collection('friendships').doc(`${pair[0]}_${pair[1]}`)
        );
        if ((bSnap.data() || {}).status === 'blocked') {
          throw new HttpsError('failed-precondition', 'blocked');
        }
      }

      const userData = userSnap.data() || {};
      const isPremium = userData.premiumActive === true;

      const animeCoins = userData.animeCoins || 0;
      if (animeCoins < stakeAmount) {
        throw new HttpsError('resource-exhausted', 'insufficient_coins');
      }

      // ── Opponent daily join limit ──────────────────────────────────────
      // Spars run on their own budget (never consume the staked budget).
      const joinedDate = userData.challengesJoinedDate || '';
      let joinedToday = (joinedDate === todayWAT) ? (userData.challengesJoinedToday || 0) : 0;
      let sparsJoinedToday = 0;
      if (isSparJoin) {
        sparsJoinedToday =
          (userData.sparsJoinedDate === todayWAT)
            ? (userData.sparsJoinedToday || 0)
            : 0;
        const sparBudget = isPremium ? SPAR_DAILY_PREMIUM : SPAR_DAILY_FREE;
        if (sparsJoinedToday >= sparBudget) {
          throw new HttpsError('resource-exhausted', 'daily_spar_limit_reached');
        }
      } else if (joinedToday >= (isPremium ? DAILY_CHALLENGE_JOIN_PREMIUM : DAILY_CHALLENGE_JOIN_FREE)) {
        throw new HttpsError('resource-exhausted', 'daily_challenge_limit_reached');
      }

      // ── Joiner stake-shape parity with createChallenge ───────────────
      // The challenge doc was server-created, so its stake already passed
      // the creator-side max at create time. Join validates SHAPE only
      // (integer, minimum, step) �?never the joiner's tier max �?so a free
      // user can join a premium-sized stake and pre-change challenges (which
      // always met minima/steps at create) are never blocked here. Daily
      // caps + balance + cooldown below still apply to the joiner.
      if (!isSparJoin) {
        if (!Number.isInteger(stakeAmount) || stakeAmount < AC_MIN_STAKE ||
            stakeAmount % AC_STAKE_STEP !== 0) {
          throw new HttpsError('invalid-argument', 'invalid_stake_amount');
        }
      }

      // ── Opponent WP validation (if wpStake > 0) ────────────────────────
      if (wpStake > 0) {
        if (!Number.isInteger(wpStake) || wpStake < WP_MIN_STAKE ||
            wpStake % WP_STEP !== 0) {
          throw new HttpsError('invalid-argument', 'invalid_wp_stake');
        }

        let wpStakedToday = 0;
        if (userData.wpStakedDate === todayWAT) {
          wpStakedToday = userData.wpStakedToday || 0;
        }
        const dailyCap = isPremium ? WP_DAILY_CAP_PREMIUM : WP_DAILY_CAP_FREE;
        if (wpStakedToday + wpStake > dailyCap) {
          throw new HttpsError('resource-exhausted', 'wp_daily_cap_exceeded');
        }

        const currentWP = userData.weeklyPoints || 0;
        if (currentWP < wpStake) {
          throw new HttpsError('resource-exhausted', 'insufficient_wp');
        }

        // ── WP Cooldown Check for opponent ──────────────────────────────
        // Rolling record (see createChallenge): rotation across several
        // rivals must not clear the cooldown against any one of them.
        // Series-aware: skipped inside an active series with games played.
        const joinerCooldownMap = _getRivalCooldownMap(userData);
        {
          let inActiveSeries = false;
          try {
            const pair = [creatorUid, uid].sort();
            const rSnap = await tx.get(
              db.collection('rivalries').doc(`${pair[0]}_${pair[1]}`)
            );
            const r = rSnap.exists ? (rSnap.data() || {}) : {};
            const wA = Number(r.winsA) || 0;
            const wB = Number(r.winsB) || 0;
            inActiveSeries = r.status === 'active' && (wA + wB) > 0;
          } catch (_) { inActiveSeries = false; }
          if (!inActiveSeries) {
            const cooldownHours = isPremium ? WP_COOLDOWN_PREMIUM_HOURS : WP_COOLDOWN_FREE_HOURS;
            const remainingHours = _rivalCooldownRemainingHours(
              joinerCooldownMap, creatorUid, cooldownHours);
            if (remainingHours > 0) {
              throw new HttpsError('resource-exhausted', `wp_cooldown_active_${remainingHours}h`);
            }
          }
        }
      }

      // ── Deduct AC ────────────────────────────────────────────────────────
      // Spars stake nothing: only the spar budget counter moves.
      if (isSparJoin) {
        tx.update(userRef, {
          sparsJoinedToday: sparsJoinedToday + 1,
          sparsJoinedDate: todayWAT,
        });
      } else {
        const acBalanceAfter = animeCoins - stakeAmount;
        tx.update(userRef, {
          animeCoins: FieldValue.increment(-stakeAmount),
          challengesJoinedToday: joinedToday + 1,
          challengesJoinedDate: todayWAT,
        });

        const acTxLogRef = userRef.collection('coinTransactions').doc();
        tx.set(acTxLogRef, {
          type: 'spend_challenge_stake',
          delta: -stakeAmount,
          balanceAfter: acBalanceAfter,
          timestamp: FieldValue.serverTimestamp(),
        });
      }

      // ── Deduct WP (if wpStake > 0) ──────────────────────────────────────
      if (wpStake > 0) {
        const currentWP = userData.weeklyPoints || 0;
        const wpBalanceAfter = currentWP - wpStake;
        
        let wpStakedToday = 0;
        if (userData.wpStakedDate === todayWAT) {
          wpStakedToday = userData.wpStakedToday || 0;
        }
        
        tx.update(userRef, {
          weeklyPoints: FieldValue.increment(-wpStake),
          wpStakedToday: wpStakedToday + wpStake,
          wpStakedDate: todayWAT,
          rivalCooldowns: _touchRivalCooldownMap(_getRivalCooldownMap(userData), creatorUid),
          lastRivalChallenge: FieldValue.serverTimestamp(),
          lastRivalUid: creatorUid,
        });

        // WP transaction log
        const wpTxLogRef = userRef.collection('wpTransactions').doc();
        tx.set(wpTxLogRef, {
          type: 'spend_challenge_stake',
          delta: -wpStake,
          balanceAfter: wpBalanceAfter,
          timestamp: FieldValue.serverTimestamp(),
        });
      }

      // ── Update challenge ────────────────────────────────────────────────
      // Acceptance extends the deadline back to the full in-play window:
      // invites start on the short 12h fuse, accepted duels get 24h from
      // the moment both sides are in.
      tx.update(challengeRef, {
        opponentUid: uid,
        opponentUsername: userData.username || 'Anonymous',
        status: 'opponent_joined',
        // Stamped so the refund/forfeit sweeps can tell a challenge that was
        // actually joined (both stakes paid) from one whose invitee never
        // showed up �?only the former may refund the opponent or forfeit them.
        joinedAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromDate(
          new Date(now.getTime() + CHALLENGE_EXPIRY_HOURS * 60 * 60 * 1000)
        ),
      });

      // ── Phase 2 fraud signal (in-tx merge �?joiner IP, server-only) ─────
      tx.set(
        db.collection('telemetry').doc('challenge_signals').collection('events').doc(challengeRef.id),
        {
          joinerUid: uid,
          joinerIp: _clientIp(request),
          joinedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    });

    console.log(
      `[joinChallenge] uid=${uid} | challengeId=${challengeId}` +
      ` | stake=${stakeAmount} AC | wpStake=${wpStake} WP deducted`
    );
    return { success: true, stakeAmount, wpStake };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── declineChallenge ───────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Lets the invited opponent on a pending rival challenge (status: 'waiting',
// opponentUid already set) reject it without playing. Refunds the creator's
// AC/WP stake (which was deducted at createChallenge time) and marks the
// challenge 'declined' so it drops out of ACTIVE_CHALLENGE_STATUSES and no
// longer counts against either player's active-challenge cap.
exports.declineChallenge = onSecureCall(
  {
    region: 'us-central1',
    cpu: 0.5,
    memory: '256MiB',
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'declineChallenge');

    const { challengeId } = request.data;
    if (typeof challengeId !== 'string' || !challengeId.trim()) {
      throw new HttpsError('invalid-argument', 'invalid_challenge_id');
    }

    const challengeRef = db.collection('challenges').doc(challengeId);

    await db.runTransaction(async (tx) => {
      const challengeSnap = await tx.get(challengeRef);
      if (!challengeSnap.exists) {
        throw new HttpsError('not-found', 'challenge_not_found');
      }
      const challenge = challengeSnap.data();

      // Authorization BEFORE state: the opponent check must come first.
      // Checking status first lets ANY user (including non-participants and
      // unauthenticated-looking probes) distinguish 'waiting' from
      // 'opponent_joined'/'completed' via the error code, which leaks challenge
      // state to callers who have no right to see it.
      if (challenge.opponentUid !== uid) {
        throw new HttpsError('permission-denied', 'not_the_invited_opponent');
      }
      if (!JOINABLE_CHALLENGE_STATUSES.includes(challenge.status)) {
        throw new HttpsError('failed-precondition', 'challenge_not_pending');
      }

      const stakeAmt = challenge.stakeAmount || 0;
      const wpStake = challenge.wpStake || 0;
      const creatorRef = db.collection('users').doc(challenge.creatorUid);
      const creatorSnap = await tx.get(creatorRef);
      const creatorData = creatorSnap.data() || {};

      tx.update(challengeRef, {
        status: 'declined',
        declinedAt: FieldValue.serverTimestamp(),
        declinedBy: uid,
      });

      if (stakeAmt > 0) {
        const currentCoins = creatorData.animeCoins || 0;
        tx.update(creatorRef, { animeCoins: FieldValue.increment(stakeAmt) });
        const txLogRef = creatorRef.collection('coinTransactions').doc();
        tx.set(txLogRef, {
          type: 'refund_challenge_stake',
          delta: stakeAmt,
          balanceAfter: currentCoins + stakeAmt,
          timestamp: FieldValue.serverTimestamp(),
        });
      }

      if (wpStake > 0) {
        const currentWP = creatorData.weeklyPoints || 0;
        tx.update(creatorRef, { weeklyPoints: FieldValue.increment(wpStake) });
        const wpTxRef = creatorRef.collection('wpTransactions').doc();
        tx.set(wpTxRef, {
          type: 'refund_challenge_stake',
          delta: wpStake,
          balanceAfter: currentWP + wpStake,
          timestamp: FieldValue.serverTimestamp(),
        });
      }
    });

    console.log(`[declineChallenge] uid=${uid} | challengeId=${challengeId} declined`);
    return { success: true };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── resolveChallengeOutcome ──────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// ─── Shared resolution logic (used by both the automatic trigger below and
// the manual forceResolveChallenge callable) ────────────────────────────────
async function _resolveChallengeCore(challengeId, challengeRef, after) {
  const {
    creatorUid,
    opponentUid,
    betAmount,
    creatorScore,
    opponentScore,
    animeTitle = 'Unknown Anime',
    creatorUsername = 'Anonymous',
    opponentUsername = 'Anonymous',
    stakeAmount = 0,
    wpStake = 0,
    isQuickMatch = false,
    questionIds = [],
  } = after;

  // Silent enforcement decay for both sides. Only minted rewards (flat WP and
  // QM AC) are decayed; staked principal/refunds are never reduced.
  const [creatorEnforcement, opponentEnforcement] = await Promise.all([
    _readEnforcement(creatorUid),
    _readEnforcement(opponentUid),
  ]);

  // Sparring: explicit 'spar' type written at create time (zero stakes).
  // Legacy docs predate the type, so fall back to the old derivation.
  const resolvedType = after.challengeType
    || (isQuickMatch ? 'quick' : (wpStake > 0 ? 'rival' : 'code'));
  const isSpar = resolvedType === 'spar';
  // Ranked = named-rival competition (spar and code excluded). Series score
  // and upset bounties only apply here.
  const isRankedRival = resolvedType === 'rival';

  // Determine outcome
  let outcome;
  if (creatorScore > opponentScore) outcome = 'creator_wins';
  else if (opponentScore > creatorScore) outcome = 'opponent_wins';
  else outcome = 'draw';

  const isDraw = outcome === 'draw';
  const creatorWins = outcome === 'creator_wins';
  const opponentWins = outcome === 'opponent_wins';
  const creatorOutcome = isDraw ? 'draw' : (creatorWins ? 'win' : 'lose');
  const opponentOutcome = isDraw ? 'draw' : (!creatorWins ? 'win' : 'lose');

  const creatorPointsChange = isDraw ? 0 : (creatorWins ? betAmount : -betAmount);
  const opponentPointsChange = isDraw ? 0 : (!creatorWins ? betAmount : -betAmount);

  // AC challenge rake follows the locked economy spec (v4.8 §9): house rake
  // r = 5% of the stake. Settlement:
  //   Win  -> net = S(1 �?2r) = S × 0.90  (winner's bonus on top of their stake)
  //   Draw -> net = −S × r     = −S × 0.05 (each side refunded 95%, 5% fee)
  //   Loss -> net = −S
  // So the winner is credited stake + 90%, a draw refunds 95% of the stake
  // (NOT the old 90% �?that over-charged a 10% draw fee, contradicting the
  // locked r = 5% rake and the client's payoutDraw preview), and the house
  // collects S × 2r on both a win and a draw.
  const winnerBonus = Math.floor(stakeAmount * 0.9);
  const winnerTotal = stakeAmount + winnerBonus;
  const drawReturn = Math.floor(stakeAmount * 0.95);
  const houseFee = isDraw
    ? Math.floor(stakeAmount * 0.05) * 2
    : Math.floor(stakeAmount * 0.1);

  const creatorRef = db.collection('users').doc(creatorUid);
  const opponentRef = db.collection('users').doc(opponentUid);

  const creatorMatchRef = creatorRef.collection('matches').doc();
  const opponentMatchRef = opponentRef.collection('matches').doc();
  const creatorCoinTxRef = creatorRef.collection('coinTransactions').doc();
  const opponentCoinTxRef = opponentRef.collection('coinTransactions').doc();
  const houseFeeRef = db.collection('house_fees').doc();

  let wpCreatorChange = 0, wpOpponentChange = 0;

  // Series prize state is touched inside the transaction below but RETURNED to
  // the caller afterwards. Declaring the variables inside the async tx callback
  // left them undefined at return time, so hoist them to the outer function
  // scope where the final return can always see them.
  let seriesNo = 0;
  let seriesWinnerUid = null;
  let seriesPrizePaid = false;
  let cSeriesAC = 0;
  let oSeriesAC = 0;

  await db.runTransaction(async (tx) => {
    console.log(`[resolveChallengeCore] ${challengeId} �?transaction started.`);

    // Idempotency: the resolve trigger and forceResolveChallenge (or two
    // concurrent force calls) can race. The committed doc is the only
    // authority �?re-read it inside the transaction and bail if another
    // transaction already settled this challenge. Without this, both
    // transactions would credit the same payouts twice.
    const [cSnap, oSnap, challengeSnap] = await Promise.all([
      tx.get(creatorRef),
      tx.get(opponentRef),
      tx.get(challengeRef),
    ]);

    if (challengeSnap.exists && challengeSnap.data()?.resolved === true) {
      console.log(
        `[resolveChallengeCore] ${challengeId} already resolved by a ` +
        `concurrent transaction; skipping duplicate settlement.`
      );
      return;
    }

    const cData = cSnap.data() || {};
    const oData = oSnap.data() || {};

    // ── Pair reward cap ────────────────────────────────────────────────────
    // Three rewarded matches per account pair per WAT day. Stakes still settle
    // (a player's own coins are never trapped); only the minted flat reward
    // stops. Quick Match is ghost-only, so it has no real pair to cap.
    const rewardPairKey = (!isQuickMatch && creatorUid && opponentUid)
      ? [creatorUid, opponentUid].sort().join('_')
      : '';
    const rewardPairRef = rewardPairKey
      ? db.collection('challengePairs').doc(rewardPairKey)
      : null;
    const rewardPairSnap = rewardPairRef ? await tx.get(rewardPairRef) : null;
    const rewardPairDayId = _watDateString();
    const rewardPairData = (rewardPairSnap && rewardPairSnap.exists)
      ? (rewardPairSnap.data() || {})
      : {};
    const rewardPairCount = rewardPairData.dayId === rewardPairDayId
      ? (Number(rewardPairData.rewardedCount) || 0)
      : 0;
    const rewardPairCapReached =
      rewardPairCount >= CFG.PAIR_REWARD_MAX_PER_DAY;

    const cCurrentCoins = cData.animeCoins || 0;
    const oCurrentCoins = oData.animeCoins || 0;

    // ── Creator updates ──
    const cUpdate = { 'stats.gamesPlayed': FieldValue.increment(1) };

    // Flat WP base reward. Accumulated as a plain number (not written straight
    // to cUpdate.weeklyPoints) so that the stake payout below can be ADDED to
    // it instead of overwriting it �?the second assignment to the same property
    // used to clobber the flat CHALLENGE_WIN_WP / CHALLENGE_DRAW_WP reward for
    // rival challenges (a rival-win creator was being credited only the stake
    // change, silently losing their flat 50 WP win bonus).
    let cBaseWp = 0;
    if (isQuickMatch) {
      cBaseWp = creatorWins ? QM_WP_WIN : (isDraw ? QM_WP_DRAW : QM_WP_LOSE);
    } else if (!isSpar) {
      if (creatorWins) cBaseWp = CHALLENGE_WIN_WP;
      else if (isDraw) cBaseWp = CHALLENGE_DRAW_WP;
    }
    // Spars never touch gamesWon/Lost/Draw stats (an alt account could
    // otherwise farm the win achievements for free). Head-to-head history
    // still records every spar via the matches below.
    if (!isSpar && creatorOutcome === 'win') cUpdate['stats.gamesWon'] = FieldValue.increment(1);
    else if (!isSpar && creatorOutcome === 'lose') cUpdate['stats.gamesLost'] = FieldValue.increment(1);
    else if (!isSpar) cUpdate['stats.gamesDraw'] = FieldValue.increment(1);

    if (!isSpar) {
      cUpdate['stats.hseStaked'] = FieldValue.increment(stakeAmount);
      if (creatorOutcome === 'win') cUpdate['stats.hseWon'] = FieldValue.increment(winnerBonus);
      if (creatorOutcome === 'lose') cUpdate['stats.hseLost'] = FieldValue.increment(stakeAmount);
    }

    // ── Opponent updates ──
    const oUpdate = { 'stats.gamesPlayed': FieldValue.increment(1) };

    // See creator counterpart: flat WP base reward accumulated as a number so
    // the stake payout below can be added to it rather than overwriting it.
    let oBaseWp = 0;
    if (isQuickMatch) {
      oBaseWp = opponentWins ? QM_WP_WIN : (isDraw ? QM_WP_DRAW : QM_WP_LOSE);
    } else if (!isSpar) {
      if (opponentWins) oBaseWp = CHALLENGE_WIN_WP;
      else if (isDraw) oBaseWp = CHALLENGE_DRAW_WP;
    }
    if (!isSpar && opponentOutcome === 'win') oUpdate['stats.gamesWon'] = FieldValue.increment(1);
    else if (!isSpar && opponentOutcome === 'lose') oUpdate['stats.gamesLost'] = FieldValue.increment(1);
    else if (!isSpar) oUpdate['stats.gamesDraw'] = FieldValue.increment(1);

    if (!isSpar) {
      oUpdate['stats.hseStaked'] = FieldValue.increment(stakeAmount);
      if (opponentOutcome === 'win') oUpdate['stats.hseWon'] = FieldValue.increment(winnerBonus);
      if (opponentOutcome === 'lose') oUpdate['stats.hseLost'] = FieldValue.increment(stakeAmount);
    }

    // ── AC payouts ──
    // Computed once and reused below for the coin-transaction log too �?
    // previously this was independently recomputed there with the same
    // bare numbers, a duplication that could silently drift.
    //
    // Accumulated as plain local numbers (not written straight to
    // cUpdate.animeCoins) so the achievement tier check below can add its
    // AC grant on top and write a SINGLE FieldValue.increment() call. Reading
    // back .operand from an existing FieldValue.increment() is fragile �?
    // summing plain locals is the same clean pattern submitQuizAnswers uses.
    const qmCreatorAC = creatorWins ? QM_AC_WIN : (isDraw ? QM_AC_DRAW : QM_AC_LOSE);
    const qmOpponentAC = opponentWins ? QM_AC_WIN : (isDraw ? QM_AC_DRAW : QM_AC_LOSE);
    let cBaseAC = 0;
    let oBaseAC = 0;
    if (isQuickMatch) {
      if (qmCreatorAC > 0) cBaseAC = qmCreatorAC;
      if (qmOpponentAC > 0) oBaseAC = qmOpponentAC;
    } else if (stakeAmount > 0) {
      if (creatorWins) {
        cBaseAC = winnerTotal;
      } else if (opponentWins) {
        oBaseAC = winnerTotal;
      } else {
        cBaseAC = drawReturn;
        oBaseAC = drawReturn;
      }
    }

    // Apply enforcement decay to the minted flat rewards. Staked AC/WP
    // principal and refunds are deliberately untouched.
    if (creatorEnforcement.decayFactor < 1) {
      cBaseWp = _applyDecay(cBaseWp, creatorEnforcement.decayFactor);
      if (isQuickMatch) cBaseAC = _applyDecay(cBaseAC, creatorEnforcement.decayFactor);
    }
    if (opponentEnforcement.decayFactor < 1) {
      oBaseWp = _applyDecay(oBaseWp, opponentEnforcement.decayFactor);
      if (isQuickMatch) oBaseAC = _applyDecay(oBaseAC, opponentEnforcement.decayFactor);
    }

    // ── WP outcome ──
    // wpCreatorChange / wpOpponentChange are TOTAL CREDITS applied on top of
    // the stake that was already deducted at create/join time (mirrors the
    // AC payout pattern above: winnerTotal / drawReturn are full credits,
    // and a loser simply gets no further credit �?never an extra deduction).
    if (wpStake > 0) {
      if (outcome === 'creator_wins') {
        wpCreatorChange = wpStake + Math.floor(wpStake * 0.9);
        wpOpponentChange = 0; // stake already lost at stake time �?no further deduction
        cUpdate['stats.rivalWins'] = FieldValue.increment(1);
      } else if (outcome === 'opponent_wins') {
        wpOpponentChange = wpStake + Math.floor(wpStake * 0.9);
        wpCreatorChange = 0;
        oUpdate['stats.rivalWins'] = FieldValue.increment(1);
      } else {
        // Draw: refund ~90% of the stake (10% fee), same shape as the AC draw refund.
        wpCreatorChange = Math.floor(wpStake * 0.9);
        wpOpponentChange = Math.floor(wpStake * 0.9);
      }
      // Apply WP changes (credits only; a losing side's FieldValue is skipped).
      // These are ADDED to the flat base WP reward (cBaseWp / oBaseWp) that was
      // computed above. Previously this overwrote cUpdate.weeklyPoints /
      // oUpdate.weeklyPoints, silently discarding the flat CHALLENGE_WIN_WP /
      // CHALLENGE_DRAW_WP reward any time a rival challenge had a WP stake.
      cBaseWp += wpCreatorChange;
      oBaseWp += wpOpponentChange;

      // Update stats �?wpStaked/wpLost track the original stake regardless
      // of whether a credit was applied (a loser's "loss" is the stake they
      // already paid, not a further balance change).
      //
      // IMPORTANT: cUpdate/oUpdate use Firestore dot-notation keys everywhere
      // else (e.g. 'stats.gamesPlayed') so that this single object can be
      // passed straight to tx.update(). Writing cUpdate.stats = {...} here
      // as a *nested object* alongside those dot-notation keys made Firestore
      // reject the whole update with "Cannot specify field 'stats.gamesPlayed'
      // and its parent 'stats' in the same update" �?which only happens when
      // wpStake > 0 (i.e. rival challenges), silently breaking resolution for
      // every rival challenge while leaving non-rival challenges unaffected.
      cUpdate['stats.wpStaked'] = FieldValue.increment(wpStake);
      if (outcome === 'creator_wins') cUpdate['stats.wpWon'] = FieldValue.increment(Math.floor(wpStake * 0.9));
      else if (outcome === 'opponent_wins') cUpdate['stats.wpLost'] = FieldValue.increment(wpStake);
      else cUpdate['stats.wpLost'] = FieldValue.increment(wpStake - wpCreatorChange);

      oUpdate['stats.wpStaked'] = FieldValue.increment(wpStake);
      if (outcome === 'opponent_wins') oUpdate['stats.wpWon'] = FieldValue.increment(Math.floor(wpStake * 0.9));
      else if (outcome === 'creator_wins') oUpdate['stats.wpLost'] = FieldValue.increment(wpStake);
      else oUpdate['stats.wpLost'] = FieldValue.increment(wpStake - wpOpponentChange);
    }

    // ── Spar flat reward + upset bounty ───────────────────────────────────
    // Spars pay a flat SPAR_WP_WIN on a win while the side is inside its
    // daily spar budget (created + joined today); draws, losses and
    // over-budget play pay nothing �?glory only. Counted on resolve day,
    // mirroring how the rest of the economy reads WAT-day counters.
    let cBountyWP = 0;
    let oBountyWP = 0;
    if (isSpar) {
      // todayWAT is declared further below in this scope �?read the clock
      // directly here to avoid the temporal dead zone.
      const _today = _watDateString();
      const _sparsToday = (d) => {
        const c = d.sparsCreatedDate === _today ? (Number(d.sparsCreatedToday) || 0) : 0;
        const j = d.sparsJoinedDate === _today ? (Number(d.sparsJoinedToday) || 0) : 0;
        return c + j;
      };
      const cBudget = cData.premiumActive === true ? SPAR_DAILY_PREMIUM : SPAR_DAILY_FREE;
      const oBudget = oData.premiumActive === true ? SPAR_DAILY_PREMIUM : SPAR_DAILY_FREE;
      if (creatorWins && _sparsToday(cData) <= cBudget) cBaseWp = SPAR_WP_WIN;
      if (opponentWins && _sparsToday(oData) <= oBudget) oBaseWp = SPAR_WP_WIN;
      // Pair cap (3 paid wins/pair/day, single shared counter on the
      // friendship doc �?the same doc the create/join gates already read, so
      // this adds 1 tx read and at most 1 tx write per spar resolve).
      // Non-friend spars (pre-friends legacy) pay nothing.
      const [sA, sB] = [creatorUid, opponentUid].sort();
      const pairRef = db.collection('friendships').doc(`${sA}_${sB}`);
      let pairUsed = SPAR_PAID_PER_PAIR_PER_DAY;
      let pairIsFriend = false;
      try {
        const pSnap = await tx.get(pairRef);
        const p = pSnap.exists ? (pSnap.data() || {}) : {};
        pairIsFriend = p.status === 'active';
        pairUsed = (p.sparWinsDate === _today) ? Number(p.sparWinsCount || 0) : 0;
      } catch (_) { pairIsFriend = false; }
      if (!pairIsFriend || pairUsed >= SPAR_PAID_PER_PAIR_PER_DAY) {
        if (creatorWins) cBaseWp = 0;
        if (opponentWins) oBaseWp = 0;
      } else if ((creatorWins && cBaseWp > 0) || (opponentWins && oBaseWp > 0)) {
        tx.set(pairRef, { sparWinsDate: _today, sparWinsCount: pairUsed + 1 }, { merge: true });
      }
    }

    // Upset bounty (ranked rival duels only): beating a rival whose
    // pre-match weeklyPoints led yours by BOUNTY_WP_GAP pays a flat minted
    // bonus on top of stake + participation. Added pre-multiplier/pre-cap
    // like every other WP source. Bounded by the duel budget.
    if (isRankedRival && !isDraw) {
      const cWP = Number(cData.weeklyPoints) || 0;
      const oWP = Number(oData.weeklyPoints) || 0;
      if (creatorWins && oWP - cWP >= BOUNTY_WP_GAP) {
        cBaseWp += BOUNTY_WP_BONUS;
        cBountyWP = BOUNTY_WP_BONUS;
      }
      if (opponentWins && cWP - oWP >= BOUNTY_WP_GAP) {
        oBaseWp += BOUNTY_WP_BONUS;
        oBountyWP = BOUNTY_WP_BONUS;
      }
    }

    // ── Premium 1.20× WP multiplier ───────────────────────────────────────
    // Applied AFTER retry decay (all wpStake adjustments complete) but
    // BEFORE the daily soft cap. Each side's multiplier is independent
    // based on server-authoritative premiumActive status.
    if (cData.premiumActive === true && cBaseWp > 0) {
      cBaseWp = Math.floor(cBaseWp * 1.20);
    }
    if (oData.premiumActive === true && oBaseWp > 0) {
      oBaseWp = Math.floor(oBaseWp * 1.20);
    }

    // Pair cap: no more minted WP from this pair today. Stake settlement still
    // happens — only the flat/bounty/premium reward is removed, so nobody's
    // staked coins are trapped.
    if (rewardPairCapReached) {
      let cStakeCredit = 0;
      let oStakeCredit = 0;
      if (resolvedType === 'rival' && wpStake > 0) {
        const winCredit = wpStake + Math.floor(wpStake * 0.9);
        if (creatorWins) cStakeCredit = winCredit;
        else if (opponentWins) oStakeCredit = winCredit;
        else {
          cStakeCredit = Math.floor(wpStake * 0.9);
          oStakeCredit = Math.floor(wpStake * 0.9);
        }
      }
      cBaseWp = cStakeCredit;
      oBaseWp = oStakeCredit;
    }

    // ── Apply combined flat + stake weeklyPoints increment ──
    // Single write of the accumulated value (base reward + stake credit). A
    // zero value means the player is on the losing side of a staked challenge
    // and gets nothing further �?their stake was already forfeited at stake time.
    // Each side's computed WP total is also wrapped through the shared daily
    // WP soft cap before being applied.
    const todayWAT = _watDateString();
    // Post-cap WP awards, captured as plain locals so the achievement tier
    // check below can use them for careerWpEarned deltas without reading
    // back .operand from a FieldValue.increment() object.
    let cAwardedWP = 0;
    let oAwardedWP = 0;
    if (cBaseWp > 0) {
      const { award, newEarnedToday } =
        _applyDailyWPSoftCap(cBaseWp, _resolveDailyWPEarned(cData, todayWAT));
      cAwardedWP = award;
      cUpdate.weeklyPoints  = FieldValue.increment(award);
      cUpdate.wpEarnedToday = newEarnedToday;
      cUpdate.wpEarnedDate  = FieldValue.serverTimestamp();
      cUpdate['stats.careerWpEarned'] = FieldValue.increment(award);
    }
    if (oBaseWp > 0) {
      const { award, newEarnedToday } =
        _applyDailyWPSoftCap(oBaseWp, _resolveDailyWPEarned(oData, todayWAT));
      oAwardedWP = award;
      oUpdate.weeklyPoints  = FieldValue.increment(award);
      oUpdate.wpEarnedToday = newEarnedToday;
      oUpdate.wpEarnedDate  = FieldValue.serverTimestamp();
      oUpdate['stats.careerWpEarned'] = FieldValue.increment(award);
    }

    // ── Stage 13: Achievement tier check (creator + opponent, same tx) ──────
    // Check if any stat increments crossed a threshold and grant one-time AC
    // rewards. Runs in the same transaction so the stat increment, AC grant, and
    // achievementsGranted map update are atomic �?no double-grant possible even
    // under retries.
    //
    // A side is "perfect" when it answered the entire question set correctly �?
    // the same definition submitQuizAnswers (correctCount === 10) and
    // submitDailyGauntlet (correctCount === 7) use, generalised to
    // questionIds.length for any challenge size. Guard against a 0-length
    // questionIds so a 0/0 score isn't misread as perfect.
    const totalQ = Array.isArray(questionIds) ? questionIds.length : 0;
    const creatorPerfect  = totalQ > 0 && creatorScore   === totalQ;
    const opponentPerfect = totalQ > 0 && opponentScore  === totalQ;

    // Spars never feed perfectQuizzes (same alt-account farming concern as
    // gamesWon above).
    if (!isSpar && creatorPerfect)  cUpdate['stats.perfectQuizzes'] = FieldValue.increment(1);
    if (!isSpar && opponentPerfect) oUpdate['stats.perfectQuizzes'] = FieldValue.increment(1);

    // Build per-side stat deltas: only the stats that actually incremented on
    // this side. gamesWon/rivalWins are mutually exclusive per side (a side
    // either won, lost, or drew), so only one of them is ever > 0.
    const cStatDeltas = { gamesPlayed: 1, careerWpEarned: cAwardedWP };
    if (!isSpar && creatorOutcome === 'win') cStatDeltas.gamesWon = 1;
    if (cUpdate['stats.rivalWins']) cStatDeltas.rivalWins = 1;
    if (!isSpar && creatorPerfect) cStatDeltas.perfectQuizzes = 1;

    const oStatDeltas = { gamesPlayed: 1, careerWpEarned: oAwardedWP };
    if (!isSpar && opponentOutcome === 'win') oStatDeltas.gamesWon = 1;
    if (oUpdate['stats.rivalWins']) oStatDeltas.rivalWins = 1;
    if (!isSpar && opponentPerfect) oStatDeltas.perfectQuizzes = 1;

    // ── Rivalry series (ranked rival duels, decisive results only) ──────
    // First-to-SERIES_WINS_REQUIRED on rivalries/{sortedUidPair}. A decided
    // series pays SERIES_AC_PRIZE to the winner (AC gated by
    // SERIES_PRIZE_COOLDOWN_MS) and the next ranked
    // duel between the pair opens a fresh series (seriesNo++). Draws replay:
    // they read the current seriesNo for stamping but write nothing to the
    // rivalry doc. Spars and code duels never touch it. Expired series
    // restart like decided ones. Winner is mapped by UID against aUid/bUid.
    // The prize is applied as a separate tx.update below (Firestore sums
    // multiple increments to one field inside a transaction), so the
    // existing single-increment merge pattern is left untouched.
    if (isRankedRival && !isDraw) {
      const [aUid, bUid] = [creatorUid, opponentUid].sort();
      const rivalryRef = db.collection('rivalries').doc(`${aUid}_${bUid}`);
      const rSnap = await tx.get(rivalryRef);
      const r = rSnap.data() || {};
      seriesNo = Number(r.seriesNo) || 1;
      let winsA = Number(r.winsA) || 0;
      let winsB = Number(r.winsB) || 0;
      if (r.status === 'decided' || r.status === 'expired') {
        seriesNo += 1;
        winsA = 0;
        winsB = 0;
      }
      // FIX (series correctness): map the actual winner UID to the sorted
      // pair. The old code did `if (creatorWins) winsA++ else winsB++`, which
      // credited A whenever the creator won even when the creator was B.
      const winnerUid = creatorWins ? creatorUid : opponentUid;
      if (winnerUid === aUid) winsA++;
      else if (winnerUid === bUid) winsB++;
      else winsA++; // defensive: unknown winner defaults to A (unverified path)
      const decided = winsA >= SERIES_WINS_REQUIRED || winsB >= SERIES_WINS_REQUIRED;
      // lastSeriesPrizeAt gates AC only, never the decision/count.
      let lastPrizeMs = NaN;
      const rawPrize = r.lastSeriesPrizeAt;
      if (rawPrize && typeof rawPrize.toDate === 'function') {
        try { lastPrizeMs = rawPrize.toDate().getTime(); } catch (_) { lastPrizeMs = NaN; }
      } else if (typeof rawPrize === 'number' && Number.isFinite(rawPrize)) {
        lastPrizeMs = rawPrize;
      }
      const nowMs = Date.now();
      const prizeEligible = !Number.isFinite(lastPrizeMs) ||
        (nowMs - lastPrizeMs) > SERIES_PRIZE_COOLDOWN_MS;
      if (decided) {
        seriesWinnerUid = winsA >= SERIES_WINS_REQUIRED ? aUid : bUid;
        if (prizeEligible) {
          if (seriesWinnerUid === creatorUid) cSeriesAC = SERIES_AC_PRIZE;
          else oSeriesAC = SERIES_AC_PRIZE;
          seriesPrizePaid = true;
        }
      }
      const rivalryWrite = {
        aUid,
        bUid,
        seriesNo,
        winsA,
        winsB,
        status: decided ? 'decided' : 'active',
        lastWinnerUid: winnerUid,
        seriesWinnerUid: decided ? seriesWinnerUid : null,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (decided && seriesPrizePaid) {
        rivalryWrite.lastSeriesPrizeAt = FieldValue.serverTimestamp();
      }
      tx.set(rivalryRef, rivalryWrite, { merge: true });
    } else if (isRankedRival && isDraw) {
      // LOCKED: draws replay �?read current seriesNo for stamping, write
      // nothing to the rivalry doc.
      try {
        const [aUid, bUid] = [creatorUid, opponentUid].sort();
        const rivalryRef = db.collection('rivalries').doc(`${aUid}_${bUid}`);
        const rSnap = await tx.get(rivalryRef);
        const r = rSnap.exists ? (rSnap.data() || {}) : {};
        // If no rivalry exists yet, this draw belongs to series 1 but must
        // not create the doc. If a series exists (active/decided/expired),
        // stamp its current number so history stays grouped.
        seriesNo = Number(r.seriesNo) || 1;
        if (!rSnap.exists) seriesNo = 1;
      } catch (_) {
        seriesNo = seriesNo || 1;
      }
      seriesWinnerUid = null;
      seriesPrizePaid = false;
    }

    const cAchievements = _checkAchievementTiers(cData, cStatDeltas);

    // Written after every tx.get in this transaction (Firestore requires all
    // reads before all writes), so the pair counter joins the same commit as
    // the rewards it is limiting.
    if (rewardPairRef && !rewardPairCapReached
        && (cAwardedWP > 0 || oAwardedWP > 0)) {
      tx.set(rewardPairRef, {
        uids: [creatorUid, opponentUid],
        dayId: rewardPairDayId,
        rewardedCount: rewardPairCount + 1,
        updatedAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(Date.now() + 8 * CFG.DAY_MS),
      }, { merge: true });
    }

    const oAchievements = _checkAchievementTiers(oData, oStatDeltas);

    // Merge achievement AC grants into the base AC using plain local sums �?
    // same pattern as submitQuizAnswers. Single FieldValue.increment() call
    // per side, no .operand reads on existing update-object fields.
    if (cAchievements.acGranted > 0) {
      cUpdate.animeCoins = FieldValue.increment(cBaseAC + cAchievements.acGranted);
      cUpdate.achievementsGranted = cAchievements.newAchievementsGranted;
    } else if (cBaseAC > 0) {
      cUpdate.animeCoins = FieldValue.increment(cBaseAC);
    }
    if (oAchievements.acGranted > 0) {
      oUpdate.animeCoins = FieldValue.increment(oBaseAC + oAchievements.acGranted);
      oUpdate.achievementsGranted = oAchievements.newAchievementsGranted;
    } else if (oBaseAC > 0) {
      oUpdate.animeCoins = FieldValue.increment(oBaseAC);
    }

    // Grant any cosmetic frames from crossed tiers (e.g. frame_victory at 200 wins).
    if (cAchievements.framesToGrant.length > 0) {
      cUpdate.ownedCosmetics = FieldValue.arrayUnion(...cAchievements.framesToGrant);
    }
    if (oAchievements.framesToGrant.length > 0) {
      oUpdate.ownedCosmetics = FieldValue.arrayUnion(...oAchievements.framesToGrant);
    }

    // ── Series prize application (separate increments, summed server-side) ──
    // AC is paid only when seriesPrizePaid (7-day anti-farm gate in the
    // series block above). coinTransactions is written only when AC is
    // actually paid. No cosmetic is granted (frame reward removed).
    if (cSeriesAC > 0) {
      tx.update(creatorRef, {
        animeCoins: FieldValue.increment(cSeriesAC),
      });
      tx.set(creatorRef.collection('coinTransactions').doc(), {
        type: 'earn_series',
        delta: cSeriesAC,
        balanceAfter: cCurrentCoins + cBaseAC + cAchievements.acGranted + cSeriesAC,
        timestamp: FieldValue.serverTimestamp(),
      });
    }
    if (oSeriesAC > 0) {
      tx.update(opponentRef, {
        animeCoins: FieldValue.increment(oSeriesAC),
      });
      tx.set(opponentRef.collection('coinTransactions').doc(), {
        type: 'earn_series',
        delta: oSeriesAC,
        balanceAfter: oCurrentCoins + oBaseAC + oAchievements.acGranted + oSeriesAC,
        timestamp: FieldValue.serverTimestamp(),
      });
    }

    // ── Finalise challenge ──
    // Determine challenge type for UI display
    const challengeType = after.challengeType
      || (after.isQuickMatch
        ? 'quick'
        : (after.wpStake > 0 ? 'rival' : 'code'));
    tx.update(challengeRef, {
      outcome,
      status: 'completed',
      resolved: true,
      challengeType,
      // Upset bounty + series outcome for the result UI (null when n/a).
      bountyWinnerUid: cBountyWP > 0 ? creatorUid : (oBountyWP > 0 ? opponentUid : null),
      bountyWP: cBountyWP + oBountyWP,
      seriesNo,
      seriesWinnerUid,
      // Whether the +100 AC was actually paid (false when the 7-day
      // anti-farm gate suppressed it). UI uses this to explain the prize.
      seriesPrizePaid,
    });

    // ── Update users ──
    tx.update(creatorRef, cUpdate);
    tx.update(opponentRef, oUpdate);

    // ── AC coin logs ──
    // Base earnings keep their own types; achievement bonuses get a distinct
    // `earn_achievement` entry so the client can style them differently
    // (trophy/purple) from regular match earnings.
    if (isQuickMatch) {
      if (qmCreatorAC > 0) {
        tx.set(creatorCoinTxRef, {
          type: 'earn_quick_match',
          delta: qmCreatorAC,
          balanceAfter: cCurrentCoins + qmCreatorAC,
          timestamp: FieldValue.serverTimestamp(),
        });
      }
      if (qmOpponentAC > 0) {
        tx.set(opponentCoinTxRef, {
          type: 'earn_quick_match',
          delta: qmOpponentAC,
          balanceAfter: oCurrentCoins + qmOpponentAC,
          timestamp: FieldValue.serverTimestamp(),
        });
      }
      if (cAchievements.acGranted > 0) {
        tx.set(creatorRef.collection('coinTransactions').doc(), {
          type: 'earn_achievement',
          delta: cAchievements.acGranted,
          balanceAfter: cCurrentCoins + cBaseAC + cAchievements.acGranted,
          timestamp: FieldValue.serverTimestamp(),
        });
      }
      if (oAchievements.acGranted > 0) {
        tx.set(opponentRef.collection('coinTransactions').doc(), {
          type: 'earn_achievement',
          delta: oAchievements.acGranted,
          balanceAfter: oCurrentCoins + oBaseAC + oAchievements.acGranted,
          timestamp: FieldValue.serverTimestamp(),
        });
      }
    } else if (stakeAmount > 0) {
      if (creatorWins) {
        tx.set(creatorCoinTxRef, {
          type: 'earn_challenge_win',
          delta: winnerTotal,
          balanceAfter: cCurrentCoins + winnerTotal,
          timestamp: FieldValue.serverTimestamp(),
        });
      } else if (opponentWins) {
        tx.set(opponentCoinTxRef, {
          type: 'earn_challenge_win',
          delta: winnerTotal,
          balanceAfter: oCurrentCoins + winnerTotal,
          timestamp: FieldValue.serverTimestamp(),
        });
      } else {
        tx.set(creatorCoinTxRef, {
          type: 'earn_challenge_draw',
          delta: drawReturn,
          balanceAfter: cCurrentCoins + drawReturn,
          timestamp: FieldValue.serverTimestamp(),
        });
        tx.set(opponentCoinTxRef, {
          type: 'earn_challenge_draw',
          delta: drawReturn,
          balanceAfter: oCurrentCoins + drawReturn,
          timestamp: FieldValue.serverTimestamp(),
        });
      }
      // Distinct achievement ledger entries (see Quick Match branch above).
      if (cAchievements.acGranted > 0) {
        tx.set(creatorRef.collection('coinTransactions').doc(), {
          type: 'earn_achievement',
          delta: cAchievements.acGranted,
          balanceAfter: cCurrentCoins + cBaseAC + cAchievements.acGranted,
          timestamp: FieldValue.serverTimestamp(),
        });
      }
      if (oAchievements.acGranted > 0) {
        tx.set(opponentRef.collection('coinTransactions').doc(), {
          type: 'earn_achievement',
          delta: oAchievements.acGranted,
          balanceAfter: oCurrentCoins + oBaseAC + oAchievements.acGranted,
          timestamp: FieldValue.serverTimestamp(),
        });
      }
      tx.set(houseFeeRef, {
        challengeId: challengeId,
        houseFee,
        stakeAmount,
        creatorUid,
        opponentUid,
        outcome: isDraw ? 'draw' : 'win',
        timestamp: FieldValue.serverTimestamp(),
      });
    }

    // ── Match history ──
    //
    // `wpAwarded` is the post-premium, post-daily-cap WP that was actually
    // applied to `weeklyPoints` (see the cAwardedWP / oAwardedWP locals above).
    // The client ledger needs it because `wpChange` alone is only the
    // pre-multiplier stake settlement �?it omits the flat 50/25 participation
    // bonus entirely (so a Code challenge win logged 0) and is 0 for the losing
    // side (so a rival loss logged nothing at all, even though the stake had
    // already been debited at create/join time).
    tx.set(creatorMatchRef, {
      opponent: opponentUsername,
      opponentUid: opponentUid,
      playerScore: creatorScore,
      opponentScore: opponentScore,
      betScore: betAmount,
      stakeAmount,
      wpStake,
      wpChange: wpCreatorChange,
      wpAwarded: cAwardedWP,
      outcome: creatorOutcome,
      pointsChange: creatorPointsChange,
      animeTitle,
      isQuickMatch,
      challengeType: resolvedType,
      bountyWP: cBountyWP,
      seriesNo,
      challengeId: challengeId,
      timestamp: FieldValue.serverTimestamp(),
    });

    tx.set(opponentMatchRef, {
      opponent: creatorUsername,
      opponentUid: creatorUid,
      playerScore: opponentScore,
      opponentScore: creatorScore,
      betScore: betAmount,
      stakeAmount,
      wpStake,
      wpChange: wpOpponentChange,
      wpAwarded: oAwardedWP,
      outcome: opponentOutcome,
      pointsChange: opponentPointsChange,
      animeTitle,
      isQuickMatch,
      challengeType: resolvedType,
      bountyWP: oBountyWP,
      seriesNo,
      challengeId: challengeId,
      timestamp: FieldValue.serverTimestamp(),
    });

    // ── AC Challenge EV Telemetry ───────────────────────────────────────────
    // Written server-side only; clients cannot write to telemetry collection.
    const acReturnedActual = isDraw
      ? drawReturn * 2
      : winnerTotal;
    const acBurnedActual = houseFee;

    const telemetryRef = db.collection('telemetry').doc('ac_challenge_events').collection('events').doc();
    tx.set(telemetryRef, {
      challengeId,
      stakeAmount,
      houseRake: houseFee,
      outcome,
      acBurnedActual,
      acReturnedActual,
      timestamp: FieldValue.serverTimestamp(),
    });

    // ── Phase 2 fraud signal: resolution outcome merged onto the per- ────
    // challenge signal doc (create/join IPs already recorded there; the
    // resolve trigger itself carries no client IP, so nothing new is added).
    tx.set(
      db.collection('telemetry').doc('challenge_signals').collection('events').doc(challengeId),
      {
        creatorUid,
        opponentUid,
        outcome,
        stakeAmount,
        wpStake,
        resolvedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    console.log(`[resolveChallengeCore] ${challengeId} �?transaction committed successfully.`);
  });

  // ── Ghost-pool seeding from Rival/Code challenges ──────────────────────
  // Quick Match's "ghost opponent" fallback (joinMatchmakingQueue) only
  // ever had data to draw from once a REAL two-player Quick Match had
  // completed (via saveGhostSession, now called from QuizController right
  // after every Quick Match completion �?ghost or real). That's a
  // bootstrap gap: Quick Match itself needs a second player online in the
  // same WAT window to ever produce that first completion, so
  // ghost_sessions can stay empty indefinitely and Quick Match silently
  // fails end-to-end. Rival and Code challenges are also real two-player
  // games but don't depend on matchmaking timing �?you just invite a
  // specific rival or share a code �?so we also seed the ghost pool here
  // whenever one of those finishes, using the same MIN_GHOST_SCORE bar and
  // 20-session cap as saveGhostSession. Skipped for Quick Match itself
  // (isQuickMatch) since that already has its own seeding path.
  //
  // NOTE: rival/code challenges only ever store the aggregate score per
  // side (see FirestoreService.submitCreatorScore/submitOpponentScore �?
  // they write just `creatorScore`/`opponentScore`, not a per-question
  // answers array), so these auto-seeded entries carry `answers: []`.
  // That's fine: nothing that reads ghost_sessions today (joinMatchmakingQueue,
  // submitQuickMatchResult) ever looks at the `answers` field �?only
  // `sessionId`, `username`, `score`, and `questionIds` are used.
  if (!isQuickMatch && Array.isArray(questionIds) && questionIds.length === 10) {
    const MIN_GHOST_SCORE = 6;
    const ghostRef = db.collection('ghost_sessions').doc(animeTitle);

    const candidates = [
      { uid: creatorUid, username: creatorUsername, score: creatorScore },
      { uid: opponentUid, username: opponentUsername, score: opponentScore },
    ].filter((p) => Number.isInteger(p.score) && p.score >= MIN_GHOST_SCORE);

    if (candidates.length > 0) {
      try {
        await db.runTransaction(async (tx) => {
          const snap     = await tx.get(ghostRef);
          const data     = snap.data() || {};
          const sessions = Array.isArray(data.sessions) ? [...data.sessions] : [];

          for (const p of candidates) {
            if (sessions.length >= 20) sessions.shift();
            sessions.push({
              sessionId: db.collection('ghost_sessions').doc().id,
              uid: p.uid,
              username: p.username || 'Anonymous',
              questionIds,
              answers: [],
              score: p.score,
              recordedAt: Timestamp.now(),
            });
          }

          tx.set(ghostRef, { sessions }, { merge: true });
        });

        console.log(
          `[resolveChallengeCore] ${challengeId} �?seeded ghost_sessions/${animeTitle}` +
          ` with ${candidates.length} session(s): ` +
          candidates.map((p) => `${p.username}=${p.score}`).join(', ')
        );
      } catch (ghostErr) {
        // Never let ghost-pool bookkeeping take down a real payout resolution.
        console.error(`[resolveChallengeCore] ${challengeId} �?ghost seed failed (non-fatal):`, ghostErr);
      }
    }
  }

  // ── Step 5b: mark both players' sets at resolution time (approved: no
  // partial marks; force-resolve flows through here too). Post-payout,
  // non-awaited, non-fatal �?the getAll + writes below can never delay or
  // block the committed awards above. Ghost challenges never reach here
  // (the trigger skips opponentUid === 'ghost'), so only real uids remain.
  {
    const seenUids = [creatorUid, opponentUid].filter(
      (id) => typeof id === 'string' && id.length > 0 && id !== 'ghost'
    );
    if (Array.isArray(questionIds) && questionIds.length > 0 && seenUids.length > 0) {
      db.getAll(
        ...questionIds
          .slice(0, 10)
          .map((id) => db.collection('questions').doc(id))
      )
        .then((snaps) => {
          const qMap = {};
          for (const s of snaps) {
            if (s.exists) qMap[s.id] = s.data();
          }
          return Promise.all(
            seenUids.map((id) =>
              _markQuestionsSeen(id, questionIds, qMap).catch((e) =>
                console.error(`[resolveChallengeCore] seen-mark failed (non-fatal) uid=${id}: ${e.message}`)
              )
            )
          );
        })
        .catch((e) =>
          console.error(`[resolveChallengeCore] seen question-load failed (non-fatal): ${e.message}`)
        );
    }
  }

  const logQM = isQuickMatch
    ? ` | QM wp=${creatorWins ? 35 : isDraw ? 15 : 5}/${opponentWins ? 35 : isDraw ? 15 : 5} ac=${creatorWins ? 35 : isDraw ? 15 : 0}/${opponentWins ? 35 : isDraw ? 15 : 0}`
    : ` | stake: ${stakeAmount} AC | houseFee: ${houseFee} AC`;

  console.log(
    `[resolveChallengeCore] ${challengeId} �?${outcome}` +
    ` | creator(${creatorUsername}): ${creatorScore}` +
    ` vs opponent(${opponentUsername}): ${opponentScore}` +
    logQM +
    (wpStake > 0 ? ` | WP change: +${wpCreatorChange}/${wpOpponentChange}` : '')
  );
  console.log(`[resolveChallengeCore] ${challengeId} �?DONE.`);

  return { outcome, seriesNo, seriesWinnerUid, seriesPrizePaid };
}

exports.resolveChallengeOutcome = onDocumentUpdated(
  {
    document: 'challenges/{challengeId}',
    // NOTE: the region below MUST match the Firestore database location
    // (firebase.json: firestore.location). A Firestore trigger deployed to a
    // region that doesn't match the database silently never receives events.
    // The trigger still "deploys" successfully, but is never invoked.
    // Confirm your actual database location (Firebase Console �?Firestore �?Settings)
    // and make sure this matches it EXACTLY.
    // All other functions in this file (HTTP callables / schedules) are not
    // region-sensitive and can use any region independently of the DB location.
    region: 'europe-west1',
  },
  async (event) => {
    const challengeId = event.params.challengeId;
    console.log(`[resolveChallengeOutcome] 🔔 Triggered for: ${challengeId}`);

    const before = event.data.before.data();
    const after  = event.data.after.data();

    if (!before || !after) {
      console.log(`[resolveChallengeOutcome] ${challengeId} �?missing data, skipping.`);
      return null;
    }

    // Idempotency guard
    if (after.resolved === true) {
      console.log(`[resolveChallengeOutcome] ${challengeId} �?already resolved, skipping.`);
      return null;
    }

    // Ghost challenges are fully resolved by submitQuickMatchResult
    if (after.opponentUid === 'ghost') {
      console.log(`[resolveChallengeOutcome] ${challengeId} �?ghost, skipping.`);
      return null;
    }

    // Check if both scores are now present
    const bothNow = after.creatorScore != null && after.opponentScore != null;
    if (!bothNow) {
      // Exactly one side has played so far. Record that as an explicit
      // status (creator_submitted / opponent_submitted) rather than leaving
      // the document at 'opponent_joined' �?the Lobby UI already has copy
      // and _canPlay logic that key off these two statuses, and the hourly
      // expiredChallengeRefund sweep queries for them directly, so leaving
      // this transition unwritten made both effectively dead paths.
      // Guards against a loop: once the doc holds a *_submitted status, a later
      // trigger event finds partialStatus null and writes nothing.
      let partialStatus = null;
      // Promote on the first score landing from EITHER the joined state or the
      // bare invite state. A creator is pushed straight into the quiz by
      // createChallenge and routinely finishes before the invitee accepts, so
      // 'waiting' + one score is a NORMAL state; leaving it as 'waiting' hid the
      // "someone has played" fact from the UI and from the partial-forfeit
      // sweep. Promotion is idempotent: the next trigger event observes a
      // *_submitted status and writes nothing, so there is no loop.
      if (after.status === 'opponent_joined' || after.status === 'waiting') {
        if (after.creatorScore != null) partialStatus = 'creator_submitted';
        else if (after.opponentScore != null) partialStatus = 'opponent_submitted';
      }
      if (partialStatus) {
        // Stamp when the first score landed. forfeitStalePartialChallenges
        // uses this to auto-forfeit the silent side after
        // PARTIAL_FORFEIT_MINUTES (score -> 0) so the match settles
        // immediately instead of sitting unfinished until expiry.
        // serverTimestamp() may not settle inside a trigger write, so use a
        // local Date �?a few minutes of skew is harmless for a 15-minute
        // deadline, and the sweep clamps missing timestamps conservatively.
        await event.data.after.ref.update({
          status: partialStatus,
          firstSubmittedAt: new Date(),
        });
        // Your-turn nudge (best-effort): the silent side gets 15 minutes
        // before forfeit, so tell them now while it matters.
        const silentUid = partialStatus === 'creator_submitted'
          ? after.opponentUid
          : after.creatorUid;
        const playedName = partialStatus === 'creator_submitted'
          ? (after.creatorUsername || 'Your rival')
          : (after.opponentUsername || 'Your rival');
        if (silentUid && silentUid !== 'ghost') {
          sendToUser(silentUid, {
            title: `${playedName} played �?your turn!`,
            body: `Answer in the next 15 minutes or the duel auto-forfeits.`,
          }).catch((e) =>
            console.warn(`[resolveChallengeOutcome] turn notify failed (ignored): ${e.message}`)
          );
        }
      } else {
        console.log(`[resolveChallengeOutcome] ${challengeId} —not both scores yet. Creator: ${after.creatorScore}, Opponent: ${after.opponentScore}`);
      }
      return null;
    }

    console.log(`[resolveChallengeOutcome] ${challengeId} —both scores present! Proceeding...`);
    await _resolveChallengeCore(challengeId, event.data.after.ref, after);
    // Result notifications (best-effort): re-read the settled doc for the
    // outcome + bounty/series fields the core just wrote.
    try {
      const settled = (await event.data.after.ref.get()).data() || {};
      const cUid = after.creatorUid;
      const oUid = after.opponentUid;
      const cName = after.creatorUsername || 'Your rival';
      const oName = after.opponentUsername || 'Your rival';
      const isDraw = settled.outcome === 'draw';
      const cWon = settled.outcome === 'creator_wins';
      const extras = [
        settled.bountyWinnerUid ? 'Upset bounty claimed!' : '',
        settled.seriesWinnerUid
          ? `Series ${settled.seriesNo || ''} decided!`
          : '',
      ].filter(Boolean).join(' ');
      const cBody = isDraw
        ? `You drew ${oName}. ${extras}`.trim()
        : (cWon ? `You beat ${oName}! ${extras}`.trim() : `${oName} beat you. ${extras}`.trim());
      const oBody = isDraw
        ? `You drew ${cName}. ${extras}`.trim()
        : (!cWon ? `You beat ${cName}! ${extras}`.trim() : `${cName} beat you. ${extras}`.trim());
      const kind = settled.challengeType === 'spar' ? 'Spar result' : 'Duel result';
      await Promise.all([
        sendToUser(cUid, { title: `${kind}: ${isDraw ? 'Draw' : (cWon ? 'You won!' : 'You lost')}`, body: cBody }).catch(() => {}),
        oUid !== 'ghost'
          ? sendToUser(oUid, { title: `${kind}: ${isDraw ? 'Draw' : (!cWon ? 'You won!' : 'You lost')}`, body: oBody }).catch(() => {})
          : Promise.resolve(),
      ]);
    } catch (e) {
      console.warn(`[resolveChallengeOutcome] result notify failed (ignored): ${e.message}`);
    }
    return null;
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── forceResolveChallenge ──────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Manual safety-net: lets either participant force-resolve a challenge that
// has both scores in but never got picked up by the automatic trigger (e.g.
// during the period where the trigger was deployed to the wrong region).
// Uses the EXACT same payout logic as the trigger (_resolveChallengeCore) �?
// no duplicated/divergent math. Restricted to the challenge's own creator or
// opponent; anyone else gets rejected.
exports.forceResolveChallenge = onSecureCall(
  {
    region: 'us-central1',
    cpu: 0.5,
    memory: '256MiB',
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Sign in required.');
    await _assertClientBuildAllowed(request, 'forceResolveChallenge');

    const challengeId = request.data?.challengeId;
    if (!challengeId) {
      throw new HttpsError('invalid-argument', 'challengeId is required.');
    }

    const challengeRef = db.collection('challenges').doc(challengeId);
    const snap = await challengeRef.get();
    if (!snap.exists) {
      throw new HttpsError('not-found', 'Challenge not found.');
    }

    const data = snap.data();

    if (uid !== data.creatorUid && uid !== data.opponentUid) {
      throw new HttpsError('permission-denied', 'Not a participant in this challenge.');
    }

    if (data.resolved === true || data.status === 'completed') {
      return { alreadyResolved: true, outcome: data.outcome ?? null };
    }

    if (data.opponentUid === 'ghost') {
      throw new HttpsError('failed-precondition', 'Ghost matches resolve automatically.');
    }

    if (data.creatorScore == null || data.opponentScore == null) {
      throw new HttpsError(
        'failed-precondition',
        'Both players need to submit a score before this challenge can be resolved.'
      );
    }

    console.log(`[forceResolveChallenge] ${challengeId} �?manually triggered by ${uid}.`);
    const result = await _resolveChallengeCore(challengeId, challengeRef, data);
    return { alreadyResolved: false, outcome: result.outcome };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── repairRivalrySeries (admin, idempotent, dry-run first) ───────────────
// ─────────────────────────────────────────────────────────────────────────────
// Safest repair for wrong winsA/winsB counts (e.g. the old
// `if (creatorWins) winsA++` mapping that credited A whenever the creator
// won). Recomputes the CURRENT series from decisive ranked challenge docs
// and aligns the rivalry doc to that evidence. Never touches AC/WP balances
// or already-paid prizes �?only rivalries/{pair} wins/status/winner fields.
//
// Evidence per pair: completed challenges between aUid/bUid with
// challengeType=='rival' (legacy fallback: wpStake>0, not quick/spar) and
// outcome creator_wins/opponent_wins, grouped by stamped seriesNo. Only the
// group matching the rivalry's current seriesNo is counted. Docs without a
// usable seriesNo are ignored (not guessed). If no evidence exists for the
// current series, the pair is reported as needsManualReview and NOT written.
exports.repairRivalrySeries = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }
    const dryRun = request.data?.dryRun !== false;
    const limit = Math.min(Math.max(Number(request.data?.limit) || 50, 1), 100);
    const onlyPair = typeof request.data?.pairId === 'string'
      ? request.data.pairId.trim()
      : '';

    let pairRefs = [];
    if (onlyPair) {
      const d = await db.collection('rivalries').doc(onlyPair).get();
      if (d.exists) pairRefs = [d.ref];
    } else {
      const snap = await db.collection('rivalries')
        .orderBy('__name__')
        .limit(limit)
        .get();
      pairRefs = snap.docs.map((d) => d.ref);
    }

    const changes = [];
    let checked = 0;
    for (const ref of pairRefs) {
      const snap = await ref.get();
      if (!snap.exists) continue;
      const r = snap.data() || {};
      const aUid = r.aUid;
      const bUid = r.bUid;
      if (typeof aUid !== 'string' || typeof bUid !== 'string' || !aUid || !bUid) {
        changes.push({ pairId: ref.id, action: 'skip_bad_doc' });
        continue;
      }
      checked++;
      const curSeries = Number(r.seriesNo) || 1;
      const curA = Number(r.winsA) || 0;
      const curB = Number(r.winsB) || 0;
      const curStatus = r.status || 'active';

      // Evidence: both directions, single-field queries only (no new index).
      const [asA, asB] = await Promise.all([
        db.collection('challenges').where('creatorUid', '==', aUid).limit(100).get(),
        db.collection('challenges').where('creatorUid', '==', bUid).limit(100).get(),
      ]);
      let evA = 0;
      let evB = 0;
      let evCount = 0;
      for (const doc of [...asA.docs, ...asB.docs]) {
        const c = doc.data() || {};
        const cA = c.creatorUid;
        const cO = c.opponentUid;
        const isPair = (cA === aUid && cO === bUid) || (cA === bUid && cO === aUid);
        if (!isPair) continue;
        if (c.status !== 'completed' && c.resolved !== true) continue;
        const cType = c.challengeType ||
          (c.isQuickMatch ? 'quick' : ((Number(c.wpStake) || 0) > 0 ? 'rival' : 'code'));
        if (cType !== 'rival') continue;
        if (c.outcome !== 'creator_wins' && c.outcome !== 'opponent_wins') continue;
        const cSeries = Number(c.seriesNo) || 0;
        if (cSeries !== curSeries) continue;
        evCount++;
        const winner = c.outcome === 'creator_wins' ? cA : cO;
        if (winner === aUid) evA++;
        else if (winner === bUid) evB++;
      }

      if (evCount === 0) {
        changes.push({
          pairId: ref.id, action: 'needsManualReview',
          reason: 'no_decisive_rival_challenges_for_current_series',
          current: { seriesNo: curSeries, winsA: curA, winsB: curB, status: curStatus },
        });
        continue;
      }
      // A valid first-to-3 series holds at most 5 decisive games and can
      // never have both sides at 3+. Either pattern means overlapping or
      // mis-stamped evidence �?flag, never auto-fix.
      if (evCount > 5 || (evA >= SERIES_WINS_REQUIRED && evB >= SERIES_WINS_REQUIRED)) {
        changes.push({
          pairId: ref.id, action: 'needsManualReview',
          reason: 'ambiguous_series_evidence',
          current: { seriesNo: curSeries, winsA: curA, winsB: curB, status: curStatus },
          evidence: { winsA: evA, winsB: evB, challenges: evCount },
        });
        continue;
      }
      const wantStatus = (evA >= SERIES_WINS_REQUIRED || evB >= SERIES_WINS_REQUIRED)
        ? 'decided'
        : 'active';
      const wantWinner = wantStatus === 'decided'
        ? (evA >= SERIES_WINS_REQUIRED ? aUid : bUid)
        : null;
      const same = curA === evA && curB === evB && curStatus === wantStatus &&
        (r.seriesWinnerUid || null) === wantWinner;
      if (same) {
        changes.push({ pairId: ref.id, action: 'ok' });
        continue;
      }
      const patch = {
        winsA: evA,
        winsB: evB,
        status: wantStatus,
        seriesWinnerUid: wantWinner,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (!dryRun) {
        await ref.set(patch, { merge: true });
      }
      changes.push({
        pairId: ref.id,
        action: dryRun ? 'would_fix' : 'fixed',
        before: { winsA: curA, winsB: curB, status: curStatus, seriesWinnerUid: r.seriesWinnerUid || null },
        after: { winsA: evA, winsB: evB, status: wantStatus, seriesWinnerUid: wantWinner },
        evidenceChallenges: evCount,
      });
    }
    console.log(`[repairRivalrySeries] dryRun=${dryRun} checked=${checked} pairs=${pairRefs.length}`);
    return { success: true, dryRun, checked, pairs: pairRefs.length, changes };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── expireStaleRivalries (daily) ───────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Active series with updatedAt older than RIVALRY_EXPIRY_MS become 'expired':
// no winner, no prize. The next ranked duel restarts like after 'decided'
// (seriesNo+1 at 0-0). Requires the (status ASC, updatedAt ASC) composite
// index in firestore.indexes.json.
exports.expireStaleRivalries = onSchedule(
  {
    schedule: '0 2 * * *',
    timeZone: 'UTC',
    region: 'us-central1',
    timeoutSeconds: 300,
    memory: '256MiB',
  },
  async () => {
    const cutoff = new Date(Date.now() - RIVALRY_EXPIRY_MS);
    const snap = await db.collection('rivalries')
      .where('status', '==', 'active')
      .where('updatedAt', '<=', Timestamp.fromDate(cutoff))
      .orderBy('updatedAt')
      .limit(RIVALRY_EXPIRY_BATCH)
      .get();
    let expired = 0;
    for (const doc of snap.docs) {
      try {
        await doc.ref.set({
          status: 'expired',
          seriesWinnerUid: null,
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        expired++;
      } catch (err) {
        console.error(`[expireStaleRivalries] ERROR on ${doc.id}:`, err);
      }
    }
    console.log(`[expireStaleRivalries] Expired ${expired} stale rivalr(ies).`);
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── forfeitStalePartialChallenges ─────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// If exactly ONE side has submitted a score and the other has been silent for
// PARTIAL_FORFEIT_MINUTES, record the silent side's score as 0 and let the
// existing resolveChallengeOutcome trigger settle the match normally
// (completer wins, stake payout + stats as usual). Symmetric: applies to a
// creator who quits just as much as to an opponent who quits.
//
// Why 0-score-and-resolve instead of refund-and-wait:
//   �?The player who actually finished gets their win immediately �?their AC
//     stake + bonus lands, gamesPlayed / win-loss stats update, and the match
//     appears in history as a real result.
//   �?Both players' active-challenge slots free up right away (status leaves
//     ACTIVE_CHALLENGE_STATUSES once resolved) instead of being blocked by a
//     ghost match for the remaining expiry window.
//   �?The quitter forfeits �?that's the cost of walking away mid-game, which
//     is exactly the behaviour players asked to stop "wasting time."
//
// firstSubmittedAt is stamped by resolveChallengeOutcome the moment the first
// side's score lands (client writes creatorScore/opponentScore directly to the
// challenge doc, so no client change is needed here). Documents without that
// field (pre-deploy legacy partials) are skipped �?expiredChallengeRefund
// still catches those at expiry.
//
// Runs every 5 minutes so a 15-minute abandonment is caught within ~20 min
// worst case, never later than the hourly expired-sweep that used to be the
// only backstop.
exports.forfeitStalePartialChallenges = onSchedule(
  {
    schedule: '*/5 * * * *',
    region:   'us-central1',
    timeoutSeconds: 120,
    memory:         '256MiB',
  },
  async () => {
    const cutoff = Timestamp.fromDate(
      new Date(Date.now() - PARTIAL_FORFEIT_MINUTES * 60 * 1000)
    );

    const snap = await db.collection('challenges')
      .where('status', 'in', ['creator_submitted', 'opponent_submitted'])
      .where('firstSubmittedAt', '<=', cutoff)
      .get();

    let forfeited = 0;
    for (const doc of snap.docs) {
      const d = doc.data();
      if (d.resolved === true || d.opponentUid === 'ghost') continue;

      // Safety: only act while EXACTLY one score is missing. If both landed
      // in the meantime, the trigger already resolved (or will) �?skip.
      const missingCreator  = d.creatorScore  == null;
      const missingOpponent = d.opponentScore == null;
      if (!missingCreator === !missingOpponent) continue;

      // Only forfeit a seat that was actually JOINED (both stakes paid). With
      // the promote-on-'waiting' change, a creator_submitted challenge may not
      // have an opponent yet; writing opponentScore=0 there would settle the
      // match and mint a payout for an opponent who never staked anything.
      if (missingOpponent && !d.joinedAt) continue;

      const scoreField = missingCreator ? 'creatorScore' : 'opponentScore';
      const quitUid    = missingCreator ? d.creatorUid : d.opponentUid;

      try {
        await doc.ref.update({ [scoreField]: 0, forfeitedUid: quitUid });
        // The update above fires resolveChallengeOutcome �?_resolveChallengeCore,
        // which settles payouts/stats and flips status to 'completed'.
        console.log(
          `[forfeitStalePartialChallenges] ${doc.id} �?${scoreField} set to 0 for ${quitUid} (silent >${PARTIAL_FORFEIT_MINUTES}m); resolving normally.`
        );
        forfeited++;
      } catch (err) {
        console.error(`[forfeitStalePartialChallenges] ERROR on ${doc.id}:`, err);
      }
    }

    if (forfeited > 0) {
      console.log(`[forfeitStalePartialChallenges] Forfeited ${forfeited} stale partial challenge(s).`);
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── expireAbandonedQuickMatches ───────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// A ghost match is reserved (and its token consumed) the moment matchmaking
// succeeds: the challenge doc is created with status 'ghost' and a 1-hour
// expiresAt. Nothing else ever touches that status �?the forfeit and expiry
// sweeps only look at the staked statuses �?so an abandoned quick match used to
// linger forever AND its ghost recording stayed spliced out of the pool (ghosts
// are removed at reserve and never returned). Enough abandons and matchmaking
// runs dry. This sweep settles them and hands the recording back.
exports.expireAbandonedQuickMatches = onSchedule(
  {
    schedule: '*/10 * * * *',
    region:   'us-central1',
    timeoutSeconds: 120,
    memory:         '256MiB',
  },
  async () => {
    const now = Timestamp.now();
    const snap = await db.collection('challenges')
      .where('status', '==', 'ghost')
      .where('expiresAt', '<=', now)
      .limit(200)
      .get();

    let returned = 0;
    for (const doc of snap.docs) {
      const d = doc.data();
      const animeTitle  = typeof d.animeTitle === 'string' ? d.animeTitle : '';
      const qIds        = Array.isArray(d.questionIds) ? d.questionIds : [];
      const ghostRef    = animeTitle
        ? db.collection('ghost_sessions').doc(animeTitle)
        : null;
      try {
        await db.runTransaction(async (tx) => {
          // Idempotency: touch only a doc still in 'ghost' and not yet settled
          // by submitQuickMatchResult (which writes 'completed' + resolved).
          const refs = [tx.get(doc.ref)];
          if (ghostRef) refs.push(tx.get(ghostRef));
          const [freshSnap, ghostSnap] = await Promise.all(refs);
          const fresh = freshSnap.data() || {};
          if (!freshSnap.exists || fresh.status !== 'ghost' || fresh.resolved === true) {
            return;
          }

          if (ghostRef && qIds.length === 10 &&
              typeof d.ghostSessionId === 'string' && d.ghostSessionId) {
            const sessions = Array.isArray(ghostSnap.data()?.sessions)
              ? [...ghostSnap.data().sessions]
              : [];
            const alreadyThere = sessions.some((s) => s?.sessionId === d.ghostSessionId);
            if (!alreadyThere) {
              if (sessions.length >= 20) sessions.shift();
              sessions.push({
                sessionId:   d.ghostSessionId,
                uid:         d.ghostUid ?? null,
                username:    d.ghostUsername || 'Ghost Opponent',
                questionIds: qIds.map(String),
                answers:     [],
                score:       Number.isInteger(d.ghostScore) ? d.ghostScore : 0,
                recordedAt:  Timestamp.now(),
              });
              tx.set(ghostRef, { sessions }, { merge: true });
              returned++;
            }
          }

          tx.update(doc.ref, { status: 'expired_refunded', resolved: true });
        });
      } catch (err) {
        console.error(`[expireAbandonedQuickMatches] ERROR on ${doc.id}:`, err);
      }
    }

    if (snap.size > 0) {
      console.log(
        `[expireAbandonedQuickMatches] Settled ${snap.size} abandoned quick ` +
        `match(es); returned ${returned} ghost recording(s) to the pool.`
      );
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── expiredChallengeRefund ─────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.expiredChallengeRefund = onSchedule(
  {
    schedule: '0 * * * *',
    region:   'us-central1',
    timeoutSeconds: 300,
    memory:         '256MiB',
  },
  async () => {
    const now = Timestamp.now();
    let processedCount = 0;

    // ── waiting challenges ──────────────────────────────────────────────
    const waitingSnap = await db.collection('challenges')
      .where('status', '==', 'waiting')
      .where('expiresAt', '<=', now)
      .get();
    for (const doc of waitingSnap.docs) {
      const data = doc.data();
      const stakeAmt = data.stakeAmount || 0;
      const wpStake = data.wpStake || 0;
      const creatorRef = db.collection('users').doc(data.creatorUid);
      try {
        await db.runTransaction(async (tx) => {
          // Idempotency: re-read the challenge INSIDE the tx so a concurrent
          // resolve/decline/join can never be refunded on top of its real
          // outcome. Only a doc still in the exact state this sweep queried is
          // settled �?otherwise the last write wins and money is duplicated.
          const [freshSnap, creatorSnap] = await Promise.all([
            tx.get(doc.ref),
            tx.get(creatorRef),
          ]);
          if (!freshSnap.exists || freshSnap.data()?.status !== 'waiting') return;
          const creatorData = creatorSnap.data() || {};
          tx.update(doc.ref, { status: 'expired_refunded', resolved: true });
          
          if (stakeAmt > 0) {
            const currentCoins = creatorData.animeCoins || 0;
            tx.update(creatorRef, { animeCoins: FieldValue.increment(stakeAmt) });
            const txLogRef = creatorRef.collection('coinTransactions').doc();
            tx.set(txLogRef, {
              type: 'refund_challenge_stake',
              delta: stakeAmt,
              balanceAfter: currentCoins + stakeAmt,
              timestamp: FieldValue.serverTimestamp(),
            });
          }
          
          if (wpStake > 0) {
            const currentWP = creatorData.weeklyPoints || 0;
            tx.update(creatorRef, { weeklyPoints: FieldValue.increment(wpStake) });
            const wpTxRef = creatorRef.collection('wpTransactions').doc();
            tx.set(wpTxRef, {
              type: 'refund_challenge_stake',
              delta: wpStake,
              balanceAfter: currentWP + wpStake,
              timestamp: FieldValue.serverTimestamp(),
            });
          }
        });
        processedCount++;
      } catch (err) {
        console.error(`[expiredChallengeRefund] ERROR on waiting ${doc.id}:`, err);
      }
    }

    // ── opponent_joined challenges ──────────────────────────────────────
    const joinedSnap = await db.collection('challenges')
      .where('status', '==', 'opponent_joined')
      .where('expiresAt', '<=', now)
      .get();
    for (const doc of joinedSnap.docs) {
      const data = doc.data();
      const stakeAmt = data.stakeAmount || 0;
      const wpStake = data.wpStake || 0;
      const creatorRef = db.collection('users').doc(data.creatorUid);
      const opponentRef = db.collection('users').doc(data.opponentUid);
      try {
        await db.runTransaction(async (tx) => {
          // Idempotency: re-read the challenge inside the tx and settle only if
          // it is STILL an un-joined, un-resolved opponent_joined doc. A
          // concurrent resolve/decline must never be refunded on top.
          const [freshSnap, creatorSnap, opponentSnap] = await Promise.all([
            tx.get(doc.ref),
            tx.get(creatorRef),
            tx.get(opponentRef),
          ]);
          if (!freshSnap.exists || freshSnap.data()?.status !== 'opponent_joined') return;
          const cData = creatorSnap.data() || {};
          const oData = opponentSnap.data() || {};
          tx.update(doc.ref, { status: 'expired_refunded', resolved: true });
          
          if (stakeAmt > 0) {
            const cCoins = cData.animeCoins || 0;
            const oCoins = oData.animeCoins || 0;
            tx.update(creatorRef, { animeCoins: FieldValue.increment(stakeAmt) });
            tx.update(opponentRef, { animeCoins: FieldValue.increment(stakeAmt) });
            
            const cTxRef = creatorRef.collection('coinTransactions').doc();
            tx.set(cTxRef, {
              type: 'refund_challenge_stake',
              delta: stakeAmt,
              balanceAfter: cCoins + stakeAmt,
              timestamp: FieldValue.serverTimestamp(),
            });
            const oTxRef = opponentRef.collection('coinTransactions').doc();
            tx.set(oTxRef, {
              type: 'refund_challenge_stake',
              delta: stakeAmt,
              balanceAfter: oCoins + stakeAmt,
              timestamp: FieldValue.serverTimestamp(),
            });
          }
          
          if (wpStake > 0) {
            const cWP = cData.weeklyPoints || 0;
            const oWP = oData.weeklyPoints || 0;
            tx.update(creatorRef, { weeklyPoints: FieldValue.increment(wpStake) });
            tx.update(opponentRef, { weeklyPoints: FieldValue.increment(wpStake) });
            
            const cWpTx = creatorRef.collection('wpTransactions').doc();
            tx.set(cWpTx, {
              type: 'refund_challenge_stake',
              delta: wpStake,
              balanceAfter: cWP + wpStake,
              timestamp: FieldValue.serverTimestamp(),
            });
            const oWpTx = opponentRef.collection('wpTransactions').doc();
            tx.set(oWpTx, {
              type: 'refund_challenge_stake',
              delta: wpStake,
              balanceAfter: oWP + wpStake,
              timestamp: FieldValue.serverTimestamp(),
            });
          }
        });
        processedCount++;
      } catch (err) {
        console.error(`[expiredChallengeRefund] ERROR on opponent_joined ${doc.id}:`, err);
      }
    }

    // ── partial_submitted challenges ────────────────────────────────────
    const partialSnap = await db.collection('challenges')
      .where('status', 'in', ['creator_submitted', 'opponent_submitted'])
      .where('expiresAt', '<=', now)
      .get();
    for (const doc of partialSnap.docs) {
      const data = doc.data();
      const stakeAmt = data.stakeAmount || 0;
      const wpStake = data.wpStake || 0;
      const creatorRef = db.collection('users').doc(data.creatorUid);
      const opponentRef = db.collection('users').doc(data.opponentUid);
      try {
        await db.runTransaction(async (tx) => {
          // Idempotency: settle only if the doc is STILL in one of the partial
          // states this sweep queried. A concurrent resolve (which writes
          // 'completed' + resolved) must never be refunded on top of its payout.
          const [freshSnap, creatorSnap, opponentSnap] = await Promise.all([
            tx.get(doc.ref),
            tx.get(creatorRef),
            tx.get(opponentRef),
          ]);
          const fresh = freshSnap.data() || {};
          if (!freshSnap.exists ||
              !['creator_submitted', 'opponent_submitted'].includes(fresh.status)) {
            return;
          }
          // Refund the opponent's stake ONLY when they actually joined and paid
          // it. A creator_submitted challenge whose invitee never accepted �?          // the normal shape now that a creator may play before the invitee
          // accepts �?has only the creator's stake to return.
          const refundOpponent = !!fresh.joinedAt &&
            !!data.opponentUid && data.opponentUid !== 'ghost';
          const cData = creatorSnap.data() || {};
          const oData = opponentSnap.data() || {};
          tx.update(doc.ref, { status: 'expired_refunded', resolved: true });

          if (stakeAmt > 0) {
            const cCoins = cData.animeCoins || 0;
            tx.update(creatorRef, { animeCoins: FieldValue.increment(stakeAmt) });
            tx.set(creatorRef.collection('coinTransactions').doc(), {
              type: 'refund_challenge_stake',
              delta: stakeAmt,
              balanceAfter: cCoins + stakeAmt,
              timestamp: FieldValue.serverTimestamp(),
            });
            if (refundOpponent) {
              const oCoins = oData.animeCoins || 0;
              tx.update(opponentRef, { animeCoins: FieldValue.increment(stakeAmt) });
              tx.set(opponentRef.collection('coinTransactions').doc(), {
                type: 'refund_challenge_stake',
                delta: stakeAmt,
                balanceAfter: oCoins + stakeAmt,
                timestamp: FieldValue.serverTimestamp(),
              });
            }
          }

          if (wpStake > 0) {
            const cWP = cData.weeklyPoints || 0;
            tx.update(creatorRef, { weeklyPoints: FieldValue.increment(wpStake) });
            tx.set(creatorRef.collection('wpTransactions').doc(), {
              type: 'refund_challenge_stake',
              delta: wpStake,
              balanceAfter: cWP + wpStake,
              timestamp: FieldValue.serverTimestamp(),
            });
            if (refundOpponent) {
              const oWP = oData.weeklyPoints || 0;
              tx.update(opponentRef, { weeklyPoints: FieldValue.increment(wpStake) });
              tx.set(opponentRef.collection('wpTransactions').doc(), {
                type: 'refund_challenge_stake',
                delta: wpStake,
                balanceAfter: oWP + wpStake,
                timestamp: FieldValue.serverTimestamp(),
              });
            }
          }
        });
        processedCount++;
      } catch (err) {
        console.error(`[expiredChallengeRefund] ERROR on ${doc.data().status} ${doc.id}:`, err);
      }
    }

    console.log(
      `[expiredChallengeRefund] Processed ${processedCount} expired challenge(s).` +
      ` (waiting: ${waitingSnap.size}, opponent_joined: ${joinedSnap.size},` +
      ` partial_submitted: ${partialSnap.size})`
    );
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── cleanupExpiredQuizRuns ──────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Server-minted runs are small but permanent unless swept. A submitted run is
// kept for 24h after expiry so a late retry can still return its stored result;
// after that it has no reader (challenge results live on the challenge doc,
// solo/gauntlet results in users/{uid}/quizSessions). Deletes in bounded
// batches so a backlog cannot blow the function timeout.
const QUIZ_RUN_RETENTION_MS = 24 * 60 * 60 * 1000;
const QUIZ_RUN_CLEANUP_BATCH = 400;
const QUIZ_RUN_CLEANUP_MAX_BATCHES = 20;

exports.cleanupExpiredQuizRuns = onSchedule(
  {
    schedule:       'every 6 hours',
    timeZone:       'UTC',
    region:         'us-central1',
    timeoutSeconds: 540,
    memory:         '256MiB',
  },
  async () => {
    const cutoff = Timestamp.fromMillis(Date.now() - QUIZ_RUN_RETENTION_MS);
    let deleted = 0;

    for (let batchNum = 0; batchNum < QUIZ_RUN_CLEANUP_MAX_BATCHES; batchNum++) {
      const snap = await db.collection(QUIZ_RUNS)
        .where('expiresAt', '<', cutoff)
        .limit(QUIZ_RUN_CLEANUP_BATCH)
        .get();
      if (snap.empty) break;

      const batch = db.batch();
      for (const doc of snap.docs) batch.delete(doc.ref);
      await batch.commit();
      deleted += snap.size;

      if (snap.size < QUIZ_RUN_CLEANUP_BATCH) break;
    }

    console.log(
      `[cleanupExpiredQuizRuns] deleted=${deleted} cutoff=${cutoff.toMillis()}`
    );
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── NEW: getHeadToHeadRecord ──────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.getHeadToHeadRecord = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    // Gate must precede argument validation: otherwise an old APK sending an
    // incomplete payload gets 'missing_uids' instead of the update prompt and
    // the user is stuck with no way forward.
    await _assertClientBuildAllowed(request, 'getHeadToHeadRecord');

    const { uid1, uid2 } = request.data;
    if (!uid1 || !uid2) {
      throw new HttpsError('invalid-argument', 'missing_uids');
    }

    // Query matches from uid1's perspective where opponentUid == uid2
    const snap1 = await db.collection('users').doc(uid1).collection('matches')
      .where('opponentUid', '==', uid2)
      .get();

    // Also query from uid2's perspective where opponentUid == uid1
    const snap2 = await db.collection('users').doc(uid2).collection('matches')
      .where('opponentUid', '==', uid1)
      .get();

    let wins = 0, losses = 0, draws = 0;
    
    // From uid1's perspective (uid1 vs uid2)
    for (const doc of snap1.docs) {
      const data = doc.data();
      if (data.challengeType === 'spar') continue; // spars never count
      if (data.outcome === 'win') wins++;
      else if (data.outcome === 'lose') losses++;
      else if (data.outcome === 'draw') draws++;
    }
    
    // From uid2's perspective (uid2 vs uid1) - invert the results
    for (const doc of snap2.docs) {
      const data = doc.data();
      if (data.challengeType === 'spar') continue; // spars never count
      if (data.outcome === 'win') losses++; // uid2 won = uid1 lost
      else if (data.outcome === 'lose') wins++; // uid2 lost = uid1 won
      else if (data.outcome === 'draw') draws++;
    }

    return { wins, losses, draws };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 2B: FRIENDS (friends-core batch) ───────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Friends model (per approved spec):
//   friendships/{sortedUidPair}: {aUid, bUid, status ('pending'|'active'|
//     'declined'|'blocked'), requestedBy, declinedAt?, blockedBy?, sparWinsDate, sparWinsCount,
//     lastNudgeAt {sender_receiver: ts}, createdAt, decidedAt}
//   users/{uid}/friendLinks/{otherUid}: {otherUid, status ('incoming'|
//     'outgoing'|'friend'|'blocked'), username, since}
//   friendCodes/{CODE}: {uid}  (CF-only lookup; clients resolve via
//     sendFriendRequest so the code space is never enumerable)
// Caps: 50 friends (enforced on accept), 10 outgoing requests/day (WAT,
// new requests only �?cancel does not refund), 20 pending incoming max,
// 15 failed code lookups/day. No username search. All writes CF-only
// (firestore.rules denies client writes to all three).
const FRIEND_MAX = 50;
const FRIEND_OUTGOING_PER_DAY = 10;
const FRIEND_INCOMING_MAX = 20;
const FRIEND_CODE_ATTEMPTS_PER_DAY = 15;
const FRIEND_USERNAME_MAX = 30;
// After a decline, the same requester can't re-send to that player for a week.
const FRIEND_DECLINE_COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;
const FRIEND_UNIS = [
  'UNILAG', 'UI (University of Ibadan)', 'OAU', 'FUTA', 'UNIABUJA',
  'UNIBEN', 'ABU Zaria', 'UNIPORT', 'NOUN', 'Babcock', 'Other',
];

function _friendPairId(a, b) {
  const pair = [String(a), String(b)].sort();
  return `${pair[0]}_${pair[1]}`;
}

function _sanitizeFriendUsername(raw) {
  const s = (typeof raw === 'string' ? raw : 'Anonymous').trim();
  const cut = s.length > FRIEND_USERNAME_MAX ? s.slice(0, FRIEND_USERNAME_MAX) : s;
  return cut || 'Anonymous';
}

function _sanitizeFriendUniversity(raw) {
  return FRIEND_UNIS.includes(raw) ? raw : '';
}

// Same cohort as the Add Friend campus suggestions: same university and both
// in the current leaderboard week.
function _isSameCampusCohort(me, peer, weekId) {
  const uni = typeof me.university === 'string' ? me.university : '';
  return uni !== '' &&
    peer.university === uni &&
    peer.leaderboardEntryWeekId === weekId;
}

// Same paid leaderboard week (the Rankings board cohort). Tapping a board row
// opens that player's Rivalry page, and the page offers Add friend — so the
// uid path must accept a fellow payer even from another campus or with no
// shared match yet. No enumeration: the caller already saw the uid on a board
// they paid to read, and unknown/blocked still return the fixed not_found.
function _isSamePaidCohort(me, peer, weekId) {
  return typeof me.leaderboardEntryWeekId === 'string' &&
    me.leaderboardEntryWeekId === weekId &&
    peer.leaderboardEntryWeekId === weekId;
}

// Writes an accepted friendship. Caller must have read meSnap/peerSnap and must
// not read again in the same transaction.
function _activateFriendshipTx(tx, { uid, peer, pairRef, meRef, peerRef, meSnap, peerSnap }) {
  const meCount = Number((meSnap.data() || {}).friendCount || 0);
  const peerCount = Number((peerSnap.data() || {}).friendCount || 0);
  const now = FieldValue.serverTimestamp();
  tx.set(pairRef, { status: 'active', decidedAt: now }, { merge: true });
  tx.set(meRef.collection('friendLinks').doc(peer), {
    otherUid: peer, status: 'friend',
    username: _sanitizeFriendUsername(peerSnap.data().username),
    since: now,
  });
  tx.set(peerRef.collection('friendLinks').doc(uid), {
    otherUid: uid, status: 'friend',
    username: _sanitizeFriendUsername((meSnap.data() || {}).username),
    since: now,
  });
  tx.set(meRef, { friendCount: meCount + 1 }, { merge: true });
  tx.set(peerRef, { friendCount: peerCount + 1 }, { merge: true });
}

// Lazily mints + returns the caller's friend code. Idempotent: an existing
// code is returned as-is. Retries on CODE collision (same loop shape as the
// challenge shareCode loop in createChallenge).
async function _getOrMintFriendCode(uid, tx) {
  const userRef = db.collection('users').doc(uid);
  const snap = await tx.get(userRef);
  const data = snap.exists ? (snap.data() || {}) : {};
  if (typeof data.friendCode === 'string' && data.friendCode.length === 6) {
    return data.friendCode;
  }
  for (let i = 0; i < 5; i++) {
    const code = _generateCode();
    const codeRef = db.collection('friendCodes').doc(code);
    const codeSnap = await tx.get(codeRef);
    if (codeSnap.exists) continue;
    tx.set(codeRef, { uid, createdAt: FieldValue.serverTimestamp() });
    tx.set(userRef, { friendCode: code }, { merge: true });
    return code;
  }
  throw new HttpsError('internal', 'code_mint_failed');
}

exports.getMyFriendCode = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'getMyFriendCode');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const todayWAT = _watDateString();
    let code = '';
    await db.runTransaction(async (tx) => {
      code = await _getOrMintFriendCode(uid, tx);
    });
    return { friendCode: code, todayWAT };
  }
);

exports.sendFriendRequest = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'sendFriendRequest');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const { code, uid: rawUid } = request.data || {};
    const todayWAT = _watDateString();

    // Resolve target uid: code path goes through the CF-only friendCodes
    // collection (never client-readable); uid path is accepted for
    // campus-suggestion rows (uids the caller already legitimately saw).
    let targetUid = null;
    let viaUid = false;
    if (typeof code === 'string' && code.trim().length === 6) {
      const clean = code.trim().toUpperCase();
      // Failed-lookup rate limit (15/day, WAT) �?counted before lookup so
      // enumeration grinding is throttled. Cancel does not refund; failures
      // do not consume the outgoing-request budget.
      // Budget check, code lookup and miss-count in one transaction so parallel
      // guesses can't all slip under the ceiling.
      const found = await db.runTransaction(async (tx) => {
        const userRef = db.collection('users').doc(uid);
        const [mePre, codeSnap] = await Promise.all([
          tx.get(userRef),
          tx.get(db.collection('friendCodes').doc(clean)),
        ]);
        const mePreData = mePre.exists ? (mePre.data() || {}) : {};
        const attempts = (mePreData.failedCodeDate === todayWAT)
          ? Number(mePreData.failedCodeCount || 0) : 0;
        if (attempts >= FRIEND_CODE_ATTEMPTS_PER_DAY) {
          throw new HttpsError('resource-exhausted', 'too_many_attempts');
        }
        if (!codeSnap.exists) {
          tx.set(userRef, {
            failedCodeDate: todayWAT,
            failedCodeCount: attempts + 1,
          }, { merge: true });
          return null;
        }
        return codeSnap.data().uid;
      });
      // Fixed message for unknown AND blocked (no oracle).
      if (!found) throw new HttpsError('not-found', 'not_found');
      targetUid = found;
    } else if (typeof rawUid === 'string' && rawUid.trim()) {
      targetUid = rawUid.trim();
      viaUid = true;
    } else {
      throw new HttpsError('invalid-argument', 'missing_code');
    }

    if (targetUid === uid) {
      throw new HttpsError('invalid-argument', 'cannot_friend_yourself');
    }

    const txResult = await db.runTransaction(async (tx) => {
      const meRef = db.collection('users').doc(uid);
      const peerRef = db.collection('users').doc(targetUid);
      const pairRef = db.collection('friendships').doc(_friendPairId(uid, targetUid));
      const [meSnap, peerSnap, pairSnap] = await Promise.all([
        tx.get(meRef), tx.get(peerRef), tx.get(pairRef),
      ]);
      if (!peerSnap.exists) throw new HttpsError('not-found', 'not_found');
      const me = meSnap.data() || {};
      const peerData = peerSnap.data() || {};
      // Raw-uid requests are limited to players the caller legitimately knows:
      // the same campus cohort as the Add Friend suggestions, the same paid
      // leaderboard week (Rankings board → Rivalry page → Add friend), or
      // someone they have actually played (the Rivalry page passes a uid from
      // real match history). Anything else is indistinguishable from unknown.
      if (viaUid && !_isSameCampusCohort(me, peerData, currentWeekId()) &&
          !_isSamePaidCohort(me, peerData, currentWeekId())) {
        const played = await tx.get(
          meRef.collection('matches')
            .where('opponentUid', '==', targetUid).limit(1)
        );
        if (played.empty) throw new HttpsError('not-found', 'not_found');
      }
      const existing = pairSnap.exists ? (pairSnap.data() || {}) : null;
      // Blocked either way �?same fixed message (no oracle).
      if (existing && existing.status === 'blocked') {
        throw new HttpsError('not-found', 'not_found');
      }
      const myLinkRef = meRef.collection('friendLinks').doc(targetUid);
      const myLinkSnap = await tx.get(myLinkRef);
      if (myLinkSnap.exists && myLinkSnap.data().status === 'blocked') {
        throw new HttpsError('not-found', 'not_found');
      }
      if (existing) {
        if (existing.status === 'active') {
          throw new HttpsError('already-exists', 'already_friends');
        }
        if (existing.status === 'pending' && existing.requestedBy === targetUid) {
          // They already asked us: sending back is an acceptance, not a second request.
          const meCount = Number(me.friendCount || 0);
          const peerCount = Number(peerData.friendCount || 0);
          if (meCount >= FRIEND_MAX) throw new HttpsError('resource-exhausted', 'friend_limit_reached');
          if (peerCount >= FRIEND_MAX) throw new HttpsError('resource-exhausted', 'peer_friend_limit');
          _activateFriendshipTx(tx, {
            uid, peer: targetUid, pairRef, meRef, peerRef, meSnap, peerSnap,
          });
          return { mutual: true };
        }
        if (existing.status === 'pending') {
          throw new HttpsError('already-exists', 'already_pending');
        }
        if (existing.status === 'declined' && existing.requestedBy === uid) {
          const declinedMs = existing.declinedAt?.toMillis?.() || 0;
          if (declinedMs && Date.now() - declinedMs < FRIEND_DECLINE_COOLDOWN_MS) {
            throw new HttpsError('failed-precondition', 'request_cooldown');
          }
        }
      }
      const meCount = Number(me.friendCount || 0);
      if (meCount >= FRIEND_MAX) {
        throw new HttpsError('resource-exhausted', 'friend_limit_reached');
      }
      if (Number(peerData.friendCount || 0) >= FRIEND_MAX) {
        throw new HttpsError('resource-exhausted', 'peer_friend_limit');
      }
      // Outgoing budget: new requests only (cancel does not refund �?the
      // counter only ever increments).
      const sent = (me.outgoingReqDate === todayWAT)
        ? Number(me.outgoingReqCount || 0) : 0;
      if (sent >= FRIEND_OUTGOING_PER_DAY) {
        throw new HttpsError('resource-exhausted', 'request_limit_reached');
      }
      // Incoming cap on the receiver (at most 20 pending).
      const incomingSnap = await db.collection('users').doc(targetUid)
        .collection('friendLinks').where('status', '==', 'incoming')
        .limit(FRIEND_INCOMING_MAX + 1).get();
      if (incomingSnap.size >= FRIEND_INCOMING_MAX) {
        throw new HttpsError('resource-exhausted', 'inbox_full');
      }
      const now = FieldValue.serverTimestamp();
      tx.set(pairRef, {
        aUid: [uid, targetUid].sort()[0],
        bUid: [uid, targetUid].sort()[1],
        status: 'pending',
        requestedBy: uid,
        createdAt: now,
      }, { merge: true });
      tx.set(myLinkRef, {
        otherUid: targetUid,
        status: 'outgoing',
        username: _sanitizeFriendUsername(peerSnap.data().username),
        since: now,
      });
      tx.set(peerRef.collection('friendLinks').doc(uid), {
        otherUid: uid,
        status: 'incoming',
        username: _sanitizeFriendUsername(me.username),
        since: now,
      });
      tx.update(meRef, {
        outgoingReqDate: todayWAT,
        outgoingReqCount: sent + 1,
      });
    });

    if (txResult && txResult.mutual) {
      try {
        const meDoc = await db.collection('users').doc(uid).get();
        await sendToUser(targetUid, {
          title: 'You are now friends!',
          body: `${_sanitizeFriendUsername(meDoc.data()?.username)} accepted your request.`,
          data: { type: 'friend_accepted' },
        });
      } catch (_) { /* ignored */ }
      return { success: true, status: 'active' };
    }

    // Friend-request notification (best-effort, never blocks).
    try {
      const meDoc = await db.collection('users').doc(uid).get();
      const inviter = _sanitizeFriendUsername(meDoc.data()?.username);
      await sendToUser(targetUid, {
        title: 'New friend request',
        body: `${inviter} wants to add you as a friend.`,
        data: { type: 'friend_request' },
      });
    } catch (_) { /* ignored */ }
    return { success: true, status: 'pending' };
  }
);

exports.respondFriendRequest = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'respondFriendRequest');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const { otherUid, accept } = request.data || {};
    if (typeof otherUid !== 'string' || !otherUid.trim()) {
      throw new HttpsError('invalid-argument', 'missing_uid');
    }
    const peer = otherUid.trim();
    await db.runTransaction(async (tx) => {
      const pairRef = db.collection('friendships').doc(_friendPairId(uid, peer));
      const pairSnap = await tx.get(pairRef);
      if (!pairSnap.exists) throw new HttpsError('not-found', 'not_found');
      const pair = pairSnap.data() || {};
      if (pair.status === 'blocked') throw new HttpsError('not-found', 'not_found');
      if (pair.status !== 'pending') {
        throw new HttpsError('failed-precondition', 'not_pending');
      }
      if (pair.requestedBy === uid) {
        throw new HttpsError('failed-precondition', 'cannot_accept_own_request');
      }
      const meRef = db.collection('users').doc(uid);
      const peerRef = db.collection('users').doc(peer);
      const myLinkRef = meRef.collection('friendLinks').doc(peer);
      const peerLinkRef = peerRef.collection('friendLinks').doc(uid);
      if (accept === true) {
        const [meSnap, peerSnap] = await Promise.all([
          tx.get(meRef), tx.get(peerRef),
        ]);
        if (!peerSnap.exists) throw new HttpsError('not-found', 'not_found');
        const meCount = Number((meSnap.data() || {}).friendCount || 0);
        const peerCount = Number((peerSnap.data() || {}).friendCount || 0);
        if (meCount >= FRIEND_MAX || peerCount >= FRIEND_MAX) {
          throw new HttpsError('resource-exhausted', 'friend_limit_reached');
        }
        _activateFriendshipTx(tx, {
          uid, peer, pairRef, meRef, peerRef, meSnap, peerSnap,
        });
      } else {
        // Keep the pair as 'declined' (no link, no count) so the requester's
        // cooldown can be enforced; their outgoing link is removed.
        tx.set(pairRef, {
          status: 'declined', declinedAt: FieldValue.serverTimestamp(),
          declinedBy: uid,
        }, { merge: true });
        tx.delete(myLinkRef);
        tx.delete(peerLinkRef);
      }
    });
    return { success: true };
  }
);

exports.cancelFriendRequest = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'cancelFriendRequest');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const { otherUid } = request.data || {};
    if (typeof otherUid !== 'string' || !otherUid.trim()) {
      throw new HttpsError('invalid-argument', 'missing_uid');
    }
    const peer = otherUid.trim();
    await db.runTransaction(async (tx) => {
      const pairRef = db.collection('friendships').doc(_friendPairId(uid, peer));
      const pairSnap = await tx.get(pairRef);
      if (!pairSnap.exists) throw new HttpsError('not-found', 'not_found');
      const pair = pairSnap.data() || {};
      if (pair.status !== 'pending' || pair.requestedBy !== uid) {
        throw new HttpsError('failed-precondition', 'not_your_outgoing_request');
      }
      tx.delete(pairRef);
      tx.delete(db.collection('users').doc(uid).collection('friendLinks').doc(peer));
      tx.delete(db.collection('users').doc(peer).collection('friendLinks').doc(uid));
      // Outgoing budget is NOT refunded (spec).
    });
    return { success: true };
  }
);

exports.blockUser = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'blockUser');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const { otherUid } = request.data || {};
    if (typeof otherUid !== 'string' || !otherUid.trim()) {
      throw new HttpsError('invalid-argument', 'missing_uid');
    }
    const peer = otherUid.trim();
    if (peer === uid) {
      throw new HttpsError('invalid-argument', 'cannot_friend_yourself');
    }
    const refunded = [];
    await db.runTransaction(async (tx) => {
      // All reads first: Firestore rejects a read after any write in a tx.
      const pairRef = db.collection('friendships').doc(_friendPairId(uid, peer));
      const meRef = db.collection('users').doc(uid);
      const peerRef = db.collection('users').doc(peer);
      const [pairSnap, meSnap, peerSnap] = await Promise.all([
        tx.get(pairRef), tx.get(meRef), tx.get(peerRef),
      ]);
      if (!peerSnap.exists) throw new HttpsError('not-found', 'not_found');
      const wasActive = pairSnap.exists &&
        (pairSnap.data() || {}).status === 'active';
      const now = FieldValue.serverTimestamp();
      tx.set(pairRef, {
        aUid: [uid, peer].sort()[0],
        bUid: [uid, peer].sort()[1],
        status: 'blocked',
        blockedBy: uid,
        createdAt: now,
      }, { merge: true });
      tx.set(db.collection('users').doc(uid).collection('friendLinks').doc(peer), {
        otherUid: peer, status: 'blocked',
        username: 'Blocked user', since: now,
      });
      // Blockee sees nothing: remove their link to me (unblock later
      // requires a fresh request).
      tx.delete(db.collection('users').doc(peer).collection('friendLinks').doc(uid));
      // Only a live friendship held a count slot: decrement both sides
      // (floor 0). Pending pairs never incremented, so they decrement nothing.
      if (wasActive) {
        for (const [ref, snap] of [[meRef, meSnap], [peerRef, peerSnap]]) {
          const n = Number((snap.data() || {}).friendCount || 0);
          if (n > 0) tx.set(ref, { friendCount: n - 1 }, { merge: true });
        }
      }
    });
    // Auto-decline pending INVITES between the pair + refund creators.
    // Joined/in-play challenges are left to expire/forfeit (spec). Queried per
    // direction so the pair's invites are found regardless of global volume.
    try {
      const [asCreator, asOpponent] = await Promise.all([
        db.collection('challenges').where('creatorUid', '==', uid)
          .where('opponentUid', '==', peer).where('status', '==', 'waiting')
          .limit(20).get(),
        db.collection('challenges').where('creatorUid', '==', peer)
          .where('opponentUid', '==', uid).where('status', '==', 'waiting')
          .limit(20).get(),
      ]);
      for (const doc of [...asCreator.docs, ...asOpponent.docs]) {
        try {
          await db.runTransaction(async (tx) => {
            const cSnap = await tx.get(doc.ref);
            if (!cSnap.exists || cSnap.data().status !== 'waiting') return;
            const stakeAmt = cSnap.data().stakeAmount || 0;
            const wpStake = cSnap.data().wpStake || 0;
            const creatorRef = db.collection('users').doc(cSnap.data().creatorUid);
            const creatorSnap = await tx.get(creatorRef);
            const creatorData = creatorSnap.data() || {};
            tx.update(doc.ref, {
              status: 'declined', declinedAt: FieldValue.serverTimestamp(),
              declinedBy: uid,
            });
            if (stakeAmt > 0) {
              tx.update(creatorRef, { animeCoins: FieldValue.increment(stakeAmt) });
              tx.set(creatorRef.collection('coinTransactions').doc(), {
                type: 'refund_challenge_stake', delta: stakeAmt,
                balanceAfter: (creatorData.animeCoins || 0) + stakeAmt,
                timestamp: FieldValue.serverTimestamp(),
              });
            }
            if (wpStake > 0) {
              tx.update(creatorRef, { weeklyPoints: FieldValue.increment(wpStake) });
              tx.set(creatorRef.collection('wpTransactions').doc(), {
                type: 'refund_challenge_stake', delta: wpStake,
                balanceAfter: (creatorData.weeklyPoints || 0) + wpStake,
                timestamp: FieldValue.serverTimestamp(),
              });
            }
          });
          refunded.push(doc.id);
        } catch (_) { /* per-challenge best-effort */ }
      }
    } catch (_) { /* best-effort */ }
    // Block telemetry (CF-only; doubles as the v1 abuse log �?no report flow).
    try {
      await db.collection('telemetry').doc('user_blocks')
        .collection('events').doc().set({
          blockedBy: uid, blockedUid: peer,
          timestamp: FieldValue.serverTimestamp(),
        });
    } catch (_) { /* ignored */ }
    return { success: true, autoDeclined: refunded.length };
  }
);

exports.unblockUser = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'unblockUser');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const { otherUid } = request.data || {};
    if (typeof otherUid !== 'string' || !otherUid.trim()) {
      throw new HttpsError('invalid-argument', 'missing_uid');
    }
    const peer = otherUid.trim();
    await db.runTransaction(async (tx) => {
      const myLinkRef = db.collection('users').doc(uid).collection('friendLinks').doc(peer);
      const myLinkSnap = await tx.get(myLinkRef);
      if (!myLinkSnap.exists || myLinkSnap.data().status !== 'blocked') {
        throw new HttpsError('not-found', 'not_blocked');
      }
      tx.delete(myLinkRef);
      // Remove the blocked pair doc too �?a fresh request is required later.
      tx.delete(db.collection('friendships').doc(_friendPairId(uid, peer)));
    });
    return { success: true };
  }
);

exports.removeFriend = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'removeFriend');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const { otherUid } = request.data || {};
    if (typeof otherUid !== 'string' || !otherUid.trim()) {
      throw new HttpsError('invalid-argument', 'missing_uid');
    }
    const peer = otherUid.trim();
    await db.runTransaction(async (tx) => {
      // All reads first: Firestore rejects a read after any write in a tx.
      const pairRef = db.collection('friendships').doc(_friendPairId(uid, peer));
      const meRef = db.collection('users').doc(uid);
      const peerRef = db.collection('users').doc(peer);
      const [pairSnap, meSnap, peerSnap] = await Promise.all([
        tx.get(pairRef), tx.get(meRef), tx.get(peerRef),
      ]);
      if (!pairSnap.exists || (pairSnap.data() || {}).status !== 'active') {
        throw new HttpsError('not-found', 'not_friends');
      }
      tx.delete(pairRef);
      tx.delete(meRef.collection('friendLinks').doc(peer));
      tx.delete(peerRef.collection('friendLinks').doc(uid));
      for (const [ref, snap] of [[meRef, meSnap], [peerRef, peerSnap]]) {
        const n = Number((snap.data() || {}).friendCount || 0);
        if (n > 0) tx.set(ref, { friendCount: n - 1 }, { merge: true });
      }
    });
    return { success: true };
  }
);

// ─── Friends board (no mirrors �?callable fan-in, zero writes) ──────────────
// Reads my friendLinks (status friend, limit 50), then Admin-reads each
// friend's user doc and returns ONLY sanitized, board-safe fields. Missing
// doc (deleted/banned) �?"Deleted user" row. weeklyPoints is exposed only
// when the friend's entryWeekId == the current week; otherwise null and the
// client renders "-". Client caches the result for the 6h window inside the
// existing leaderboard refresh �?no listeners, no new timers.
exports.getFriendsBoard = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'getFriendsBoard');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const linksSnap = await db.collection('users').doc(uid)
      .collection('friendLinks').where('status', '==', 'friend')
      .limit(FRIEND_MAX).get();
    if (linksSnap.empty) return { friends: [] };
    const weekId = currentWeekId();
    const todayWAT = _watDateString();
    const dayStart = _watDayStart(todayWAT);
    const peerIds = linksSnap.docs.map((d) => d.id);
    const [snaps, pairSnaps, turns, playedFlags] = await Promise.all([
      db.getAll(...peerIds.map((p) => db.collection('users').doc(p))),
      db.getAll(...peerIds.map((p) => db.collection('friendships').doc(_friendPairId(uid, p)))),
      _duelTurnsFor(uid),
      Promise.all(peerIds.map((p) => _playedSince(p, dayStart))),
    ]);
    // My nudge stamp per friend lives on the pair doc (keyed sender_receiver).
    const nudgedToday = new Set();
    pairSnaps.forEach((ps, i) => {
      const ts = (ps.data() || {}).lastNudgeAt?.[`${uid}_${peerIds[i]}`];
      if (ts?.toDate && _watDateString(ts.toDate()) === todayWAT) nudgedToday.add(peerIds[i]);
    });
    const playedToday = new Map(peerIds.map((p, i) => [p, playedFlags[i]]));
    // Ghost admin accounts never appear on a player's friends board.
    const friends = snaps
      .filter((s) => !isAdminAccountUid(s.id))
      .map((s) => {
        if (!s.exists) {
          return {
            uid: s.id, username: 'Deleted user', university: '',
            weeklyPoints: null, entryWeekId: null,
            theirTurn: false, myTurn: false, nudgedToday: false, playedToday: false,
          };
        }
        const d = s.data() || {};
        const entryWeekId = typeof d.leaderboardEntryWeekId === 'string'
          ? d.leaderboardEntryWeekId : null;
        return {
          uid: s.id,
          username: _sanitizeFriendUsername(d.username),
          university: _sanitizeFriendUniversity(d.university),
          weeklyPoints: entryWeekId === weekId
            ? Math.max(0, Number(d.weeklyPoints || 0) | 0) : null,
          entryWeekId,
          theirTurn: turns.theirTurn.has(s.id),
          myTurn: turns.myTurn.has(s.id),
          nudgedToday: nudgedToday.has(s.id),
          playedToday: playedToday.get(s.id) === true,
        };
      });
    return { friends };
  }
);

// ─── Preset social: nudge (social-preset batch) ────────────────────────────
// No free text anywhere: nudge bodies are server-templated (sender username +
// anime title, both sanitized). All writes CF-only (rules deny client
// challenge writes except own-score).

function _theirTurnOnChallenge(ch, me) {
  const status = ch.status;
  const creator = ch.creatorUid;
  const opp = ch.opponentUid;
  if (!['waiting', 'opponent_joined', 'creator_submitted', 'opponent_submitted'].includes(status)) return false;
  if (status === 'waiting') return opp === me && creator !== me;
  if (status === 'opponent_joined') {
    if (me === creator) return ch.creatorScore == null;
    if (me === opp) return ch.opponentScore == null;
    return false;
  }
  if (status === 'creator_submitted') return me === opp && ch.opponentScore == null;
  if (status === 'opponent_submitted') return me === creator && ch.creatorScore == null;
  return false;
}

// Bounded read of the caller's duels, split by who owes the next move:
//   theirTurn �?peers who owe the caller a move (the caller can nudge them)
//   myTurn    �?peers the caller owes a move (the friend row says "Your move")
// The in-code check is the same one nudgeFriend enforces, so the board and the
// server agree.
async function _duelTurnsFor(uid) {
  const [asCreator, asOpponent] = await Promise.all([
    db.collection('challenges').where('creatorUid', '==', uid).limit(200).get(),
    db.collection('challenges').where('opponentUid', '==', uid).limit(200).get(),
  ]);
  const theirTurn = new Set();
  const myTurn = new Set();
  for (const d of [...asCreator.docs, ...asOpponent.docs]) {
    const c = d.data() || {};
    const peer = c.creatorUid === uid ? c.opponentUid : c.creatorUid;
    if (!peer || peer === 'ghost') continue;
    if (_theirTurnOnChallenge(c, peer)) theirTurn.add(peer);
    if (_theirTurnOnChallenge(c, uid)) myTurn.add(peer);
  }
  return { theirTurn, myTurn };
}

// Start of today in WAT (UTC+1, no DST), as a Date for timestamp queries.
function _watDayStart(todayWAT) {
  return new Date(Date.parse(`${todayWAT}T00:00:00Z`) - 60 * 60 * 1000);
}

// Did this player play a match (duel, spar or quick match) since [since]?
// Match docs are written at settlement with a server timestamp.
async function _playedSince(peerUid, since) {
  const snap = await db.collection('users').doc(peerUid).collection('matches')
    .where('timestamp', '>=', since).limit(1).get();
  return !snap.empty;
}

exports.nudgeFriend = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'nudgeFriend');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const { friendUid, challengeId } = request.data || {};
    if (typeof friendUid !== 'string' || !friendUid.trim()) {
      throw new HttpsError('invalid-argument', 'missing_uid');
    }
    const peer = friendUid.trim();
    if (peer === uid) throw new HttpsError('invalid-argument', 'cannot_friend_yourself');
    const todayWAT = _watDateString();

    // Friendship must be active (blocked pairs read 'blocked').
    const pairRef = db.collection('friendships').doc(_friendPairId(uid, peer));
    const pairSnap = await pairRef.get();
    const pair = pairSnap.exists ? (pairSnap.data() || {}) : {};
    if (pair.status !== 'active') {
      throw new HttpsError('failed-precondition', 'not_friends');
    }

    // Resolve the challenge: explicit id, or the latest their-turn duel
    // between the pair (bounded: 5 + 5 docs, in-code filter).
    let chId = (typeof challengeId === 'string' && challengeId.trim())
      ? challengeId.trim() : null;
    let ch = null;
    if (chId) {
      const snap = await db.collection('challenges').doc(chId).get();
      if (!snap.exists) throw new HttpsError('not-found', 'challenge_not_found');
      ch = snap.data() || {};
    } else {
      const [asC, asO] = await Promise.all([
        db.collection('challenges').where('creatorUid', '==', uid)
          .where('opponentUid', '==', peer).limit(5).get(),
        db.collection('challenges').where('creatorUid', '==', peer)
          .where('opponentUid', '==', uid).limit(5).get(),
      ]);
      const cands = [...asC.docs, ...asO.docs]
        .map((d) => ({ id: d.id, ...(d.data() || {}) }))
        .filter((c) => _theirTurnOnChallenge(c, peer))
        .sort((a, b) => {
          const at = a.createdAt?.toDate?.()?.getTime?.() || 0;
          const bt = b.createdAt?.toDate?.()?.getTime?.() || 0;
          return bt - at;
        });
      if (cands.length === 0) throw new HttpsError('failed-precondition', 'nothing_to_nudge');
      ch = cands[0];
      chId = cands[0].id;
    }

    // Must be a duel between the pair, and it must be THEIR turn.
    const isPair = (ch.creatorUid === uid && ch.opponentUid === peer) ||
      (ch.creatorUid === peer && ch.opponentUid === uid);
    if (!isPair) throw new HttpsError('failed-precondition', 'not_your_duel');
    if (!_theirTurnOnChallenge(ch, peer)) {
      throw new HttpsError('failed-precondition', 'not_their_turn');
    }

    // Once per friend per day (WAT), keyed sender_receiver on the pair doc.
    // The stamp is reserved in a transaction so parallel taps can't both pass,
    // then rolled back if the push does not go out, so a failed nudge does not
    // use up today's one.
    const nudgeKey = `${uid}_${peer}`;
    let prevStamp;
    await db.runTransaction(async (tx) => {
      const cur = ((await tx.get(pairRef)).data() || {});
      const lastMap = (cur.lastNudgeAt && typeof cur.lastNudgeAt === 'object')
        ? cur.lastNudgeAt : {};
      const lastTs = lastMap[nudgeKey];
      if (lastTs && lastTs.toDate && _watDateString(lastTs.toDate()) === todayWAT) {
        throw new HttpsError('resource-exhausted', 'nudge_limit_reached');
      }
      prevStamp = lastTs;
      tx.set(pairRef, {
        lastNudgeAt: { ...lastMap, [nudgeKey]: FieldValue.serverTimestamp() },
      }, { merge: true });
    });

    try {
      const meDoc = await db.collection('users').doc(uid).get();
      const sender = _sanitizeFriendUsername(meDoc.data()?.username);
      const anime = String(ch.animeTitle || 'your duel').slice(0, 40);
      await _sendPushOrThrow(peer, {
        title: 'Your turn!',
        body: `${sender} is waiting in ${anime}.`,
      });
    } catch (err) {
      console.warn(`[nudgeFriend] uid=${uid} peer=${peer} push failed, rolling back: ${err.message}`);
      await pairRef.update({
        [`lastNudgeAt.${nudgeKey}`]: prevStamp ?? FieldValue.delete(),
      }).catch((e) => console.error(`[nudgeFriend] rollback failed: ${e.message}`));
      throw new HttpsError('unavailable', 'nudge_not_delivered');
    }
    return { success: true, challengeId: chId };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 3: STREAK MILESTONES (unchanged) ─────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.awardStreakMilestone = onDocumentUpdated(
  { document: 'users/{uid}', region: 'europe-west1' },
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    if (!before || !after) return null;

    const prevStreak = before.currentStreak || 0;
    const newStreak  = after.currentStreak  || 0;
    if (newStreak <= prevStreak) return null;

    const lastAwarded = after.lastStreakMilestoneAwarded || 0;

    let award = 0;
    let milestone = 0;

    if (newStreak >= 14 && lastAwarded < 14) {
      award = 150; milestone = 14;
    } else if (newStreak >= 7 && lastAwarded < 7) {
      award = 60; milestone = 7;
    } else if (newStreak >= 3 && lastAwarded < 3) {
      award = 25; milestone = 3;
    }

    if (!award) return null;

    const uid     = event.params.uid;
    const userRef = db.collection('users').doc(uid);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const snapData = snap.data();
      if ((snapData.lastStreakMilestoneAwarded || 0) >= milestone) return;

      const currentCoins = snapData.animeCoins || 0;
      const newBalance   = currentCoins + award;

      tx.update(userRef, {
        animeCoins:                  FieldValue.increment(award),
        lastStreakMilestoneAwarded:  milestone,
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        milestone === 14 ? 'earn_streak_14'
                   : milestone === 7  ? 'earn_streak_7'
                   :                    'earn_streak_3',
        delta:       award,
        balanceAfter: newBalance,
        timestamp:   FieldValue.serverTimestamp(),
      });
    });

    console.log(`[awardStreakMilestone] uid=${uid} streak=${newStreak} �?+${award} AC (milestone ${milestone})`);
    return null;
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 4: REFERRAL BONUS ────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// ─── Referral records (users/{inviter}/referrals/{inviteeUid}) ─────────────
//
// Display data for the Referrals page only: created by ensureProfile at
// sign-up, progressed and flipped by claimReferralBonus. These records never
// gate a payout �?the quiz gate, the 30-day cap and the coin ledger in
// claimReferralBonus remain the sole authority.

// Full initial shape of one referral record. `status` only ever moves
// 'pending' -> 'rewarded' and is never reset by a re-run.
function _referralRecordDefaults(inviteeUsername) {
  return {
    inviteeUsername:  typeof inviteeUsername === 'string' ? inviteeUsername : null,
    status:           'pending',
    quizzesCompleted: 0,
    quizzesRequired:  3,   // mirrors the gate in claimReferralBonus
    quizDays:         0,
    daysRequired:     2,   // mirrors the gate in claimReferralBonus
    createdAt:        FieldValue.serverTimestamp(),
    qualifiedAt:      null,
    expiresAt:        Timestamp.fromMillis(Date.now() + 2 * 24 * 60 * 60 * 1000),
    rewardAmount:     100, // mirrors the +100 referrer payout
  };
}

// Upsert one referral record: missing doc -> full record, existing doc ->
// merge of the passed fields only, so createdAt / status / inviteeUsername
// always survive a re-run.
function _writeReferralRecord(tx, referralRef, referralSnap, inviteeUsername, fields) {
  if (referralSnap && referralSnap.exists) {
    tx.set(referralRef, fields, { merge: true });
  } else {
    tx.set(referralRef, { ..._referralRecordDefaults(inviteeUsername), ...fields });
  }
}

// ─── Referral cashout (NGN 5,000 for 20 qualifying invitees) ────────────────
//
// A QUALIFYING invitee is an account that (1) signed up with the referrer's
// code and (2) redeemed a leaderboard-entry code on that same account. The
// marker is written by redeemCode inside the activation transaction; the claim
// callable re-checks the invitee docs so a missed marker can never cost a
// legitimate player their reward.
//
// Money never comes from the weekly prize pool. Every submitted claim is
// encumbered in referralCashoutReserve/ledger (a separate budget the admin
// funds), so simultaneous claimants can never compete with leaderboard payouts.
const REFERRAL_CASHOUT_TARGET = 20;
const REFERRAL_CASHOUT_AMOUNT = 5000; // NGN, paid by hand by the admin
const REFERRAL_CASHOUT_MAX_REFERRALS = 500;
const REFERRAL_CASHOUT_READ_CHUNK = 50;
const REFERRAL_CASHOUT_RESERVE_PATH = ['referralCashoutReserve', 'ledger'];

function _referralCashoutReserveRef() {
  return db.collection(REFERRAL_CASHOUT_RESERVE_PATH[0])
    .doc(REFERRAL_CASHOUT_RESERVE_PATH[1]);
}

// Reads the inviter's referral rows and returns every qualifying invitee.
// Unmarked rows are checked against the invitee's own profile and healed, so
// accounts that activated an entry before this feature shipped still count.
async function _collectReferralCashoutEvidence(inviterUid) {
  const snap = await db.collection('users').doc(inviterUid)
    .collection('referrals')
    .limit(REFERRAL_CASHOUT_MAX_REFERRALS)
    .get();

  const qualifying = [];
  const unmarked = [];
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    if (data.leaderboardEntryPurchased === true) {
      qualifying.push({ uid: doc.id, data });
    } else {
      unmarked.push(doc);
    }
  }

  for (let i = 0; i < unmarked.length; i += REFERRAL_CASHOUT_READ_CHUNK) {
    const chunk = unmarked.slice(i, i + REFERRAL_CASHOUT_READ_CHUNK);
    const snaps = await Promise.all(chunk.map((doc) =>
      db.collection('users').doc(doc.id).get()));

    const batch = db.batch();
    let wrote = 0;
    snaps.forEach((inviteeSnap, idx) => {
      if (!inviteeSnap.exists) return;
      const invitee = inviteeSnap.data() || {};
      const weekId = typeof invitee.leaderboardEntryWeekId === 'string'
        ? invitee.leaderboardEntryWeekId
        : null;
      if (!weekId) return;

      const referral = chunk[idx];
      const buyerEmail = typeof invitee.leaderboardEntryEmail === 'string'
        ? invitee.leaderboardEntryEmail.trim().toLowerCase()
        : null;
      const fields = {
        leaderboardEntryPurchased: true,
        leaderboardEntryWeekId: weekId,
        leaderboardEntryBuyerEmail: buyerEmail || null,
        leaderboardEntryPurchasedAt: FieldValue.serverTimestamp(),
      };
      batch.set(referral.ref, fields, { merge: true });
      wrote++;
      qualifying.push({
        uid: referral.id,
        data: { ...(referral.data() || {}), ...fields },
      });
    });
    if (wrote > 0) {
      try {
        await batch.commit();
      } catch (err) {
        // Healing is best-effort: the claim still counts what was found.
        console.warn(`[referralCashout] marker heal failed: ${err.message}`);
      }
    }
  }

  return qualifying;
}

// Advisory-only fraud signals for the admin. Never blocks a claim: the admin
// makes the final call after reading the evidence.
async function _referralCashoutRiskFlags(inviterUid, qualifying) {
  const flags = [];

  const buyerCounts = new Map();
  let missingBuyer = 0;
  for (const q of qualifying) {
    const email = q.data.leaderboardEntryBuyerEmail;
    if (typeof email === 'string' && email.trim()) {
      const key = email.trim().toLowerCase();
      buyerCounts.set(key, (buyerCounts.get(key) || 0) + 1);
    } else {
      missingBuyer++;
    }
  }
  const sharedBuyers = [...buyerCounts.values()].filter((n) => n > 1);
  if (sharedBuyers.length > 0) {
    const total = sharedBuyers.reduce((sum, n) => sum + n, 0);
    flags.push(`${total} qualifying referrals share a buyer email`);
  }
  if (missingBuyer > 0) {
    flags.push(`${missingBuyer} qualifying referrals have no buyer email on record`);
  }

  // Same signup IP as the referrer (best-effort; telemetry is server-only).
  try {
    const signals = db.collection('telemetry').doc('account_signals')
      .collection('users');
    const inviterSnap = await signals.doc(inviterUid).get();
    const inviterIp = (inviterSnap.data() || {}).createdIp;
    if (typeof inviterIp === 'string' && inviterIp) {
      let sameIp = 0;
      for (let i = 0; i < qualifying.length; i += REFERRAL_CASHOUT_READ_CHUNK) {
        const chunk = qualifying.slice(i, i + REFERRAL_CASHOUT_READ_CHUNK);
        const snaps = await Promise.all(chunk.map((q) => signals.doc(q.uid).get()));
        for (const s of snaps) {
          if (s.exists && (s.data() || {}).createdIp === inviterIp) sameIp++;
        }
      }
      if (sameIp > 0) {
        flags.push(`${sameIp} qualifying invitees share the referrer's signup IP`);
      }
    }
  } catch (err) {
    console.warn(`[referralCashout] IP risk check skipped: ${err.message}`);
  }

  return flags;
}

// Mirrors the reusable payoutDetails upsert in submitPayoutDetails so the admin
// has the claimant's destination in the same place as a leaderboard winner's.
async function _recordReferralCashoutPayoutDetail(uid, payload, claimId) {
  const coll = db.collection('users').doc(uid).collection('payoutDetails');
  const existing = await coll
    .where('accountNumber', '==', payload.accountNumber)
    .limit(1)
    .get();

  const before = existing.empty ? null : existing.docs[0].data();
  let docId = '';
  if (!existing.empty) {
    docId = existing.docs[0].id;
    await existing.docs[0].ref.update({
      bankCode: payload.bankCode,
      bankName: payload.bankName || '',
      beneficiaryName: payload.beneficiaryName,
      updatedAt: FieldValue.serverTimestamp(),
    });
  } else {
    const created = await coll.add({
      accountNumber: payload.accountNumber,
      bankCode: payload.bankCode,
      bankName: payload.bankName || '',
      beneficiaryName: payload.beneficiaryName,
      updatedAt: FieldValue.serverTimestamp(),
      createdAt: FieldValue.serverTimestamp(),
    });
    docId = created.id;
  }

  await db.collection('payoutDetailAudit').add({
    uid,
    docId,
    action: before ? 'update' : 'create',
    source: 'claimReferralCashout',
    claimId,
    before: _payoutAuditSnapshot(before),
    after: _payoutAuditSnapshot(payload),
    at: FieldValue.serverTimestamp(),
  });
}

// ─── Referral codes (referralCodes/{CODE}: {uid}, CF-only) ──────────────────
//
// The invite artefact. A uid is 28 characters and cannot be read aloud or
// printed on a card, so the Referrals page mints and shows a 6-character code
// instead. The code RESOLVES TO A UID: `users/{uid}.referredBy` keeps storing
// the uid, so the claim gate, the referral records and the coin ledger are all
// untouched. A uid typed in by hand still works (see _resolveReferrerUid), so
// every referral created before this feature keeps working unchanged.
//
// referralCodes is never client-readable �?that would be a uid-enumeration
// oracle. The client resolves through resolveReferralCode. 36^6 �?2.17e9
// codes, so collisions are rare and retried in a short loop.

// Lazily mints + returns the caller's referral code. Stable: an existing code
// that still maps back to this user is returned as-is. Same shape as
// _getOrMintFriendCode.
async function _getOrMintReferralCode(uid, tx) {
  const userRef = db.collection('users').doc(uid);
  const snap = await tx.get(userRef);
  const data = snap.exists ? (snap.data() || {}) : {};
  const existing = data.referralCode;
  if (typeof existing === 'string' && existing.length === 6) {
    // Trust the cached field only if the code document still points back at
    // this user. A code deleted out-of-band would otherwise be displayed and
    // shared forever while resolving to nobody.
    const existingSnap = await tx.get(
      db.collection('referralCodes').doc(existing),
    );
    if (existingSnap.exists && (existingSnap.data() || {}).uid === uid) {
      return existing;
    }
  }
  for (let i = 0; i < 5; i++) {
    const code = _generateCode();
    const codeRef = db.collection('referralCodes').doc(code);
    const codeSnap = await tx.get(codeRef);
    if (codeSnap.exists) continue;
    tx.set(codeRef, { uid, createdAt: FieldValue.serverTimestamp() });
    tx.set(userRef, { referralCode: code }, { merge: true });
    return code;
  }
  throw new HttpsError('internal', 'code_mint_failed');
}

// Resolves a referral code OR a uid to an existing referrer's uid, else null.
//
// Used by resolveReferralCode (sign-up) and defensively by ensureProfile and
// claimReferralBonus, so a profile that somehow stores a raw code still credits
// the right person.
async function _resolveReferrerUid(raw) {
  const value = typeof raw === 'string' ? raw.trim() : '';
  if (!value) return null;

  // A '/' would make `.doc(value)` throw (an odd-segment path) instead of
  // returning "unknown". Nobody's uid or code contains one, so treat it as a
  // bad code rather than an exception on the sign-up path.
  if (value.includes('/')) return null;

  // 1) uid path. Uids are 28 chars and codes are 6, so the two can never
  // collide and trying the uid document first is unambiguous.
  const byUid = await db.collection('users').doc(value).get();
  if (byUid.exists) return value;

  // 2) short-code path.
  if (value.length !== 6) return null;
  const codeSnap = await db
    .collection('referralCodes').doc(value.toUpperCase()).get();
  const uid = codeSnap.exists ? (codeSnap.data() || {}).uid : null;
  if (!uid) return null;

  // A code doc can outlive its owner only if the deleteAccount cleanup failed.
  // There is no referrer to pay in that case, so report "unknown".
  const userSnap = await db.collection('users').doc(uid).get();
  return userSnap.exists ? uid : null;
}

// Transaction-safe twin of _resolveReferrerUid. All lookups are deterministic
// document reads, so it can run in the read phase of a transaction (redeemCode
// must stay one atom: the entry activation and the referral marker land
// together or not at all).
async function _resolveReferrerUidTx(tx, raw) {
  const value = typeof raw === 'string' ? raw.trim() : '';
  if (!value || value.includes('/')) return null;

  const byUid = await tx.get(db.collection('users').doc(value));
  if (byUid.exists) return value;

  if (value.length !== 6) return null;
  const codeSnap = await tx.get(
    db.collection('referralCodes').doc(value.toUpperCase()),
  );
  const uid = codeSnap.exists ? (codeSnap.data() || {}).uid : null;
  if (!uid) return null;

  const userSnap = await tx.get(db.collection('users').doc(uid));
  return userSnap.exists ? uid : null;
}

// The player's own invite code, minted on first open of the Referrals page.
exports.getMyReferralCode = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'getMyReferralCode');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    let code = '';
    await db.runTransaction(async (tx) => {
      code = await _getOrMintReferralCode(uid, tx);
    });
    return { referralCode: code };
  }
);

// Turns what the player typed on the sign-up form into the uid that gets
// stored in referredBy. Returns { uid: null } for anything unknown AND for the
// caller's own code, so the form can never distinguish a bad code from
// self-referral. Never throws for a bad code: a bad code just means no
// referral, and it must not fail registration.
exports.resolveReferralCode = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    await _assertClientBuildAllowed(request, 'resolveReferralCode');
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const { code } = request.data || {};
    const referrerUid = await _resolveReferrerUid(code);
    if (!referrerUid || referrerUid === uid) return { uid: null };
    return { uid: referrerUid };
  }
);

exports.claimReferralBonus = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    // The invitee (caller) must hold a verified email; the referrer needs no check.
    _assertEmailVerified(request, 'claimReferralBonus');

    const { referredBy } = request.data;
    if (typeof referredBy !== 'string' || !referredBy.trim()) {
      throw new Error('Invalid referredBy uid');
    }

    // referredBy normally holds a uid (the client resolves at sign-up), but a
    // short code is honored too so a value written by an older client keeps
    // working. Resolved before the transaction: a code's uid never changes, and
    // a lookup inside the transaction would add a read to the payout path.
    const referrerUid = await _resolveReferrerUid(referredBy);
    // Unknown referrer �?same outcome as the old `!referrerSnap.exists` early
    // return, and the same outcome for a referral whose code was retired.
    if (!referrerUid) return { success: true };

    const userRef     = db.collection('users').doc(uid);
    const referrerRef = db.collection('users').doc(referrerUid);
    const referralRef = referrerRef.collection('referrals').doc(uid);

    // ── Email verification + self-referral, re-checked at reward time ─────
    // The signup-time check alone is bypassable (verify later, or create the
    // referral before the device is known), so both are evaluated here too.
    const [inviteePreSnap, referrerPreSnap] = await Promise.all([
      userRef.get(),
      referrerRef.get(),
    ]);
    const inviteePre = inviteePreSnap.data() || {};
    const referrerPre = referrerPreSnap.data() || {};

    let selfReferral = false;
    if (inviteePre.emailNormalized && inviteePre.emailNormalized === referrerPre.emailNormalized) {
      selfReferral = true;
    }
    if (inviteePre.deviceHash && inviteePre.deviceHash === referrerPre.deviceHash) {
      selfReferral = true;
    }
    const claimIp = _clientIp(request);
    if (claimIp) {
      const referrerSignal = await db.collection('telemetry').doc('account_signals')
        .collection('users').doc(referrerUid).get();
      if ((referrerSignal.data() || {}).createdIp === claimIp) selfReferral = true;
    }
    if (selfReferral) {
      await _logAbuse({
        uid, ip: claimIp, reason: 'referral_self_account',
        fnName: 'claimReferralBonus', meta: { referrerUid },
      });
      return { success: true, blocked: 'self_referral' };
    }

    // ── Gate: the referred account must have completed �? quizzes across �?
    // different calendar (WAT) days before the bonus may fire. Counted from the
    // existing per-user quizSessions subcollection (each session carries a
    // server timestamp) �?no new per-quiz tracking fields.
    const sessionSnaps = await db.collection('users').doc(uid)
      .collection('quizSessions').get();
    const quizDays = new Set();
    for (const s of sessionSnaps.docs) {
      const ts = s.data().timestamp;
      if (ts && ts.toDate) quizDays.add(_watDateString(ts.toDate()));
    }
    const quizzesCompleted = sessionSnaps.docs.length;
    const quizDayCount     = quizDays.size;

    if (quizzesCompleted < 3 || quizDayCount < 2) {
      // Not enough quiz activity yet. Record the invitee's progress for the
      // inviter's Referrals page (display only), then leave the referral
      // economy untouched.
      await db.runTransaction(async (tx) => {
        const referralSnap = await tx.get(referralRef);
        if (referralSnap.exists
            && (referralSnap.data() || {}).status === 'rewarded') {
          return;
        }
        let username = null;
        if (!referralSnap.exists) {
          const inviteeSnap = await tx.get(userRef);
          username = (inviteeSnap.data() || {}).username;
        }
        _writeReferralRecord(tx, referralRef, referralSnap, username, {
          quizzesCompleted,
          quizDays: quizDayCount,
        });
      });
      return { success: true };
    }

    await db.runTransaction(async (tx) => {
      const [userSnap, referrerSnap, referralSnap] = await Promise.all([
        tx.get(userRef),
        tx.get(referrerRef),
        tx.get(referralRef),
      ]);

      const userData     = userSnap.data()     || {};
      const referrerData = referrerSnap.data() || {};

      if (userData.referralBonusClaimed === true) return;
      if (!referrerSnap.exists) return;
      if (referrerUid === uid) return;

      // ── Per-referrer cap: �?0 successful referral bonuses per rolling
      // 30-day window, tracked with a timestamp-array counter
      // referralBonusTimes so the window truly rolls (stale entries pruned).
      const now      = new Date();
      const cutoff   = now.getTime() - 30 * 24 * 60 * 60 * 1000;
      const occurred = (referrerData.referralBonusTimes || []).filter((t) => {
        const ms = t && t.getTime ? t.getTime()
          : (t && t.toDate ? t.toDate().getTime() : new Date(t).getTime());
        return ms >= cutoff;
      });
      // Referral record for the inviter's Referrals page. Display-only: final
      // progress plus 'rewarded' when the payout below runs, progress alone
      // (status untouched) when the cap blocks it. Written inside this
      // transaction so the record can never say 'rewarded' without the ledger
      // writes below.
      const capBlocked = occurred.length >= 10;
      _writeReferralRecord(tx, referralRef, referralSnap, userData.username, {
        quizzesCompleted,
        quizDays: quizDayCount,
        ...(capBlocked ? {} : {
          status:       'rewarded',
          qualifiedAt:  FieldValue.serverTimestamp(),
          rewardAmount: 100,
        }),
      });

      if (occurred.length >= 10) return; // cap reached �?no award, no penalty

      const userBalanceAfter     = (userData.animeCoins     || 0) + 50;
      const referrerBalanceAfter = (referrerData.animeCoins || 0) + 100;

      tx.update(userRef, {
        firstQuizCompleted:   true,
        referralBonusClaimed: true,
        // Normalize on the way through: a profile carrying a short code gets
        // upgraded to the uid, so the "referredBy is a uid" invariant holds
        // again for anything that reads it later.
        referredBy:           referrerUid,
        animeCoins:           FieldValue.increment(50),
      });

      const userTxRef = userRef.collection('coinTransactions').doc();
      tx.set(userTxRef, {
        type:         'earn_referral',
        delta:        50,
        balanceAfter: userBalanceAfter,
        timestamp:    FieldValue.serverTimestamp(),
      });

      tx.update(referrerRef, {
        animeCoins:         FieldValue.increment(100),
        referralBonusTimes: [...occurred, now],
      });

      const referrerTxRef = referrerRef.collection('coinTransactions').doc();
      tx.set(referrerTxRef, {
        type:         'earn_referral',
        delta:        100,
        balanceAfter: referrerBalanceAfter,
        timestamp:    FieldValue.serverTimestamp(),
      });
    });

    console.log(`[claimReferralBonus] uid=${uid} �?referrer=${referrerUid} +100 AC`);
    return { success: true };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── REFERRAL CASHOUT (NGN 5,000 / 20 qualifying invitees) ────────────────
// ─────────────────────────────────────────────────────────────────────────────
//
// Payouts stay MANUAL: the player submits a bank account, the admin transfers
// by hand and records it. The server is authoritative for qualification,
// amount and claim state.
//
// ISOLATION: a submitted claim is immediately encumbered in
// `referralCashoutReserve/ledger`, a budget separate from the weekly prize
// pool. Nothing here reads or writes `prize_pool` / `leaderboardCycles`, so
// several claimants at once can never reduce or compete with leaderboard
// prizes. If the budget is unfunded, `available` goes negative and the admin
// dashboard shows the exact top-up needed; the player's earned claim is never
// rejected because of the operator's bookkeeping.

exports.claimReferralCashout = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    _assertEmailVerified(request, 'claimReferralCashout');
    await _assertClientBuildAllowed(request, 'claimReferralCashout');
    await _assertAccountAge(uid, CFG.PAYOUT_MIN_ACCOUNT_AGE_DAYS, 'claimReferralCashout');

    if (isAdminAccountUid(uid)) {
      throw new HttpsError('failed-precondition',
        'Admin accounts cannot claim referral cashouts.');
    }
    await _assertPayoutAllowed(uid, 'claimReferralCashout');
    await _verifyPlayIntegrity(request, 'cashout');

    const payload = _validatePayoutPayload(request.data || {});
    const fingerprint = await _recordPayoutAccount(
      uid, payload.bankCode, payload.accountNumber, 'claimReferralCashout',
    ).catch((err) => {
      console.warn(`[claimReferralCashout] fingerprint failed: ${err.message}`);
      return {
        hash: _payoutAccountHash(payload.bankCode, payload.accountNumber),
        shared: false,
        uidCount: 1,
      };
    });
    const userRef = db.collection('users').doc(uid);
    const claimRef = db.collection('referralCashouts').doc(uid);

    const userSnap = await userRef.get();
    if (!userSnap.exists) {
      throw new HttpsError('not-found', 'Profile not found.');
    }
    const userData = userSnap.data() || {};

    const existingSnap = await claimRef.get();
    if (existingSnap.exists) {
      const existing = existingSnap.data() || {};
      if (existing.status === 'paid') {
        throw new HttpsError('failed-precondition',
          'Your referral cashout has already been paid.');
      }
      if (existing.status === 'rejected') {
        throw new HttpsError('failed-precondition',
          'This referral cashout claim was rejected. Contact support.');
      }
      if (existing.status === 'pending') {
        // Re-submitting REPLACES the destination while unpaid, exactly like a
        // leaderboard claim. The reserve was already encumbered on first
        // submission, so it must not be charged twice.
        await claimRef.set({
          accountNumber: payload.accountNumber,
          bankCode: payload.bankCode,
          bankName: payload.bankName || '',
          accountHash: fingerprint.hash,
          payoutAccountShared: fingerprint.shared,
          payoutAccountUidCount: fingerprint.uidCount,
          beneficiaryName: payload.beneficiaryName,
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });

        try {
          await _recordReferralCashoutPayoutDetail(uid, payload, claimRef.id);
        } catch (err) {
          console.warn(`[claimReferralCashout] payout detail update failed uid=${uid}: ${err.message}`);
        }

        return {
          success: true,
          status: 'pending',
          amount: REFERRAL_CASHOUT_AMOUNT,
          message: 'Your payout details were updated. An admin will transfer the cashout to this account.',
        };
      }
    }

    // ── Server-side qualification recount ──────────────────────────────────
    // Never trust a client count and never trust the marker blindly: unmarked
    // referrals are checked against the invitee's own profile and healed.
    const qualifying = await _collectReferralCashoutEvidence(uid);
    const qualifiedCount = qualifying.length;
    if (qualifiedCount < REFERRAL_CASHOUT_TARGET) {
      throw new HttpsError('failed-precondition',
        `Your cashout is not unlocked yet (${qualifiedCount}/${REFERRAL_CASHOUT_TARGET}).`);
    }

    const riskFlags = await _referralCashoutRiskFlags(uid, qualifying);

    // Small audit snapshot for the admin's review. No bank details here.
    const inviteeSnapshot = qualifying
      .slice(0, REFERRAL_CASHOUT_READ_CHUNK)
      .map((q) => ({
        uid: q.uid,
        username: typeof q.data.inviteeUsername === 'string'
          ? q.data.inviteeUsername
          : null,
        weekId: typeof q.data.leaderboardEntryWeekId === 'string'
          ? q.data.leaderboardEntryWeekId
          : null,
        // Only a resolved Timestamp is safe inside the claim doc. A self-healed
        // row carries the pending serverTimestamp sentinel, which cannot be
        // nested �?the admin still sees the week ID and buyer email.
        purchasedAt: q.data.leaderboardEntryPurchasedAt
            && typeof q.data.leaderboardEntryPurchasedAt.toMillis === 'function'
          ? q.data.leaderboardEntryPurchasedAt
          : null,
      }));

    const reserveRef = _referralCashoutReserveRef();
    let alreadySubmitted = false;

    await db.runTransaction(async (tx) => {
      const [freshUser, freshClaim, reserveSnap] = await Promise.all([
        tx.get(userRef),
        tx.get(claimRef),
        tx.get(reserveRef),
      ]);
      if (!freshUser.exists) {
        throw new HttpsError('not-found', 'Profile not found.');
      }

      const fresh = freshClaim.exists ? (freshClaim.data() || {}) : null;
      if (fresh?.status === 'paid' || fresh?.status === 'rejected') {
        throw new HttpsError('failed-precondition',
          'This cashout claim can no longer be changed.');
      }
      if (fresh?.status === 'pending') {
        // A concurrent submission won the race. It already encumbered the
        // reserve; keep its ledger entry and just refresh the destination.
        tx.set(claimRef, {
          accountNumber: payload.accountNumber,
          bankCode: payload.bankCode,
          bankName: payload.bankName || '',
          beneficiaryName: payload.beneficiaryName,
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        alreadySubmitted = true;
        return;
      }

      const reserve = reserveSnap.exists ? (reserveSnap.data() || {}) : {};
      const available = Number(reserve.available) || 0;
      const encumbered = Number(reserve.encumbered) || 0;
      const paidTotal = Number(reserve.paidTotal) || 0;
      const totalFunded = Number(reserve.totalFunded) || 0;

      tx.set(claimRef, {
        uid,
        username: userData.username || null,
        email: userData.email || null,
        amount: REFERRAL_CASHOUT_AMOUNT,
        currency: 'NGN',
        target: REFERRAL_CASHOUT_TARGET,
        qualifiedCount,
        status: 'pending',
        accountNumber: payload.accountNumber,
        bankCode: payload.bankCode,
        bankName: payload.bankName || '',
        accountHash: fingerprint.hash,
        payoutAccountShared: fingerprint.shared,
        payoutAccountUidCount: fingerprint.uidCount,
        beneficiaryName: payload.beneficiaryName,
        riskFlags,
        qualifiedInvitees: inviteeSnapshot,
        reserved: true,
        submittedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Encumber exactly one payout. `available` is allowed to go negative �?      // that is the admin's funding shortfall, not a reason to deny an earned
      // reward.
      tx.set(reserveRef, {
        available: available - REFERRAL_CASHOUT_AMOUNT,
        encumbered: encumbered + REFERRAL_CASHOUT_AMOUNT,
        paidTotal,
        totalFunded,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    try {
      await _recordReferralCashoutPayoutDetail(uid, payload, claimRef.id);
    } catch (err) {
      // The claim is the obligation; a missing reusable detail is recoverable
      // by the admin from the claim doc itself.
      console.warn(`[claimReferralCashout] payout detail write failed uid=${uid}: ${err.message}`);
    }

    console.log(`[claimReferralCashout] uid=${uid} qualified=${qualifiedCount} ` +
      `amount=${REFERRAL_CASHOUT_AMOUNT}${alreadySubmitted ? ' (race, refreshed)' : ''}`);

    return {
      success: true,
      status: 'pending',
      amount: REFERRAL_CASHOUT_AMOUNT,
      qualifiedCount,
      message: 'Referral cashout submitted. An admin will transfer it to this account.',
    };
  }
);

// ─── Admin: referral cashout queue + separate budget ───────────────────────
// READ-ONLY claim list, mirroring listPayoutClaims: full bank details are
// returned only through the ADMIN_UIDS gate. Clients never read the collection
// directly (owner-read only) and can never write it.

function _referralCashoutReserveDto(reserve) {
  const available = Number(reserve?.available) || 0;
  const encumbered = Number(reserve?.encumbered) || 0;
  return {
    available,
    encumbered,
    paidTotal: Number(reserve?.paidTotal) || 0,
    totalFunded: Number(reserve?.totalFunded) || 0,
    shortfall: available < 0 ? -available : 0,
    updatedAt: reserve?.updatedAt?.toMillis
      ? reserve.updatedAt.toDate().toISOString()
      : null,
    lastFundedAt: reserve?.lastFundedAt?.toMillis
      ? reserve.lastFundedAt.toDate().toISOString()
      : null,
    lastFundedBy: typeof reserve?.lastFundedBy === 'string'
      ? reserve.lastFundedBy
      : null,
  };
}

exports.listReferralCashoutClaims = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const { status } = request.data || {};
    let { limit } = request.data || {};
    limit = Number(limit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) limit = 200;

    const fmtTs = (ts) => (ts?.toMillis ? ts.toDate().toISOString() : null);

    // No status filter in the query: `status == X` + `orderBy(submittedAt)`
    // would need a composite index, and the admin queue is small. Filter in
    // memory so a fresh deploy cannot fail on a missing index.
    if (typeof status === 'string' && status && status !== 'all'
        && !['pending', 'paid', 'rejected', 'anonymized'].includes(status)) {
      throw new HttpsError('invalid-argument', 'Invalid status filter');
    }
    const claimsSnap = await db.collection('referralCashouts')
      .orderBy('submittedAt', 'desc')
      .limit(limit)
      .get();
    const reserveSnap = await _referralCashoutReserveRef().get();

    const allClaims = claimsSnap.docs.map((doc) => {
      const d = doc.data() || {};
      return {
        claimId: doc.id,
        uid: d.uid || doc.id,
        username: d.username || null,
        email: d.email || null,
        amount: Number(d.amount) || REFERRAL_CASHOUT_AMOUNT,
        currency: d.currency || 'NGN',
        status: d.status || 'pending',
        qualifiedCount: Number(d.qualifiedCount) || 0,
        accountNumber: d.accountNumber || null,
        bankCode: d.bankCode || null,
        bankName: d.bankName || null,
        accountHash: d.accountHash || null,
        payoutAccountShared: d.payoutAccountShared === true,
        payoutAccountUidCount: d.payoutAccountUidCount != null
          ? Number(d.payoutAccountUidCount) || null
          : null,
        beneficiaryName: d.beneficiaryName || null,
        riskFlags: Array.isArray(d.riskFlags) ? d.riskFlags : [],
        qualifiedInvitees: (Array.isArray(d.qualifiedInvitees)
          ? d.qualifiedInvitees
          : []).map((q) => ({
          uid: q?.uid || null,
          username: q?.username || null,
          weekId: q?.weekId || null,
          purchasedAt: fmtTs(q?.purchasedAt),
        })),
        submittedAt: fmtTs(d.submittedAt),
        updatedAt: fmtTs(d.updatedAt),
        paidAt: fmtTs(d.paidAt),
        markedAt: fmtTs(d.markedAt),
        markedBy: d.markedBy || null,
        payoutReference: d.payoutReference || null,
        rejectedAt: fmtTs(d.rejectedAt),
        rejectionReason: d.rejectionReason || null,
        anonymizedAt: fmtTs(d.anonymizedAt),
      };
    });

    const counts = { pending: 0, paid: 0, rejected: 0, anonymized: 0 };
    for (const c of allClaims) {
      if (counts[c.status] !== undefined) counts[c.status]++;
    }

    const claims = (typeof status === 'string' && status && status !== 'all')
      ? allClaims.filter((c) => c.status === status)
      : allClaims;

    return {
      success: true,
      claims,
      counts,
      reserve: _referralCashoutReserveDto(
        reserveSnap.exists ? reserveSnap.data() : null,
      ),
    };
  }
);

// Moves a claim between pending / paid / rejected and keeps the reserve ledger
// in step. The admin calls this ONLY after checking their own bank transfer.
exports.markReferralCashoutPaid = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const adminUid = request.auth?.uid;
    if (!adminUid || !ADMIN_UIDS.includes(adminUid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const { claimId, status, payoutReference, reason } = request.data || {};
    if (typeof claimId !== 'string' || !/^[A-Za-z0-9_-]{1,120}$/.test(claimId)) {
      throw new HttpsError('invalid-argument', 'claimId is invalid');
    }
    if (!['paid', 'rejected', 'pending'].includes(status)) {
      throw new HttpsError('invalid-argument', 'status must be paid, rejected or pending');
    }
    const reference = typeof payoutReference === 'string'
      ? payoutReference.trim().slice(0, 120)
      : '';
    const rejectionReason = typeof reason === 'string'
      ? reason.trim().slice(0, 500)
      : '';

    const claimRef = db.collection('referralCashouts').doc(claimId);
    const reserveRef = _referralCashoutReserveRef();
    let unchanged = false;

    await db.runTransaction(async (tx) => {
      const [claimSnap, reserveSnap] = await Promise.all([
        tx.get(claimRef),
        tx.get(reserveRef),
      ]);
      if (!claimSnap.exists) {
        throw new HttpsError('not-found', 'Cashout claim not found.');
      }

      const claim = claimSnap.data() || {};
      const from = claim.status || 'pending';
      if (from === status) {
        unchanged = true;
        return;
      }

      const allowed = {
        pending: ['paid', 'rejected'],
        paid: ['pending'],
        rejected: ['pending'],
        anonymized: [],
      };
      if (!(allowed[from] || []).includes(status)) {
        throw new HttpsError('failed-precondition',
          `Cannot move a ${from} claim to ${status}.`);
      }

      const amount = Number(claim.amount) || REFERRAL_CASHOUT_AMOUNT;
      const reserve = reserveSnap.exists ? (reserveSnap.data() || {}) : {};
      let available = Number(reserve.available) || 0;
      let encumbered = Number(reserve.encumbered) || 0;
      let paidTotal = Number(reserve.paidTotal) || 0;
      const totalFunded = Number(reserve.totalFunded) || 0;

      if (from === 'pending' && status === 'paid') {
        encumbered -= amount;
        paidTotal += amount;
      } else if (from === 'pending' && status === 'rejected') {
        encumbered -= amount;
        available += amount;
      } else if (from === 'paid' && status === 'pending') {
        paidTotal -= amount;
        encumbered += amount;
      } else if (from === 'rejected' && status === 'pending') {
        available -= amount;
        encumbered += amount;
      }

      // `available` may legitimately be negative: that is the admin's funding
      // shortfall, not an inconsistency. Only the other two counters must never
      // go below zero.
      if (encumbered < 0 || paidTotal < 0) {
        throw new HttpsError('failed-precondition',
          'Referral cashout ledger is inconsistent; refusing the update.');
      }

      const now = FieldValue.serverTimestamp();
      const patch = {
        status,
        updatedAt: now,
        markedAt: now,
        markedBy: adminUid,
      };
      if (status === 'paid') {
        patch.paidAt = now;
        patch.payoutReference = reference || null;
        patch.rejectedAt = FieldValue.delete();
        patch.rejectionReason = FieldValue.delete();
      } else if (status === 'rejected') {
        patch.rejectedAt = now;
        patch.rejectionReason = rejectionReason || null;
        patch.paidAt = FieldValue.delete();
        patch.payoutReference = FieldValue.delete();
      } else {
        patch.paidAt = FieldValue.delete();
        patch.payoutReference = FieldValue.delete();
        patch.rejectedAt = FieldValue.delete();
        patch.rejectionReason = FieldValue.delete();
      }
      tx.update(claimRef, patch);

      tx.set(reserveRef, {
        available,
        encumbered,
        paidTotal,
        totalFunded,
        updatedAt: now,
      }, { merge: true });

      tx.set(db.collection('referralCashoutAudit').doc(), {
        claimId,
        action: `status:${from}->${status}`,
        amount,
        adminUid,
        payoutReference: reference || null,
        reason: rejectionReason || null,
        at: now,
      });
    });

    console.log(`[markReferralCashoutPaid] admin=${adminUid} claim=${claimId} ` +
      `status=${status}${unchanged ? ' (unchanged)' : ''}`);
    return { success: true, status, unchanged };
  }
);

// Tops up the SEPARATE referral cashout budget. This never touches the weekly
// prize pool, `prize_pool` or `leaderboard_entry_config`.
exports.fundReferralCashoutReserve = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const adminUid = request.auth?.uid;
    if (!adminUid || !ADMIN_UIDS.includes(adminUid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const { amount, note } = request.data || {};
    const naira = Number(amount);
    if (!Number.isInteger(naira) || naira < 1 || naira > 10000000) {
      throw new HttpsError('invalid-argument',
        'amount must be a whole number of naira between 1 and 10,000,000');
    }
    const cleanNote = typeof note === 'string' ? note.trim().slice(0, 200) : '';

    const reserveRef = _referralCashoutReserveRef();
    await db.runTransaction(async (tx) => {
      const reserveSnap = await tx.get(reserveRef);
      const reserve = reserveSnap.exists ? (reserveSnap.data() || {}) : {};
      const now = FieldValue.serverTimestamp();

      tx.set(reserveRef, {
        available: (Number(reserve.available) || 0) + naira,
        encumbered: Number(reserve.encumbered) || 0,
        paidTotal: Number(reserve.paidTotal) || 0,
        totalFunded: (Number(reserve.totalFunded) || 0) + naira,
        lastFundedAt: now,
        lastFundedBy: adminUid,
        updatedAt: now,
      }, { merge: true });

      tx.set(db.collection('referralCashoutAudit').doc(), {
        action: 'fund',
        amount: naira,
        note: cleanNote || null,
        adminUid,
        at: now,
      });
    });

    const fresh = await reserveRef.get();
    console.log(`[fundReferralCashoutReserve] admin=${adminUid} +${naira}`);
    return {
      success: true,
      reserve: _referralCashoutReserveDto(fresh.exists ? fresh.data() : null),
    };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 5: REWARDED AD �?COIN AWARD (unchanged) ──────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// ─── Ad sessions + rewarded-ad award ───────────────────────────────────────
// Rewarded ads are client-observed, so the server ties each award to a session
// IT issued: startAdSession mints a single-use, 5-minute token; recordAdWatch
// redeems it exactly once. The daily cap (10) + 30s spacing still bound the
// payout. Real ad-network server-side verification (SSV) would be the next
// step.
//
// MIGRATION: the shipped APK sends no token. app_config/security
// .requireAdSession defaults to FALSE so those clients keep earning while the
// new build rolls out; the new client always mints/redeems. Flip the flag once
// the old build is gone.
const AD_SESSION_TTL_MS = 5 * 60 * 1000;
const AD_SESSION_RATE_WINDOW_MS = 60 * 1000;
const AD_SESSION_RATE_MAX = 6;
const AD_DAILY_MAX = 10;
const AD_SPACING_MS = 30 * 1000;
const AD_REWARD_COINS = 15;

exports.startAdSession = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'startAdSession');

    const token = randomUUID();
    const now = Date.now();
    const rateRef = db.collection('adSessionRate').doc(uid);

    await db.runTransaction(async (tx) => {
      const rateSnap = await tx.get(rateRef);
      const data = rateSnap.data() || {};
      const windowStart = data.windowStart?.toMillis ? data.windowStart.toMillis() : 0;
      const inWindow = now - windowStart < AD_SESSION_RATE_WINDOW_MS;
      const count = inWindow ? (data.count || 0) : 0;
      if (inWindow && count >= AD_SESSION_RATE_MAX) {
        throw new HttpsError(
          'resource-exhausted',
          'Too many ad sessions. Try again in a minute.'
        );
      }
      tx.set(rateRef, {
        windowStart: Timestamp.fromMillis(inWindow ? windowStart : now),
        count: count + 1,
      }, { merge: true });
      tx.set(db.collection('adSessions').doc(token), {
        uid,
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(now + AD_SESSION_TTL_MS),
        used: false,
      });
    });

    return { sessionToken: token, expiresAt: now + AD_SESSION_TTL_MS };
  }
);

exports.recordAdWatch = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const rawToken = request.data?.sessionToken;
    const hasToken = typeof rawToken === 'string' &&
      /^[0-9a-fA-F-]{36}$/.test(rawToken);

    // The shipped APK predates sessions. While requireAdSession is false we
    // still accept an untokened call (same daily cap + spacing as before);
    // the new client always sends a token. Flip the flag once the old build
    // is out of circulation, then this branch can be deleted.
    if (!hasToken) {
      const flags = await _securityFlags();
      if (flags.requireAdSession) {
        throw new HttpsError('invalid-argument', 'ad_session_required');
      }
    }

    const userRef = db.collection('users').doc(uid);
    const sessionRef = hasToken
      ? db.collection('adSessions').doc(rawToken)
      : null;
    let result;

    await db.runTransaction(async (tx) => {
      // ALL reads first (Firestore transaction requirement).
      const sessionSnap = sessionRef ? await tx.get(sessionRef) : null;
      const snap = await tx.get(userRef);

      if (sessionRef) {
        if (!sessionSnap.exists) {
          result = { success: false, error: 'ad_session_invalid' };
          return;
        }
        const session = sessionSnap.data() || {};
        const expiresAt = session.expiresAt?.toMillis ? session.expiresAt.toMillis() : 0;
        if (session.uid !== uid || session.used === true ||
            !expiresAt || expiresAt < Date.now()) {
          result = { success: false, error: 'ad_session_invalid' };
          return;
        }

        // Burn the token before the award decision: a token is redeemable
        // once, even when the daily cap or spacing rule then blocks the coins.
        tx.update(sessionRef, {
          used: true,
          usedAt: FieldValue.serverTimestamp(),
        });
      }

      const data = snap.data() || {};
      const todayWAT       = _watDateString();
      const lastWatchField = data.lastAdWatchDate;
      const lastWatchStr   = lastWatchField?.toDate
        ? _watDateString(lastWatchField.toDate())
        : null;

      const dailyAdWatched = (lastWatchStr === todayWAT)
        ? (data.dailyAdWatched || 0)
        : 0;

      // Defense-in-depth spacing: reject a redemption whose last recorded
      // ad-watch timestamp is under 30 seconds ago. Does not penalize the
      // daily count (dailyAdWatched is left untouched).
      const lastWatchDate = lastWatchField?.toDate ? lastWatchField.toDate() : null;
      if (lastWatchDate && (Date.now() - lastWatchDate.getTime()) < AD_SPACING_MS) {
        result = { success: false, error: 'ad_cooldown_active' };
        return;
      }

      if (dailyAdWatched >= AD_DAILY_MAX) {
        result = { success: false, error: 'daily_limit_reached' };
        return;
      }

      const currentCoins  = data.animeCoins || 0;
      const newBalance    = currentCoins + AD_REWARD_COINS;
      const newDailyCount = dailyAdWatched + 1;

      tx.update(userRef, {
        animeCoins:      FieldValue.increment(AD_REWARD_COINS),
        dailyAdWatched:  newDailyCount,
        lastAdWatchDate: FieldValue.serverTimestamp(),
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        'earn_ad',
        delta:       AD_REWARD_COINS,
        balanceAfter: newBalance,
        timestamp:   FieldValue.serverTimestamp(),
      });

      result = {
        success:        true,
        coinsAwarded:   AD_REWARD_COINS,
        newBalance,
        dailyAdWatched: newDailyCount,
      };
    });

    if (result.success) {
      console.log(
        `[recordAdWatch] uid=${uid}${hasToken ? '' : ' legacy(no token)'} ` +
        `+${AD_REWARD_COINS} AC | dailyAdWatched=${result.dailyAdWatched}/${AD_DAILY_MAX}`
      );
    } else {
      console.log(`[recordAdWatch] uid=${uid}${hasToken ? '' : ' legacy(no token)'} -> ${result.error}`);
    }

    return result;
  }
);


// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 6: DAILY LOGIN (unchanged) ────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.recordDailyLogin = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const userRef  = db.collection('users').doc(uid);
    const todayWAT = _watDateString();

    const yesterdayWAT = new Date(
      new Date(todayWAT + 'T00:00:00Z').getTime() - 24 * 60 * 60 * 1000
    ).toISOString().slice(0, 10);

    let coinsAwarded = 0;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      if (data.lastLoginDate === todayWAT) return;

      const baseBonus     = 20;
      const bonus         = data.premiumActive === true ? baseBonus * 2 : baseBonus;
      const currentCoins  = data.animeCoins || 0;
      const newBalance    = currentCoins + bonus;

      const prevStreak = data.currentStreak || 0;
      const newStreak  = (data.lastLoginDate === yesterdayWAT)
        ? prevStreak + 1
        : 1;

      tx.update(userRef, {
        animeCoins:    FieldValue.increment(bonus),
        lastLoginDate: todayWAT,
        currentStreak: newStreak,
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:         'earn_daily',
        delta:        bonus,
        balanceAfter: newBalance,
        timestamp:    FieldValue.serverTimestamp(),
      });

      coinsAwarded = bonus;
    });

    console.log(`[recordDailyLogin] uid=${uid} coinsAwarded=${coinsAwarded}`);
    return { coinsAwarded };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SOLO ANIME COOLDOWNS (server-authoritative) ───────────────────────────
// A lock lives at users/{uid}/cooldowns/{title} = { title, expiresAt }. Only
// this file writes it (Admin SDK); firestore.rules makes the subcollection
// owner-readable and never client-writable, so clearing app data cannot skip a
// lock. Duration is keyed by how many titles were started together: 2 → 10 min,
// 3 → 7 min, and 4–10 → 6 min. Every lineup locks, and none locks for less than
// the 6-minute floor (there is no "no lock" lineup size).
const SOLO_COOLDOWN_SECONDS_BY_COUNT = [360, 360, 600, 420, 360, 360, 360, 360, 360, 360, 360];

// Flat cost of the summary-page "Try Again" replay (`spendCoins` type
// 'spend_retry'): clears the finished lineup's locks and starts a fresh run.
// Mirrors kSoloRetryCost in lib/core/constants/solo_economy.dart �?change both.
const SOLO_RETRY_COST = 80;

// Transitional: the build already in the field still prices the retry at 40 AC
// (it displays 40 and sends 40). Keep accepting it so the feature is not dead
// before that build is retired; delete this and its branch once the new app is
// live and the forced-update wall is armed.
const LEGACY_SOLO_RETRY_COST = 40;

// Bundled fallback; the live list is app_config/anime_catalog.titles when set.
// Mirrors lib/core/constants/anime_catalog.dart.
const ANIME_CATALOG_FALLBACK = [
  'attack on titan',
  'berserk',
  'black clover',
  'bleach',
  'blue lock',
  'chainsaw man',
  'classroom of the elite',
  'death note',
  'demon slayer',
  'dragon ball z',
  'dr stone',
  'fairy tail',
  'fire force',
  "hell's paradise",
  'hunter x hunter',
  "jojo's bizarre adventure",
  'jujutsu kaisen',
  "kuroko's basketball",
  'mushoku tensei',
  'my hero academia',
  'naruto',
  'one piece',
  'one punch man',
  're zero',
  'solo leveling',
  'sword art online',
  'that time i got reincarnated as a slime',
  'tokyo ghoul',
  'tokyo revengers',
  'tower of god',
  'vinland saga',
  'wind breaker',
];
let _animeCatalogCache = null;

function soloCooldownSeconds(titleCount) {
  const i = Math.max(0, Math.min(10, Number(titleCount) || 0));
  return SOLO_COOLDOWN_SECONDS_BY_COUNT[i];
}

function _normalizeTitle(raw) {
  return typeof raw === 'string' ? raw.trim().toLowerCase() : '';
}

async function _loadAnimeCatalog() {
  const nowMs = Date.now();
  if (_animeCatalogCache && nowMs - _animeCatalogCache.at < 60000) {
    return _animeCatalogCache.titles;
  }
  let titles = ANIME_CATALOG_FALLBACK;
  try {
    const snap = await db.collection('app_config').doc('anime_catalog').get();
    const raw = snap.exists ? snap.data()?.titles : null;
    if (Array.isArray(raw)) {
      const clean = [...new Set(raw.map(_normalizeTitle).filter(Boolean))];
      if (clean.length) titles = clean;
    }
  } catch (err) {
    console.warn(`[anime_catalog] read failed, using bundled list: ${err.message}`);
  }
  _animeCatalogCache = { at: nowMs, titles };
  return titles;
}

// ─── Featured rotation (global homepage shelf, max 9) ────────────────────
// One doc for every user: app_config/featured_rotation
// { titles: [...9], intervalHours, rotatesAt, updatedAt }.
// Hourly tick; rotates only when now >= rotatesAt. Both the subset AND the
// next window (one of 6/12/18/24/48h) are drawn with crypto randomness, so
// the shelf is unpredictable but never churns faster than 6h.
const FEATURED_SHELF_SIZE = 9;
const FEATURED_INTERVALS_HOURS = [6, 12, 18, 24, 48];

function _shuffleInPlace(arr) {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = randomInt(i + 1);
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

async function _rotateFeaturedAnimesCore(nowMs = Date.now()) {
  const titles = await _loadAnimeCatalog();
  const ref = db.collection('app_config').doc('featured_rotation');
  const snap = await ref.get();
  const data = snap.exists ? snap.data() || {} : {};
  const rotatesAt = data.rotatesAt && typeof data.rotatesAt.toMillis === 'function'
    ? data.rotatesAt.toMillis()
    : 0;
  if (snap.exists && nowMs < rotatesAt) {
    return { rotated: false, titles: data.titles || [] };
  }
  const pool = _shuffleInPlace([...titles]).slice(0, FEATURED_SHELF_SIZE);
  const intervalHours =
    FEATURED_INTERVALS_HOURS[randomInt(FEATURED_INTERVALS_HOURS.length)];
  const next = {
    titles: pool,
    intervalHours,
    rotatesAt: Timestamp.fromMillis(nowMs + intervalHours * 3600 * 1000),
    updatedAt: FieldValue.serverTimestamp(),
  };
  await ref.set(next, { merge: true });
  return { rotated: true, titles: pool, intervalHours };
}

exports.rotateFeaturedAnimes = onSchedule(
  {
    schedule: '0 * * * *',
    region: 'us-central1',
    timeoutSeconds: 120,
    memory: '256MiB',
  },
  async () => {
    try {
      const res = await _rotateFeaturedAnimesCore();
      console.log(
        `[featured] tick rotated=${res.rotated} ` +
        `interval=${res.intervalHours || '-'} titles=${(res.titles || []).length}`
      );
    } catch (err) {
      console.warn(`[featured] tick failed: ${err.message}`);
    }
  }
);

// Test seam (unit tests run this file's fakes, not the scheduler).
globalThis.__featuredForTest = globalThis.__featuredForTest || {};
globalThis.__featuredForTest.rotateCore = (dbOverride, nowMs) => {
  void dbOverride;
  return _rotateFeaturedAnimesCore(nowMs);
};
globalThis.__featuredForTest.intervals = FEATURED_INTERVALS_HOURS;
globalThis.__featuredForTest.shelfSize = FEATURED_SHELF_SIZE;

function _isCooldownActive(snap, nowMs) {
  if (!snap || !snap.exists) return false;  const ts = snap.data()?.expiresAt;
  return !!ts && typeof ts.toMillis === 'function' && ts.toMillis() > nowMs;
}

// Starts the solo cooldown for a lineup. Refuses (failed-precondition /
// cooldown_active) if any picked title is still locked, so the lock is enforced
// here rather than trusted to the client. Titles the user has permanently
// unlocked (users/{uid}.unlockedAnimes) are exempt and never get a lock.
//
// It also mints the run's SESSION: users/{uid}.soloSession = {id, titles,
// startedAt}. submitQuizAnswers requires that stamp and deletes it in the same
// transaction that awards, so one start can pay at most one run �?a duplicate
// tap (or a patched client) cannot collect twice. Starting a new run overwrites
// the stamp (latest wins), which keeps quitting a run from locking the player
// out of starting another. The id is informational for now: the field build
// submits its own id and its paid retry never calls this at all.
exports.startSoloCooldowns = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }
    // No `requireStamp`: the oldest shipped build may predate the stamp and
    // must still be able to start until minBuild is raised. The minBuild gate
    // below is the actual cutoff, and an unmigrated client is rejected here
    // only once legacy paths are retired.
    await _assertClientBuildAllowed(request, 'startSoloCooldowns');
    if (await _legacyQuizPathsRetired() && request.data?.runV2 !== true) {
      throw _legacyPathRetiredError();
    }

    const raw = request.data?.titles;
    if (!Array.isArray(raw)) {
      throw new HttpsError('invalid-argument', 'invalid_titles');
    }
    const titles = [...new Set(raw.map(_normalizeTitle))];
    if (titles.length < 2 || titles.length > 10 || titles.some((t) => !t)) {
      throw new HttpsError('invalid-argument', 'invalid_titles');
    }
    const catalog = await _loadAnimeCatalog();
    if (titles.some((t) => !catalog.includes(t))) {
      throw new HttpsError('invalid-argument', 'invalid_anime');
    }

    const lockSecs = soloCooldownSeconds(titles.length);
    const nowMs = Date.now();
    const expiresAtMs = nowMs + lockSecs * 1000;
    const userRef = db.collection('users').doc(uid);
    const refs = titles.map((t) => userRef.collection('cooldowns').doc(t));
    const expiresAt = {};
    // Minted before the transaction so a retried attempt keeps the same id.
    const sessionId = userRef.collection('quizSessions').doc().id;

    await db.runTransaction(async (tx) => {
      const [userSnap, ...cdSnaps] = await Promise.all([
        tx.get(userRef),
        ...refs.map((r) => tx.get(r)),
      ]);
      const unlocked = Array.isArray(userSnap.data()?.unlockedAnimes)
        ? userSnap.data().unlockedAnimes
        : [];

      // One run at a time. Checking here (before the cooldown locks are
      // written) stops the home page navigating into a run that getQuizRun
      // would immediately reject, and stops a challenge/gauntlet session
      // being stacked under a new solo run.
      const activeBlocked = await _activeRunBlocked(tx, userSnap.data() || {}, null);
      if (activeBlocked) {
        throw new HttpsError('failed-precondition', 'run_in_progress');
      }

      const blocked = titles.filter(
        (t, i) => !unlocked.includes(t) && _isCooldownActive(cdSnaps[i], nowMs)
      );
      if (blocked.length) {
        throw new HttpsError('failed-precondition', 'cooldown_active', { titles: blocked });
      }

      // Stamp the run first, so a lineup whose titles are all permanently
      // unlocked is still a real, payable run (it just writes no locks).
      tx.set(userRef, {
        soloSession: {
          id: sessionId,
          titles,
          startedAt: FieldValue.serverTimestamp(),
        },
      }, { merge: true });

      titles.forEach((t, i) => {
        if (unlocked.includes(t)) return;
        tx.set(refs[i], {
          title: t,
          expiresAt: Timestamp.fromMillis(expiresAtMs),
          startedAt: FieldValue.serverTimestamp(),
        });
        expiresAt[t] = expiresAtMs;
      });
    });

    return { lockSeconds: lockSecs, expiresAt, sessionId };
  }
);

// ─── SECTION 7: SPEND COINS ────────────────────────────────────────────────
// spend_timer (20 AC) = Timer Pause power-up: freezes the current question's
// countdown until the player answers (client-side freeze, one use per
// question). The server only validates/deducts the 20 AC cost �?no time is
// added server-side.
// ─────────────────────────────────────────────────────────────────────────────

exports.spendCoins = onSecureCall(
  {
    region: 'us-central1',
    minInstances: 0,
    timeoutSeconds: 15,
    memory: '256MiB',
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }

    const { amount, type } = request.data;

    const validTypes = [
      'spend_hint',
      'spend_cooldown',
      'spend_retry',
      'spend_unlock',
      'spend_timer',
    ];

    if (!Number.isInteger(amount) || amount <= 0) {
      throw new HttpsError('invalid-argument', 'invalid_amount');
    }

    if (!validTypes.includes(type)) {
      throw new HttpsError('invalid-argument', 'invalid_spend_type');
    }

    const userRef = db.collection('users').doc(uid);
    let result = null;

    // spend_cooldown names the one title whose lock it clears; spend_retry
    // names the lineup whose locks a paid retry clears.
    let cooldownRef = null;
    if (type === 'spend_cooldown') {
      const title = _normalizeTitle(request.data?.title);
      const catalog = await _loadAnimeCatalog();
      if (!title || !catalog.includes(title)) {
        throw new HttpsError('invalid-argument', 'invalid_anime');
      }
      cooldownRef = userRef.collection('cooldowns').doc(title);
    }
    const retryTitles = type === 'spend_retry' && Array.isArray(request.data?.titles)
      ? [...new Set(request.data.titles.map(_normalizeTitle).filter(Boolean))].slice(0, 10)
      : [];

    // The summary-page replay is a flat SOLO_RETRY_COST (80 AC). The amount is
    // client-supplied, so enforce it here, and require a real lineup because the
    // retry also mints the replay run's session below. LEGACY_SOLO_RETRY_COST is
    // accepted only for the pre-80 app build (see the constant).
    if (type === 'spend_retry') {
      if (amount !== SOLO_RETRY_COST && amount !== LEGACY_SOLO_RETRY_COST) {
        throw new HttpsError(
          'invalid-argument',
          `incorrect_retry_cost: expected ${SOLO_RETRY_COST}`
        );
      }
      if (retryTitles.length < 2 || retryTitles.length > 10) {
        throw new HttpsError('invalid-argument', 'invalid_titles');
      }
    }
    // Minted before the transaction so a retried attempt keeps the same id.
    const retrySessionId = type === 'spend_retry'
      ? userRef.collection('quizSessions').doc().id
      : null;

    // Retry is a solo start too: once minBuild retires the legacy paths, do
    // not charge an old client for a run it cannot submit.
    if (type === 'spend_retry' &&
        await _legacyQuizPathsRetired() &&
        request.data?.runV2 !== true) {
      throw _legacyPathRetiredError();
    }

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};
      const current = Number(data.animeCoins || 0);

      // Solo retry (80 AC cooldown reset from the summary page) is a Premium
      // perk. The client routes free users to the upsell; this is the
      // authoritative check, since the callable is reachable directly.
      if (type === 'spend_retry' && data.premiumActive !== true) {
        throw new HttpsError('permission-denied', 'premium_required');
      }
      if (type === 'spend_retry') {
        // Don't charge for a replay while another run is still open.
        const blocked = await _activeRunBlocked(tx, data, null);
        if (blocked) throw new HttpsError('failed-precondition', 'run_in_progress');
      }

      if (type === 'spend_hint' && amount !== 10) {
        throw new HttpsError('invalid-argument', 'incorrect_hint_cost: expected 10');
      }
      if (type === 'spend_timer' && amount !== 20) {
        throw new HttpsError('invalid-argument', 'incorrect_timer_cost: expected 20');
      }
      // Timer Pause: client freezes the countdown until answered (no extra
      // seconds added). Server is authoritative only for the 20 AC deduction.

      // Flat-rate cooldown-skip: 100 AC per skip, no escalation.
      let deductAmount = amount;
      let skipUpdateFields = null;
      if (type === 'spend_cooldown') {
        const todayWAT = _watDateString();
        const storedDate = data.cooldownSkipsDate || '';
        const skipsToday = storedDate === todayWAT ? (Number(data.cooldownSkipsToday) || 0) : 0;
        if (amount !== 100) {
          throw new HttpsError('invalid-argument', 'incorrect_skip_cost: expected 100');
        }
        deductAmount = 100;
        skipUpdateFields = {
          cooldownSkipsToday: skipsToday + 1,
          cooldownSkipsDate: todayWAT,
        };
        const cdSnap = await tx.get(cooldownRef);
        if (!_isCooldownActive(cdSnap, Date.now())) {
          throw new HttpsError('failed-precondition', 'cooldown_not_active');
        }
      }

      if (current < deductAmount) {
        result = {
          success: false,
          error: 'insufficient_coins',
          balance: current,
        };
        return;
      }

      const newBalance = current - deductAmount;

      tx.update(userRef, {
        animeCoins: FieldValue.increment(-deductAmount),
      });

      if (skipUpdateFields) {
        tx.update(userRef, skipUpdateFields);
      }
      if (cooldownRef) {
        tx.delete(cooldownRef);
      }
      for (const t of retryTitles) {
        tx.delete(userRef.collection('cooldowns').doc(t));
      }
      if (retrySessionId) {
        // Fresh solo session for the replay, same contract as
        // startSoloCooldowns: submitQuizAnswers requires an open stamp (and
        // consumes it on the award). The field build's retry lands here too, so
        // this is what keeps its post-retry submission payable.
        tx.update(userRef, {
          soloSession: {
            id: retrySessionId,
            titles: retryTitles,
            startedAt: FieldValue.serverTimestamp(),
          },
        });
      }

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type,
        delta: -deductAmount,
        balanceAfter: newBalance,
        timestamp: FieldValue.serverTimestamp(),
      });

      result = {
        success: true,
        newBalance,
        ...(retrySessionId ? { sessionId: retrySessionId } : {}),
      };
    });

    return result;
  }
);


// ─── SECTION 9: REWARDED INTERSTITIAL (unchanged) ─────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.recordRewardedInterstitialWatch = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }

    const userRef = db.collection('users').doc(uid);
    let currentBalance;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};
      currentBalance = data.animeCoins || 0;

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:         'earn_ad',
        delta:        0,
        balanceAfter: currentBalance,
        timestamp:    FieldValue.serverTimestamp(),
      });
    });

    console.log(`[recordRewardedInterstitialWatch] uid=${uid} interstitial fired (analytics-only, 0 AC) balance=${currentBalance}`);
    return { success: true, coinsAwarded: 0, newBalance: currentBalance };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SERVER-MINTED QUIZ RUNS (anti-cheat P0) ───────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// The client never receives `correctAnswerIndex` and never chooses its own
// question set. A run doc (`quizRuns/{runId}`, rules: read:false write:false)
// holds the authoritative question IDs and answer key. `getQuizRun` serves a
// sanitized copy; `submitAnswer` locks one solo answer at a time; `submitRun`
// scores against the server's copy and then settles through the existing
// economy functions (which remain the only award paths).
const QUIZ_RUNS = 'quizRuns';
const QUIZ_RUN_MAX_HINTS = 2;
const QUIZ_HINT_COST = 10;
const SOLO_RUN_EXPIRY_MS = 15 * 60 * 1000;
// 90s of play plus submit retries and grace.
const GAUNTLET_RUN_EXPIRY_MS = 6 * 60 * 1000;
const CHALLENGE_RUN_EXPIRY_MS = 30 * 60 * 1000;
const QUIZ_RUN_SUBMIT_LOCK_MS = 60 * 1000;

// Mirrors kSoloDifficultyMixes (lib/core/constants/solo_economy.dart).
const SOLO_DIFFICULTY_MIX = {
  easy:   { easy: 7, medium: 2, hard: 1 },
  medium: { easy: 3, medium: 4, hard: 3 },
  hard:   { easy: 1, medium: 2, hard: 7 },
};
// Gauntlet Blitz: 90s time-attack, up to 30 questions, difficulty ramp
// 10 easy / 10 medium / 10 hard. Mirrors lib/core/constants/blitz_economy.dart
// — change both together.
const GAUNTLET_MIX = { easy: 10, medium: 10, hard: 10 };
const BLITZ_MAX_QUESTIONS = 30;
const BLITZ_SECONDS = 90;
// WP per correct answer by question difficulty (no positional tiers;
// unanswered questions score nothing).
const BLITZ_WP_BY_DIFFICULTY = { easy: 5, medium: 8, hard: 12 };
// Hard cap on raw run WP before retry decay / premium / daily soft cap.
const BLITZ_RAW_WP_CAP = 200;
const BLITZ_COMPLETION_WP = 10;
const BLITZ_COMPLETION_MIN_ANSWERED = 5;
// Gamble payout: tiered AC by correct count ([minCorrectInclusive, ac]).
// A deep retry costs up to 756 AC while the top payout is 60 AC, so only an
// excellent run on a cheap entry can profit — retrying is the gamble.
const BLITZ_AC_TIERS = [[0, 2], [5, 8], [9, 15], [13, 25], [17, 40], [21, 60]];
function _blitzAcEarned(correctCount) {
  let ac = 0;
  for (const [min, value] of BLITZ_AC_TIERS) {
    if (correctCount >= min) ac = value;
  }
  return ac;
}

function _normalizeQuizDifficulty(raw) {
  const d = typeof raw === 'string' ? raw.trim().toLowerCase() : 'easy';
  return SOLO_DIFFICULTY_MIX[d] ? d : 'easy';
}

function _shuffleList(input) {
  const out = [...input];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

function _sanitizeQuestionDoc(snap) {
  const d = snap.data() || {};
  const options = Array.isArray(d.options) ? d.options.map(String) : [];
  const correct = Number(d.correctAnswerIndex);
  if (options.length < 2 || !Number.isInteger(correct) || correct < 0 || correct >= options.length) {
    return null; // malformed question: never minted into a payable run
  }
  const rawDiff = typeof d.difficulty === 'string' ? d.difficulty.trim().toLowerCase() : 'medium';
  return {
    id: snap.id,
    question: typeof d.question === 'string' ? d.question : '',
    options,
    animeTitle: typeof d.animeTitle === 'string' ? d.animeTitle.trim().toLowerCase() : '',
    difficulty: ['easy', 'medium', 'hard'].includes(rawDiff) ? rawDiff : 'medium',
    correctAnswerIndex: correct,
  };
}

function _normalizeTitlesList(titles) {
  return [...new Set(
    (Array.isArray(titles) ? titles : [])
      .map((t) => String(t || '').trim().toLowerCase())
      .filter(Boolean),
  )];
}

async function _fetchQuestionDocsForTitles(titles) {
  const unique = _normalizeTitlesList(titles);
  const out = [];
  const seen = new Set();
  for (let i = 0; i < unique.length; i += 10) {
    const chunk = unique.slice(i, i + 10);
    const snap = await db.collection('questions')
      .where('animeTitle', 'in', chunk).get();
    for (const doc of snap.docs) {
      if (seen.has(doc.id)) continue;
      const q = _sanitizeQuestionDoc(doc);
      if (q) { seen.add(doc.id); out.push(q); }
    }
  }
  return out;
}

async function _fetchQuestionsByIds(ids) {
  const list = (Array.isArray(ids) ? ids : []).filter((id) => typeof id === 'string' && id);
  const out = [];
  for (let i = 0; i < list.length; i += 10) {
    const chunk = list.slice(i, i + 10);
    const snaps = await db.getAll(...chunk.map((id) => db.collection('questions').doc(id)));
    for (const snap of snaps) {
      const q = snap.exists ? _sanitizeQuestionDoc(snap) : null;
      if (q) out.push(q);
    }
  }
  return out;
}

async function _loadSeenQuestionIds(uid, titles) {
  const ids = new Set();
  const unique = _normalizeTitlesList(titles);
  for (let i = 0; i < unique.length; i += 10) {
    const chunk = unique.slice(i, i + 10);
    const snap = await db.collection('users').doc(uid)
      .collection('seenQuestions')
      .where('animeTitle', 'in', chunk).get();
    for (const doc of snap.docs) ids.add(doc.id);
  }
  return ids;
}

function _soloSlotOrder(mix) {
  const max = Math.max(mix.easy, mix.medium, mix.hard);
  const out = [];
  for (let i = 0; i < max; i++) {
    if (i < mix.easy) out.push('easy');
    if (i < mix.medium) out.push('medium');
    if (i < mix.hard) out.push('hard');
  }
  return out;
}

function _pickQuestionsForSlots(pool, slotOrder, seenIds) {
  const byTier = { easy: [], medium: [], hard: [] };
  for (const q of pool) {
    (byTier[q.difficulty] || byTier.medium).push(q);
  }
  const used = new Set();
  const take = (tier, allowSeen) => {
    for (const q of _shuffleList(byTier[tier] || [])) {
      if (used.has(q.id)) continue;
      if (!allowSeen && seenIds.has(q.id)) continue;
      used.add(q.id);
      return q;
    }
    return null;
  };

  const out = [];
  for (const slot of slotOrder) {
    // Strict per-tier quota: never backfill a hard slot with an easy
    // question. A short tier yields a short run, which the caller rejects
    // (`not_enough_questions`) instead of paying hard-tier rewards for easy
    // content. Seen questions are used only after the unseen pool is empty.
    const q = take(slot, false) || take(slot, true);
    if (!q) break;
    out.push(q);
  }
  return out;
}

function _gauntletTitles(userData) {
  const pool = new Set(GAUNTLET_BASE_TITLES);
  for (const t of (userData.unlockedCategories || [])) {
    const n = String(t || '').trim().toLowerCase();
    if (n) pool.add(n);
  }
  for (const t of (userData.unlockedAnimes || [])) {
    const n = String(t || '').trim().toLowerCase();
    if (n) pool.add(n);
  }
  return [...pool];
}

function _runQuestionsForResponse(run) {
  // The run stores sanitized questions, never the key. Rebuild the response
  // from that whitelist so a future field addition cannot leak by accident.
  return (Array.isArray(run.questions) ? run.questions : []).map((q) => ({
    id: q.id,
    question: q.question,
    options: Array.isArray(q.options) ? q.options : [],
    animeTitle: q.animeTitle || '',
    difficulty: q.difficulty || 'medium',
  }));
}

function _runResponse(runId, run) {
  const expiresMs = run.expiresAt?.toMillis ? run.expiresAt.toMillis() : 0;
  return {
    runId,
    mode: run.kind,
    questions: _runQuestionsForResponse(run),
    expiresAt: expiresMs,
    difficulty: run.difficulty || null,
    // The caller's own locked picks (null per unlocked question). Lets a
    // resumed duel continue from the first unlocked question instead of
    // replaying locked ones. No correctness is revealed — the key never
    // leaves the server.
    lockedAnswers: (Array.isArray(run.questionIds) ? run.questionIds : []).map((_, i) => {
      const a = Array.isArray(run.answers) ? run.answers[i] : null;
      return a && Number.isInteger(a.answer) ? a.answer : null;
    }),
  };
}

function _activeRunBlocked(tx, userData, exceptRunId) {
  const activeId = userData.activeRunId;
  if (!activeId || activeId === exceptRunId) return Promise.resolve(null);
  return tx.get(db.collection(QUIZ_RUNS).doc(activeId)).then((snap) => {
    if (!snap.exists) return null;
    const run = snap.data() || {};
    const expiresMs = run.expiresAt?.toMillis ? run.expiresAt.toMillis() : 0;
    const lockMs = run.lockAt?.toMillis ? run.lockAt.toMillis() : 0;
    if (run.state === 'active' && expiresMs > Date.now()) return activeId;
    if (run.state === 'submitting' && Date.now() - lockMs < QUIZ_RUN_SUBMIT_LOCK_MS) return activeId;
    return null;
  });
}

async function _clearActiveRun(uid, runId) {
  const userRef = db.collection('users').doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    if ((snap.data() || {}).activeRunId === runId) {
      tx.update(userRef, { activeRunId: FieldValue.delete() });
    }
  });
}

function _deriveSoloTimings(run, answers) {
  // Preserve the existing economy's semantics: `timings[i]` is the seconds
  // remaining on the 10s countdown (so an immediate answer is ~10 = "slow"
  // tier, a last-second answer is ~0.5 = "fast" tier). This is derived from
  // server-recorded answer timestamps only; client timings are never trusted.
  const out = [];
  let previous = run.startedAt?.toMillis ? run.startedAt.toMillis() : Date.now();
  for (let i = 0; i < answers.length; i++) {
    const recorded = Array.isArray(run.answers) ? run.answers[i] : null;
    if (answers[i] === -1 || !recorded || !Number.isFinite(Number(recorded.at))) {
      out.push(-1);
      continue;
    }
    const at = Number(recorded.at);
    const elapsed = Math.max(0, (at - previous) / 1000);
    previous = at;
    // The settlement handler requires integer seconds-remaining values and
    // uses `< 1.5` as its "fast" tier. 1 = fast, 10 = slow; -1 = timeout.
    out.push(elapsed > 8.5 ? 1 : 10);
  }
  return out;
}

function _detectImpossibleTimings(run, answers) {
  const recorded = Array.isArray(run.answers) ? run.answers : [];
  const startedMs = run.startedAt?.toMillis ? run.startedAt.toMillis() : null;
  let previous = startedMs;
  let minGapMs = null;
  let answered = 0;
  let lastAt = null;

  for (let i = 0; i < answers.length; i++) {
    if (answers[i] === -1) continue;
    const at = Number(recorded[i]?.at);
    if (!Number.isFinite(at)) continue;
    if (previous != null) {
      const gap = at - previous;
      if (gap >= 0 && (minGapMs === null || gap < minGapMs)) minGapMs = gap;
    }
    previous = at;
    lastAt = at;
    answered++;
  }

  const totalMs = startedMs != null && lastAt != null ? lastAt - startedMs : null;
  const impossible = answered >= 2 && (
    (minGapMs !== null && minGapMs < 1000) ||
    (totalMs !== null && totalMs < answered * 1000)
  );
  return { impossible, minGapMs, totalMs, answered };
}

function _answersFromRun(run) {
  const recorded = Array.isArray(run.answers) ? run.answers : [];
  return (Array.isArray(run.questionIds) ? run.questionIds : []).map((_, i) => {
    const a = recorded[i];
    return a && Number.isInteger(a.answer) ? a.answer : -1;
  });
}

function _validateAnswerArray(raw, expected) {
  if (!Array.isArray(raw) || raw.length !== expected) return null;
  if (!raw.every((a) => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3)))) return null;
  return raw;
}

// ── getQuizRun ─────────────────────────────────────────────────────────────
// Mints (or resumes) the authoritative run for solo / gauntlet / challenge /
// quick-match. Returns sanitized questions + runId, never an answer key.
exports.getQuizRun = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'getQuizRun', { requireStamp: true });

    const data = request.data || {};
    const mode = typeof data.mode === 'string' ? data.mode.trim().toLowerCase() : 'solo';
    const userRef = db.collection('users').doc(uid);

    // ── Resume by runId (gauntlet is pre-minted by enterDailyGauntlet) ──────
    if (typeof data.runId === 'string' && data.runId.trim()) {
      const runId = data.runId.trim();
      const snap = await db.collection(QUIZ_RUNS).doc(runId).get();
      if (!snap.exists) throw new HttpsError('not-found', 'run_not_found');
      const run = snap.data() || {};
      if (run.uid !== uid) throw new HttpsError('permission-denied', 'not_your_run');
      if (run.state === 'submitted') throw new HttpsError('failed-precondition', 'run_already_submitted');
      if (run.state === 'cancelled') throw new HttpsError('failed-precondition', 'run_cancelled');
      const expiresMs = run.expiresAt?.toMillis ? run.expiresAt.toMillis() : 0;
      if (expiresMs && expiresMs < Date.now()) throw new HttpsError('failed-precondition', 'run_expired');
      return _runResponse(runId, run);
    }

    // ── Solo: the session was minted by startSoloCooldowns / spend_retry ───
    if (mode === 'solo') {
      const userSnap = await userRef.get();
      const userData = userSnap.data() || {};
      const activeSolo = userData.soloSession;
      if (!activeSolo || typeof activeSolo.id !== 'string' || !activeSolo.id) {
        throw new HttpsError('failed-precondition', 'no_active_solo_session');
      }
      const requested = data.sessionId;
      if (typeof requested === 'string' && requested.trim() && requested.trim() !== activeSolo.id) {
        // A stale page can still submit its old run through submitRun; it just
        // cannot mint a second run on top of the newest session.
        await _recordAntiCheatSignal(uid, 'run_binding_mismatch', {
          hard: false,
          detail: { fn: 'getQuizRun', requested: requested.trim().slice(0, 80) },
        }).catch((err) => console.warn(`[getQuizRun] signal failed: ${err.message}`));
        throw new HttpsError('failed-precondition', 'solo_session_mismatch');
      }

      const runId = activeSolo.id;
      const runRef = db.collection(QUIZ_RUNS).doc(runId);
      const existing = await runRef.get();
      if (existing.exists) {
        const run = existing.data() || {};
        if (run.uid !== uid) throw new HttpsError('permission-denied', 'not_your_run');
        const expiresMs = run.expiresAt?.toMillis ? run.expiresAt.toMillis() : 0;
        if (run.state === 'active' && (!expiresMs || expiresMs > Date.now())) {
          return _runResponse(runId, run);
        }
        if (run.state === 'submitted') throw new HttpsError('failed-precondition', 'run_already_submitted');
      }

      const titles = _normalizeTitlesList(
        Array.isArray(activeSolo.titles) && activeSolo.titles.length
          ? activeSolo.titles
          : data.titles,
      );
      if (titles.length < 2) throw new HttpsError('invalid-argument', 'invalid_titles');
      const difficulty = _normalizeQuizDifficulty(data.difficulty);
      const pool = await _fetchQuestionDocsForTitles(titles);
      const seen = await _loadSeenQuestionIds(uid, titles);
      const selected = _pickQuestionsForSlots(
        pool, _soloSlotOrder(SOLO_DIFFICULTY_MIX[difficulty]), seen,
      );
      if (selected.length < 10) {
        throw new HttpsError('failed-precondition', 'not_enough_questions');
      }

      const now = Date.now();
      const run = {
        uid,
        kind: 'solo',
        refId: null,
        questionIds: selected.map((q) => q.id),
        questions: selected.map(({ correctAnswerIndex, ...q }) => q),
        answerKey: selected.map((q) => q.correctAnswerIndex),
        difficulties: selected.map((q) => q.difficulty),
        titles,
        difficulty,
        ticketId: null,
        state: 'active',
        startedAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(now + SOLO_RUN_EXPIRY_MS),
        answers: [],
        hints: [],
      };

      let raceResult = null;
      await db.runTransaction(async (tx) => {
        const [uSnap, rSnap] = await Promise.all([tx.get(userRef), tx.get(runRef)]);
        const u = uSnap.data() || {};
        if (!u.soloSession || u.soloSession.id !== runId) {
          throw new HttpsError('failed-precondition', 'no_active_solo_session');
        }
        if (rSnap.exists) {
          const r = rSnap.data() || {};
          const exp = r.expiresAt?.toMillis ? r.expiresAt.toMillis() : 0;
          if (r.state === 'active') {
            if (!exp || exp > Date.now()) raceResult = _runResponse(runId, r);
            else throw new HttpsError('failed-precondition', 'run_expired');
            return;
          }
          if (r.state === 'submitted') {
            throw new HttpsError('failed-precondition', 'run_already_submitted');
          }
          throw new HttpsError('failed-precondition', 'run_cancelled');
        }
        const blocked = await _activeRunBlocked(tx, u, runId);
        if (blocked) throw new HttpsError('failed-precondition', 'run_in_progress');
        tx.set(runRef, run);
        tx.update(userRef, {
          activeRunId: runId,
          soloSession: {
            ...u.soloSession,
            questionIds: run.questionIds,
            difficulty,
          },
        });
      });
      if (raceResult) return raceResult;
      return _runResponse(runId, run);
    }

    // ── Gauntlet Blitz: mint a fresh 30-question run when no runId was
    //    supplied (enterDailyGauntlet pre-mints this same shape) ──────────
    if (mode === 'gauntlet') {
      const userSnap = await userRef.get();
      const userData = userSnap.data() || {};
      const titles = _gauntletTitles(userData);
      const pool = await _fetchQuestionDocsForTitles(titles);
      const seen = await _loadSeenQuestionIds(uid, titles);
      const slotOrder = [
        ...Array(GAUNTLET_MIX.easy).fill('easy'),
        ...Array(GAUNTLET_MIX.medium).fill('medium'),
        ...Array(GAUNTLET_MIX.hard).fill('hard'),
      ];
      const selected = _pickQuestionsForSlots(pool, slotOrder, seen);
      if (selected.length < BLITZ_MAX_QUESTIONS) {
        throw new HttpsError('failed-precondition', 'not_enough_questions');
      }
      const runId = db.collection(QUIZ_RUNS).doc().id;
      const run = {
        uid,
        kind: 'gauntlet',
        refId: null,
        questionIds: selected.map((q) => q.id),
        questions: selected.map(({ correctAnswerIndex, ...q }) => q),
        answerKey: selected.map((q) => q.correctAnswerIndex),
        difficulties: selected.map((q) => q.difficulty),
        titles,
        difficulty: null,
        ticketId: typeof data.gauntletTicketId === 'string' ? data.gauntletTicketId : null,
        state: 'active',
        startedAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(Date.now() + GAUNTLET_RUN_EXPIRY_MS),
        answers: [],
        hints: [],
      };
      await db.runTransaction(async (tx) => {
        const uSnap = await tx.get(userRef);
        const blocked = await _activeRunBlocked(tx, uSnap.data() || {}, runId);
        if (blocked) throw new HttpsError('failed-precondition', 'run_in_progress');
        tx.set(db.collection(QUIZ_RUNS).doc(runId), run);
        tx.update(userRef, { activeRunId: runId });
      });
      return _runResponse(runId, run);
    }

    // ── Challenge / Quick Match: questions are already on the challenge doc ─
    if (mode === 'challenge' || mode === 'quickmatch') {
      const challengeId = typeof data.challengeId === 'string' ? data.challengeId.trim() : '';
      if (!challengeId) throw new HttpsError('invalid-argument', 'invalid_challenge_id');
      const challengeRef = db.collection('challenges').doc(challengeId);
      const challengeSnap = await challengeRef.get();
      if (!challengeSnap.exists) throw new HttpsError('not-found', 'challenge_not_found');
      const challenge = challengeSnap.data() || {};
      const isQuickMatch = challenge.isQuickMatch === true;
      if (mode === 'quickmatch' && !isQuickMatch) {
        throw new HttpsError('failed-precondition', 'not_a_quick_match');
      }
      if (mode === 'challenge' && isQuickMatch) {
        throw new HttpsError('failed-precondition', 'use_quickmatch_mode');
      }

      const isCreator = challenge.creatorUid === uid;
      const isOpponent = challenge.opponentUid === uid;
      if (!isCreator && !isOpponent) {
        throw new HttpsError('permission-denied', 'not_a_participant');
      }
      if (challenge.resolved === true || challenge.status === 'completed') {
        throw new HttpsError('failed-precondition', 'challenge_not_active');
      }
      const ghostMatch = challenge.opponentUid === 'ghost';
      if (isOpponent && !challenge.joinedAt) {
        throw new HttpsError('failed-precondition', 'challenge_not_active');
      }
      const scoreField = isCreator ? 'creatorScore' : 'opponentScore';
      if (challenge[scoreField] != null) {
        throw new HttpsError('failed-precondition', 'score_already_submitted');
      }

      const ids = Array.isArray(challenge.questionIds)
        ? challenge.questionIds.map(String)
        : [];
      if (ids.length !== 10 || new Set(ids).size !== 10) {
        throw new HttpsError('failed-precondition', 'invalid_challenge_questions');
      }
      const docs = await _fetchQuestionsByIds(ids);
      if (docs.length !== 10) {
        throw new HttpsError('failed-precondition', 'invalid_question_id');
      }
      const byId = new Map(docs.map((q) => [q.id, q]));
      const selected = ids.map((id) => byId.get(id)).filter(Boolean);
      if (selected.length !== 10) {
        throw new HttpsError('failed-precondition', 'invalid_question_id');
      }

      const runId = db.collection(QUIZ_RUNS).doc().id;
      const run = {
        uid,
        kind: mode,
        refId: challengeId,
        questionIds: selected.map((q) => q.id),
        questions: selected.map(({ correctAnswerIndex, ...q }) => q),
        answerKey: selected.map((q) => q.correctAnswerIndex),
        difficulties: selected.map((q) => q.difficulty),
        titles: [String(challenge.animeTitle || '').trim().toLowerCase()].filter(Boolean),
        difficulty: null,
        ticketId: null,
        state: 'active',
        startedAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(Date.now() + CHALLENGE_RUN_EXPIRY_MS),
        answers: [],
        hints: [],
      };

      let resumeId = null;
      await db.runTransaction(async (tx) => {
        const uSnap = await tx.get(userRef);
        const u = uSnap.data() || {};
        const activeId = u.activeRunId;
        if (activeId && activeId !== runId) {
          const aSnap = await tx.get(db.collection(QUIZ_RUNS).doc(activeId));
          if (aSnap.exists) {
            const a = aSnap.data() || {};
            const exp = a.expiresAt?.toMillis ? a.expiresAt.toMillis() : 0;
            if (a.uid === uid && a.kind === mode && a.refId === challengeId &&
                a.state === 'active' && (!exp || exp > Date.now())) {
              resumeId = activeId;
              return;
            }
            if (a.state === 'active' && exp > Date.now()) {
              throw new HttpsError('failed-precondition', 'run_in_progress');
            }
          }
        }
        tx.set(db.collection(QUIZ_RUNS).doc(runId), run);
        tx.update(userRef, { activeRunId: runId });
      });
      if (resumeId) {
        const resumed = await db.collection(QUIZ_RUNS).doc(resumeId).get();
        return _runResponse(resumeId, resumed.data() || {});
      }
      return _runResponse(runId, run);
    }

    throw new HttpsError('invalid-argument', 'invalid_run_mode');
  }
);

// ── submitAnswer (solo per-answer lock) ────────────────────────────────────
// Returns `{correct, correctIndex}` — the correct option is revealed ONLY for
// the locked question (the answer can no longer change, so no probing). Never
// the full key, never future questions.
exports.submitAnswer = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'submitAnswer', { requireStamp: true });

    const { runId, questionIndex, selectedAnswer } = request.data || {};
    if (typeof runId !== 'string' || !runId.trim()) {
      throw new HttpsError('invalid-argument', 'invalid_run_id');
    }
    if (!Number.isInteger(questionIndex) || questionIndex < 0 || questionIndex > 9) {
      throw new HttpsError('invalid-argument', 'invalid_question_index');
    }
    if (!Number.isInteger(selectedAnswer) || (selectedAnswer !== -1 && (selectedAnswer < 0 || selectedAnswer > 3))) {
      throw new HttpsError('invalid-argument', 'invalid_selected_answer');
    }

    const runRef = db.collection(QUIZ_RUNS).doc(runId.trim());
    let response;
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(runRef);
      if (!snap.exists) throw new HttpsError('not-found', 'run_not_found');
      const run = snap.data() || {};
      if (run.uid !== uid) throw new HttpsError('permission-denied', 'not_your_run');
      if (run.kind !== 'solo' && run.kind !== 'challenge' && run.kind !== 'quickmatch') throw new HttpsError('failed-precondition', 'per_answer_not_supported');
    if (run.kind === 'challenge' || run.kind === 'quickmatch') {
      const challengeSnap = await tx.get(db.collection('challenges').doc(String(run.refId || '')));
      if (!challengeSnap.exists) throw new HttpsError('not-found', 'challenge_not_found');
      const challenge = challengeSnap.data() || {};
      if (challenge.resolved === true || challenge.status === 'completed') throw new HttpsError('failed-precondition', 'challenge_not_active');
      const lockCreator = challenge.creatorUid === uid;
      const lockOpponent = challenge.opponentUid === uid;
      if (!lockCreator && !lockOpponent) throw new HttpsError('permission-denied', 'not_a_participant');
      if (challenge[lockCreator ? 'creatorScore' : 'opponentScore'] != null) throw new HttpsError('failed-precondition', 'score_already_submitted');
      const lockAllowed = lockCreator
        ? ['waiting', 'opponent_joined', 'opponent_submitted']
        : ['opponent_joined', 'creator_submitted'];
      if (!lockAllowed.includes(challenge.status)) throw new HttpsError('failed-precondition', 'challenge_not_active');
      if (lockOpponent && challenge.opponentUid !== 'ghost' && !challenge.joinedAt) throw new HttpsError('failed-precondition', 'challenge_not_active');
    }
      if (run.state !== 'active') throw new HttpsError('failed-precondition', 'run_not_active');
      const expiresMs = run.expiresAt?.toMillis ? run.expiresAt.toMillis() : 0;
      if (expiresMs && expiresMs < Date.now()) throw new HttpsError('failed-precondition', 'run_expired');

      const answers = Array.isArray(run.answers) ? [...run.answers] : [];
      const already = answers[questionIndex];
      if (already) {
        const key = Array.isArray(run.answerKey) ? run.answerKey : [];
        const ci = Number(key[questionIndex]);
        response = {
          index: questionIndex,
          correct: already.correct === true,
          already: true,
          ...(Number.isInteger(ci) ? { correctIndex: ci } : {}),
        };
        return;
      }
      // Heal a dropped timeout lock: fill any skipped slots as timeouts rather
      // than rejecting the player's next answer. A skipped question is always
      // wrong, so this cannot improve a score.
      while (answers.length < questionIndex) {
        answers.push({
          index: answers.length,
          answer: -1,
          correct: false,
          at: Date.now(),
        });
      }
      if (answers.length !== questionIndex) {
        throw new HttpsError('failed-precondition', 'answer_out_of_order');
      }
      const key = Array.isArray(run.answerKey) ? run.answerKey : [];
      const correct = selectedAnswer !== -1 && selectedAnswer === key[questionIndex];
      answers.push({
        index: questionIndex,
        answer: selectedAnswer,
        correct: correct === true,
        at: Date.now(),
      });
      tx.update(runRef, { answers });
      const ci = Number(key[questionIndex]);
      response = {
        index: questionIndex,
        correct: correct === true,
        already: false,
        ...(Number.isInteger(ci) ? { correctIndex: ci } : {}),
      };
    });
    return response;
  }
);

// ── useQuizHint (server-side elimination) ──────────────────────────────────
// The client no longer holds the answer key, so it cannot pick a wrong option
// locally. The server picks one and deducts the 10 AC in the same transaction.
exports.useQuizHint = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'useQuizHint', { requireStamp: true });

    const { runId, questionIndex } = request.data || {};
    if (typeof runId !== 'string' || !runId.trim()) {
      throw new HttpsError('invalid-argument', 'invalid_run_id');
    }
    if (!Number.isInteger(questionIndex) || questionIndex < 0 || questionIndex > 9) {
      throw new HttpsError('invalid-argument', 'invalid_question_index');
    }

    const runRef = db.collection(QUIZ_RUNS).doc(runId.trim());
    const userRef = db.collection('users').doc(uid);
    let result;
    await db.runTransaction(async (tx) => {
      const [runSnap, userSnap] = await Promise.all([tx.get(runRef), tx.get(userRef)]);
      if (!runSnap.exists) throw new HttpsError('not-found', 'run_not_found');
      const run = runSnap.data() || {};
      const user = userSnap.data() || {};
      if (run.uid !== uid) throw new HttpsError('permission-denied', 'not_your_run');
      // Hints are disabled in Gauntlet Blitz (time-attack): every second spent
      // reading options is part of the game, and a 10 AC hint would distort
      // the gamble payouts.
      if (run.kind === 'gauntlet') {
        throw new HttpsError('failed-precondition', 'hints_disabled_in_blitz');
      }
      if (run.state !== 'active') throw new HttpsError('failed-precondition', 'run_not_active');
      const expiresMs = run.expiresAt?.toMillis ? run.expiresAt.toMillis() : 0;
      if (expiresMs && expiresMs < Date.now()) throw new HttpsError('failed-precondition', 'run_expired');
      const answers = Array.isArray(run.answers) ? run.answers : [];
      if (answers[questionIndex]) throw new HttpsError('failed-precondition', 'question_already_answered');

      const hints = Array.isArray(run.hints) ? run.hints : [];
      const forQuestion = hints.filter((h) => h && h.index === questionIndex);
      if (forQuestion.length >= QUIZ_RUN_MAX_HINTS) {
        throw new HttpsError('resource-exhausted', 'hint_limit_reached');
      }
      const key = Array.isArray(run.answerKey) ? run.answerKey : [];
      const eliminated = new Set(forQuestion.map((h) => h.option));
      const options = Array.isArray(run.questions?.[questionIndex]?.options)
        ? run.questions[questionIndex].options
        : [];
      const candidates = options
        .map((_, i) => i)
        .filter((i) => i !== key[questionIndex] && !eliminated.has(i));
      if (candidates.length === 0) {
        throw new HttpsError('failed-precondition', 'no_hint_available');
      }
      const eliminatedIndex = candidates[Math.floor(Math.random() * candidates.length)];

      const currentCoins = Number(user.animeCoins || 0);
      if (currentCoins < QUIZ_HINT_COST) {
        throw new HttpsError('resource-exhausted', `insufficient_coins:${QUIZ_HINT_COST}`);
      }
      const newBalance = currentCoins - QUIZ_HINT_COST;
      tx.update(userRef, { animeCoins: FieldValue.increment(-QUIZ_HINT_COST) });
      tx.set(userRef.collection('coinTransactions').doc(), {
        type: 'spend_hint',
        delta: -QUIZ_HINT_COST,
        balanceAfter: newBalance,
        timestamp: FieldValue.serverTimestamp(),
      });
      tx.update(runRef, { hints: [...hints, { index: questionIndex, option: eliminatedIndex }] });
      result = {
        index: questionIndex,
        eliminatedIndex,
        hintsUsed: forQuestion.length + 1,
        newBalance,
      };
    });
    return result;
  }
);

// ── submitRun (score + settle from the server-held run) ───────────────────
exports.submitRun = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'submitRun', { requireStamp: true });

    const runId = typeof request.data?.runId === 'string' ? request.data.runId.trim() : '';
    if (!runId) throw new HttpsError('invalid-argument', 'invalid_run_id');

    const runRef = db.collection(QUIZ_RUNS).doc(runId);
    const userRef = db.collection('users').doc(uid);
    const runSnap = await runRef.get();
    if (!runSnap.exists) throw new HttpsError('not-found', 'run_not_found');
    const run = runSnap.data() || {};
    if (run.uid !== uid) throw new HttpsError('permission-denied', 'not_your_run');

    if (run.state === 'submitted') return { ...(run.result || {}), runId };

    const expiresMs = run.expiresAt?.toMillis ? run.expiresAt.toMillis() : 0;
    if (expiresMs && expiresMs + 60 * 1000 < Date.now()) {
      throw new HttpsError('failed-precondition', 'run_expired');
    }
    if (run.state === 'cancelled') throw new HttpsError('failed-precondition', 'run_cancelled');

    const expected = Array.isArray(run.questionIds) ? run.questionIds.length : 0;
    if (!expected) throw new HttpsError('failed-precondition', 'run_has_no_questions');

    let answers;
    if (run.kind === 'solo') {
      // Per-answer records win; fill any missing slot as a timeout.
      answers = _answersFromRun(run);
      const supplied = _validateAnswerArray(request.data?.answers, expected);
      if (supplied && (!Array.isArray(run.answers) || run.answers.length === 0)) {
        answers = supplied;
      }
    } else if (run.kind === 'challenge' || run.kind === 'quickmatch') {
      // Locked records only: a duel score must come from answers locked one
      // by one via submitAnswer. The client array is ignored, so quitting
      // mid-duel (or killing the app) and replaying the same fixed question
      // set can never improve the score — the locks stand and resume
      // continues from the first unlocked question. An empty lock store means
      // an outdated client: fail loudly so it updates instead of recording a
      // bogus all-timeout zero.
      if (!Array.isArray(run.answers) || run.answers.length === 0) {
        throw new HttpsError('failed-precondition', 'answers_not_locked');
      }
      answers = _answersFromRun(run);
    } else {
      answers = _validateAnswerArray(request.data?.answers, expected);
      if (!answers) throw new HttpsError('invalid-argument', 'invalid_selected_answers');
    }

    // Record the answers on the run before settlement. For solo this preserves
    // the per-answer server timestamps; for the other modes it makes the run
    // self-contained (and lets saveGhostSession verify it).
    const recordedAnswers = answers.map((answer, index) => {
      const existing = Array.isArray(run.answers) ? run.answers[index] : null;
      const key = Array.isArray(run.answerKey) ? run.answerKey[index] : undefined;
      return {
        index,
        answer,
        correct: answer !== -1 && answer === key,
        at: existing && Number.isFinite(Number(existing.at)) ? Number(existing.at) : Date.now(),
      };
    });

    // Hard signal: server-derived answer cadence below the physical floor.
    if (run.kind === 'solo') {
      const timing = _detectImpossibleTimings(
        { ...run, answers: recordedAnswers }, answers,
      );
      if (timing.impossible) {
        await _recordAntiCheatSignal(uid, 'impossible_timings', {
          hard: true,
          detail: { runId, ...timing },
        }).catch((err) => console.warn(`[submitRun] timing signal failed: ${err.message}`));
      }
    }

    // Claim the run exactly once. A concurrent submit is rejected; a retry
    // after a crash re-enters after the lock window and relies on the
    // underlying settlement function's own idempotency.
    let existingResult = null;
    let busy = false;
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(runRef);
      if (!snap.exists) throw new HttpsError('not-found', 'run_not_found');
      const fresh = snap.data() || {};
      if (fresh.uid !== uid) throw new HttpsError('permission-denied', 'not_your_run');
      if (fresh.state === 'submitted') {
        existingResult = { ...(fresh.result || {}), runId };
        return;
      }
      if (fresh.state === 'submitting') {
        const lockMs = fresh.lockAt?.toMillis ? fresh.lockAt.toMillis() : 0;
        if (Date.now() - lockMs < QUIZ_RUN_SUBMIT_LOCK_MS) {
          busy = true;
          return;
        }
      }
      tx.update(runRef, {
        state: 'submitting',
        lockAt: Timestamp.fromMillis(Date.now()),
        answers: recordedAnswers,
      });
    });
    if (existingResult) return existingResult;
    if (busy) throw new HttpsError('failed-precondition', 'run_in_progress');

    const timings = run.kind === 'solo'
      ? _deriveSoloTimings({ ...run, answers: recordedAnswers }, answers)
      : Array(expected).fill(10);

    const forwardRequest = {
      ...request,
      data: {
        ...(request.data || {}),
        runId,
        questionIds: run.questionIds,
        selectedAnswers: answers,
        timings,
      },
    };

    let settled;
    try {
      if (run.kind === 'solo') {
        forwardRequest.data.sessionId = runId;
        forwardRequest.data.soloDifficulty = _normalizeQuizDifficulty(run.difficulty);
        settled = await _handleSubmitQuizAnswers(forwardRequest);
      } else if (run.kind === 'gauntlet') {
        forwardRequest.data.sessionId = runId;
        if (run.ticketId) forwardRequest.data.gauntletTicketId = run.ticketId;
        settled = await _handleSubmitDailyGauntlet(forwardRequest);
        settled = {
          ...settled,
          // Per-question WP by difficulty (0 for wrong/unanswered). The client
          // renders this read-only; the authoritative total is totalWP.
          perQuestionWP: answers.map((a, i) =>
            (a !== -1 && a === run.answerKey[i])
              ? (BLITZ_WP_BY_DIFFICULTY[(run.difficulties || [])[i]] || 0) : 0),
        };
      } else if (run.kind === 'quickmatch') {
        forwardRequest.data.challengeId = run.refId;
        settled = await _handleSubmitQuickMatchResult(forwardRequest);
      } else {
        forwardRequest.data.challengeId = run.refId;
        settled = await _handleSubmitChallengeScore(forwardRequest);
      }
    } catch (err) {
      // Release the claim so the player can retry. The underlying settlement
      // functions are idempotent, so a retry cannot double-pay.
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(runRef);
        if (snap.exists && (snap.data() || {}).state === 'submitting') {
          tx.update(runRef, { state: 'active', lockAt: FieldValue.delete() });
        }
      }).catch(() => {});
      throw err;
    }

    await db.runTransaction(async (tx) => {
      const [snap, uSnap] = await Promise.all([tx.get(runRef), tx.get(userRef)]);
      const fresh = snap.data() || {};
      if (fresh.state !== 'submitted') {
        tx.update(runRef, {
          state: 'submitted',
          result: settled || {},
          submittedAt: FieldValue.serverTimestamp(),
          lockAt: FieldValue.delete(),
        });
      }
      if ((uSnap.data() || {}).activeRunId === runId) {
        tx.update(userRef, { activeRunId: FieldValue.delete() });
      }
    });

    return { ...(settled || {}), runId };
  }
);

// ── cancelRun (quit flow: release the one-active-run lock) ────────────────
exports.cancelRun = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    const runId = typeof request.data?.runId === 'string' ? request.data.runId.trim() : '';
    if (!runId) throw new HttpsError('invalid-argument', 'invalid_run_id');

    const runRef = db.collection(QUIZ_RUNS).doc(runId);
    const userRef = db.collection('users').doc(uid);
    await db.runTransaction(async (tx) => {
      const [runSnap, userSnap] = await Promise.all([tx.get(runRef), tx.get(userRef)]);
      if (!runSnap.exists) {
        console.log(`[cancelRun] uid=${uid} run=${runId} missing`);
        return;
      }
      const run = runSnap.data() || {};
      console.log(
        `[cancelRun] uid=${uid} run=${runId} owner=${run.uid}` +
        ` state=${run.state} active=${(userSnap.data() || {}).activeRunId || 'none'}`,
      );
      if (run.uid !== uid) return;
      if (run.state === 'active' || run.state === 'submitting') {
        tx.update(runRef, { state: 'cancelled', cancelledAt: FieldValue.serverTimestamp() });
      }
      const user = userSnap.data() || {};
      const patch = {};
      if (user.activeRunId === runId) patch.activeRunId = FieldValue.delete();
      if (run.kind === 'solo' && user.soloSession?.id === runId) {
        patch.soloSession = FieldValue.delete();
      }
      if (Object.keys(patch).length) tx.update(userRef, patch);
      // A prepaid Gauntlet entry is non-refundable; consume the ticket so a
      // quit cannot be used to reroll the question set for free.
      if (run.kind === 'gauntlet' && run.ticketId) {
        tx.update(userRef.collection('gauntletEntries').doc(run.ticketId), {
          consumed: true,
          consumedAt: FieldValue.serverTimestamp(),
        });
      }
      // Walking away from a live duel costs the quit fee on top of forfeiting
      // the match: without it, quitting to preview the fixed question set and
      // replaying it was profitable. Floored at zero so a broke player can
      // still clear a stuck run; the seat stays empty so the forfeit sweep
      // still zeroes the score and the stake is still lost.
      if ((run.kind === 'challenge' || run.kind === 'quickmatch') &&
          (run.state === 'active' || run.state === 'submitting')) {
        const balance = Number(user.animeCoins) || 0;
        const fee = Math.max(0, Math.min(QUIT_FEE_AC, balance));
        if (fee > 0) {
          tx.update(userRef, { animeCoins: balance - fee });
          tx.set(userRef.collection('coinTransactions').doc(), {
            type: 'challenge_quit_fee',
            delta: -fee,
            balanceAfter: balance - fee,
            challengeId: run.refId || null,
            timestamp: FieldValue.serverTimestamp(),
          });
        }
      }
    });
    return { success: true, runId };
  }
);

// ── getActiveRunStatus (stuck-run countdown + self-heal) ────────────────────
// Read-only: tells the caller which run is holding their one-active-run lock
// and how long until it expires, so the client can show "ends in N min"
// instead of a dead-end message. Also self-heals: an expired/settled run
// whose lock was never cleared (quit raced the cancel, app killed) is
// released here, so the next start succeeds without a manual clear.
exports.getActiveRunStatus = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const userRef = db.collection('users').doc(uid);
    const userSnap = await userRef.get();
    const raw = (userSnap.data() || {}).activeRunId;
    if (typeof raw !== 'string' || !raw.trim()) {
      return { active: false };
    }
    const runId = raw.trim();
    const runRef = db.collection(QUIZ_RUNS).doc(runId);
    const runSnap = await runRef.get();
    if (!runSnap.exists) {
      await _clearActiveRun(uid, runId);
      return { active: false, cleared: true };
    }
    const run = runSnap.data() || {};
    const expiresMs = run.expiresAt?.toMillis ? run.expiresAt.toMillis() : 0;
    const settled = run.state === 'submitted' || run.state === 'cancelled';
    if (settled || (expiresMs && expiresMs < Date.now())) {
      await _clearActiveRun(uid, runId);
      return { active: false, cleared: true };
    }
    return {
      active: true,
      runId,
      kind: typeof run.kind === 'string' ? run.kind : 'solo',
      expiresAt: expiresMs || null,
      secondsLeft: expiresMs
        ? Math.max(1, Math.ceil((expiresMs - Date.now()) / 1000))
        : null,
    };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 10: SUBMIT QUIZ ANSWERS (unchanged) ──────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

async function _handleSubmitQuizAnswers(request) {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }
    await _assertClientBuildAllowed(request, 'submitQuizAnswers');
    const enforcement = await _assertNotSuspended(uid, 'submitQuizAnswers');
    await _verifyPlayIntegrity(request, 'submit_solo');

    const { sessionId, questionIds, selectedAnswers, timings } = request.data;

    // ── Homepage solo difficulty (easy | medium | hard) ────────────────
    // Selects the WP/AC reward table below. Legacy clients omit it �?'easy'
    // (the pre-difficulty baseline), so old app versions see zero change.
    // Mirrors kSoloDifficultyRewards in lib/core/constants/solo_economy.dart
    // �?change both together. Quick Match / Create Challenge use their own
    // CFs and are unaffected.
    const SOLO_DIFFICULTY_REWARDS = {
      easy:   { wpFast: 8,  wpSlow: 15, completionWP: 20, perfectBonus: 10, ac: 8 },
      medium: { wpFast: 12, wpSlow: 22, completionWP: 30, perfectBonus: 15, ac: 12 },
      // Generous on purpose: hard runs burn AC on Timer Pause (20) / hints
      // (10), so a strong clear must profit. Max raw: 10x40+50+30 = 480 WP.
      hard:   { wpFast: 20, wpSlow: 40, completionWP: 50, perfectBonus: 30, ac: 35 },
    };
    const _rawDiff = typeof request.data?.soloDifficulty === 'string'
      ? request.data.soloDifficulty.trim().toLowerCase()
      : 'easy';
    let soloDifficulty = SOLO_DIFFICULTY_REWARDS[_rawDiff] ? _rawDiff : 'easy';
    let diffReward = SOLO_DIFFICULTY_REWARDS[soloDifficulty];

    if (typeof sessionId !== 'string' || !sessionId.trim()) {
      throw new Error('invalid_session_id');
    }

    if (
      !Array.isArray(questionIds)           ||
      questionIds.length !== 10             ||
      !questionIds.every(id => typeof id === 'string' && id.length > 0)
    ) {
      throw new Error('invalid_question_ids');
    }

    if (new Set(questionIds).size !== 10) {
      throw new Error('duplicate_question_id');
    }

    if (
      !Array.isArray(selectedAnswers)     ||
      selectedAnswers.length !== 10       ||
      !selectedAnswers.every(
        a => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3))
      )
    ) {
      throw new Error('invalid_selected_answers');
    }

    if (
      !Array.isArray(timings)  ||
      timings.length !== 10    ||
      !timings.every(t => typeof t === 'number')
    ) {
      throw new HttpsError('invalid-argument', 'invalid_timings');
    }

    // ── Phase 1a: timings validity bounds ────────────────────────────────
    // -1 is the client's legitimate timeout sentinel (a question that ran out
    // with no selection �?quiz_controller appends -1 for timed-out questions).
    // It can never be correct, so it never reaches the WP/AC scoring below;
    // only non-negative values carry physical answer-time plausibility bounds.
    // Previously any number passed (NaN/Infinity scored as "slow" for the
    // higher 15 WP tier). Per-question bounds are hardcoded: they encode
    // physical answer-time plausibility, not a tunable economy value.
    if (!timings.every(t =>
      Number.isInteger(t) && (t === -1 ||
        (t >= SOLO_TIMING_MIN_S && t <= SOLO_TIMING_MAX_S))
    )) {
      throw new HttpsError('invalid-argument', 'invalid_timings');
    }

    const sessionRef  = db.collection('users').doc(uid)
                          .collection('quizSessions').doc(sessionId);
    const sessionSnap = await sessionRef.get();

    if (sessionSnap.exists) {
      console.log(
        `[submitQuizAnswers] uid=${uid} sessionId=${sessionId}` +
        ` �?cache hit, returning stored result`
      );
      return sessionSnap.data().result;
    }

    // ── Server-minted solo session gate ───────────────────────────────────
    // startSoloCooldowns (and the paid retry inside spendCoins) stamps
    // users/{uid}.soloSession with the run's id. The award transaction consumes
    // that stamp, so a duplicate tap can never pay two runs started from one
    // session �?whichever submission lands first is paid, the rest are rejected.
    //
    // The stamp is required, but the id itself is not: the app build already in
    // the field submits its own id (and its paid retry never calls
    // startSoloCooldowns at all), so a strict id match would reject every live
    // player's run. One-payout-per-start is the guarantee that closes the hole;
    // the id remains recorded/compared for the new client and future tightening.
    //
    // Checked here as well as inside the transaction so a forged submission is
    // rejected before the question reads; the transaction re-check is the
    // authoritative one (it races with a newer start).
    const userRef = db.collection('users').doc(uid);
    const userDoc = await userRef.get();
    const activeSolo = (userDoc.data() || {}).soloSession;
    if (!activeSolo) {
      console.warn(
        `[submitQuizAnswers] uid=${uid} rejected: no open solo run ` +
        `(sessionId=${sessionId})`
      );
      throw new HttpsError('failed-precondition', 'no_active_solo_session');
    }
    // Once minBuild retires the legacy paths, a session that never went
    // through getQuizRun (no server-chosen question set) cannot be submitted.
    if (await _legacyQuizPathsRetired() &&
        !(Array.isArray(activeSolo.questionIds) && activeSolo.questionIds.length)) {
      throw _legacyPathRetiredError();
    }
    if (activeSolo.id !== sessionId) {
      console.warn(
        `[submitQuizAnswers] uid=${uid} legacy submission ` +
        `(client=${sessionId}, run=${activeSolo.id})`
      );
    }

    // New-flow sessions carry the exact server-chosen set and difficulty.
    // Enforce both here too, so calling the legacy callable directly cannot
    // swap in an easier set while claiming a harder reward table.
    if (Array.isArray(activeSolo.questionIds) && activeSolo.questionIds.length) {
      const locked = activeSolo.questionIds.map(String);
      if (locked.length !== questionIds.length ||
          locked.some((id, i) => id !== questionIds[i])) {
        await _recordAntiCheatSignal(uid, 'run_binding_mismatch', {
          hard: false,
          detail: { fn: 'submitQuizAnswers', sessionId },
        }).catch((err) => console.warn(`[submitQuizAnswers] signal failed: ${err.message}`));
        throw new HttpsError('failed-precondition', 'question_set_mismatch');
      }
      soloDifficulty = _normalizeQuizDifficulty(activeSolo.difficulty);
      diffReward = SOLO_DIFFICULTY_REWARDS[soloDifficulty];
    }

    const CHUNK_SIZE   = 10;
    const questionDocs = [];

    for (let i = 0; i < questionIds.length; i += CHUNK_SIZE) {
      const chunk = questionIds.slice(i, i + CHUNK_SIZE);
      const refs  = chunk.map(id => db.collection('questions').doc(id));
      const snaps = await db.getAll(...refs);
      questionDocs.push(...snaps);
    }

    for (const snap of questionDocs) {
      if (!snap.exists) {
        console.warn(`[submitQuizAnswers] uid=${uid} �?unknown questionId: ${snap.id}`);
        throw new Error('invalid_question_id');
      }
    }

    const questionMap = {};
    for (const snap of questionDocs) {
      questionMap[snap.id] = snap.data();
    }

    let correctCount = 0;
    let baseWP       = 0;

    for (let i = 0; i < 10; i++) {
      const question  = questionMap[questionIds[i]];
      const isCorrect = selectedAnswers[i] === question.correctAnswerIndex;

      if (isCorrect) {
        correctCount++;
        baseWP += (timings[i] < 1.5) ? diffReward.wpFast : diffReward.wpSlow;
      }
    }

    const completionWP  = diffReward.completionWP;
    const isPerfect     = correctCount === 10;
    const perfectBonus  = isPerfect ? diffReward.perfectBonus : 0;
    const acEarned      = diffReward.ac;
    const todayWAT     = _watDateString();

    let totalWP;
    let result;

    // ── Solo soft decay (config-driven, default full for games 1-100) ───
    // Read outside the transaction (config doc, not contended user state).
    // Games always succeed �?volume is throttled by decaying rewards, never
    // by rejection. Only fabricated timings (validated above) hard-reject.
    const soloDecay = await _getSoloDecayConfig();

    await db.runTransaction(async (tx) => {
      const [sessionCheck, userSnap] = await Promise.all([
        tx.get(sessionRef),
        tx.get(userRef),
      ]);

      if (sessionCheck.exists) return;

      const userData     = userSnap.data() || {};

      // Authoritative session check: a newer run may have replaced the stamp
      // after the pre-check above. `sessionCheck.exists` was false, so a missing
      // stamp here means this submission is not entitled to a payout.
      if (!userData.soloSession) {
        throw new HttpsError('failed-precondition', 'no_active_solo_session');
      }

      const currentCoins = userData.animeCoins || 0;

      // Same WAT-day lazy-reset pattern as wpEarnedToday: a stale date means
      // the counter restarts at 0 without any scheduled reset job. This is
      // the Nth game of the day *before* this submission counts (1-indexed
      // game number = counter + 1).
      const soloPlayedToday =
        _resolveDailyCounter(userData, 'soloPlayedToday', 'soloPlayedDate', todayWAT);
      const soloGameNumber = soloPlayedToday + 1;
      const decayFactor = _soloDecayFactor(soloGameNumber, soloDecay.tiers);

      // ── Reward pipeline (deliberate order �?see note below) ──────────
      //   raw WP �?solo decay (floor, min 1) �?daily 300-WP soft cap
      //   (existing _applyDailyWPSoftCap, min 1).
      // The two stages are intentionally multiplicative in the tail: decay
      // throttles per-game farming volume while the soft cap throttles daily
      // totals, and each stage floors at �? so a game never pays zero WP.
      // E.g. perfect raw 180 at game 150 (0.5x): 90 �?18 past the soft cap.
      const decayedBaseWP = Math.max(1, Math.floor(
        (baseWP + completionWP + perfectBonus) * decayFactor));
      // Same decay on the AC award so volume farming cannot route around
      // the WP decay into full-value AC (floored at 1 AC so games always
      // visibly reward something).
      const decayedAC = Math.max(1, Math.floor(acEarned * decayFactor));
      // Silent enforcement decay (restricted+ accounts). Floored at 1 so a
      // sanctioned account still sees a reward, just a reduced one.
      const enforcedWP = Math.max(1, _applyDecay(decayedBaseWP, enforcement.decayFactor));
      const enforcedAC = Math.max(1, _applyDecay(decayedAC, enforcement.decayFactor));
      const balanceAfter = currentCoins + enforcedAC;

      totalWP = enforcedWP;

      // Wrap the decayed award through the shared daily WP soft cap.
      const { award: awardedWP, newEarnedToday } =
        _applyDailyWPSoftCap(totalWP, _resolveDailyWPEarned(userData, todayWAT));
      totalWP = awardedWP;

      // achievementAC is returned separately so the client can render
      // achievement coins with a distinct UI (trophy/purple) from base quiz
      // earnings. It is also logged as its own `earn_achievement` ledger
      // entry below �?never silently merged into `earn_quiz`.
      let achievementAC = 0;
      result = { correctCount, totalWP, acEarned: enforcedAC, isPerfect, achievementAC, soloDifficulty };

      const userUpdateFields = {
        weeklyPoints:   FieldValue.increment(awardedWP),
        animeCoins:     FieldValue.increment(enforcedAC),
        wpEarnedToday:  newEarnedToday,
        wpEarnedDate:   FieldValue.serverTimestamp(),
        soloPlayedToday: soloPlayedToday + 1,
        soloPlayedDate:  todayWAT,
        'stats.gamesPlayed': FieldValue.increment(1),
        'stats.careerWpEarned': FieldValue.increment(awardedWP),
        // Consume the run's server session: this submission is paid exactly
        // once, and a later start mints a new id for the next run.
        soloSession:    FieldValue.delete(),
      };
      if (isPerfect) userUpdateFields['stats.perfectQuizzes'] = FieldValue.increment(1);

      // ── Stage 13: Achievement tier check (same tx) ─────────────────────────
      // Build stat deltas for this call: gamesPlayed always +1, careerWpEarned
      // is the post-cap awarded amount, perfectQuizzes only on a perfect run.
      const statDeltas = { gamesPlayed: 1, careerWpEarned: awardedWP };
      if (isPerfect) statDeltas.perfectQuizzes = 1;

      const achievements = _checkAchievementTiers(userData, statDeltas);
      if (achievements.acGranted > 0) {
        achievementAC = achievements.acGranted;
        result.achievementAC = achievementAC;
        userUpdateFields.animeCoins = FieldValue.increment(decayedAC + achievements.acGranted);
        userUpdateFields.achievementsGranted = achievements.newAchievementsGranted;
      }
      if (achievements.framesToGrant.length > 0) {
        userUpdateFields.ownedCosmetics = FieldValue.arrayUnion(...achievements.framesToGrant);
      }

      tx.update(userRef, userUpdateFields);

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        'earn_quiz',
        delta:       enforcedAC,
        balanceAfter,
        timestamp:   FieldValue.serverTimestamp(),
      });

      // Distinct ledger entry for achievement coins �?UI distinction source.
      if (achievementAC > 0) {
        tx.set(userRef.collection('coinTransactions').doc(), {
          type:         'earn_achievement',
          delta:        achievementAC,
          balanceAfter: currentCoins + enforcedAC + achievementAC,
          timestamp:    FieldValue.serverTimestamp(),
        });
      }

      tx.set(sessionRef, {
        result,
        timestamp: FieldValue.serverTimestamp(),
      });
    });

    if (result === undefined) {
      const fallback = await sessionRef.get();
      if (fallback.exists) {
        console.log(
          `[submitQuizAnswers] uid=${uid} sessionId=${sessionId}` +
          ` �?race-condition fallback: returning committed result`
        );
        return fallback.data().result;
      }
      throw new HttpsError('internal', 'session_write_failed');
    }

    console.log(
      `[submitQuizAnswers] uid=${uid} sessionId=${sessionId}` +
      ` | diff=${soloDifficulty} correct=${correctCount}/10 baseWP=${baseWP} totalWP=${totalWP}` +
      ` isPerfect=${isPerfect} +${result.acEarned} AC`
    );

    // ── Step 5b: mark questions seen (fire-and-forget, never blocks awards).
    _markQuestionsSeen(uid, questionIds, questionMap).catch((e) =>
      console.error(`[submitQuizAnswers] seen-mark failed (non-fatal): ${e.message}`)
    );

    // ── Phase 2 fraud signal: IP + cadence timestamp (fire-and-forget �?──
    // _logQuizCadence swallows all failures internally, never blocks awards).
    _logQuizCadence(uid, _clientIp(request), Date.now());

    return result;
}

exports.submitQuizAnswers = onSecureCall(
  { region: 'us-central1' },
  _handleSubmitQuizAnswers
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 10a: ENTER GAUNTLET BLITZ (pre-entry deduction) ─────────────────
// Gauntlet Blitz: 90s time-attack, up to 30 questions. One free attempt per
// WAT day, then escalating paid retries (40 → 756 free curve,
// 0 → 203 premium curve, max 6/day). There is no streak and no milestone —
// each retry is a priced gamble against the tiered AC payouts.
// - Free daily attempt — costs 0, no deduction, no ticket, retry index
//   untouched. The daily flag is still only consumed at submit time, so
//   quitting a free run does not burn the free attempt.
// - Paid retry — deducts retryCost atomically, advances gauntletRetryIndex
//   (0…5), logs `spend_gauntlet_entry`, and mints a single-use
//   ticket (users/{uid}/gauntletEntries/{ticketId}). The ticket must be
//   passed to submitDailyGauntlet, which consumes it WITHOUT charging again.
//   Entry fees are non-refundable on quit — by design (user-confirmed).
// ─────────────────────────────────────────────────────────────────────────────
// Deducts the Blitz retry cost BEFORE the player enters the quiz page.
// Legacy clients that submit without a ticket fall back to the old atomic
// deduct-at-submit path inside submitDailyGauntlet, so this is backwards
// compatible.
exports.enterDailyGauntlet = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }
    await _assertClientBuildAllowed(request, 'enterDailyGauntlet');

    const todayWAT = _watDateString();
    const userRef = db.collection('users').doc(uid);
    const runV2 = request.data?.runV2 === true;

    if (await _legacyQuizPathsRetired() && !runV2) {
      throw _legacyPathRetiredError();
    }

    // New clients: pick the 30 questions BEFORE charging, so a content failure
    // never burns the entry fee. The run doc is written in the same
    // transaction as the charge/ticket.
    let runId = null;
    let runQuestions = null;
    if (runV2) {
      const preSnap = await userRef.get();
      const preData = preSnap.data() || {};
      const pool = await _fetchQuestionDocsForTitles(_gauntletTitles(preData));
      const seen = await _loadSeenQuestionIds(uid, _gauntletTitles(preData));
      const slotOrder = [
        ...Array(GAUNTLET_MIX.easy).fill('easy'),
        ...Array(GAUNTLET_MIX.medium).fill('medium'),
        ...Array(GAUNTLET_MIX.hard).fill('hard'),
      ];
      const selected = _pickQuestionsForSlots(pool, slotOrder, seen);
      if (selected.length < BLITZ_MAX_QUESTIONS) {
        throw new HttpsError('failed-precondition', 'not_enough_questions');
      }
      runId = db.collection(QUIZ_RUNS).doc().id;
      runQuestions = selected;
    }

    const finishRunWrite = (tx, userData, ticketId) => {
      if (!runV2) return;
      const now = Date.now();
      const run = {
        uid,
        kind: 'gauntlet',
        refId: null,
        questionIds: runQuestions.map((q) => q.id),
        questions: runQuestions.map(({ correctAnswerIndex, ...q }) => q),
        answerKey: runQuestions.map((q) => q.correctAnswerIndex),
        difficulties: runQuestions.map((q) => q.difficulty),
        titles: _gauntletTitles(userData),
        difficulty: null,
        ticketId: ticketId || null,
        state: 'active',
        startedAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(now + GAUNTLET_RUN_EXPIRY_MS),
        answers: [],
        hints: [],
      };
      tx.set(db.collection(QUIZ_RUNS).doc(runId), run);
      tx.update(userRef, { activeRunId: runId });
    };

    let result;
    await db.runTransaction(async (tx) => {
      const userSnap = await tx.get(userRef);
      const userData = userSnap.data() || {};

      const storedDate = userData.dailyChallengeDate || '';
      const storedUsed = userData.dailyChallengeUsed === true;
      const isFreeAttempt = (storedDate !== todayWAT || !storedUsed);
      // Lazy-reset WAT counter. Counts every free entry, including the first,
      // so quit/re-enter cannot be used to reroll the 30 questions.
      const freeEntryCount = _resolveDailyCounter(
        userData, 'gauntletFreeEntryCount', 'gauntletFreeEntryDate', todayWAT,
      );

      if (runV2) {
        const blocked = await _activeRunBlocked(tx, userData, runId);
        if (blocked) throw new HttpsError('failed-precondition', 'run_in_progress');
      }

      let retryIdx = Number(userData.gauntletRetryIndex || 0);
      const retryDate = userData.gauntletRetryDate || '';
      if (retryDate !== todayWAT) retryIdx = 0;

      const isPremium = userData.premiumActive === true;

      if (isFreeAttempt) {
        if (freeEntryCount >= GAUNTLET_FREE_ENTRY_MAX) {
          throw new HttpsError(
            'failed-precondition',
            'gauntlet_free_entry_limit',
          );
        }
        result = {
          isFreeAttempt: true,
          retryCost: 0,
          ticketId: null,
          retryIndex: retryIdx,
        };
        if (runV2) {
          finishRunWrite(tx, userData, null);
          result.runId = runId;
        }
        tx.update(userRef, {
          gauntletFreeEntryCount: freeEntryCount + 1,
          gauntletFreeEntryDate: todayWAT,
        });
        return;
      }

      if (retryIdx >= GAUNTLET_MAX_RETRIES) {
        throw new HttpsError('failed-precondition', 'max_retries_exceeded');
      }

      const retryCost = isPremium
        ? GAUNTLET_RETRY_COST_PREMIUM[retryIdx]
        : GAUNTLET_RETRY_COST_FREE[retryIdx];

      const currentCoins = Number(userData.animeCoins || 0);
      if (currentCoins < retryCost) {
        throw new HttpsError('resource-exhausted',
          `insufficient_coins:${retryCost}`);
      }

      const newBalance = currentCoins - retryCost;
      const ticketRef = userRef.collection('gauntletEntries').doc();

      tx.update(userRef, {
        animeCoins: FieldValue.increment(-retryCost),
        gauntletRetryIndex: retryIdx + 1,
        gauntletRetryDate: todayWAT,
      });

      tx.set(userRef.collection('coinTransactions').doc(), {
        type:         'spend_gauntlet_entry',
        delta:        -retryCost,
        balanceAfter: newBalance,
        timestamp:    FieldValue.serverTimestamp(),
      });

      tx.set(ticketRef, {
        date:       todayWAT,
        retryIndex: retryIdx,
        cost:       retryCost,
        consumed:   false,
        createdAt:  FieldValue.serverTimestamp(),
      });

      if (runV2) {
        finishRunWrite(tx, userData, ticketRef.id);
      }
      result = {
        isFreeAttempt: false,
        retryCost,
        ticketId: ticketRef.id,
        retryIndex: retryIdx,
        newBalance,
        prepaid: retryCost > 0,
        ...(runV2 ? { runId } : {}),
      };
    });

    console.log(
      `[enterDailyGauntlet] uid=${uid}` +
      ` free=${result.isFreeAttempt} cost=${result.retryCost}` +
      ` ticket=${result.ticketId || 'none'}`
    );
    return result;
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 10b: SUBMIT GAUNTLET BLITZ (90s time-attack) ───────────────────
// Blitz draws up to 30 questions from the player's unlocked anime pool (the
// default titles every player has, plus anything they've unlocked via
// unlockedCategories / unlockedAnimes). One free attempt per WAT day reuses
// the dailyChallengeDate / dailyChallengeUsed rollover pattern.
//
// rewards: WP per correct by difficulty (5/8/12, raw-capped at 200) plus a
// small completion bonus; AC from the BLITZ_AC_TIERS gamble table by correct
// count. No streak, no milestones.
//
// PREPAID FLOW (new clients): enterDailyGauntlet deducts the retry cost at
// entry and mints a ticket; submitDailyGauntlet consumes that ticket WITHOUT
// charging again (netCoinDelta = acEarned only). LEGACY FLOW (old clients
// without a ticket): the retry cost is still deducted atomically inside this
// transaction �?a prior separate spendCoins call is not trusted, and an
// unaffordable retry is rejected without awarding anything.

// Default titles every player has in their unlocked pool. Mirrors the
// bundled ANIME_CATALOG_FALLBACK list (the home grid's starting set).
const GAUNTLET_BASE_TITLES = [
  'attack on titan',
  'demon slayer',
  'jujutsu kaisen',
  'naruto',
  'one piece',
  'one punch man',
  'bleach',
  'dragon ball z',
  'my hero academia',
  'death note',
];
// Blitz has no streak and no milestones. The old gauntletStreak /
// gauntletStreakDate / gauntletMilestonesAwarded user fields are left dormant
// (never read or written) so past streaks simply stop mattering.

// Retry cost curves (index = retry number, 0-based)
const GAUNTLET_RETRY_COST_FREE    = [40, 72, 130, 234, 420, 756];
const GAUNTLET_RETRY_COST_PREMIUM = [0,  40,  60,  90, 135, 203];
const GAUNTLET_MAX_RETRIES = 6; // max valid index

// Free entries per WAT day (the first attempt + tolerance for crashes/network
// loss). Quitting a free run does not consume the daily attempt, so without
// this cap a player could re-enter repeatedly to reroll the question set.
const GAUNTLET_FREE_ENTRY_MAX = 3;

// WP reward decay applied to a same-day Gauntlet RETRY (NOT the free daily
// attempt). Per the locked economy spec (v4.8 §7), settlement is:
//   rawWP -> retry decay -> Premium multiplier -> final WP
// with integer-floor after each stage. A retry's raw run WP is multiplied by
// this factor before the Premium 1.20× multiplier, so deep retry farming earns
// progressively less WP for a rising AC cost. The free attempt is not decayed.
const GAUNTLET_RETRY_DECAY = 0.55;

async function _handleSubmitDailyGauntlet(request) {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }
    const enforcement = await _assertNotSuspended(uid, 'submitDailyGauntlet');
    await _verifyPlayIntegrity(request, 'submit_gauntlet');

    // gauntletTicketId is minted by enterDailyGauntlet (pre-entry deduction).
    // New clients always send it for retries; legacy clients send nothing and
    // fall back to atomic deduct-at-submit.
    const { sessionId, questionIds, selectedAnswers, gauntletTicketId } = request.data;

    if (typeof sessionId !== 'string' || !sessionId.trim()) {
      throw new Error('invalid_session_id');
    }

    // Blitz submits 1..30 answers (however many the 90s timer allowed).
    // Run-bound clients must match the minted 30-question set exactly (checked
    // below); legacy direct submits send whatever the client picked.
    if (
      !Array.isArray(questionIds)           ||
      questionIds.length < 1               ||
      questionIds.length > BLITZ_MAX_QUESTIONS ||
      !questionIds.every(id => typeof id === 'string' && id.length > 0)
    ) {
      throw new Error('invalid_question_ids');
    }

    if (new Set(questionIds).size !== questionIds.length) {
      throw new Error('duplicate_question_id');
    }

    if (
      !Array.isArray(selectedAnswers)     ||
      selectedAnswers.length !== questionIds.length ||
      !selectedAnswers.every(
        a => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3))
      )
    ) {
      throw new Error('invalid_selected_answers');
    }

    const sessionRef  = db.collection('users').doc(uid)
                          .collection('quizSessions').doc(sessionId);
    const sessionSnap = await sessionRef.get();

    if (sessionSnap.exists) {
      console.log(
        `[submitDailyGauntlet] uid=${uid} sessionId=${sessionId}` +
        ` �?cache hit, returning stored result`
      );
      return sessionSnap.data().result;
    }

    // A runV2 Blitz session is bound to the server-chosen 30-question set.
    // Reject a direct legacy call that swaps in easier questions for the
    // difficulty-based WP.
    const gauntletRunSnap = await db.collection(QUIZ_RUNS).doc(sessionId).get();
    if (gauntletRunSnap.exists) {
      const run = gauntletRunSnap.data() || {};
      if (run.uid !== uid || run.kind !== 'gauntlet') {
        throw new HttpsError('failed-precondition', 'invalid_gauntlet_run');
      }
      const locked = Array.isArray(run.questionIds) ? run.questionIds.map(String) : [];
      if (locked.length !== questionIds.length ||
          locked.some((id, idx) => id !== questionIds[idx])) {
        await _recordAntiCheatSignal(uid, 'run_binding_mismatch', {
          hard: false,
          detail: { fn: 'submitDailyGauntlet', sessionId },
        }).catch((err) => console.warn(`[submitDailyGauntlet] signal failed: ${err.message}`));
        throw new HttpsError('failed-precondition', 'question_set_mismatch');
      }
    }
    if (await _legacyQuizPathsRetired() && !gauntletRunSnap.exists) {
      throw _legacyPathRetiredError();
    }

    const questionDocs = await db.getAll(
      ...questionIds.map(id => db.collection('questions').doc(id))
    );

    for (const snap of questionDocs) {
      if (!snap.exists) {
        console.warn(`[submitDailyGauntlet] uid=${uid} �?unknown questionId: ${snap.id}`);
        throw new Error('invalid_question_id');
      }
    }

    const questionMap = {};
    for (const snap of questionDocs) {
      questionMap[snap.id] = snap.data();
    }

    // Score: WP per correct by question difficulty (5 / 8 / 12), raw-capped.
    // AC from the BLITZ_AC_TIERS gamble table by correct count.
    const _normBlitzDiff = (d) => {
      const v = typeof d === 'string' ? d.trim().toLowerCase() : 'medium';
      return BLITZ_WP_BY_DIFFICULTY[v] !== undefined ? v : 'medium';
    };
    let correctCount = 0;
    let answeredCount = 0;
    let baseWP = 0;

    for (let i = 0; i < questionIds.length; i++) {
      if (selectedAnswers[i] === -1) continue;
      answeredCount++;
      const question = questionMap[questionIds[i]];
      const isCorrect = selectedAnswers[i] === question.correctAnswerIndex;

      if (isCorrect) {
        correctCount++;
        baseWP += BLITZ_WP_BY_DIFFICULTY[_normBlitzDiff(question.difficulty)] || 0;
      }
    }

    const completionWP =
      answeredCount >= BLITZ_COMPLETION_MIN_ANSWERED ? BLITZ_COMPLETION_WP : 0;
    const totalQuestions = questionIds.length;
    const isPerfect = correctCount > 0 && correctCount === totalQuestions;
    let acEarned = _blitzAcEarned(correctCount);
    acEarned = Math.max(1, _applyDecay(acEarned, enforcement.decayFactor));
    const todayWAT = _watDateString();

    let totalWP;
    let isFreeAttempt = false;
    let result;

    const userRef = db.collection('users').doc(uid);

    await db.runTransaction(async (tx) => {
      const [sessionCheck, userSnap] = await Promise.all([
        tx.get(sessionRef),
        tx.get(userRef),
      ]);

      if (sessionCheck.exists) return;

      const userData = userSnap.data() || {};

      // ── Build the player's unlocked anime pool and verify every submitted
      //    question comes from it (prevents submitting locked titles) ────────
      const pool = new Set(GAUNTLET_BASE_TITLES);
      for (const t of (userData.unlockedCategories || [])) {
        pool.add(t.trim().toLowerCase());
      }
      for (const t of (userData.unlockedAnimes || [])) {
        pool.add(t.trim().toLowerCase());
      }

      for (const id of questionIds) {
        const title = (questionMap[id].animeTitle || '').trim().toLowerCase();
        if (!pool.has(title)) {
          throw new HttpsError('failed-precondition', 'question_not_in_unlocked_pool');
        }
      }

      const storedDate = userData.dailyChallengeDate || '';
      const storedUsed = userData.dailyChallengeUsed === true;
      isFreeAttempt    = (storedDate !== todayWAT || !storedUsed);

      // ── Per-day retry index ───────────────────────────────────────────────
      // Resets to 0 on a new WAT day. Free daily attempt does NOT advance
      // the index; only actual paid retries do.
      let retryIdx = Number(userData.gauntletRetryIndex || 0);
      const retryDate = userData.gauntletRetryDate || '';
      if (retryDate !== todayWAT) retryIdx = 0;

      const currentCoins = userData.animeCoins || 0;
      const isPremium = userData.premiumActive === true;

      // ── Prepaid ticket (new clients) vs legacy deduct-at-submit ──────────
      // New flow: enterDailyGauntlet already deducted retryCost at entry,
      // advanced gauntletRetryIndex, and minted a ticket. Here we consume the
      // ticket WITHOUT charging again. Legacy flow (no ticket): charge
      // atomically here as before.
      let prepaid = false;
      let ticketRef = null;
      let ticketSnap = null;
      if (!isFreeAttempt && typeof gauntletTicketId === 'string' && gauntletTicketId.trim() !== '') {
        ticketRef = userRef.collection('gauntletEntries').doc(gauntletTicketId.trim());
        ticketSnap = await tx.get(ticketRef);
        if (!ticketSnap.exists) {
          throw new HttpsError('failed-precondition', 'invalid_gauntlet_ticket');
        }
        const t = ticketSnap.data() || {};
        if (t.date !== todayWAT || t.consumed === true) {
          throw new HttpsError('failed-precondition', 'invalid_gauntlet_ticket');
        }
        prepaid = true;
      }

      // First premium retry is free. Free users always pay.
      // For prepaid retries the authoritative cost is the ticket's cost
      // (already deducted at entry); otherwise compute from the curve.
      let retryCost;
      if (isFreeAttempt) {
        retryCost = 0;
      } else if (prepaid) {
        retryCost = Number(ticketSnap.data().cost || 0);
      } else {
        // Legacy path needs the curve value; guard the cap BEFORE indexing
        // to avoid an out-of-bounds read.
        if (retryIdx >= GAUNTLET_MAX_RETRIES) {
          throw new HttpsError('failed-precondition', 'max_retries_exceeded');
        }
        retryCost = isPremium ? GAUNTLET_RETRY_COST_PREMIUM[retryIdx]
                              : GAUNTLET_RETRY_COST_FREE[retryIdx];
      }

      if (!isFreeAttempt && !prepaid && currentCoins < retryCost) {
        throw new HttpsError('resource-exhausted',
          `insufficient_coins:${retryCost}`);
      }

      if (!isFreeAttempt && !prepaid && retryIdx >= GAUNTLET_MAX_RETRIES) {
        throw new HttpsError('failed-precondition', 'max_retries_exceeded');
      }

      // Route the run WP through the shared daily soft cap.
      let earnedTodayRunner = _resolveDailyWPEarned(userData, todayWAT);
      let awardedRunWP;
      {
        // Settlement order: rawWP (capped) -> retry decay -> Premium
        // multiplier -> daily soft cap, with integer-floor after each stage.
        // A same-day RETRY (not the free attempt) is decayed by
        // GAUNTLET_RETRY_DECAY (0.55) FIRST, then the Premium 1.20× multiplier
        // is applied, then the shared daily soft cap.
        let eligibleBlitzWP = Math.min(baseWP + completionWP, BLITZ_RAW_WP_CAP);
        if (!isFreeAttempt) {
          eligibleBlitzWP = Math.floor(eligibleBlitzWP * GAUNTLET_RETRY_DECAY);
        }
        // Silent enforcement decay applies before the Premium multiplier.
        eligibleBlitzWP = Math.max(
          1,
          _applyDecay(eligibleBlitzWP, enforcement.decayFactor),
        );
        if (isPremium && eligibleBlitzWP > 0) {
          eligibleBlitzWP = Math.floor(eligibleBlitzWP * 1.20);
        }
        const r = _applyDailyWPSoftCap(eligibleBlitzWP, earnedTodayRunner);
        awardedRunWP = r.award;
        earnedTodayRunner = r.newEarnedToday;
      }
      totalWP = awardedRunWP;

      // achievementAC is returned separately for distinct UI + ledger.
      let achievementAC = 0;
      result = {
        correctCount,
        answeredCount,
        totalQuestions,
        totalWP,
        acEarned,
        isPerfect,
        isFreeAttempt,
        // Deprecated streak-era fields. Old clients may still read them;
        // Blitz awards nothing through them.
        streak: 0,
        milestoneAwarded: [],
        achievementAC,
        retryCost,
        prepaid,
      };

      // Prepaid retry: cost was already deducted at entry — net is +acEarned
      // only. Free attempt: +acEarned. Legacy retry: -retryCost + acEarned.
      // Achievement AC is added on top in both paths.
      const netCoinDelta = (isFreeAttempt || prepaid) ? acEarned : (acEarned - retryCost);
      const runBalanceAfter = currentCoins + netCoinDelta;

      const userUpdateFields = {
        weeklyPoints:        FieldValue.increment(awardedRunWP),
        animeCoins:          FieldValue.increment(netCoinDelta),
        wpEarnedToday:       earnedTodayRunner,
        wpEarnedDate:        FieldValue.serverTimestamp(),
        'stats.gamesPlayed': FieldValue.increment(1),
        'stats.careerWpEarned': FieldValue.increment(awardedRunWP),
      };
      if (isPerfect) userUpdateFields['stats.perfectQuizzes'] = FieldValue.increment(1);

      // ── Stage 13: Achievement tier check (same tx) ─────────────────────────
      const statDeltas = { gamesPlayed: 1, careerWpEarned: awardedRunWP };
      if (isPerfect) statDeltas.perfectQuizzes = 1;

      const achievements = _checkAchievementTiers(userData, statDeltas);
      if (achievements.acGranted > 0) {
        achievementAC = achievements.acGranted;
        result.achievementAC = achievementAC;
        userUpdateFields.animeCoins = FieldValue.increment(netCoinDelta + achievements.acGranted);
        userUpdateFields.achievementsGranted = achievements.newAchievementsGranted;
      }
      if (achievements.framesToGrant.length > 0) {
        userUpdateFields.ownedCosmetics = FieldValue.arrayUnion(...achievements.framesToGrant);
      }

      // Only the free attempt consumes the daily flag. A retry leaves it set.
      if (isFreeAttempt) {
        userUpdateFields.dailyChallengeDate = todayWAT;
        userUpdateFields.dailyChallengeUsed = true;
      }

      // Advance retry index on LEGACY paid retries only. Prepaid retries
      // already advanced it inside enterDailyGauntlet; free attempts never do.
      if (!isFreeAttempt && !prepaid) {
        userUpdateFields.gauntletRetryIndex = retryIdx + 1;
        userUpdateFields.gauntletRetryDate  = todayWAT;
      }

      tx.update(userRef, userUpdateFields);

      // Consume the prepaid ticket (no second charge).
      if (prepaid && ticketRef) {
        tx.update(ticketRef, {
          consumed: true,
          consumedAt: FieldValue.serverTimestamp(),
          sessionId,
        });
      }

      // Record the atomic retry spend for LEGACY path only (mirrors spendCoins
      // 'spend_retry'). Prepaid path already logged 'spend_gauntlet_entry' at
      // entry time �?logging again would double-count the spend.
      if (!isFreeAttempt && !prepaid) {
        tx.set(userRef.collection('coinTransactions').doc(), {
          type:         'spend_retry',
          delta:        -retryCost,
          balanceAfter: currentCoins - retryCost,
          timestamp:    FieldValue.serverTimestamp(),
        });
      }

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:          'earn_gauntlet',
        delta:         acEarned,
        balanceAfter:  runBalanceAfter,
        timestamp:     FieldValue.serverTimestamp(),
      });

      // Distinct ledger entry for achievement coins — UI distinction source.
      if (achievementAC > 0) {
        tx.set(userRef.collection('coinTransactions').doc(), {
          type:         'earn_achievement',
          delta:        achievementAC,
          balanceAfter: runBalanceAfter + achievementAC,
          timestamp:    FieldValue.serverTimestamp(),
        });
      }

      tx.set(sessionRef, {
        result,
        timestamp: FieldValue.serverTimestamp(),
      });
    });

    if (result === undefined) {
      const fallback = await sessionRef.get();
      if (fallback.exists) {
        console.log(
          `[submitDailyGauntlet] uid=${uid} sessionId=${sessionId}` +
          ` �?race-condition fallback: returning committed result`
        );
        return fallback.data().result;
      }
      throw new HttpsError('internal', 'session_write_failed');
    }

    console.log(
      `[submitDailyGauntlet] uid=${uid} sessionId=${sessionId}` +
      ` | correct=${correctCount}/${totalQuestions} answered=${answeredCount}` +
      ` baseWP=${baseWP} totalWP=${totalWP}` +
      ` isPerfect=${isPerfect} freeAttempt=${isFreeAttempt} prepaid=${result.prepaid || false}` +
      ` +${acEarned} AC achievement=+${result.achievementAC || 0} AC`
    );

    // ── Step 5b: mark questions seen (fire-and-forget, never blocks awards).
    _markQuestionsSeen(uid, questionIds, questionMap).catch((e) =>
      console.error(`[submitDailyGauntlet] seen-mark failed (non-fatal): ${e.message}`)
    );

    return result;
}

exports.submitDailyGauntlet = onSecureCall(
  { region: 'us-central1' },
  _handleSubmitDailyGauntlet
);
// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 11: LOGIN STREAK WP MILESTONES (unchanged) ────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.awardLoginStreakWP = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const MILESTONES = [
      { streak: 14, wp: 200 },
      { streak:  7, wp: 100 },
      { streak:  3, wp:  30 },
    ];

    const userRef = db.collection('users').doc(uid);
    let result;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      const currentStreak = data.currentStreak                 || 0;
      const lastAwarded   = data.lastStreakWPMilestoneAwarded  || 0;

      const hit = MILESTONES.find(
        ({ streak }) => currentStreak >= streak && lastAwarded < streak
      );

      if (!hit) {
        result = { awarded: false };
        return;
      }

      tx.update(userRef, {
        weeklyPoints:                 FieldValue.increment(hit.wp),
        lastStreakWPMilestoneAwarded: hit.streak,
      });

      result = { awarded: true, wpAwarded: hit.wp, milestone: hit.streak };
    });

    if (result.awarded) {
      console.log(
        `[awardLoginStreakWP] uid=${uid}` +
        ` streak milestone=${result.milestone} �?+${result.wpAwarded} WP`
      );
    } else {
      console.log(`[awardLoginStreakWP] uid=${uid} �?no milestone reached`);
    }

    return result;
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 12: QUICK MATCH FUNCTIONS (unchanged) ────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.consumeQMToken = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'consumeQMToken');

    const now             = new Date();
    // 24/7 QM: the token bucket is the WAT day, never a time window.
    const currentWindowId = getQMDayId(now);

    const userRef = db.collection('users').doc(uid);
    let tokensRemaining;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      let qmWindowId    = data.qmWindowId   ?? null;
      let qmTokens      = data.qmTokens     ?? 0;
      let qmAdTokenUsed = data.qmAdTokenUsed ?? false;

      if (qmWindowId !== currentWindowId) {
        qmTokens      = _qmDailyTokens(data.premiumActive === true);
        qmAdTokenUsed = false;
        qmWindowId    = currentWindowId;
      }

      if (qmTokens <= 0) {
        throw new HttpsError('resource-exhausted', 'no_qm_tokens');
      }

      qmTokens -= 1;
      tokensRemaining = qmTokens;

      tx.update(userRef, { qmWindowId, qmTokens, qmAdTokenUsed });
    });

    console.log(
      `[consumeQMToken] uid=${uid} | windowId=${currentWindowId}` +
      ` | tokensRemaining=${tokensRemaining}`
    );
    return { success: true, tokensRemaining, windowId: currentWindowId };
  }
);

exports.grantAdQMToken = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    await _assertClientBuildAllowed(request, 'grantAdQMToken');

    const userRef = db.collection('users').doc(uid);
    let tokensRemaining;

    await db.runTransaction(async (tx) => {
      const now             = new Date();
      // 24/7 QM: the token bucket is the WAT day, never a time window.
      const currentWindowId = getQMDayId(now);

      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      let qmWindowId    = data.qmWindowId   ?? null;
      let qmTokens      = data.qmTokens     ?? 0;
      let qmAdTokenUsed = data.qmAdTokenUsed ?? false;

      const isPremium = data.premiumActive === true;
      if (qmWindowId !== currentWindowId) {
        qmTokens      = _qmDailyTokens(isPremium);
        qmAdTokenUsed = false;
        qmWindowId    = currentWindowId;
      }

      if (qmAdTokenUsed === true) {
        throw new HttpsError('resource-exhausted', 'ad_token_already_used');
      }

      // The ad token stacks one ABOVE the daily budget.
      const maxTokens = _qmDailyTokens(isPremium) + 1;
      if (qmTokens >= maxTokens) {
        throw new HttpsError('resource-exhausted', 'already_at_max_tokens');
      }

      qmTokens     += 1;
      qmAdTokenUsed = true;
      tokensRemaining = qmTokens;

      tx.update(userRef, { qmWindowId, qmTokens, qmAdTokenUsed });
    });

    console.log(`[grantAdQMToken] uid=${uid} | tokensRemaining=${tokensRemaining}`);
    return { success: true, tokensRemaining };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── joinMatchmakingQueue (ghost-only) ─────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Ghost-only Quick Match: removes all real-player matchmaking, goes straight
// to ghost match with no waiting. Real 1v1 matchmaking has been disabled.

exports.joinMatchmakingQueue = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
      await _assertClientBuildAllowed(request, 'joinMatchmakingQueue');
      await _touchDevice(uid, request.data?.deviceId);

      const now             = new Date();
      // 24/7 QM: the token bucket is the WAT day, never a time window.
      const currentWindowId = getQMDayId(now);

      const userRef  = db.collection('users').doc(uid);
      const userSnap = await userRef.get();
      const userData = userSnap.data() || {};
      const username = userData.username || 'Anonymous';

      // Check for existing match where player is EITHER opponent OR creator
      // This handles the race condition where one player finds the other,
      // creates the challenge, and the creator needs to find their own challenge
      const existingMatchSnapAsOpponent = await db.collection('challenges')
        .where('opponentUid',  '==', uid)
        .where('status',       '==', 'opponent_joined')
        .where('isQuickMatch', '==', true)
        .orderBy('createdAt',  'desc')
        .limit(1)
        .get();

      const existingMatchSnapAsCreator = await db.collection('challenges')
        .where('creatorUid',   '==', uid)
        .where('status',       '==', 'opponent_joined')
        .where('isQuickMatch', '==', true)
        .orderBy('createdAt',  'desc')
        .limit(1)
        .get();

      // Merge results, prioritizing the most recent
      let existingDoc = null;
      if (!existingMatchSnapAsOpponent.empty && !existingMatchSnapAsCreator.empty) {
        // Both queries returned something, use the most recent
        const docOpponent = existingMatchSnapAsOpponent.docs[0];
        const docCreator = existingMatchSnapAsCreator.docs[0];
        existingDoc = (docOpponent.createTime.toMillis() >= docCreator.createTime.toMillis())
          ? docOpponent : docCreator;
      } else if (!existingMatchSnapAsOpponent.empty) {
        existingDoc = existingMatchSnapAsOpponent.docs[0];
      } else if (!existingMatchSnapAsCreator.empty) {
        existingDoc = existingMatchSnapAsCreator.docs[0];
      }

      if (existingDoc) {
        const existing     = existingDoc;
        const existingData = existing.data();
        await db.collection('matchmaking_queue').doc(uid).delete().catch(() => {});
        const isCreator = existingData.creatorUid === uid;
        console.log(
          `[joinMatchmakingQueue] OPPONENT_DETECTED uid=${uid}` +
          ` | challengeId=${existing.id} | isCreator=${isCreator}`
        );
        return {
          matched:          true,
          isCreator:        isCreator,
          challengeId:      existing.id,
          questionIds:      Array.isArray(existingData.questionIds)
            ? existingData.questionIds.map(String)
            : [],
          animeTitle:       existingData.animeTitle,
          opponentUsername: isCreator ? existingData.opponentUsername : existingData.creatorUsername,
        };
      }

      // ── Active challenge cap ───────────────────────────────────────────────
      // Moved INSIDE the ghost-reserve transaction below so two concurrent
      // quick matches (or a quick match racing a create/join) can't both pass a
      // stale pre-read. Ghost challenges don't count (status 'ghost' is not in
      // ACTIVE_CHALLENGE_STATUSES), so this only limits real 1v1s.

      // ── Ghost-only Quick Match: removed real player matchmaking ─────────────────
      // Remove self from queue if exists (cleanup from previous attempts)
      await db.collection('matchmaking_queue').doc(uid).delete().catch(() => {});

      // Go straight to ghost match (no waiting)
      //
      // IMPORTANT: the QM token is NOT consumed here up-front anymore. It used to
      // be burned in a standalone transaction BEFORE searching for a ghost
      // opponent �?so when every ghost title was unavailable (no sessions), the
      // player still lost a token without ever getting a match. The token is now
      // consumed atomically inside the same transaction that reserves a ghost
      // session (see _consumeQMTokenInTx below), so a token is only ever spent
      // when a match is actually created. If no ghost is found, nothing is
      // consumed and the caller sees noGhostsAvailable with their token intact.
      // ── Skill-matched ghost selection ──────────────────────────────────
      // The player's rolling QM average (qmAvgScore, maintained in
      // submitQuickMatchResult; 7.0 until they have history) picks the
      // band: ghosts scoring within ±2 first, widening to ±3, then any.
      // The player's OWN ghosts are always excluded �?facing yourself
      // means replaying questions you already know the answers to.
      // Candidates are pooled across all anime titles (not per-title) so a
      // thin title never forces a mismatch when a fair ghost exists
      // elsewhere. ghostScore is returned so the client can show an honest
      // "beat X/10" target instead of a mystery opponent.
      const rawAvg = Number(userData.qmAvgScore);
      const targetScore = Number.isFinite(rawAvg)
        ? Math.min(10, Math.max(0, Math.round(rawAvg)))
        : 7;

      const _isValidGhost = (s) =>
        s &&
        typeof s === 'object' &&
        typeof s.sessionId === 'string' && s.sessionId.length > 0 &&
        typeof s.username === 'string' &&
        Number.isInteger(s.score) &&
        Array.isArray(s.questionIds) &&
        s.questionIds.length === 10 &&
        s.questionIds.every((id) => typeof id === 'string' && id.length > 0);

      const ghostTitlesSnap2 = await db.collection('ghost_sessions').limit(30).get();
      const allGhosts = [];
      for (const titleDoc of ghostTitlesSnap2.docs) {
        const sessions = titleDoc.data()?.sessions;
        if (!Array.isArray(sessions)) continue;
        for (const s of sessions) {
          if (!_isValidGhost(s)) continue;
          if (s.uid === uid) continue; // never face your own recording
          allGhosts.push({ anime: titleDoc.id, ref: titleDoc.ref, session: s });
        }
      }

      const _inBand = (band) => {
        const pool = allGhosts.filter(
          (g) => Math.abs(g.session.score - targetScore) <= band
        );
        // Shuffle so the same ghost isn't served to everyone.
        for (let i = pool.length - 1; i > 0; i--) {
          const j = Math.floor(Math.random() * (i + 1));
          [pool[i], pool[j]] = [pool[j], pool[i]];
        }
        return pool;
      };

      let candidates = _inBand(2);
      if (candidates.length === 0) candidates = _inBand(3);
      if (candidates.length === 0) candidates = _inBand(10);

      let reservedGhost = null;
      let chosenAnime = '';
      // A reserved ghost is spliced out of its doc inside the tx, so a
      // concurrent take throws ghost_unavailable �?retry with the next
      // candidate (max 3 attempts) before giving up.
      for (let attempt = 0;
           attempt < 3 && reservedGhost == null && attempt < candidates.length;
           attempt++) {
        const pick = candidates[attempt];
        const challengeRef = db.collection('challenges').doc();
        const expiresAt = Timestamp.fromDate(new Date(Date.now() + 60 * 60 * 1000));
        try {
          await db.runTransaction(async (tx) => {
            const ghostSnap = await tx.get(pick.ref);
            const sessions = (Array.isArray(ghostSnap.data()?.sessions)
              ? [...ghostSnap.data().sessions]
              : []).filter(_isValidGhost);

            const idx = sessions.findIndex(
              (s) => s.sessionId === pick.session.sessionId
            );
            if (idx < 0) {
              throw new Error('ghost_unavailable');
            }

            // Active-challenge cap, checked inside the tx (race-safe). Ghost
            // challenges are excluded by the status filter, so only real 1v1s
            // count against the user's concurrent-match budget.
            const [capAsCreator, capAsOpponent] = await Promise.all([
              tx.get(db.collection('challenges')
                .where('creatorUid', '==', uid)
                .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)),
              tx.get(db.collection('challenges')
                .where('opponentUid', '==', uid)
                .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)),
            ]);
            const capMaxActive = userData.premiumActive === true
              ? ACTIVE_CHALLENGES_PREMIUM
              : ACTIVE_CHALLENGES_FREE;
            if (capAsCreator.size + capAsOpponent.size >= capMaxActive) {
              throw new HttpsError('resource-exhausted', 'too_many_active_challenges');
            }

            reservedGhost = sessions[idx];
            sessions.splice(idx, 1);

            // Consume the QM token in the SAME transaction that reserves the
            // ghost, so a token is never spent unless a match is actually
            // created (see the note above about the old up-front consumption).
            // This also keeps the no_qm_tokens guard atomic with the reserve.
            await _consumeQMTokenInTx(tx, userRef, currentWindowId);

            tx.set(pick.ref, { sessions }, { merge: true });
            tx.set(challengeRef, {
              creatorUid:     uid,
              opponentUid:    'ghost',
              ghostSessionId: reservedGhost.sessionId,
              ghostUsername:  reservedGhost.username,
              // Recorder uid, kept so an abandoned match can hand the recording
              // back to the pool with its "never face your own ghost" identity
              // intact (see expireAbandonedQuickMatches).
              ghostUid:       reservedGhost.uid ?? null,
              opponentUsername: reservedGhost.username,
                ghostScore:     reservedGhost.score,
                animeTitle:     pick.anime,
                betAmount:      0,
                stakeAmount:    0,
                status:         'ghost',
                isQuickMatch:   true,
                challengeType:  'quick',
                questionIds:    reservedGhost.questionIds.map(String),
                expiresAt,
                createdAt: FieldValue.serverTimestamp(),
              });
            });
          } catch (txErr) {
            if (txErr.isTokenError) {
              throw new HttpsError('resource-exhausted', 'no_qm_tokens');
            }
            if (txErr.message === 'ghost_unavailable') {
              reservedGhost = null;
              continue;
            }
            throw txErr;
          }
          if (reservedGhost != null) {
            chosenAnime = pick.anime;
            // Remember which challenge doc the tx wrote (declared outside).
            reservedGhost.challengeId = challengeRef.id;
          }
        }

        if (reservedGhost != null) {
          console.log(
            `[joinMatchmakingQueue] GHOST uid=${uid}` +
            ` | ghost=${reservedGhost.sessionId} | anime=${chosenAnime}` +
            ` | ghostScore=${reservedGhost.score}/10 target=${targetScore}` +
            ` | challengeId=${reservedGhost.challengeId}`
          );
          return {
              matched:       false,
              isGhost:       true,
              isCreator:     true,
              challengeId:   reservedGhost.challengeId,
              questionIds:   reservedGhost.questionIds.map(String),
              animeTitle:    chosenAnime,
              ghostUsername: reservedGhost.username,
              ghostScore:    reservedGhost.score,
            };
        }

      // No ghost sessions available
      console.warn(
        `[joinMatchmakingQueue] No ghost sessions available for uid=${uid}`
      );
      return { matched: false, isGhost: false, noGhostsAvailable: true };

    } catch (err) {
      console.error('[joinMatchmakingQueue] ERROR:', err);
      throw err;
    }
  }
);

exports.leaveMatchmakingQueue = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
      await _assertClientBuildAllowed(request, 'leaveMatchmakingQueue');

      await db.collection('matchmaking_queue').doc(uid).delete();

      console.log(`[leaveMatchmakingQueue] uid=${uid}`);
      return { success: true };

    } catch (err) {
      console.error('[leaveMatchmakingQueue] ERROR:', err);
      throw err;
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── submitQuickMatchResult (unchanged) ────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

async function _handleSubmitQuickMatchResult(request) {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
      await _assertClientBuildAllowed(request, 'submitQuickMatchResult');
      const enforcement = await _assertNotSuspended(uid, 'submitQuickMatchResult');
      await _verifyPlayIntegrity(request, 'submit_quickmatch');

      const {
        challengeId,
        questionIds,
        selectedAnswers,
        timings,
      } = request.data;

      if (typeof challengeId !== 'string' || !challengeId.trim()) {
        throw new Error('invalid_challenge_id');
      }

      if (
        !Array.isArray(questionIds)   ||
        questionIds.length !== 10     ||
        !questionIds.every(id => typeof id === 'string' && id.length > 0)
      ) {
        throw new Error('invalid_question_ids');
      }

      if (new Set(questionIds).size !== 10) {
        throw new Error('duplicate_question_id');
      }

      if (
        !Array.isArray(selectedAnswers) ||
        selectedAnswers.length !== 10   ||
        !selectedAnswers.every(
          a => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3))
        )
      ) {
        throw new Error('invalid_selected_answers');
      }

      if (
        !Array.isArray(timings) ||
        timings.length !== 10   ||
        !timings.every(
          t => Number.isInteger(t) && (t === -1 || (t >= 0 && t <= 60))
        )
      ) {
        throw new Error('invalid_timings');
      }

      const CHUNK_SIZE   = 10;
      const questionDocs = [];

      for (let i = 0; i < questionIds.length; i += CHUNK_SIZE) {
        const chunk = questionIds.slice(i, i + CHUNK_SIZE);
        const refs  = chunk.map(id => db.collection('questions').doc(id));
        const snaps = await db.getAll(...refs);
        questionDocs.push(...snaps);
      }

      for (const snap of questionDocs) {
        if (!snap.exists) throw new Error('invalid_question_id');
      }

      const questionMap = {};
      for (const snap of questionDocs) questionMap[snap.id] = snap.data();

      let correctCount = 0;
      let baseWP       = 0;

      for (let i = 0; i < 10; i++) {
        const question  = questionMap[questionIds[i]];
        const isCorrect = selectedAnswers[i] === question.correctAnswerIndex;
        if (isCorrect) {
          correctCount++;
          baseWP += (timings[i] >= 5) ? 15 : 10;
        }
      }

      const completionWP = 20;
      const totalWP = baseWP + completionWP;

      const challengeRef  = db.collection('challenges').doc(challengeId);
      const challengeSnap = await challengeRef.get();
      if (!challengeSnap.exists) throw new Error('challenge_not_found');

      const challenge = challengeSnap.data();

      if (!challenge.isQuickMatch) throw new Error('not_a_quick_match');

      const authoritativeQuestionIds = Array.isArray(challenge.questionIds) ? challenge.questionIds : [];
      if (
        authoritativeQuestionIds.length !== 10 ||
        authoritativeQuestionIds.some((id, idx) => id !== questionIds[idx])
      ) {
        throw new Error('question_set_mismatch');
      }

      const isCreator  = challenge.creatorUid  === uid;
      const isOpponent = challenge.opponentUid === uid;
      if (!isCreator && !isOpponent) throw new Error('not_a_participant');

      const ghostMatch = challenge.opponentUid === 'ghost';

      if (ghostMatch) {
        if (challenge.status === 'completed') {
          console.log(
            `[submitQuickMatchResult] GHOST uid=${uid}` +
            ` challengeId=${challengeId} �?already completed, skipping`
          );
          return {
            correctCount,
            isGhost:  true,
            outcome:  challenge.outcome || 'opponent_wins',
            wpEarned: 0,
            acEarned: 0,
          };
        }

        const ghostScore  = challenge.ghostScore ?? 0;
        const animeTitle  = challenge.animeTitle || 'Unknown Anime';
        const ghostUsername = challenge.ghostUsername || 'Ghost Opponent';

        // `outcome` uses the SAME creator_wins/opponent_wins/draw vocabulary
        // _resolveChallengeCore writes to the challenge doc for every other
        // challenge type (Rival/Code/real Quick Match). This used to be
        // 'win'/'draw'/'lose' here, which ChallengeModel.winnerUid() on the
        // client never recognises (it only matches 'creator_wins' /
        // 'opponent_wins') �?so a ghost-match WIN was silently treated as
        // unresolved/lost throughout the Lobby/Result UI: wrong "You Lost"
        // banner, no confetti, and the VS card never highlighted the winner.
        // This only stayed hidden as long as ghost matches had their own
        // dedicated QuickMatchResultPage reading wpEarned/acEarned/outcome
        // straight off this function's return value instead of the
        // Firestore doc's outcome field.
        //
        // `matchOutcome` keeps the separate win/lose/draw vocabulary the
        // per-user matches subcollection already uses everywhere else (see
        // creatorOutcome/opponentOutcome in _resolveChallengeCore, and
        // getHeadToHeadRecord's reads) �?the ghost always occupies the
        // "opponent" slot, so from the real player's own perspective a
        // challenge-level 'opponent_wins' is a personal 'lose'.
        let outcome, matchOutcome, wpEarned, acEarned;
        // Declared OUTSIDE the transaction: it is read by the console.log and
        // return statement below, after the tx callback has closed. Declaring
        // it inside made those throw ReferenceError post-commit, so the client
        // saw an error even though the match had been saved.
        let achievementAC = 0;
        if (correctCount > ghostScore) {
          outcome = 'creator_wins';  matchOutcome = 'win';  wpEarned = QM_WP_WIN;  acEarned = QM_AC_WIN;
        } else if (correctCount === ghostScore) {
          outcome = 'draw';          matchOutcome = 'draw'; wpEarned = QM_WP_DRAW; acEarned = QM_AC_DRAW;
        } else {
          outcome = 'opponent_wins'; matchOutcome = 'lose'; wpEarned = QM_WP_LOSE; acEarned = QM_AC_LOSE;
        }

        // Silent enforcement decay on the minted QM reward (never the stake;
        // QM is stake-free). AC may legitimately be 0 on a loss.
        wpEarned = Math.max(1, _applyDecay(wpEarned, enforcement.decayFactor));
        acEarned = Math.max(0, _applyDecay(acEarned, enforcement.decayFactor));

        const userRef    = db.collection('users').doc(uid);
        const matchRef   = userRef.collection('matches').doc();

        // Idempotency: the pre-tx status check above is not race-safe on its
        // own. Re-read the challenge inside the tx and bail if a concurrent
        // submission already settled it, so a double-tap can't pay twice.
        let alreadySettled = false;

        await db.runTransaction(async (tx) => {
          const [userSnap, freshChallengeSnap] = await Promise.all([
            tx.get(userRef),
            tx.get(challengeRef),
          ]);
          const freshChallenge = freshChallengeSnap.data() || {};
          if (!freshChallengeSnap.exists ||
              freshChallenge.resolved === true ||
              freshChallenge.status === 'completed') {
            alreadySettled = true;
            return;
          }
          const userData     = userSnap.data() || {};
          const currentCoins = userData.animeCoins || 0;
          const newBalance   = currentCoins + acEarned;

          // Apply Premium 1.20× multiplier BEFORE soft cap.
          if (userData.premiumActive === true && wpEarned > 0) {
            wpEarned = Math.floor(wpEarned * 1.20);
          }

          tx.update(challengeRef, {
            status:        'completed',
            outcome,
            challengeType: 'quick',
            creatorScore:  correctCount,
            // Previously never written for ghost matches, so the Lobby/
            // Result "vs" card always showed the ghost's score as blank �?
            // real matches get this from the resolveChallengeOutcome
            // trigger, but ghost matches skip that trigger entirely and
            // resolve fully here, so it has to be set explicitly.
            opponentScore: ghostScore,
            resolved:      true,
          });

          // Wrap the awarded WP through the shared daily soft cap. wpEarned is
          // reassigned to the awarded amount so the match log (wpChange) and the
          // returned value reflect what the player actually received.
          const { award: awardedWP, newEarnedToday } =
            _applyDailyWPSoftCap(wpEarned, _resolveDailyWPEarned(userData, _watDateString()));
          wpEarned = awardedWP;

          const userUpdate = {
            weeklyPoints:        FieldValue.increment(wpEarned),
            'stats.gamesPlayed': FieldValue.increment(1),
            'stats.careerWpEarned': FieldValue.increment(wpEarned),
            wpEarnedToday:       newEarnedToday,
            wpEarnedDate:        FieldValue.serverTimestamp(),
            // Rolling QM skill average �?drives fair ghost matching in
            // joinMatchmakingQueue (band around this average). Plain
            // read-modify-write inside the tx; first game seeds it.
            qmAvgCount: (() => {
              const c = Number(userData.qmAvgCount) || 0;
              return c + 1;
            })(),
            qmAvgScore: (() => {
              const c = Number(userData.qmAvgCount) || 0;
              const prev = Number(userData.qmAvgScore);
              return Number.isFinite(prev)
                ? (prev * c + correctCount) / (c + 1)
                : correctCount;
            })(),
          };

          if      (matchOutcome === 'win')  userUpdate['stats.gamesWon']  = FieldValue.increment(1);
          else if (matchOutcome === 'draw') userUpdate['stats.gamesDraw']  = FieldValue.increment(1);
          else                              userUpdate['stats.gamesLost'] = FieldValue.increment(1);

          // Stage 13: Achievements for ghost matches. Reads pre-increment stats
          // from userData (fetched at tx start) and writes the granted map in the
          // same transaction. "Perfect" = all 10 questions correct, matching
          // submitQuizAnswers. Uses plain local-number deltas �?no .operand reads.
          const isPerfect = correctCount === 10;
          if (isPerfect) {
            userUpdate['stats.perfectQuizzes'] = FieldValue.increment(1);
          }

          const statDeltas = { gamesPlayed: 1, careerWpEarned: wpEarned };
          if (matchOutcome === 'win') statDeltas.gamesWon = 1;
          if (isPerfect) statDeltas.perfectQuizzes = 1;

          const achievements = _checkAchievementTiers(userData, statDeltas);
          achievementAC = achievements.acGranted || 0;

          const totalAC = acEarned + achievementAC;
          if (totalAC > 0) {
            userUpdate.animeCoins = FieldValue.increment(totalAC);
          }
          if (achievementAC > 0) {
            userUpdate.achievementsGranted = achievements.newAchievementsGranted;
          }
          if (achievements.framesToGrant.length > 0) {
            userUpdate.ownedCosmetics = FieldValue.arrayUnion(...achievements.framesToGrant);
          }

          tx.update(userRef, userUpdate);

          if (acEarned > 0) {
            const txLogRef = userRef.collection('coinTransactions').doc();
            tx.set(txLogRef, {
              type:        'earn_quick_match',
              delta:       acEarned,
              balanceAfter: newBalance,
              timestamp:   FieldValue.serverTimestamp(),
            });
          }

          // Distinct ledger entry for achievement coins.
          if (achievementAC > 0) {
            tx.set(userRef.collection('coinTransactions').doc(), {
              type:         'earn_achievement',
              delta:        achievementAC,
              balanceAfter: newBalance + achievementAC,
              timestamp:    FieldValue.serverTimestamp(),
            });
          }

          tx.set(matchRef, {
            opponent:      ghostUsername,
            playerScore:   correctCount,
            opponentScore: ghostScore,
            betScore:      0,
            stakeAmount:   0,
            wpStake:       0,
            outcome:       matchOutcome,
            pointsChange:  0,
            wpChange:      wpEarned,
            wpAwarded:     wpEarned,
            animeTitle,
            isQuickMatch:  true,
            challengeId:   challengeId,
            timestamp:     FieldValue.serverTimestamp(),
          });
        });

        if (alreadySettled) {
          console.log(
            `[submitQuickMatchResult] GHOST uid=${uid}` +
            ` | challengeId=${challengeId} already settled by a concurrent submission`
          );
          return {
            correctCount,
            isGhost:  true,
            outcome:  challenge.outcome || 'opponent_wins',
            wpEarned: 0,
            acEarned: 0,
          };
        }

        console.log(
          `[submitQuickMatchResult] GHOST uid=${uid}` +
          ` | challengeId=${challengeId}` +
          ` | correct=${correctCount}/10 ghostScore=${ghostScore}` +
          ` | outcome=${outcome} (${matchOutcome}) +${wpEarned} WP +${acEarned} AC achievement=+${achievementAC} AC`
        );
        // ── Step 5b: ghost QM �?mark the human player's set here. The
        // resolve trigger skips ghost docs, so core never sees them. Real
        // (non-ghost) matches are marked once at resolution time instead.
        _markQuestionsSeen(uid, questionIds, questionMap).catch((e) =>
          console.error(`[submitQuickMatchResult] seen-mark failed (non-fatal): ${e.message}`)
        );
        return { correctCount, isGhost: true, outcome, wpEarned, acEarned, achievementAC, opponentScore: ghostScore };
      }

      const scoreField = isCreator ? 'creatorScore' : 'opponentScore';

      if (challenge[scoreField] != null) {
        console.log(
          `[submitQuickMatchResult] REAL uid=${uid}` +
          ` | challengeId=${challengeId}` +
          ` | ${scoreField} already set �?skipping`
        );
        return { correctCount, isGhost: false };
      }

      await challengeRef.update({ [scoreField]: correctCount });

      console.log(
        `[submitQuickMatchResult] REAL uid=${uid}` +
        ` | challengeId=${challengeId}` +
        ` | wrote ${scoreField}=${correctCount} (formula totalWP=${totalWP})`
      );
      return { correctCount, isGhost: false };

    } catch (err) {
      console.error('[submitQuickMatchResult] ERROR:', err);
      throw err;
    }
}

exports.submitQuickMatchResult = onSecureCall(
  { region: 'us-central1' },
  _handleSubmitQuickMatchResult
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── submitChallengeScore (Rival / Code / Spar) ─────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Server-authoritative score for every NON-ghost challenge, exactly as
// submitQuickMatchResult is for Quick Match. The client no longer writes
// creatorScore / opponentScore directly (firestore.rules denies it), so a
// patched client can no longer submit a winning score and steal the opponent's
// stake. The question set is read straight off the challenge doc, so a caller
// cannot swap in questions whose answers they know.
async function _handleSubmitChallengeScore(request) {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
      await _assertClientBuildAllowed(request, 'submitChallengeScore', { requireStamp: true });
      await _assertNotSuspended(uid, 'submitChallengeScore');
      await _verifyPlayIntegrity(request, 'submit_challenge');

      const {
        challengeId,
        questionIds,
        selectedAnswers,
        timings,
      } = request.data || {};

      if (typeof challengeId !== 'string' || !challengeId.trim()) {
        throw new HttpsError('invalid-argument', 'invalid_challenge_id');
      }
      if (
        !Array.isArray(questionIds) || questionIds.length !== 10 ||
        !questionIds.every((id) => typeof id === 'string' && id.length > 0)
      ) {
        throw new HttpsError('invalid-argument', 'invalid_question_ids');
      }
      if (new Set(questionIds).size !== 10) {
        throw new HttpsError('invalid-argument', 'duplicate_question_id');
      }
      if (
        !Array.isArray(selectedAnswers) || selectedAnswers.length !== 10 ||
        !selectedAnswers.every((a) => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3)))
      ) {
        throw new HttpsError('invalid-argument', 'invalid_selected_answers');
      }
      if (
        !Array.isArray(timings) || timings.length !== 10 ||
        !timings.every((t) => Number.isInteger(t) && (t === -1 || (t >= 0 && t <= 60)))
      ) {
        throw new HttpsError('invalid-argument', 'invalid_timings');
      }

      const challengeRef  = db.collection('challenges').doc(challengeId);
      const challengeSnap = await challengeRef.get();
      if (!challengeSnap.exists) {
        throw new HttpsError('not-found', 'challenge_not_found');
      }
      const challenge = challengeSnap.data();

      // Quick Match owns its own submission path (it also settles the ghost in
      // place), so it must never route through here.
      if (challenge.isQuickMatch === true || challenge.opponentUid === 'ghost') {
        throw new HttpsError('failed-precondition', 'use_submit_quick_match');
      }
      if (challenge.resolved === true || challenge.status === 'completed') {
        throw new HttpsError('failed-precondition', 'challenge_not_active');
      }

      const isCreator  = challenge.creatorUid  === uid;
      const isOpponent = challenge.opponentUid === uid;
      if (!isCreator && !isOpponent) {
        throw new HttpsError('permission-denied', 'not_a_participant');
      }

      // The question set is authoritative on the challenge doc.
      const authoritativeIds = Array.isArray(challenge.questionIds)
        ? challenge.questionIds.map(String)
        : [];
      if (
        authoritativeIds.length !== 10 ||
        authoritativeIds.some((id, idx) => id !== questionIds[idx])
      ) {
        throw new HttpsError('failed-precondition', 'question_set_mismatch');
      }

      // The caller's own seat must still be free.
      const scoreField = isCreator ? 'creatorScore' : 'opponentScore';
      if (challenge[scoreField] != null) {
        throw new HttpsError('failed-precondition', 'score_already_submitted');
      }
      // The caller must actually hold a seat: the opponent can only play after
      // joining (which is what debited their stake); the creator after their own
      // create (which is why 'waiting' is allowed for the creator only).
      const allowedStatuses = isCreator
        ? ['waiting', 'opponent_joined', 'opponent_submitted']
        : ['opponent_joined', 'creator_submitted'];
      if (!allowedStatuses.includes(challenge.status)) {
        throw new HttpsError('failed-precondition', 'challenge_not_active');
      }
      // 'creator_submitted' now ALSO occurs while a creator has played but the
      // invitee has not accepted yet (the invite stays open). In that state the
      // opponent has not paid a stake, so they must not be able to play: require
      // joinedAt (set by joinChallenge) before an opponent's score is accepted.
      // (Legacy docs joined before this field existed are still covered by the
      // unambiguous 'opponent_joined' state.)
      if (isOpponent && !challenge.joinedAt) {
        throw new HttpsError('failed-precondition', 'challenge_not_active');
      }

      // Score the answers against the real question documents.
      const refs = questionIds.map((id) => db.collection('questions').doc(id));
      const snaps = await db.getAll(...refs);
      let correctCount = 0;
      for (let i = 0; i < snaps.length; i++) {
        const snap = snaps[i];
        if (!snap.exists) {
          throw new HttpsError('failed-precondition', 'invalid_question_id');
        }
        const q = snap.data() || {};
        if (selectedAnswers[i] === q.correctAnswerIndex) correctCount++;
      }

      // Write atomically, and only if the seat is STILL free: a double-tap or a
      // retry must never overwrite/duplicate a submitted score.
      let wrote = false;
      await db.runTransaction(async (tx) => {
        const freshSnap = await tx.get(challengeRef);
        const fresh = freshSnap.data() || {};
        if (!freshSnap.exists || fresh.resolved === true) return;
        if (fresh[scoreField] != null) return;
        tx.update(challengeRef, { [scoreField]: correctCount });
        wrote = true;
      });

      console.log(
        `[submitChallengeScore] uid=${uid} | challengeId=${challengeId}` +
        ` | ${scoreField}=${correctCount} | wrote=${wrote}`
      );
      return { correctCount, scoreField, isCreator, wrote };
    } catch (err) {
      if (!(err instanceof HttpsError)) {
        console.error('[submitChallengeScore] ERROR:', err);
      }
      throw err;
    }
}

exports.submitChallengeScore = onSecureCall(
  { region: 'us-central1' },
  _handleSubmitChallengeScore
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── saveGhostSession (unchanged) ──────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.saveGhostSession = onSecureCall(
  { region: 'us-central1', cpu: 0.5, memory: '256MiB', maxInstances: 1 },
  async (request) => {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
      await _assertClientBuildAllowed(request, 'saveGhostSession', { requireStamp: true });

      let { animeTitle, questionIds, answers } = request.data || {};

      // Ghosts are now derived from a completed, server-minted run. The client
      // can no longer post an arbitrary perfect session into the pool.
      const runId = typeof request.data?.runId === 'string' ? request.data.runId.trim() : '';
      if (!runId) throw new Error('invalid_run_id');
      const runSnap = await db.collection(QUIZ_RUNS).doc(runId).get();
      if (!runSnap.exists) throw new Error('invalid_run_id');
      const run = runSnap.data() || {};
      if (run.uid !== uid) throw new Error('not_your_run');
      if (run.kind !== 'quickmatch') throw new Error('invalid_run_kind');
      if (run.state !== 'submitted') throw new Error('run_not_submitted');
      questionIds = Array.isArray(run.questionIds) ? run.questionIds : [];
      answers = (Array.isArray(run.answers) ? run.answers : [])
        .sort((a, b) => Number(a.index) - Number(b.index))
        .map((a) => Number(a.answer));
      if (Array.isArray(run.titles) && run.titles.length) {
        animeTitle = run.titles[0];
      }

      const cleanAnimeTitle = typeof animeTitle === 'string' ? animeTitle.trim().toLowerCase() : '';

      if (!cleanAnimeTitle) {
        throw new Error('invalid_anime_title');
      }

      if (
        !Array.isArray(questionIds)  ||
        questionIds.length !== 10    ||
        !questionIds.every(id => typeof id === 'string' && id.length > 0)
      ) {
        throw new Error('invalid_question_ids');
      }

      if (new Set(questionIds).size !== 10) {
        throw new Error('duplicate_question_ids');
      }

      if (
        !Array.isArray(answers)    ||
        answers.length !== 10      ||
        !answers.every(a => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3)))
      ) {
        throw new Error('invalid_answers');
      }

      const refs = questionIds.map(id => db.collection('questions').doc(id));
      const questionSnaps = await db.getAll(...refs);

      let computedScore = 0;
      for (let i = 0; i < questionSnaps.length; i++) {
        const snap = questionSnaps[i];
        if (!snap.exists) {
          throw new Error('invalid_question_id');
        }

        const q = snap.data() || {};
        if ((q.animeTitle || '').trim().toLowerCase() !== cleanAnimeTitle) {
          throw new Error('question_anime_mismatch');
        }

        if (answers[i] === q.correctAnswerIndex) {
          computedScore++;
        }
      }

      const MIN_GHOST_SCORE = 6;
      if (computedScore < MIN_GHOST_SCORE) {
        console.log(`[saveGhostSession] uid=${uid} score=${computedScore} below threshold �?not saved`);
        return { success: true, saved: false, score: computedScore };
      }

      const sessionId = db.collection('ghost_sessions').doc().id;
      const ghostRef  = db.collection('ghost_sessions').doc(cleanAnimeTitle);
      const userRef   = db.collection('users').doc(uid);

      let saved = false;
      let duplicate = false;

      await db.runTransaction(async (tx) => {
        const [ghostSnap, userSnap] = await Promise.all([
          tx.get(ghostRef),
          tx.get(userRef),
        ]);

        const data     = ghostSnap.data() || {};
        const sessions = Array.isArray(data.sessions) ? [...data.sessions] : [];

        duplicate = sessions.some((s) =>
          s.uid === uid &&
          Array.isArray(s.questionIds) &&
          Array.isArray(s.answers) &&
          s.questionIds.length === questionIds.length &&
          s.answers.length === answers.length &&
          s.questionIds.every((id, idx) => id === questionIds[idx]) &&
          s.answers.every((answer, idx) => answer === answers[idx])
        );

        if (duplicate) return;

        if (sessions.length >= 20) sessions.shift();

        const serverUsername = typeof userSnap.data()?.username === 'string' && userSnap.data().username.trim()
          ? userSnap.data().username.trim()
          : 'Anonymous';

        sessions.push({
          sessionId,
          uid,
          username: serverUsername,
          questionIds,
          answers,
          score: computedScore,
          recordedAt: Timestamp.now(),
        });

        tx.set(ghostRef, { sessions }, { merge: true });
        saved = true;
      });

      console.log(
        `[saveGhostSession] uid=${uid}` +
        ` | anime=${cleanAnimeTitle}` +
        ` | sessionId=${saved ? sessionId : 'duplicate'}` +
        ` | score=${computedScore}/10` +
        ` | saved=${saved}`
      );
      return { success: true, saved, duplicate, score: computedScore };

    } catch (err) {
      console.error('[saveGhostSession] ERROR:', err);
      throw err;
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 13: IAP COIN PACKS (unchanged) ───────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// Coin amounts are 1 AC per �? of pack price, plus the advertised tier bonus
// (�?00 �?500; �?,500 + 10% �?1,650; �?,000 + 20% �?4,800). Product IDs keep
// their original names because they are external identifiers (Play Store SKUs
// / Flutterwave tx_ref tokens) and must not change.
const IAP_CATALOG = {
  animequiz_coins_300:  { acAmount: 500  },
  animequiz_coins_1100: { acAmount: 1650 },
  animequiz_coins_3600: { acAmount: 4800 },
};

exports.verifyIAPPurchase = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const { purchaseToken, productId } = request.data || {};
    if (typeof purchaseToken !== 'string' || !purchaseToken.trim()) {
      throw new HttpsError('invalid-argument', 'purchaseToken is required');
    }

    const product = IAP_CATALOG[productId];
    if (!product) {
      throw new HttpsError('invalid-argument', 'invalid_product');
    }

    const userRef    = db.collection('users').doc(uid);
    const receiptRef = userRef.collection('iapReceipts').doc(purchaseToken);

    const existing = await receiptRef.get();
    if (existing.exists) {
      return { success: true, alreadyClaimed: true };
    }

    let result;
    await db.runTransaction(async (tx) => {
      const receiptSnap = await tx.get(receiptRef);
      if (receiptSnap.exists) {
        result = { success: true, alreadyClaimed: true };
        return;
      }

      const userSnap    = await tx.get(userRef);
      const currentCoins = userSnap.data()?.animeCoins || 0;
      const newBalance    = currentCoins + product.acAmount;

      tx.update(userRef, {
        animeCoins: FieldValue.increment(product.acAmount),
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:         'iap',
        delta:        product.acAmount,
        balanceAfter: newBalance,
        timestamp:    FieldValue.serverTimestamp(),
      });

      tx.set(receiptRef, {
        productId,
        acAmount:  product.acAmount,
        uid,
        claimedAt: FieldValue.serverTimestamp(),
      });

      result = {
        success:              true,
        coinsAwarded:         product.acAmount,
        newBalance,
      };
    });

    console.log(`[verifyIAPPurchase] uid=${uid} product=${productId} �?${JSON.stringify(result)}`);
    return result;
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 14: PREMIUM PASS (unchanged) ──────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

exports.verifyPremiumPurchase = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const { purchaseToken } = request.data || {};
    if (typeof purchaseToken !== 'string' || !purchaseToken.trim()) {
      throw new HttpsError('invalid-argument', 'purchaseToken is required');
    }

    const userRef    = db.collection('users').doc(uid);
    const receiptRef = userRef.collection('premiumReceipts').doc(purchaseToken);

    const existing = await receiptRef.get();
    if (existing.exists) {
      return { success: true, alreadyClaimed: true };
    }

    const now      = Timestamp.now();
    const expiresAt = Timestamp.fromMillis(now.toMillis() + 28 * 24 * 60 * 60 * 1000);

    await db.runTransaction(async (tx) => {
      const receiptSnap = await tx.get(receiptRef);
      if (receiptSnap.exists) return;

      tx.update(userRef, { premiumActive: true });
      tx.set(receiptRef, {
        uid,
        activatedAt: FieldValue.serverTimestamp(),
        expiresAt,
      });
    });

    console.log(`[verifyPremiumPurchase] uid=${uid} premiumActive=true expiresAt=${expiresAt.toDate().toISOString()}`);
    return { success: true };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 14b: REDEMPTION CODES ──────────────────────────────────────────
// Alternative distribution channel for AC / Premium entitlements (not a
// payment method �?claiming an already-granted entitlement, so no Play Billing
// involvement). The grant paths below reuse the exact shapes proven in
// verifyIAPPurchase (coinTransactions ledger) and verifyPremiumPurchase
// (premiumReceipts + premiumActive), so expireExpiredPremium needs zero changes.
// ─────────────────────────────────────────────────────────────────────────────

// Admin-only gate. FILL IN the real UID before deploying �?the placeholder is
// intentionally left so it can't be missed.
const ADMIN_UIDS = ['owMNkXmb6QSzO0xfHkSgMlx0zSJ3'];

// O(1) membership + one named predicate so every admin exclusion reads the
// same way. Admin accounts are GHOSTS: never ranked, never paid, never
// notified, never counted on any player-facing board or query.
// Mirrored in firestore.rules (isPayoutAdmin) and in
// lib/core/constants/admin_accounts.dart �?keep all three in sync when the
// admin account rotates.
const ADMIN_UID_SET = new Set(ADMIN_UIDS);
function isAdminAccountUid(uid) {
  return !!uid && ADMIN_UID_SET.has(uid);
}

// Charset for generated codes: uppercase letters + digits, excluding the
// ambiguous 0/O and 1/I/L. 12 chars (XXXX-XXXX-XXXX) �?31^12 �?7.9e17 combos.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

// Cryptographically uniform picks (crypto.randomInt carries no modulo bias).
// NOTE: this is the LEADERBOARD REDEMPTION-code generator (XXXX-XXXX-XXXX).
// It must NOT be named _generateCode �?the early challenge-code helper at the
// top of this file defines function _generateCode() in the same module scope,
// and the later declaration silently overrides the earlier one. That shadowing
// made every shareCode long/broken and broke join-by-code. Until the rename,
// do not add another _generateCode. Admin-generated code and the Flutterwave
// webhook both go through _generateUniqueCode below, which calls this function.
function _generateRedemptionCode() {
  let s = '';
  for (let i = 0; i < 12; i++) {
    s += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  }
  return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}`;
}

// ─── Shared code-generation core ───────────────────────────────────────────
// Both the admin generator (generateRedemptionCodes) and the Flutterwave
// webhook (flutterwaveWebhook) reuse this single source of truth so the code
// format + collision logic can never drift between the two.
//
// `_generateUniqueCode(read)` returns a fresh non-colliding code. `read` is an
// async (code) => snapshot function; when omitted it reads the live document
// (admin path). Inside a Firestore transaction, pass (c) => tx.get(ref(c)) so
// the collision check happens within that transaction.
async function _generateUniqueCode(read) {
  const get = read || ((c) => db.collection('redemptionCodes').doc(c).get());
  for (;;) {
    const candidate = _generateRedemptionCode();
    const snap = await get(candidate);
    if (!snap.exists) return candidate;
  }
}

// Build the canonical document fields for a freshly generated code. `extra` may
// carry audit-only fields (paidAmount, flwTxnId, buyerEmail, productId) for
// Flutterwave-generated codes; redeemCode ignores unknown fields.
function _buildCodeDoc({ type, value, source, createdBy, extra = {} }) {
  return {
    type,
    value,
    status:    'unused',
    source,
    createdAt: FieldValue.serverTimestamp(),
    createdBy,
    ...extra,
  };
}

// Generate one non-colliding code and persist it. `writer(code, doc)` is the
// batch/tx write hook; when omitted the redemptionCodes doc is set directly.
// Returns the generated code string.
async function _generateAndWriteCode(
  { type, value, source, createdBy, extra = {} },
  writer,
  read
) {
  const code = await _generateUniqueCode(read);
  const doc  = _buildCodeDoc({ type, value, source, createdBy, extra });
  if (writer) {
    writer(code, doc);
  } else {
    await db.collection('redemptionCodes').doc(code).set(doc);
  }
  return code;
}

// ─── Flutterwave product catalog (auditable) ───────────────────────────────
// Single source of truth mapping a productId �?what the buyer gets in-app
// ({type, value}) AND the exact NGN price the pipeline expects. txToken is the
// Flutterwave-safe (^[A-Za-z0-9-]+$) encoding embedded in tx_ref.
const FLUTTERWAVE_PRODUCTS = {
  'AQ_AC_300':  { txToken: 'AC300',  type: 'ac',      value: 500,  amount: 500,  currency: 'NGN', title: 'Add 500 Anime Coins' },
  'AQ_AC_1100': { txToken: 'AC1100', type: 'ac',      value: 1650, amount: 1500, currency: 'NGN', title: 'Add 1650 Anime Coins' },
  'AQ_AC_3600': { txToken: 'AC3600', type: 'ac',      value: 4800, amount: 4000, currency: 'NGN', title: 'Add 4800 Anime Coins' },
  'AQ_PREM_31': { txToken: 'PREM31', type: 'premium', value: 28,   amount: 2000, currency: 'NGN', title: 'Premium Pass (28 days)' },
  // Leaderboard entry: the week ID is injected at mint time (currentWeekId()),
  // so `value` here is a placeholder. txToken LBWK cannot prefix-collide with
  // AC300/AC1100/AC3600/PREM31 in the tx_ref startsWith resolution.
  'AQ_LB_WEEK': { txToken: 'LBWK',  type: 'leaderboard_entry', value: 0,   amount: 500,  currency: 'NGN', title: 'Weekly Leaderboard Entry' },
};

// Shared: resolve a product from a tx_ref (prefix match, no meta trust).
function _resolveProductFromTxRef(txRefStr) {
  const s = typeof txRefStr === 'string' ? txRefStr : '';
  const entry = Object.entries(FLUTTERWAVE_PRODUCTS)
    .find(([, p]) => s.startsWith('AQ-' + p.txToken + '-'));
  return entry ? { productId: entry[0], product: entry[1] } : { productId: '', product: null };
}

// One authenticated GET against the Flutterwave v3 API. Throws unless the call
// succeeded, EXCEPT for an explicit "no such transaction" (400/404 answering
// { status: 'error', data: null }), which is a normal empty result: the charge
// may simply not have reached Flutterwave yet.
async function _flwGet(url, secret) {
  const resp = await fetch(url, { headers: { Authorization: 'Bearer ' + secret } });
  const json = await resp.json().catch(() => ({}));
  const notFound = !resp.ok
    && (resp.status === 400 || resp.status === 404)
    && json && json.status === 'error' && !json.data;
  if (notFound) return { status: 'success', data: null };
  if (!resp.ok || json.status !== 'success') {
    throw new Error('Flutterwave verify HTTP ' + resp.status + ': ' + JSON.stringify(json).slice(0, 300));
  }
  return json;
}

// Normalise a transaction from either verify endpoint into ONE shape. The
// documented verify-by-reference endpoint nests the buyer's address under
// `customer.email`; the transaction LIST returns a flat `customer_email` (and
// often no customer object at all), so both are folded into customer.email.
function _normalizeFlwTxn(t) {
  if (!t || typeof t !== 'object') return null;
  const email = String(
    (t.customer && t.customer.email) || t.customer_email || ''
  ).trim().toLowerCase();
  return { ...t, customer: { ...(t.customer || {}), email } };
}

// Shared: verify a charge with Flutterwave by tx_ref. Used by getPurchasedCode
// to self-heal a payment whose webhook was late, lost, or transiently rejected.
//
// Prefers the documented verify-by-reference endpoint (ONE transaction, with
// the buyer's customer.email) and falls back to the transaction list when that
// endpoint is unavailable or does not know the reference yet. The list is a
// search: it can return rows for other references, so results are filtered to
// the exact tx_ref. Returns the matching transactions (possibly empty); throws
// on transport/auth errors so the caller can answer with a retryable status.
async function _verifyFlutterwaveByTxRef(txRef) {
  const secret = FLW_SECRET_KEY.value();
  const enc = encodeURIComponent(txRef);

  let firstErr = null;
  try {
    const one = await _flwGet(
      'https://api.flutterwave.com/v3/transactions/verify_by_reference?tx_ref=' + enc,
      secret
    );
    const row = _normalizeFlwTxn(one.data);
    if (row) return [row];
  } catch (err) {
    firstErr = err;
    console.warn(`[getPurchasedCode] verify_by_reference unavailable (${err.message}); trying the transactions list`);
  }

  try {
    const list = await _flwGet(
      'https://api.flutterwave.com/v3/transactions?tx_ref=' + enc,
      secret
    );
    const rows = Array.isArray(list.data) ? list.data : [];
    return rows
      .map(_normalizeFlwTxn)
      .filter((t) => t && (!t.tx_ref || t.tx_ref === txRef));
  } catch (err) {
    // Surface the documented endpoint's failure first: it is the one that
    // should have worked.
    throw firstErr || err;
  }
}

// Shared: mint the code for a CONFIRMED charge (single source of truth).
// Both the webhook (flutterwaveWebhook) and the self-healing delivery path
// (getPurchasedCode) funnel through here so a confirmed, price-checked payment
// ALWAYS produces a code, idempotently, keyed on Flutterwave's transaction id.
//
// Returns { status, code, rejected, buyerEmail }:
//   status 'fulfilled' -> a fresh code was minted (code set)
//   status 'duplicate' -> this Flutterwave txn id was already fulfilled (code set)
//   status 'rejected'  -> no trusted buyer email could be attributed (code null)
//
// buyerEmail (from the checkout paymentIntent) wins; fallbackEmail (Flutterwave's
// customer.email, authoritative in live mode) is used only when the intent is
// missing so a confirmed payment is never silently dropped.
async function _mintCharge({
  txRef, flwTxnId, amount, currency, product, productId, buyerEmail, fallbackEmail,
}) {
  const result = { status: 'rejected', code: null, rejected: null, buyerEmail: null };

  await db.runTransaction(async (tx) => {
    const processedRef = db.collection('processedTransactions').doc(flwTxnId);
    const processedSnap = await tx.get(processedRef);
    if (processedSnap.exists) {
      const prev = processedSnap.data() || {};
      result.status = 'duplicate';
      result.code = prev.code || null;
      result.rejected = null;
      return;
    }

    const intentRef  = db.collection('paymentIntents').doc(txRef);
    const intentSnap = await tx.get(intentRef);
    const intent = intentSnap.exists ? intentSnap.data() : null;

    const intentEmail = intent && typeof intent.email === 'string'
      ? intent.email.trim().toLowerCase()
      : '';
    // The account the checkout belonged to. This is what binds the minted code
    // to one person (redeemCode refuses a non-owner); a legacy intent has no
    // uid and stays email-attributed.
    const intentUid = intent && typeof intent.uid === 'string' && intent.uid
      ? intent.uid
      : '';
    const fallback = typeof fallbackEmail === 'string'
      ? fallbackEmail.trim().toLowerCase()
      : '';
    const email = intentEmail || fallback;

    if (!email) {
      result.status = 'rejected';
      result.rejected = 'no verified buyer email (no paymentIntent and no usable fallback)';
      return;
    }

    // Leaderboard entry codes embed the CURRENT week ID (not the static catalog
    // value) so eligibility aligns with the weekly reset boundary.
    const codeValue = product.type === 'leaderboard_entry'
      ? currentWeekId()
      : product.value;

    const mintedCode = await _generateAndWriteCode(
      {
        type:      product.type,
        value:     codeValue,
        source:    'flutterwave_web',
        createdBy: productId,
        extra:     {
          paidAmount: amount,
          flwTxnId,
          buyerEmail: email,
          productId,
          flwReportedEmail: fallback,
          ...(intentUid ? { boundUid: intentUid } : {}),
        },
      },
      (code, doc) => { tx.set(db.collection('redemptionCodes').doc(code), doc); },
      (code) => tx.get(db.collection('redemptionCodes').doc(code))
    );

    tx.set(processedRef, {
      productId,
      tx_ref:    txRef,
      flwTxnId,
      code:      mintedCode,
      buyerEmail: email,
      flwReportedEmail: fallback,
      uid:       intentUid || null,
      amount,
      currency,
      status:    'fulfilled',
      createdAt: FieldValue.serverTimestamp(),
    });

    // merge=true so a missing/partial intent can't abort the mint.
    // `code` is denormalised here so getMyPurchases is one query for new
    // purchases instead of an N+1 lookup into processedTransactions.
    tx.set(intentRef, {
      status:      'fulfilled',
      fulfilledAt: FieldValue.serverTimestamp(),
      code:        mintedCode,
    }, { merge: true });

    result.status = 'fulfilled';
    result.code = mintedCode;
    result.buyerEmail = email;
    result.rejected = null;
  });

  return result;
}

// ─── CORS helpers (open onRequest endpoints) ───────────────────────────────
// The only browser-origin callers of the open HTTP endpoints are our own
// Firebase Hosting pages (the static shop + success pages) and local dev.
// We echo an allowlisted Origin instead of a bare `*`, so no arbitrary site
// can fetch these endpoints from a browser. Server-to-server callers
// (Flutterwave webhooks) send no Origin header and are unaffected.
const CORS_ALLOWED_ORIGINS = [
  HOSTING_BASE,                                  // https://anime-quiz-1ab1b.web.app
  'https://anime-quiz-1ab1b.firebaseapp.com',   // authDomain
  'http://localhost:5000',                      // firebase serve / emulator hosting
  'http://localhost:5001',                      // emulator functions
];

const CORS_BASE_HEADERS = {
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  // Authorization is required: both website payment endpoints are called with
  // the buyer's Firebase ID token. Without it here the browser's preflight
  // fails and the request never leaves the page.
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Max-Age':       '3600',
};

function _allowedOrigin(req) {
  const origin = req.headers?.origin;
  if (typeof origin !== 'string' || !origin) return null;
  return CORS_ALLOWED_ORIGINS.includes(origin) ? origin : null;
}

function _corsHeaders(req) {
  const origin = _allowedOrigin(req);
  const allowOrigin = origin
    ? origin
    // No browser Origin (server-to-server webhook, or curl): allow any �?
    // CORS only matters to browsers, and these requests carry no Origin.
    : '*';
  return { ...CORS_BASE_HEADERS, 'Access-Control-Allow-Origin': allowOrigin };
}

function _sendJson(res, status, body, req) {
  return res.status(status).set(_corsHeaders(req)).json(body);
}

function _sendOptions(res, req) {
  return res.status(204).set(_corsHeaders(req)).send();
}

// ─── Simple per-IP rate limiter for the open payment endpoints ────────────
// In-memory sliding window. Good enough to blunt scripted abuse of the
// unauthenticated checkout creator; not a substitute for App Check or
// Cloud Armor at higher scale. Keyed on client IP (best-effort; X-Forwarded-For
// is advisory only behind GCF).
const _paymentRate = new Map(); // ip -> { hits, windowStart }
const PAYMENT_RATE_LIMIT = {
  windowMs: 60 * 1000,   // 1 minute
  maxHits:  20,          // 20 checkout creations / min / IP
  maxHitsLong: 60,       // 60 / 10 min / IP (hard ceiling)
  longWindowMs: 10 * 60 * 1000,
};

function _rateLimited(ip) {
  if (!ip) return false;
  const now = Date.now();
  let entry = _paymentRate.get(ip);
  if (!entry) {
    entry = { shortHits: 0, longHits: 0, shortStart: now, longStart: now };
    _paymentRate.set(ip, entry);
  }
  if (now - entry.shortStart > PAYMENT_RATE_LIMIT.windowMs) {
    entry.shortHits = 0;
    entry.shortStart = now;
  }
  if (now - entry.longStart > PAYMENT_RATE_LIMIT.longWindowMs) {
    entry.longHits = 0;
    entry.longStart = now;
  }
  entry.shortHits++;
  entry.longHits++;
  if (entry.shortHits > PAYMENT_RATE_LIMIT.maxHits ||
      entry.longHits > PAYMENT_RATE_LIMIT.maxHitsLong) {
    return true;
  }
  // Opportunistic cleanup so the map never grows without bound.
  if (_paymentRate.size > 10000) {
    for (const [k, v] of _paymentRate) {
      if (now - v.longStart > PAYMENT_RATE_LIMIT.longWindowMs) _paymentRate.delete(k);
    }
  }
  return false;
}

// ─── Per-tx_ref rate limiter for getPurchasedCode ─────────────────────────
// Stops random reference probing from burning the Flutterwave verify API quota.
// Independent of the per-IP limiter above: an attacker rotating IPs still gets
// blocked per reference, and a legit buyer's auto-poll (10 attempts over ~30s)
// plus a few manual retries stay well under the cap.
const _txRefLookupRate = new Map(); // tx_ref -> { hits, windowStart }
const TXREF_RATE_LIMIT = {
  windowMs: 60 * 1000,   // 1 minute
  maxHits:  15,          // 15 lookups / min / tx_ref
};

function _txRefLookupLimited(txRef) {
  if (!txRef) return false;
  const now = Date.now();
  let entry = _txRefLookupRate.get(txRef);
  if (!entry) {
    entry = { hits: 0, windowStart: now };
    _txRefLookupRate.set(txRef, entry);
  }
  if (now - entry.windowStart > TXREF_RATE_LIMIT.windowMs) {
    entry.hits = 0;
    entry.windowStart = now;
  }
  entry.hits++;
  if (_txRefLookupRate.size > 20000) {
    for (const [k, v] of _txRefLookupRate) {
      if (now - v.windowStart > TXREF_RATE_LIMIT.windowMs) _txRefLookupRate.delete(k);
    }
  }
  return entry.hits > TXREF_RATE_LIMIT.maxHits;
}

// ─── Terminal-failure cache for getPurchasedCode ───────────────────────────
// When a tx_ref verifies as FAILED or CANCELLED, remember that for a short
// window so repeated probes of the same dead reference don't hit the
// Flutterwave API every time. Anything else (not found yet / pending / success)
// is never cached: the success page polls while a charge settles, and success
// mints immediately, so a cached miss would break both paths.
const _verifyCache = new Map(); // tx_ref -> { untilMs, confirmed }
const VERIFY_CACHE_MS = 30 * 1000; // 30s

function _cachedVerifyResult(txRef) {
  const e = _verifyCache.get(txRef);
  if (e && e.untilMs > Date.now()) return e.confirmed;
  return undefined; // not cached (or expired)
}

function _rememberVerifyResult(txRef, confirmed) {
  _verifyCache.set(txRef, { untilMs: Date.now() + VERIFY_CACHE_MS, confirmed: !!confirmed });
  if (_verifyCache.size > 20000) {
    const now = Date.now();
    for (const [k, v] of _verifyCache) {
      if (v.untilMs <= now) _verifyCache.delete(k);
    }
  }
}

// Best-effort client IP from an Express-style onRequest handler (req.headers /
// req.ip). Mirrors _clientIp for callables; X-Forwarded-For is advisory only.
function _httpReqIp(req) {
  try {
    const h = req?.headers || {};
    const fwd = h['x-forwarded-for'];
    const fwdStr = Array.isArray(fwd) ? fwd[0] : fwd;
    if (typeof fwdStr === 'string' && fwdStr.trim()) {
      return fwdStr.split(',')[0].trim().slice(0, 64) || null;
    }
    const ip = req?.ip;
    if (typeof ip === 'string' && ip.trim()) return ip.trim().slice(0, 64);
  } catch (_) { /* best-effort �?never throw */ }
  return null;
}

// Constant-time string comparison (avoids leaking a timing signal and never
// throws on length mismatch the way crypto.timingSafeEqual does).
function _constantTimeEq(a, b) {
  const x = String(a || '');
  const y = String(b || '');
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x.charCodeAt(i) || 0) ^ (y.charCodeAt(i) || 0);
  }
  return diff === 0;
}

function _isValidEmail(email) {
  return typeof email === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());
}

// ─── Redemption failure lockout ────────────────────────────────────────────
// Code existence, status, type, expiry and duplicate-week failures all return
// ONE generic message, so a logged-in client cannot use distinct errors as an
// oracle. Failures are counted per uid in a CF-only doc: five within 15
// minutes locks redemption for 30 minutes. Success clears the counter.
const REDEEM_MAX_FAILURES = 5;
const REDEEM_WINDOW_MS = 15 * 60 * 1000;
const REDEEM_LOCK_MS = 30 * 60 * 1000;
const REDEEM_GENERIC_MESSAGE = 'Invalid or expired code.';

async function _assertRedeemNotLocked(uid) {
  const snap = await db.collection('redeemAttempts').doc(uid).get();
  const lockedUntil = snap.data()?.lockedUntil;
  const untilMs = lockedUntil?.toMillis ? lockedUntil.toMillis() : 0;
  if (untilMs > Date.now()) {
    throw new HttpsError(
      'resource-exhausted',
      'Too many attempts. Try again later.'
    );
  }
}

async function _recordRedeemFailure(uid) {
  const ref = db.collection('redeemAttempts').doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.data() || {};
    const now = Date.now();
    const windowStart = data.windowStart?.toMillis ? data.windowStart.toMillis() : 0;
    const inWindow = windowStart > 0 && (now - windowStart) < REDEEM_WINDOW_MS;
    const failCount = (inWindow ? (data.failCount || 0) : 0) + 1;
    const locked = failCount >= REDEEM_MAX_FAILURES;
    tx.set(ref, {
      failCount,
      windowStart: Timestamp.fromMillis(inWindow ? windowStart : now),
      lastFailAt:  FieldValue.serverTimestamp(),
      ...(locked ? { lockedUntil: Timestamp.fromMillis(now + REDEEM_LOCK_MS) } : {}),
    }, { merge: true });
  });
}

async function _clearRedeemFailures(uid) {
  await db.collection('redeemAttempts').doc(uid).delete();
}

// ─── User-facing redemption ────────────────────────────────────────────────
// Normalization (consistent with generation, both sides): canonical form is
// UPPERCASE XXXX-XXXX-XXXX; doc ID for lookup is exactly this string.
exports.redeemCode = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    // Gate BEFORE opening the transaction: an outdated client must be rejected
    // without ever reading or mutating the redemption code doc. Covers all
    // three grant types �?ac, premium, and leaderboard_entry (which is the
    // weekly-entry activation path, not a separate callable).
    await _assertClientBuildAllowed(request, 'redeemCode');

    const rawCode = request.data?.code;
    if (typeof rawCode !== 'string' || !rawCode.trim()) {
      throw new HttpsError('invalid-argument', 'code is required');
    }
    const code = rawCode.trim().toUpperCase();

    // Code types are not gated by email verification (the login gate covers
    // every account). The type is
    // read before the transaction so the gate happens before any write.
    const preCodeSnap = await db.collection('redemptionCodes').doc(code).get();
    await _assertRedeemNotLocked(uid);

    const codeRef = db.collection('redemptionCodes').doc(code);
    const userRef = db.collection('users').doc(uid);
    const now     = Timestamp.now();

    let result;
    try {
      await db.runTransaction(async (tx) => {
      // ALL reads happen FIRST, before ANY write (Firestore requirement).
      const codeSnap = await tx.get(codeRef);
      if (!codeSnap.exists) {
        throw new HttpsError('not-found', 'Invalid code');
      }
      const userSnap = await tx.get(userRef);

      const data = codeSnap.data() || {};
      if (data.status !== 'unused') {
        throw new HttpsError('failed-precondition', 'Code already redeemed');
      }

      // Purchased codes belong to the account that bought them (written by
      // _mintCharge as boundUid). A leaked code is worthless to anyone else,
      // which is the point of requiring website login at checkout. Admin- and
      // promo-generated codes carry no boundUid and stay transferable.
      if (typeof data.boundUid === 'string' && data.boundUid && data.boundUid !== uid) {
        throw new HttpsError('failed-precondition', 'code_bound_to_another_account');
      }

      const type = data.type;
      if (type !== 'ac' && type !== 'premium' && type !== 'leaderboard_entry') {
        throw new HttpsError('failed-precondition', 'Invalid code type');
      }

      // Ghost admin accounts are never part of the player economy: an admin
      // cannot take a leaderboard entry �?the one action that used to drag the
      // admin into the weekly prize split and payout queue.
      if (type === 'leaderboard_entry' && isAdminAccountUid(uid)) {
        throw new HttpsError('failed-precondition', 'Admin accounts cannot enter the leaderboard.');
      }

      let value = data.value;
      if (type === 'ac') {
        if (typeof value !== 'number' || !(value > 0)) {
          throw new HttpsError('failed-precondition', 'Invalid code value');
        }
      } else if (type === 'leaderboard_entry') {
        // value is a week ID string (e.g. "2026-09-07")
        if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
          throw new HttpsError('failed-precondition', 'Invalid leaderboard entry code');
        }
        // Duplicate-purchase guard: block if user already eligible for this week
        const existingWeek = userSnap.data()?.leaderboardEntryWeekId;
        if (existingWeek === value) {
          throw new HttpsError('failed-precondition', 'You already have leaderboard entry for this week');
        }
      } else {
        // Premium default: 28 days, matching verifyPremiumPurchase's expiresAt.
        if (typeof value !== 'number' || !(value > 0)) value = 28;
      }

      if (
        data.expiresAt &&
        typeof data.expiresAt.toMillis === 'function' &&
        data.expiresAt.toMillis() <= now.toMillis()
      ) {
        throw new HttpsError('failed-precondition', 'Code expired');
      }

      const currentCoins = userSnap.data()?.animeCoins || 0;
      const inviteeData = userSnap.data() || {};

      // Referral cashout qualification: a leaderboard-entry activation on the
      // invitee's own account is the second half of the gate (the first is
      // signing up with the referrer's code, i.e. this referral record existing).
      // Resolved in the read phase so the marker can be written atomically with
      // the activation below.
      let referralRef = null;
      let referralSnap = null;
      if (type === 'leaderboard_entry'
          && typeof inviteeData.referredBy === 'string'
          && inviteeData.referredBy.trim()) {
        const referrerUid = await _resolveReferrerUidTx(tx, inviteeData.referredBy);
        if (referrerUid
            && referrerUid !== uid
            && !isAdminAccountUid(referrerUid)) {
          referralRef = db.collection('users').doc(referrerUid)
            .collection('referrals').doc(uid);
          referralSnap = await tx.get(referralRef);
        }
      }

      // Mark redeemed + grant inside the SAME transaction �?a code can never be
      // marked redeemed without its reward landing, or vice versa.
      // All reads are done at this point, so the writes below are safe.
      tx.update(codeRef, {
        status:     'redeemed',
        redeemedBy: uid,
        redeemedAt: FieldValue.serverTimestamp(),
      });

      // Leaderboard entry codes also accrue the week's code revenue on the pool
      // doc (accounting only — entry sales never size the pool) so cycle-close
      // needs no collection scan. Revenue read/write uses FieldValue.increment
      // so concurrent redemptions can never lose each other's contributions.
      if (type === 'leaderboard_entry' && data.paidAmount > 0) {
        tx.set(db.collection('prize_pool').doc(value), {
          weekId:            value,
          status:            'active',
          entryCodeRevenue:  FieldValue.increment(Number(data.paidAmount) || 0),
        }, { merge: true });
      }

      if (type === 'ac') {
        const newBalance = currentCoins + value;

        tx.update(userRef, { animeCoins: FieldValue.increment(value) });

        const txLogRef = userRef.collection('coinTransactions').doc();
        tx.set(txLogRef, {
          type:         'earn_redemption',
          delta:        value,
          balanceAfter: newBalance,
          timestamp:    FieldValue.serverTimestamp(),
        });

        result = { success: true, type, value, newBalance };
      } else if (type === 'leaderboard_entry') {
        const buyerEmail = (typeof data.buyerEmail === 'string' && data.buyerEmail.trim())
          ? data.buyerEmail.trim().toLowerCase()
          : null;

        tx.update(userRef, { leaderboardEntryWeekId: value });
        if (buyerEmail) {
          tx.update(userRef, { leaderboardEntryEmail: buyerEmail });
        }
        tx.set(userRef.collection('leaderboardReceipts').doc(code), {
          uid,
          weekId:     value,
          buyerEmail: buyerEmail || null,
          redeemedAt: FieldValue.serverTimestamp(),
        });

        // Referral cashout marker on the inviter's referral record. The invitee
        // bought/activated an entry on their own account, so this referral now
        // counts toward the inviter's NGN 5,000 cashout. Merge-only: createdAt,
        // status and the quiz-gate progress are never reset.
        if (referralRef) {
          const marker = {
            leaderboardEntryPurchased: true,
            leaderboardEntryWeekId: value,
            leaderboardEntryBuyerEmail: buyerEmail || null,
            leaderboardEntryPurchasedAt: FieldValue.serverTimestamp(),
          };
          if (referralSnap && referralSnap.exists) {
            tx.set(referralRef, marker, { merge: true });
          } else {
            _writeReferralRecord(tx, referralRef, referralSnap, inviteeData.username, {
              ...marker,
              // A record created at purchase time must not render as an expired
              // quiz referral: the 2-day deadline starts at sign-up, not here.
              expiresAt: null,
            });
          }
        }

        result = { success: true, type, value, weekId: value };
      } else {
        const expiresAt = Timestamp.fromMillis(
          now.toMillis() + value * 24 * 60 * 60 * 1000
        );

        tx.update(userRef, { premiumActive: true });
        tx.set(userRef.collection('premiumReceipts').doc(code), {
          uid,
          activatedAt: FieldValue.serverTimestamp(),
          expiresAt,
        });

        result = { success: true, type, value };
      }
      });
    } catch (err) {
      if (err instanceof HttpsError) {
        // Every code-state failure is indistinguishable to the caller, and
        // each one counts toward the lockout.
        try {
          await _recordRedeemFailure(uid);
        } catch (recordErr) {
          console.warn(`[redeemCode] failure counter write failed: ${recordErr.message}`);
        }
        console.log(`[redeemCode] uid=${uid} rejected (${err.code})`);
        throw new HttpsError('invalid-argument', REDEEM_GENERIC_MESSAGE);
      }
      throw err;
    }

    // Success resets the window so a legitimate player who mistyped a code is
    // not punished after a later success.
    try {
      await _clearRedeemFailures(uid);
    } catch (err) {
      console.warn(`[redeemCode] failure counter clear failed: ${err.message}`);
    }

    console.log(`[redeemCode] uid=${uid} code=${code} -> ${JSON.stringify(result)}`);
    return result;
  }
);

// ─── Admin-only generation (testing / distribution) ────────────────────────
exports.generateRedemptionCodes = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const { type, value, count, source, buyerEmail } = request.data || {};

    if (type !== 'ac' && type !== 'premium' && type !== 'leaderboard_entry') {
      throw new HttpsError('invalid-argument', 'type must be "ac", "premium", or "leaderboard_entry"');
    }
    if (type === 'leaderboard_entry') {
      // value is a week ID string (defaults to current week when omitted)
      if (value !== undefined && value !== null && value !== '' &&
          (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value))) {
        throw new HttpsError('invalid-argument', 'value must be a YYYY-MM-DD week ID');
      }
      // A leaderboard_entry code is a real prize-payout obligation �?even in
      // testing we require a known recipient so a test win is never orphaned.
      const buyer = (typeof buyerEmail === 'string' && buyerEmail.trim())
        ? buyerEmail.trim().toLowerCase()
        : '';
      if (!_isValidEmail(buyer)) {
        throw new HttpsError('invalid-argument', 'buyerEmail is required for leaderboard_entry codes');
      }
    } else if (typeof value !== 'number' || !Number.isInteger(value) || !(value > 0)) {
      throw new HttpsError('invalid-argument', 'value must be a positive integer');
    }
    if (typeof count !== 'number' || !Number.isInteger(count) || count < 1 || count > 100) {
      throw new HttpsError('invalid-argument', 'count must be an integer between 1 and 100');
    }
    const sourceTag = (typeof source === 'string' && source.trim())
      ? source.trim()
      : 'manual';

    // Generate + write one at a time, reusing the shared core (_generateAndWriteCode)
    // that the Flutterwave webhook also uses �?a single source of truth for the
    // code format and collision-check. Each candidate's collision check reads live
    // document IDs before writing; we do NOT just trust entropy, even though
    // 31^12 makes a collision astronomically unlikely.
    const codes = [];
    while (codes.length < count) {
      const candidate = await _generateAndWriteCode({
        type,
        value:  type === 'leaderboard_entry' ? (value || currentWeekId()) : value,
        source:    sourceTag,
        createdBy: request.auth.uid,
        ...(type === 'leaderboard_entry'
          ? { extra: { buyerEmail: (typeof buyerEmail === 'string' && buyerEmail.trim()) ? buyerEmail.trim().toLowerCase() : '' } }
          : {}),
      });
      if (!codes.includes(candidate)) codes.push(candidate); // dedupe within this call
    }

    console.log(`[generateRedemptionCodes] ${codes.length} ${type} codes (value=${value}) by ${request.auth.uid}`);
    return { success: true, codes };
  }
);

// ─── NOTE: the guaranteed floor was retired ─────────────────────────────────
// Pools are admin-set only now: an unset week pays ₦0, so
// `app_config/leaderboard_entry_config.guaranteedFloor` no longer sizes any
// pool. The config value is left untouched for history; nothing reads it.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 2: LEADERBOARD PAYOUT SYSTEM ──────────────────────────────────
// MANUAL payout �?the app never moves money.
//
//   submitPayoutDetails  �?winner submits bank account in-app
//   markLeaderboardPayout�?admin records that they transferred it by hand
//   checkPendingClaim    — hourly: expire 3-day claims, forfeit the unclaimed
//   exportPayoutLog      �?admin CSV audit export
//   listPayoutClaims     �?admin read-only queue feed
//
// Collections:
//   leaderboardCycles/{weekId}/pendingClaim/{uid} : per-cycle claim state
//   users/{uid}/payoutDetails                     : reusable bank details
//
// The admin transfers from their OWN bank app, then taps "Mark as paid" here.
// This function only records that fact �?it is the single and only state
// transition that can set ranked[].paid = true.
//
// MONEY-FLOW RULES (never violated):
//   1. No automated payment integration exists. The app NEVER initiates a
//      bank transfer. There is no payment-provider secret in this section.
//   2. ranked[].paid = true ONLY via markLeaderboardPayout (admin-gated).
//   3. Amount is ALWAYS server-derived from ranked[].share �?never from the
//      client. The client sends {weekId, uid} and nothing else.
//   4. A claim must exist and must not be expired before it can be marked
//      paid. You cannot pay out to a destination the winner never supplied.
//   5. Double-taps are prevented by a transaction; mark as paid is idempotent
//      so a retry after a network timeout is safe.
//
// OPERATIONAL CAVEAT: because the transfer is manual, "paid" is a claim about
// what a human did, not a settlement confirmation. Marking paid is a
// bookkeeping step, not a guarantee. That is the deliberate trade for
// removing the automated transfer engine.
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// 2.0 listNigerianBanks �?verified bank-name �?bank-code list for winners
// ─────────────────────────────────────────────────────────────────────────────
// Authenticated callable. Proxies Flutterwave `GET /v3/banks/NG` server-side
// using the existing FLW_SECRET_KEY (never exposed to the client) and returns
// ONLY [{ name, code }] pairs for the Flutter bank-selector sheet.
// ~24h in-memory cache (module-level, same instance); no database/cache
// infra. Fails safely (HttpsError 'unavailable') when Flutterwave is down �?// the client shows error/retry and never falls back to hardcoded codes.
const _banksCache = { at: 0, banks: [] };
exports.listNigerianBanks = onSecureCall(
  { region: 'us-central1', secrets: [FLW_SECRET_KEY] },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }

    const now = Date.now();
    if (_banksCache.banks.length > 0 && now - _banksCache.at < 24 * 60 * 60 * 1000) {
      return { success: true, banks: _banksCache.banks, cached: true };
    }

    let resp;
    try {
      resp = await fetch('https://api.flutterwave.com/v3/banks/NG', {
        method:  'GET',
        headers: { 'Authorization': `Bearer ${FLW_SECRET_KEY.value()}` },
      });
    } catch (err) {
      console.error(`[listNigerianBanks] fetch failed: ${err.message}`);
      throw new HttpsError('unavailable', 'Bank list unavailable');
    }
    if (!resp.ok) {
      console.error(`[listNigerianBanks] http_${resp.status}`);
      throw new HttpsError('unavailable', 'Bank list unavailable');
    }
    const data = await resp.json();
    if (data.status !== 'success' || !Array.isArray(data.data)) {
      console.error(`[listNigerianBanks] unexpected payload: ${data.message || 'unknown'}`);
      throw new HttpsError('unavailable', 'Bank list unavailable');
    }
    const banks = data.data
      .map((b) => ({
        name: String((b && b.name) || '').trim(),
        code: String((b && b.code) || '').trim(),
      }))
      .filter((b) => b.name && b.code)
      .sort((a, b) => a.name.localeCompare(b.name));

    _banksCache.at = now;
    _banksCache.banks = banks;
    console.log(`[listNigerianBanks] refreshed ${banks.length} banks`);
    return { success: true, banks, cached: false };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// 2.1 submitPayoutDetails �?winner submits bank account for a cycle
// ─────────────────────────────────────────────────────────────────────────────
// The ONLY player-facing payout callable. Records the destination account the
// admin will later transfer to by hand.
//
// No payment-provider call happens here: no account-name resolution, no
// transfer. The bank list itself (2.0) is still served from Flutterwave so
// bank codes are always valid, but nothing is looked up per-submission.
//
// Privacy: bank details are stored so the admin can pay the winner. They are
// NOT purged after payment �?the winner may need them again for a future
// week, and they are never exposed to any other player.
// ─── Payout detail writes (CF-only) + audit trail ──────────────────────────
// users/{uid}/payoutDetails is the reusable destination account the admin pays
// by hand. It used to be owner-writable from the client, so a stolen session
// (or a patched app) could swap a winner's account at any time. Writes now go
// through savePayoutDetail / submitPayoutDetails, and every change appends an
// immutable entry to payoutDetailAudit (CF-only collection) with the account
// number reduced to its last four digits.
function _maskAccountNumber(raw) {
  const s = String(raw || '');
  return s.length >= 4 ? `****${s.slice(-4)}` : '****';
}

function _payoutAuditSnapshot(data) {
  if (!data) return null;
  return {
    bankName: typeof data.bankName === 'string' ? data.bankName : '',
    bankCode: typeof data.bankCode === 'string' ? data.bankCode : '',
    beneficiaryName: typeof data.beneficiaryName === 'string' ? data.beneficiaryName : '',
    accountMask: _maskAccountNumber(data.accountNumber || data.accountMask || ''),
  };
}

function _validatePayoutPayload(data) {
  const { accountNumber, bankCode, beneficiaryName, bankName } = data || {};
  if (typeof accountNumber !== 'string' || !/^\d{10}$/.test(accountNumber.trim())) {
    throw new HttpsError('invalid-argument', 'accountNumber must be a 10-digit string');
  }
  if (typeof bankCode !== 'string' || !/^\d{2,10}$/.test(bankCode.trim())) {
    throw new HttpsError('invalid-argument', 'bankCode must be a valid bank code');
  }
  if (typeof beneficiaryName !== 'string' ||
      beneficiaryName.trim().length < 3 ||
      beneficiaryName.trim().length > 100) {
    throw new HttpsError('invalid-argument', 'beneficiaryName must be 3-100 characters');
  }
  if (bankName !== undefined &&
      (typeof bankName !== 'string' || bankName.trim().length > 80)) {
    throw new HttpsError('invalid-argument', 'bankName is invalid');
  }
  return {
    accountNumber: accountNumber.trim(),
    bankCode: bankCode.trim(),
    beneficiaryName: beneficiaryName.trim(),
    bankName: typeof bankName === 'string' ? bankName.trim() : '',
  };
}

// ── 3-day claim window (single source of truth) ──────────────────────────
// Winners must submit payout details within 3 days of the cycle's
// calculatedAt. After that the share is automatically forfeited: the claim
// is marked 'expired', the share is added to the cycle's forfeitedNaira, and
// nothing is carried into a later week.
const CLAIM_WINDOW_MS = 3 * 24 * 60 * 60 * 1000; // 3 days

function _claimWindowClosed(calculatedAt, nowMs = Date.now()) {
  if (!calculatedAt?.toMillis) return false;
  return calculatedAt.toMillis() + CLAIM_WINDOW_MS < nowMs;
}

// Best-effort auto-forfeit for ONE winner. Idempotent: only flips a claim
// that is still 'pending' (or was never submitted) while the winner is still
// unpaid. Returns true only when this call actually forfeited the share.
async function _autoForfeitClaim(cycleRef, uid, share) {
  const claimRef = cycleRef.collection('pendingClaim').doc(uid);
  try {
    const forfeited = await db.runTransaction(async (tx) => {
      const freshClaim = await tx.get(claimRef);
      const freshCycle = await tx.get(cycleRef);
      const liveData = freshCycle.data() || {};
      const liveRanked = Array.isArray(liveData.ranked) ? liveData.ranked : [];
      const liveWinner = liveRanked.find((r) => r && r.uid === uid);
      if (!liveWinner || liveWinner.paid === true) return false;
      const status = freshClaim.exists ? freshClaim.data().status : null;
      if (status === 'marked' || status === 'expired') return false;
      tx.set(claimRef, {
        ...(freshClaim.exists ? freshClaim.data() : {}),
        uid,
        status: 'expired',
        expiredAt: FieldValue.serverTimestamp(),
        forfeitedNaira: share,
        ...(freshClaim.exists ? {} : { neverSubmitted: true }),
        autoForfeited: true,
      }, { merge: true });
      tx.update(cycleRef, { forfeitedNaira: FieldValue.increment(share) });
      return true;
    });
    return forfeited;
  } catch (err) {
    console.warn(`[_autoForfeitClaim] ${cycleRef.id}/${uid} failed (will retry): ${err.message}`);
    return false;
  }
}

// Creates or updates ONE reusable payout detail. The detail write and its audit
// entry happen in the same transaction, so an account change can never be
// recorded without its before/after trail (or vice versa).
exports.savePayoutDetail = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    _assertEmailVerified(request, 'savePayoutDetail');
    await _assertClientBuildAllowed(request, 'savePayoutDetail');
    await _assertAccountAge(uid, CFG.PAYOUT_MIN_ACCOUNT_AGE_DAYS, 'savePayoutDetail');

    const payload = _validatePayoutPayload(request.data);
    // Fingerprint even a saved (not yet claimed) destination, so a ring
    // preparing multiple accounts is visible before the first claim.
    await _recordPayoutAccount(
      uid, payload.bankCode, payload.accountNumber, 'savePayoutDetail',
    ).catch((err) => console.warn(`[savePayoutDetail] fingerprint failed: ${err.message}`));
    const rawDocId = request.data?.docId;
    const docId = typeof rawDocId === 'string' && rawDocId.trim()
      ? rawDocId.trim()
      : null;
    if (docId && !/^[A-Za-z0-9_-]{1,120}$/.test(docId)) {
      throw new HttpsError('invalid-argument', 'docId is invalid');
    }

    const coll = db.collection('users').doc(uid).collection('payoutDetails');
    const ref = docId ? coll.doc(docId) : coll.doc();
    const action = docId ? 'update' : 'create';

    await db.runTransaction(async (tx) => {
      const beforeSnap = docId ? await tx.get(ref) : null;
      if (docId && !beforeSnap.exists) {
        throw new HttpsError('not-found', 'Payout detail not found.');
      }
      const before = beforeSnap?.data() || null;

      tx.set(ref, {
        ...payload,
        updatedAt: FieldValue.serverTimestamp(),
        ...(docId ? {} : { createdAt: FieldValue.serverTimestamp() }),
      }, { merge: true });

      tx.set(db.collection('payoutDetailAudit').doc(), {
        uid,
        docId: ref.id,
        action,
        before: _payoutAuditSnapshot(before),
        after:  _payoutAuditSnapshot(payload),
        at:     FieldValue.serverTimestamp(),
      });
    });

    console.log(`[savePayoutDetail] uid=${uid} doc=${ref.id} action=${action}`);
    return { success: true, id: ref.id };
  }
);

exports.submitPayoutDetails = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    _assertEmailVerified(request, 'submitPayoutDetails');

    // Gate BEFORE the cycle read: an outdated client must not be able to
    // overwrite a destination account the admin is about to pay.
    await _assertClientBuildAllowed(request, 'submitPayoutDetails');
    // Payout details are the cash-out identity: a week-old account is the floor.
    await _assertAccountAge(uid, CFG.PAYOUT_MIN_ACCOUNT_AGE_DAYS, 'submitPayoutDetails');
    await _assertPayoutAllowed(uid, 'submitPayoutDetails');
    await _verifyPlayIntegrity(request, 'payout');

    const { weekId, accountNumber, bankCode, beneficiaryName } = request.data || {};

    if (typeof weekId !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(weekId)) {
      throw new HttpsError('invalid-argument', 'weekId must be YYYY-MM-DD');
    }
    if (typeof accountNumber !== 'string' || !/^\d{10}$/.test(accountNumber.trim())) {
      throw new HttpsError('invalid-argument', 'accountNumber must be a 10-digit string');
    }
    if (typeof bankCode !== 'string' || !bankCode.trim()) {
      throw new HttpsError('invalid-argument', 'bankCode is required');
    }
    if (typeof beneficiaryName !== 'string' || beneficiaryName.trim().length < 3) {
      throw new HttpsError('invalid-argument', 'beneficiaryName must be at least 3 characters');
    }

    const cleanAccount = accountNumber.trim();
    const cleanBank    = bankCode.trim();
    const cleanName    = beneficiaryName.trim();

    // Fingerprint the destination before writing the claim. A second UID using
    // the same account records a hard signal and puts the new claimant on a
    // silent payout hold for manual review; it never deletes or blocks play.
    const fingerprint = await _recordPayoutAccount(
      uid, cleanBank, cleanAccount, 'submitPayoutDetails',
    ).catch((err) => {
      console.warn(`[submitPayoutDetails] fingerprint failed: ${err.message}`);
      return { hash: _payoutAccountHash(cleanBank, cleanAccount), shared: false, uidCount: 1 };
    });

    // ── Read cycle snapshot (all reads before any write) ─────────────────────
    const cycleRef  = db.collection('leaderboardCycles').doc(weekId);
    const cycleSnap = await cycleRef.get();
    if (!cycleSnap.exists) {
      throw new HttpsError('not-found', 'No leaderboard cycle for that week');
    }

    const cycleData = cycleSnap.data();
    const ranked    = Array.isArray(cycleData.ranked) ? cycleData.ranked : [];
    const idx       = ranked.findIndex((r) => r && r.uid === uid);

    if (idx === -1) {
      throw new HttpsError('not-found', 'You are not in this cycle\'s ranked list');
    }
    if (ranked[idx].paid === true) {
      throw new HttpsError('failed-precondition', 'Your prize has already been paid out');
    }

    const share = Number(ranked[idx].share) || 0;
    if (share <= 0) {
      throw new HttpsError(
        'failed-precondition',
        'No prize share for that rank: only the top 3 paid entrants win a prize.'
      );
    }

    // The advertised 3-day claim window is enforced here, not just in copy.
    // A late submit attempt automatically forfeits the share on the spot, so
    // the books reconcile even before the scheduled sweep runs.
    const calculatedAt = cycleData.calculatedAt;
    if (_claimWindowClosed(calculatedAt)) {
      await _autoForfeitClaim(cycleRef, uid, share);
      throw new HttpsError(
        'failed-precondition',
        'The claim window has closed (3 days after the week closed) and this share was forfeited.'
      );
    }

    const claimRef   = cycleRef.collection('pendingClaim').doc(uid);
    const claimSnap  = await claimRef.get();

    if (claimSnap.exists) {
      const existing = claimSnap.data();
      if (existing.status === 'marked') {
        throw new HttpsError('failed-precondition',
          'Your payout has already been marked as sent and cannot be changed');
      }
      if (existing.status === 'pending') {
        return {
          success: true,
          status:  'already_submitted',
          message: 'Your payout details were already submitted. An admin will send your prize to this account.',
        };
      }
      if (existing.status === 'expired') {
        throw new HttpsError('failed-precondition',
          'This prize was forfeited when the 3-day claim window closed. Expired claims cannot be re-submitted.');
      }
    }

    // ── Write pendingClaim (tx: prevents double-submit race) ────────────────
    // Re-submitting REPLACES the destination account. Allowed while unpaid so
    // a winner who mistyped their account number can correct it before the
    // admin pays.
    await db.runTransaction(async (tx) => {
      const fresh = await tx.get(claimRef);
      if (fresh.exists) {
        const s = fresh.data();
        if (s.status === 'marked') {
          throw new HttpsError('failed-precondition',
            'Your payout was marked as sent while you were submitting. Cannot change it.');
        }
        if (s.status === 'pending') return; // race lost �?idempotent ok
        if (s.status === 'expired') {
          throw new HttpsError('failed-precondition',
            'This prize was forfeited when the 3-day claim window closed. Expired claims cannot be re-submitted.');
        }
      }
      tx.set(claimRef, {
        uid,
        accountNumber:   cleanAccount,
        bankCode:       cleanBank,
        accountHash:    fingerprint.hash,
        payoutAccountShared: fingerprint.shared,
        payoutAccountUidCount: fingerprint.uidCount,
        beneficiaryName: cleanName,
        submittedAt:    FieldValue.serverTimestamp(),
        status:         'pending',
      });
    });

    // ── Upsert reusable payoutDetails (repeat winners don't re-enter) ─────────
    const existingDetail = await db.collection('users').doc(uid)
      .collection('payoutDetails')
      .where('accountNumber', '==', cleanAccount).limit(1).get();

    const auditBefore = existingDetail.empty ? null : existingDetail.docs[0].data();
    let auditDocId = '';
    if (!existingDetail.empty) {
      auditDocId = existingDetail.docs[0].id;
      await existingDetail.docs[0].ref.update({
        bankCode: cleanBank,
        bankName: '',
        accountHash: fingerprint.hash,
        beneficiaryName: cleanName,
        updatedAt: FieldValue.serverTimestamp(),
      });
    } else {
      const created = await db.collection('users').doc(uid).collection('payoutDetails').add({
        accountNumber:   cleanAccount,
        bankCode:        cleanBank,
        bankName:        '',
        accountHash:     fingerprint.hash,
        beneficiaryName: cleanName,
        updatedAt:       FieldValue.serverTimestamp(),
        createdAt:       FieldValue.serverTimestamp(),
      });
      auditDocId = created.id;
    }

    // Audit every destination change. The detail write above is already
    // committed, so an audit failure is logged rather than surfacing as a
    // submission failure (retrying would be treated as already_submitted).
    try {
      await db.collection('payoutDetailAudit').add({
        uid,
        docId: auditDocId,
        action: auditBefore ? 'update' : 'create',
        source: 'submitPayoutDetails',
        cycleWeekId: weekId,
        before: _payoutAuditSnapshot(auditBefore),
        after: _payoutAuditSnapshot({
          accountNumber: cleanAccount,
          bankCode: cleanBank,
          beneficiaryName: cleanName,
          bankName: '',
        }),
        at: FieldValue.serverTimestamp(),
      });
    } catch (auditErr) {
      console.error(`[submitPayoutDetails] audit write failed uid=${uid}: ${auditErr.message}`);
    }

    console.log(`[submitPayoutDetails] uid=${uid} week=${weekId} account=****${cleanAccount.slice(-4)} bank=${cleanBank}`);
    return {
      success: true,
      status:  'pending',
      message: 'Payout details submitted. An admin will transfer your prize to this account.',
    };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// 2.2 markLeaderboardPayout �?admin records a manual bank transfer
// ─────────────────────────────────────────────────────────────────────────────
// THE ONLY function that can set ranked[].paid = true.
//
// The admin has already sent the money from their own bank before calling this.
// This is bookkeeping: it records what a human did. There is no payment
// provider, no webhook, and no transfer to confirm �?"paid" is an assertion,
// not a settlement proof.
//
// Transactional so two concurrent taps cannot both apply. Idempotent when
// re-applied with the same value, so a retry after a client-side timeout is
// safe and will NOT create a second payout record.
//
// Undo: pass paid=false to reverse a mistaken mark. Supported as long as the
// cycle has not been fully settled �?see the allPaid recomputation below.
exports.markLeaderboardPayout = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const { weekId, uid, paid, payoutReference } = request.data || {};
    if (typeof weekId !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(weekId)) {
      throw new HttpsError('invalid-argument', 'weekId must be a YYYY-MM-DD string');
    }
    if (typeof uid !== 'string' || !uid.trim()) {
      throw new HttpsError('invalid-argument', 'uid is required');
    }
    if (paid !== true && paid !== false) {
      throw new HttpsError('invalid-argument', 'paid must be a boolean');
    }

    const markPaid  = paid === true;
    const reference = (typeof payoutReference === 'string' && payoutReference.trim())
      ? payoutReference.trim().slice(0, 120)
      : null;

    const cycleRef = db.collection('leaderboardCycles').doc(weekId);
    const claimRef = cycleRef.collection('pendingClaim').doc(uid);

    let result;
    await db.runTransaction(async (tx) => {
      // All reads first, then writes.
      const cycleSnap = await tx.get(cycleRef);
      if (!cycleSnap.exists) {
        throw new HttpsError('not-found', 'No leaderboard cycle for that week');
      }
      const cycleData = cycleSnap.data();
      const ranked    = Array.isArray(cycleData.ranked) ? cycleData.ranked : [];
      const idx       = ranked.findIndex((r) => r && r.uid === uid);
      if (idx === -1) {
        throw new HttpsError('not-found', 'That user is not in this cycle\'s ranked list');
      }
      const winner = ranked[idx];
      const share  = Number(winner.share) || 0;

      const claimSnap = await tx.get(claimRef);
      const claim     = claimSnap.exists ? claimSnap.data() : null;

      // The 3-day window binds the admin too: once it closes, an unpaid
      // winner is automatically forfeited and can no longer be marked paid,
      // even if the scheduled sweep has not run yet.
      if (markPaid && winner.paid !== true && _claimWindowClosed(cycleData.calculatedAt)) {
        if (claim?.status !== 'marked') {
          tx.set(claimRef, {
            ...(claim || {}),
            uid,
            status: 'expired',
            expiredAt: FieldValue.serverTimestamp(),
            forfeitedNaira: share,
            ...(!claim ? { neverSubmitted: true } : {}),
            autoForfeited: true,
          }, { merge: true });
          if (share > 0) {
            tx.update(cycleRef, { forfeitedNaira: FieldValue.increment(share) });
          }
        }
        result = { share, allPaid: false, alreadyApplied: false, windowClosed: true };
        return;
      }

      // A destination account must exist before money is recorded as sent.
      // This is what stops a payout being marked against a winner who never
      // actually supplied somewhere to send it.
      if (markPaid && !claim) {
        throw new HttpsError('failed-precondition',
          'This winner has not submitted payout details yet. Ask them to claim first.');
      }
      if (markPaid && claim?.status === 'expired') {
        throw new HttpsError('failed-precondition',
          'This winner\'s claim expired and their prize was forfeited. '
          + 'Expired claims are not paid and are not carried into a later week.');
      }
      if (markPaid && (!Number.isFinite(share) || share <= 0)) {
        throw new HttpsError('failed-precondition', 'Prize share is zero or invalid');
      }

      const now = FieldValue.serverTimestamp();
      const updated = ranked.map((r, i) =>
        i === idx
          ? {
              ...r,
              paid:            markPaid,
              payoutMethod:    markPaid ? 'manual_bank_transfer' : null,
              payoutReference: markPaid ? (reference || r.payoutReference || null) : null,
            }
          : r
      );
      const allPaid = updated.length > 0 && updated.every((r) => r.paid === true);

      tx.set(cycleRef, {
        ...cycleData,
        ranked:  updated,
        status:  allPaid ? 'paid' : (cycleData.status === 'paid' ? 'calculated' : (cycleData.status || 'calculated')),
        paidAt:  allPaid ? now : null,
      }, { merge: true });

      if (claim) {
        tx.set(claimRef, {
          ...claim,
          status:           markPaid ? 'marked' : 'pending',
          markedAt:         markPaid ? now : null,
          markedBy:         markPaid ? request.auth.uid : null,
          payoutReference:  markPaid ? (reference || claim.payoutReference || null) : null,
          paidAmountNaira:  markPaid ? share : null,
          updatedAt:        now,
        }, { merge: true });
      }

      result = { share, allPaid, alreadyApplied: winner.paid === markPaid };
    });

    if (result?.windowClosed) {
      console.log(`[markLeaderboardPayout] week=${weekId} uid=${uid} rejected: window closed, share auto-forfeited`);
      throw new HttpsError('failed-precondition',
        'The 3-day claim window has closed and this prize was forfeited. '
        + 'Expired claims are not paid and are not carried into a later week.');
    }

    // Never log account numbers �?masked only, and only at debug level.
    console.log(`[markLeaderboardPayout] week=${weekId} uid=${uid} paid=${markPaid} ` +
      `share=${result.share} allPaid=${result.allPaid} alreadyApplied=${result.alreadyApplied} ` +
      `by ${request.auth.uid}`);

    return {
      success:    true,
      weekId,
      uid,
      paid:       markPaid,
      amount:     result.share,
      allPaid:    result.allPaid,
      unchanged:  result.alreadyApplied,
      message: markPaid
        ? (result.allPaid
            ? 'Recorded as sent. Every winner in this week is now marked paid.'
            : 'Recorded as sent.')
        : 'Mark reverted. This winner is back in the payment queue.',
    };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// 2.3 checkPendingClaim — hourly 3-day claim expiry (NO rollover)
// ─────────────────────────────────────────────────────────────────────────────
// Runs hourly. For each leaderboardCycles/{weekId} whose calculatedAt is 3 days
// old and whose status is still 'calculated' (not 'paid'), any unpaid winner
// whose pendingClaim is still 'pending' OR was never submitted at all is
// expired and their share forfeited. Late submit/mark attempts also forfeit
// on the spot (see submitPayoutDetails / markLeaderboardPayout), so this sweep
// is the backstop for winners who never try after the window closes.
//
// WHAT HAPPENS TO THE MONEY: nothing is paid and nothing is carried forward.
// The share is FORFEITED �?it stays inside that week already-snapshotted
// prizePool and is never transferred to anyone. It is recorded on the cycle as
// `forfeitedNaira` so the books still reconcile: every naira in the pool is
// accounted for as either paid out or forfeited.
//
// There is deliberately NO rollover into a future week's pool. A previous
// version carried expired shares forward via prize_pool.rolloverNaira, which
// had two problems: it credited the money to whichever week happened to be live
// rather than the week it was taken from, and it grew the pool without any
// corresponding revenue. The accumulator is no longer read or written.
//
// The 3-day window is deliberately short: payouts are manual, so holding a
// winner's prize hostage for two weeks while an admin catches up is unfair to
// the rest of the pool. A player who misses it forfeits that week's share.
//
// Idempotent: a claim is only flipped while it is still 'pending' AND the
// winner is still unpaid, both re-checked inside the transaction.
exports.checkPendingClaim = onSchedule(
  { schedule: '0 * * * *', timeZone: 'Africa/Lagos', region: 'us-central1' },
  async () => {
    const cutoff = Timestamp.now().toMillis() - CLAIM_WINDOW_MS;

    const cyclesSnap = await db.collection('leaderboardCycles')
      .where('status', '==', 'calculated')
      .get();

    let expiredCount = 0;
    let forfeitedTotal = 0;

    for (const cycleDoc of cyclesSnap.docs) {
      const weekId = cycleDoc.id;
      const cycle  = cycleDoc.data();
      if (cycle.status === 'paid') continue;

      const calculatedAt = cycle.calculatedAt;
      if (!calculatedAt?.toMillis) continue;
      if (calculatedAt.toMillis() > cutoff) continue; // claim window still open

      const ranked = Array.isArray(cycle.ranked) ? cycle.ranked : [];
      // Only unpaid ranks with a positive share are expirable.
      const expirable = ranked.filter((r) => r && r.paid !== true && (Number(r.share) || 0) > 0);
      if (expirable.length === 0) continue;

      let cycleForfeited = 0;

      for (const winner of expirable) {
        const uid   = winner.uid;
        const share = Number(winner.share) || 0;
        const claimRef = cycleDoc.ref.collection('pendingClaim').doc(uid);

        // Read-before-write tx: re-read claim + live cycle; expire if the claim
        // is still 'pending' OR was never submitted at all, AND the winner is
        // still unpaid. Both checks happen inside the tx so a concurrent
        // mark-paid cannot be clobbered and a re-run cannot double-count the
        // forfeiture.
        try {
          // Resolves true only when this run actually forfeited the share, so a
          // re-run that finds the winner already settled is not counted again.
          const forfeited = await db.runTransaction(async (tx) => {
            // All reads first.
            const freshClaim = await tx.get(claimRef);
            const freshCycle = await tx.get(cycleDoc.ref);

            const liveData   = freshCycle.data() || {};
            const liveRanked = Array.isArray(liveData.ranked) ? liveData.ranked : [];
            const liveWinner = liveRanked.find((r) => r && r.uid === uid);
            if (!liveWinner || liveWinner.paid === true) return false;

            const status = freshClaim.exists ? freshClaim.data().status : null;
            // Already settled or already expired/forfeited.
            if (status === 'marked' || status === 'expired') return false;

            // 'pending' (submitted, never marked) OR no claim at all �?expire
            // and record the forfeiture. The never-submitted case previously
            // left the share unaccounted for forever.
            tx.set(claimRef, {
              ...(freshClaim.exists ? freshClaim.data() : {}),
              uid,
              status:         'expired',
              expiredAt:      FieldValue.serverTimestamp(),
              forfeitedNaira: share,
              ...(freshClaim.exists ? {} : { neverSubmitted: true }),
            }, { merge: true });

            tx.update(cycleDoc.ref, {
              forfeitedNaira: FieldValue.increment(share),
            });
            return true;
          });
          if (!forfeited) continue;
          expiredCount++;
          cycleForfeited += share;
          forfeitedTotal += share;
          console.log(`[checkPendingClaim] EXPIRED week=${weekId} uid=${uid} share=${share} forfeited (not rolled over)`);
        } catch (err) {
          console.warn(`[checkPendingClaim] expire ${weekId}/${uid} failed (will retry next run): ${err.message}`);
        }
      }

      if (cycleForfeited > 0) {
        console.log(`[checkPendingClaim] cycle ${weekId}: expired ${cycleForfeited} naira forfeited`);
      }
    }

    console.log(`[checkPendingClaim] done. expired=${expiredCount} forfeited=${forfeitedTotal}`);
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// 2.4 exportPayoutLog �?admin CSV payout audit export
// ─────────────────────────────────────────────────────────────────────────────
// Admin-only. Returns the payout record as CSV text in the callable response
// (no Cloud Storage infra exists in this project; result sets are tiny at
// pre-launch scale, so inline CSV is the smallest approach).
//
// NEVER includes bank account numbers or beneficiary names �?bookkeeping only.
// Account numbers stay inside the app's admin queue and are never bulk-exported.
exports.exportPayoutLog = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }
    const { fromWeekId, toWeekId } = request.data || {};
    const validWeek = (w) => typeof w === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(w);

    let query = db.collection('leaderboardCycles').orderBy('__name__');
    if (validWeek(fromWeekId) && validWeek(toWeekId)) {
      query = query.where(FieldPath.documentId(), '>=', fromWeekId)
                   .where(FieldPath.documentId(), '<=', toWeekId);
    }

    const csvEscape = (v) => {
      const s = (v === null || v === undefined) ? '' : String(v);
      return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    const fmtTs = (ts) => (ts?.toMillis ? ts.toDate().toISOString() : '');

    const HEADER = 'weekId,uid,username,rank,amount,currency,claimStatus,submittedAt,markedAt,markedBy,payoutReference,paid';
    const rows   = [HEADER];
    let rowCount = 0;

    const cyclesSnap = await query.get();
    for (const cycleDoc of cyclesSnap.docs) {
      const weekId = cycleDoc.id;
      const cycle   = cycleDoc.data() || {};
      const ranked  = Array.isArray(cycle.ranked) ? cycle.ranked : [];

      for (const winner of ranked) {
        if (!winner || !winner.uid) continue;

        // One claim doc per winner. Absent doc = never submitted.
        let claim = null;
        try {
          const snap = await cycleDoc.ref.collection('pendingClaim').doc(winner.uid).get();
          if (snap.exists) claim = snap.data() || null;
        } catch (err) {
          console.warn(`[exportPayoutLog] claim read failed for ${weekId}/${winner.uid} (skipped): ${err.message}`);
          continue;
        }

        const paid = winner.paid === true;
        // Bookkeeping fields only �?never account numbers or beneficiary names.
        const row = [
          weekId,
          winner.uid,
          winner.username || '',
          winner.rank ?? '',
          Number(winner.share) || 0,
          'NGN',
          claim ? (claim.status || '') : 'not_submitted',
          fmtTs(claim?.submittedAt),
          fmtTs(claim?.markedAt),
          paid ? (claim?.markedBy || '') : '',
          paid ? (winner.payoutReference || claim?.payoutReference || '') : '',
          paid,
        ].map(csvEscape).join(',');
        rows.push(row);
        rowCount++;
      }
    }

    console.log(`[exportPayoutLog] by ${request.auth.uid} rows=${rowCount}`);
    return { success: true, rowCount, csv: rows.join('\n') };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// 2.5 listPayoutClaims �?admin read-only payout queue (ADMIN UI SUPPORT)
// ─────────────────────────────────────────────────────────────────────────────
// Admin-only READ-ONLY helper for the Admin Payout Dashboard Flutter client.
//
// WHY THIS EXISTS (read-only data-access audit): firestore.rules deny ALL
// client writes to pendingClaim/* and only let a winner read their own. The
// dashboard therefore cannot assemble the review queue from direct Firestore
// reads without weakening those rules �?which is forbidden. This callable
// exposes what the admin SDK already sees through the ADMIN_UIDS gate.
//
// SAFETY PROPERTIES:
//   - READ-ONLY: zero Firestore writes, zero payment-provider calls, zero
//     secrets. It cannot mark anything paid.
//   - Returns the FULL account number. Payouts are manual, so the admin must
//     be able to read the destination and type it into their banking app.
//     This widens exposure versus a masked feed, so the ADMIN_UIDS gate and
//     the deny-all client rules are what stand behind it. Access is limited to
//     the single hardcoded admin account.
//   - markLeaderboardPayout remains the ONLY state transition available here.
// ─────────────────────────────────────────────────────────────────────────────
exports.listPayoutClaims = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', 'Forbidden');
    }

    const { weekId } = request.data || {};
    let { limit } = request.data || {};
    const validWeek = (w) => typeof w === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(w);

    limit = Number(limit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 12) limit = 8;

    const fmtTs = (ts) => (ts?.toMillis ? ts.toDate().toISOString() : null);

    let cycleDocs;
    if (validWeek(weekId)) {
      const snap = await db.collection('leaderboardCycles').doc(weekId).get();
      cycleDocs = snap.exists ? [snap] : [];
    } else {
      const snap = await db.collection('leaderboardCycles')
        .orderBy('__name__', 'desc').limit(limit).get();
      cycleDocs = snap.docs;
    }

    const cycles = [];
    for (const cycleDoc of cycleDocs) {
      const c = cycleDoc.data() || {};
      const id = cycleDoc.id;
      const ranked = Array.isArray(c.ranked) ? c.ranked : [];

      const claims = [];
      let claimsSubmitted = 0;
      let claimsMarked     = 0;
      let paidCount         = 0;

      // ── Fraud advisory (additive, read-only) ───────────────────────────
      // Stored fraudReviews/{weekId}_{uid} docs from scoreFraudForWeek, read
      // in one batch. Missing doc �?nulls ("not scored yet"). Never blocks or
      // influences any state �?display only, useful as a signal before sending
      // money by hand.
      let fraudByUid = {};
      try {
        const fraudRefs = ranked
          .filter((r) => r && r.uid)
          .map((r) => db.collection('fraudReviews').doc(`${id}_${r.uid}`));
        if (fraudRefs.length > 0) {
          const fraudSnaps = await db.getAll(...fraudRefs);
          for (const s of fraudSnaps) {
            if (s.exists) fraudByUid[s.data()?.uid] = s.data() || {};
          }
        }
      } catch (err) {
        console.warn(`[listPayoutClaims] fraud read failed for ${id} (ignored): ${err.message}`);
      }

      // Enforcement state (auto-ban ladder) for the admin review. Read-only.
      let enforcementByUid = {};
      try {
        const enfRefs = ranked
          .filter((r) => r && r.uid)
          .map((r) => db.collection(ENFORCEMENT_COLLECTION).doc(r.uid));
        if (enfRefs.length > 0) {
          const enfSnaps = await db.getAll(...enfRefs);
          for (const s of enfSnaps) {
            if (s.exists) enforcementByUid[s.id] = s.data() || {};
          }
        }
      } catch (err) {
        console.warn(`[listPayoutClaims] enforcement read failed for ${id} (ignored): ${err.message}`);
      }

      for (const r of ranked) {
        if (!r || !r.uid) continue;
        const uid = r.uid;
        const paid = r.paid === true;
        if (paid) paidCount++;

        let claim = null;
        try {
          const claimSnap = await cycleDoc.ref.collection('pendingClaim').doc(uid).get();
          if (claimSnap.exists) claim = claimSnap.data() || null;
        } catch (err) {
          console.warn(`[listPayoutClaims] claim read failed for ${id}/${uid} (ignored): ${err.message}`);
        }

        const claimStatus = claim ? (claim.status || null) : null;
        if (claimStatus === 'pending') claimsSubmitted++;
        if (claimStatus === 'marked') claimsMarked++;

        const fraud = fraudByUid[uid] || null;

        claims.push({
          uid,
          rank:        r.rank ?? null,
          username:    r.username || 'Anonymous',
          share:       Number(r.share) || 0,
          paid,
          // Fraud advisory �?null when scoreFraudForWeek has not run for this
          // week yet. Advisory only; marking paid ignores it.
          fraudScore:   fraud && Number.isFinite(Number(fraud.score)) ? Number(fraud.score) : null,
          fraudBand:    fraud ? (fraud.band || null) : null,
          fraudReasons: fraud && Array.isArray(fraud.reasons) ? fraud.reasons : [],
          fraudScoredAt: fraud ? fmtTs(fraud.scoredAt) : null,
          // Silent enforcement state (auto-ban ladder). Review before paying.
          enforcementLevel: enforcementByUid[uid]?.level || null,
          payoutHold: enforcementByUid[uid]?.payoutHold === true,
          suspended: enforcementByUid[uid]?.suspended === true,
          leaderboardExcluded: enforcementByUid[uid]?.leaderboardExcluded === true,
          payoutAccountShared: claim ? claim.payoutAccountShared === true : false,
          payoutAccountUidCount: claim && claim.payoutAccountUidCount != null
            ? Number(claim.payoutAccountUidCount) || null
            : null,
          // Claim state (null when the winner never submitted).
          claimStatus,
          bankCode:        claim ? (claim.bankCode || null) : null,
          // FULL account number: the admin needs it to send the money.
          accountNumber:   claim ? (claim.accountNumber || null) : null,
          beneficiaryName: claim ? (claim.beneficiaryName || null) : null,
          submittedAt:     claim ? fmtTs(claim.submittedAt) : null,
          // Manual-transfer record (authoritative for Paid display = paid above).
          markedAt:        claim ? fmtTs(claim.markedAt) : null,
          markedBy:        claim ? (claim.markedBy || null) : null,
          payoutReference: r.payoutReference || (claim ? (claim.payoutReference || null) : null),
        });
      }

      claims.sort((a, b) => (a.rank ?? 99) - (b.rank ?? 99));

      cycles.push({
        weekId:           id,
        totalCodeRevenue: Number(c.totalCodeRevenue) || 0,
        prizePool:        Number(c.prizePool) || 0,
        houseCut:         Number(c.houseCut) || 0,
        guaranteedFloor:  Number(c.guaranteedFloor) || 0,
        eligibleCount:    Number(c.eligibleCount) || ranked.length,
        status:           c.status || null,
        calculatedAt:     fmtTs(c.calculatedAt),
        paidAt:           fmtTs(c.paidAt),
        notes:            typeof c.notes === 'string' ? c.notes : '',
        claimsSubmitted,
        claimsMarked,
        paidCount,
        claims,
      });
    }

    // Never log account data �?counts only.
    const totalClaims = cycles.reduce((n, c) => n + c.claims.length, 0);
    console.log(`[listPayoutClaims] by ${request.auth.uid} cycles=${cycles.length} claims=${totalClaims}`);
    return { success: true, cycles };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 14c: FLUTTERWAVE (external payment �?redemption code) ────────
// ─────────────────────────────────────────────────────────────────────────────
// A buyer pays on an external web page via Flutterwave (outside the app, so no
// Google Play Billing involvement). On a verified charge.completed webhook we
// mint a single-use redemption code (reusing the shared generation core) that
// the buyer redeems in-app via redeemCode. This is NOT a Play Billing purchase:
// the entitlement is granted through the existing redemption-code channel, not
// through in-app digital-goods billing.
//
// Collections (CF-only by default-deny rules, like redemptionCodes):
//   - paymentIntents/{tx_ref}      : pending order recorded at checkout time.
//   - processedTransactions/{id}   : idempotency + audit record, keyed on
//                                    Flutterwave's transaction id so a duplicate
//                                    webhook delivery can never mint two codes.
// ─────────────────────────────────────────────────────────────────────────────

// ─── (0) Website identity ─────────────────────────────────────────────────
// Both website endpoints are called from a static Hosting page holding a
// Firebase Auth ID token (the same email/password account used in the app).
// The token �?not a body field �?is the buyer identity, so a purchase can never
// be attached to an address the caller does not control.
//
// Returns { uid, email, emailVerified }. Throws on a missing/invalid token; the callers
// translate that into a 401 and the page shows its sign-in card.
//
async function _verifyBearer(req) {
  const raw = req.headers?.authorization || req.headers?.Authorization || '';
  const match = /^Bearer\s+(\S+)$/i.exec(String(raw).trim());
  if (!match) throw new Error('missing_bearer_token');

  // checkRevoked=true: a deleted/disabled account must not be able to create a
  // checkout or read a code with a token minted before the deletion.
  const decoded = await getAuth().verifyIdToken(match[1], true);
  const uid = typeof decoded?.uid === 'string' ? decoded.uid : '';
  if (!uid) throw new Error('token_without_uid');

  let emailVerified = decoded.email_verified === true;

  let email = typeof decoded.email === 'string'
    ? decoded.email.trim().toLowerCase()
    : '';

  // Email/password tokens always carry the email; this is only for a token
  // shape that does not (custom claims, a provider change).
  if (!email) {
    try {
      const record = await getAuth().getUser(uid);
      email = String(record.email || '').trim().toLowerCase();
    } catch (err) {
      console.warn(`[verifyBearer] getUser fallback failed uid=${uid}: ${err.message}`);
    }
  }

  // Test accounts bypass the verification-link flow.
  if (!emailVerified && _isEmailVerificationBypassed(email)) {
    emailVerified = true;
  }

  return { uid, email, emailVerified };
}

// ─── (1) Create a Flutterwave checkout link ───────────────────────────────
// Requires a signed-in buyer. The amount is
// ALWAYS derived server-side from productId; the client supplies only the
// productId + buyer email, never a price. CORS is open so the static hosted
// page can call this directly via fetch().
exports.requestPaymentLink = onRequest(
  { region: 'us-central1', timeoutSeconds: 60, secrets: [FLW_SECRET_KEY] },
  async (req, res) => {
    if (req.method === 'OPTIONS') return _sendOptions(res, req);

    if (req.method !== 'POST') {
      return _sendJson(res, 405, { error: 'Method not allowed' }, req);
    }

    // CORS origin allowlist: the checkout creator is only meant to be called
    // from our own Firebase Hosting pages. Reject requests whose Origin is a
    // browser from an unknown site (no Origin = server-side/curl = allowed).
    const origin = req.headers?.origin;
    if (typeof origin === 'string' && origin && !CORS_ALLOWED_ORIGINS.includes(origin)) {
      console.warn(`[requestPaymentLink] blocked disallowed origin=${origin}`);
      return _sendJson(res, 403, { error: 'Forbidden origin' }, req);
    }

    // Basic per-IP rate limiting (unauthenticated endpoint) to blunt scripted
    // abuse. Not a replacement for App Check at scale.
    const ip = _httpReqIp(req);
    if (_rateLimited(ip)) {
      console.warn(`[requestPaymentLink] rate limited ip=${ip}`);
      return _sendJson(res, 429, { error: 'Too many requests - try again shortly' }, req);
    }

    try {
      const { productId } = req.body || {};

      // ── Who is buying ──────────────────────────────────────────────────
      // Purchases are ACCOUNT-bound: the buyer must be signed in on the
      // website with the same account they play with. The request body's email is ignored entirely -
      // the ID token is the identity, so a caller cannot pay "as" someone
      // else or attach a purchase to an address they do not control.
      let buyerUid = '';
      let buyerEmail = '';
      let buyerVerified = false;
      try {
        const identity = await _verifyBearer(req);
        buyerUid = identity.uid;
        buyerEmail = identity.email;
        buyerVerified = identity.emailVerified === true;
      } catch (err) {
        console.warn(`[requestPaymentLink] unauthenticated: ${err.message}`);
        return _sendJson(res, 401, {
          error: 'Sign in to buy',
          reason: 'unauthenticated',
        }, req);
      }

      if (buyerVerified !== true) {
        console.warn(`[requestPaymentLink] unverified email uid=${buyerUid}`);
        return _sendJson(res, 403, {
          error: 'Verify your email address to continue',
          reason: 'email_not_verified',
        }, req);
      }

      const product = FLUTTERWAVE_PRODUCTS[productId];
      if (!product) {
        return _sendJson(res, 400, { error: 'Unknown productId' }, req);
      }

      if (!_isValidEmail(buyerEmail)) {
        return _sendJson(res, 400, {
          error: 'Your account has no usable email',
          reason: 'no_email',
        }, req);
      }


      // Unique reference that encodes the product (Flutterwave-safe charset).
      // tx_ref pattern: ^[A-Za-z0-9-]+$ �?underscores are NOT allowed, so we
      // use the hyphenated txToken rather than the underscored productId.
      const tx_ref = `AQ-${product.txToken}-${randomUUID()}`;

      // Record the pending intent so the webhook + success page are auditable
      // and the buyer is reproducible. `uid` is what makes the minted code
      // belong to this account (see _mintCharge / redeemCode). Contact details
      // are deliberately NOT copied here: the account doc is their home, and a
      // second copy would be PII that outlives account deletion.
      await db.collection('paymentIntents').doc(tx_ref).set({
        productId,
        uid:      buyerUid,
        email:    buyerEmail,
        amount:   product.amount,
        currency: product.currency,
        status:   'pending',
        createdAt: FieldValue.serverTimestamp(),
      });

      const payload = {
        tx_ref,
        amount:        String(product.amount),
        currency:      product.currency,
        redirect_url:  `${HOSTING_BASE}/success.html?email=${encodeURIComponent(buyerEmail)}`,
        customer:      { email: buyerEmail },
        customizations: { title: 'AnimeQuiz', description: product.title },
        // product_id is the authoritative lookup key for the webhook.
        meta:          { product_id: productId },
      };

      const resp = await fetch('https://api.flutterwave.com/v3/payments', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${FLW_SECRET_KEY.value()}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payload),
      });

      const json = await resp.json();

      if (!resp.ok || !json.data?.link) {
        console.error('[requestPaymentLink] Flutterwave checkout failed',
          resp.status, JSON.stringify(json).slice(0, 500));
        return _sendJson(res, 502, { error: 'Flutterwave checkout failed' }, req);
      }

      console.log(`[requestPaymentLink] tx_ref=${tx_ref} product=${productId} email=${buyerEmail}`);
      return _sendJson(res, 200, { success: true, link: json.data.link, tx_ref }, req);
    } catch (err) {
      console.error('[requestPaymentLink] ERROR:', err);
      return _sendJson(res, 500, { error: 'Internal error' }, req);
    }
  }
);

// ─── (2) Flutterwave webhook receiver ─────────────────────────────────────
// Server-to-server (NOT onCall �?no Firebase Auth token). Signature-checked via
// BOTH documented mechanisms (v3 verif-hash + v4 HMAC-SHA256), then normalized.
// Idempotent: keyed on Flutterwave's transaction id, and the code + processed
// record are written in a single Firestore transaction so a retried delivery can
// never mint a second code.
exports.flutterwaveWebhook = onRequest(
  { region: 'us-central1', timeoutSeconds: 60, secrets: [FLW_SECRET_KEY, FLW_SECRET_HASH] },
  async (req, res) => {
    if (req.method === 'OPTIONS') {
      console.log('[flutterwaveWebhook] OPTIONS preflight �?responding 204');
      return _sendOptions(res, req);
    }

    // Every response below is funneled through `respond`, so the exact status
    // and the full JSON body sent back to Flutterwave are ALWAYS written to the
    // logs. No silent return is left in this function.
    const respond = (status, body) => {
      console.log(`[flutterwaveWebhook] RESPOND status=${status} body=${JSON.stringify(body)}`);
      return _sendJson(res, status, body, req);
    };

    // ── 2a. Signature verification (v3 + v4, defensive) ──────────────────
    const rawBody = req.rawBody || Buffer.from(JSON.stringify(req.body || {}), 'utf8');
    const secretHash = FLW_SECRET_HASH.value();

    const v4Header = req.headers['flutterwave-signature'];
    const v4Ok = v4Header != null
      && _constantTimeEq(
        createHmac('sha256', secretHash).update(rawBody).digest('base64'),
        v4Header
      );

    const v3Header = req.headers['verif-hash'];
    const v3Ok = v3Header != null && _constantTimeEq(v3Header, secretHash);

    if (!v4Ok && !v3Ok) {
      console.warn(`[flutterwaveWebhook] Invalid signature �?rejected (v4 header present=${v4Header != null} v4Ok=${v4Ok}, v3 header present=${v3Header != null} v3Ok=${v3Ok})`);
      return respond(401, { error: 'Invalid signature' });
    }
    // Log which mechanism validated so we can confirm this account's API version
    // on the first live webhook (a genuine webhook failing both = wrong secret
    // hash or wrong version).
    console.log(`[flutterwaveWebhook] signature OK via ${v4Ok ? 'v4-HMAC' : 'v3-verif-hash'}`);

    try {
      // ── 2b. Normalize the payload (v3 FLAT vs v4 data-wrapped) ─────────
      // Confirmed from live logs (topKeys = id, txRef, flwRef, orderRef, ...,
      // customer, entity, "event.type"): this account delivers v3 FLAT
      // payloads �?ALL fields (including the event name at the literal key
      // "event.type", customer, amount, currency, status) sit at the TOP level,
      // with NO `data` wrapper and NO `meta`. Read the flat body first, falling
      // back to a possible `data` wrapper so a v4-shaped payload still works.
      const body  = req.body || {};
      const data  = body.data || {};
      const pick  = (k) => (k in body && body[k] !== null) ? body[k] : data[k];
      const eventType = body['event.type'] || body.type || body.event
                     || data['event.type'] || data.type || data.event;
      const status    = pick('status'); // v3 flat 'successful' | v4 'succeeded'
      const succeeded = status === 'succeeded' || status === 'successful';

      console.log(`[flutterwaveWebhook] entry eventType=${JSON.stringify(eventType)} status=${JSON.stringify(status)} topKeys=${Object.keys(body).join(',')} dataKeys=${Object.keys(data).join(',')}`);

      // Two independent signals, BOTH required before minting:
      //   (1) eventType �?WHAT happened. Completed-charge event names:
      //       'charge.completed' (v4/standard shape) and 'CARD_TRANSACTION'
      //       (this account's v3 flat feed, confirmed in logs). eventType
      //       alone is NOT proof of success.
      //   (2) status �?the OUTCOME (succeeded/successful vs failed) of that
      //       transaction. Both eventType AND status must pass.
      const isCompleted = eventType === 'charge.completed' || eventType === 'CARD_TRANSACTION';
      if (!isCompleted) {
        console.log(`[flutterwaveWebhook] ignored eventType=${JSON.stringify(eventType)} (expected charge.completed | CARD_TRANSACTION)`);
        return respond(200, { ok: true, ignored: eventType });
      }
      if (!succeeded) {
        console.log(`[flutterwaveWebhook] ignored non-success status=${JSON.stringify(status)} (expected "succeeded" or "successful")`);
        return respond(200, { ok: true, ignored: status });
      }

      // v3 flat payloads use camelCase `txRef`/`flwRef`; v4 uses `tx_ref`.
      const flwTxnId    = String(pick('id'));
      const txRef       = pick('txRef') || pick('tx_ref') || pick('reference') || '';
      const amount      = Number(pick('amount'));
      const currency    = pick('currency');
      // Flutterwave's customer.email is NOT authoritative: in test/sandbox mode
      // it substitutes a generated address (ravesb_...), and it may differ in
      // live mode too. Keep it for AUDIT ONLY �?the authoritative buyer email
      // comes from paymentIntents/{txRef}, written at checkout BEFORE Flutterwave
      // ever saw the transaction (see the transaction below).
      const customer      = pick('customer') || {};
      const flwReportedEmail = ((customer && customer.email) || '').trim().toLowerCase();

      // ── 3. Resolve product from tx_ref (NO meta in v3 flat payloads) ───
      // The flat payload contains no `meta`, so data.meta.product_id can never
      // exist on this account. The product is encoded in the tx_ref WE
      // generated at checkout �?`AQ-{txToken}-{uuid}` �?so match the token
      // prefix back to the catalog instead of trusting meta.product_id.
      const txRefStr = typeof txRef === 'string' ? txRef : '';
      const resolved = _resolveProductFromTxRef(txRefStr);
      const productId = resolved.productId;
      const product   = resolved.product;

      console.log(`[flutterwaveWebhook] normalized flwTxnId=${JSON.stringify(flwTxnId)} txRef=${JSON.stringify(txRef)} amount=${amount} currency=${JSON.stringify(currency)} productId=${JSON.stringify(productId)} flwReportedEmail=${JSON.stringify(flwReportedEmail)}`);

      if (!product) {
        console.warn(`[flutterwaveWebhook] unknown product from txRef=${JSON.stringify(txRef)} (known prefixes: ${Object.values(FLUTTERWAVE_PRODUCTS).map(p => `AQ-${p.txToken}-`).join(', ')})`);
        return respond(400, { error: 'Unknown product' });
      }
      if (amount !== product.amount || currency !== product.currency) {
        // Price-tamper guard: never mint for a mismatched amount/currency.
        console.warn(`[flutterwaveWebhook] PRICE-TAMPER txn=${flwTxnId} expected ${product.amount} ${product.currency} got ${amount} ${currency}`);
        return respond(400, { error: 'Amount/currency mismatch' });
      }

      // 2c. Idempotent mint, in ONE transaction.
      // _mintCharge asserts the processed doc is absent, writes the processed
      // doc, and writes the new code doc so a retried delivery can never
      // double-mint. A confirmed charge ALWAYS produces a code: if the checkout
      // paymentIntent is missing (requestPaymentLink write failed or raced) the
      // mint falls back to Flutterwave's customer.email instead of silently
      // dropping a paid purchase, which is what left buyers with a confirmed
      // payment and no way to retrieve a code.
      const mint = await _mintCharge({
        txRef,
        flwTxnId,
        amount,
        currency,
        product,
        productId,
        fallbackEmail: flwReportedEmail,
      });

      if (mint.status === 'rejected') {
        // 200 with ack so Flutterwave does not retry; no code was minted and
        // nothing was written (the whole transaction was a no-op).
        console.warn(`[flutterwaveWebhook] REJECT txRef=${JSON.stringify(txRef)} reason=${mint.rejected} refusing to mint`);
        return respond(200, { ok: true, minted: false, rejected: mint.rejected });
      }
      if (mint.status === 'fulfilled') {
        console.log(`[flutterwaveWebhook] MINTED code=${mint.code} txn=${flwTxnId} product=${productId} email=${mint.buyerEmail || flwReportedEmail}`);
      } else {
        console.log(`[flutterwaveWebhook] duplicate txn=${flwTxnId} no code minted (code=${mint.code || 'none'})`);
      }

      // 4. Respond 200 quickly (Flutterwave treats non-200 as failure).
      return respond(200, { ok: true, minted: mint.status === 'fulfilled', code: mint.code });
    } catch (err) {
      console.error('[flutterwaveWebhook] ERROR:', err);
      // Do NOT return non-200 here for a genuine, already-handled txn; but a
      // real processing error should surface so Flutterwave retries.
      return respond(500, { error: 'Internal error' });
    }
  }
);

// ─── (3) Deliver the code to the buyer (success page) ─────────────────────
// Open endpoint (buyer isn't logged in). Returns the code ONLY when BOTH the
// recorded tx_ref AND the buyer's checkout email match: a bare tx_ref is not
// enough. Recoverable: any later visit with the same tx_ref+email re-fetches it.
//
// SELF-HEALING: if no processedTransactions record exists yet (webhook late,
// lost, or transiently rejected), the charge is verified directly with
// Flutterwave by tx_ref and minted on demand. A confirmed, price-checked
// payment therefore ALWAYS yields a code even when the webhook never fires.
// Buyers who previously saw "No processed transaction for that reference" can
// retrieve their code from this endpoint (or re-visit success.html).
exports.getPurchasedCode = onRequest(
  { region: 'us-central1', timeoutSeconds: 60, secrets: [FLW_SECRET_KEY] },
  async (req, res) => {
    if (req.method === 'OPTIONS') return _sendOptions(res, req);

    if (req.method !== 'POST') {
      return _sendJson(res, 405, { error: 'Method not allowed' }, req);
    }

    // CORS origin allowlist + rate limit (same policy as requestPaymentLink).
    const origin = req.headers?.origin;
    if (typeof origin === 'string' && origin && !CORS_ALLOWED_ORIGINS.includes(origin)) {
      console.warn(`[getPurchasedCode] blocked disallowed origin=${origin}`);
      return _sendJson(res, 403, { error: 'Forbidden origin' }, req);
    }
    if (_rateLimited(_httpReqIp(req))) {
      return _sendJson(res, 429, { error: 'Too many requests - try again shortly' }, req);
    }

    try {
      const { tx_ref } = req.body || {};

      if (typeof tx_ref !== 'string' || !tx_ref.trim()) {
        return _sendJson(res, 400, { error: 'tx_ref is required' }, req);
      }
      const txRef = tx_ref.trim();

      // The caller must be signed in. The token's email is the only email we
      // trust �?the old free-text `email` body field is gone, because a code
      // that belongs to an account must never be releasable to whoever types
      // the buyer's address.
      let buyerUid = '';
      let buyerEmail = '';
      try {
        const identity = await _verifyBearer(req);
        buyerUid = identity.uid;
        buyerEmail = identity.email;
      } catch (err) {
        console.warn(`[getPurchasedCode] unauthenticated: ${err.message}`);
        return _sendJson(res, 401, {
          error: 'Sign in to see your purchase',
          reason: 'unauthenticated',
        }, req);
      }
      if (!_isValidEmail(buyerEmail)) {
        return _sendJson(res, 400, {
          error: 'Your account has no usable email',
          reason: 'no_email',
        }, req);
      }

      // Fast path: the code was already minted (webhook delivered).
      const snap = await db.collection('processedTransactions')
        .where('tx_ref', '==', txRef)
        .limit(1)
        .get();

      if (!snap.empty) {
        const rec = snap.docs[0].data();
        const ownerUid = typeof rec.uid === 'string' ? rec.uid : '';
        const ownerEmail = typeof rec.buyerEmail === 'string'
          ? rec.buyerEmail.trim().toLowerCase()
          : '';
        // Account-bound codes release only to their account. Records minted
        // before binding existed (no uid) still work by matching the token's
        // email, so no pre-migration buyer is stranded.
        const allowed = ownerUid
          ? ownerUid === buyerUid
          : ownerEmail === buyerEmail;
        if (!allowed) {
          return _sendJson(res, 403, {
            error: 'This purchase belongs to another account',
            reason: 'not_owner',
          }, req);
        }
        const p = rec.productId ? FLUTTERWAVE_PRODUCTS[rec.productId] : null;
        return _sendJson(res, 200, {
          success: true,
          code:    rec.code,
          type:    p ? p.type : undefined,
          value:   p ? p.value : undefined,
        }, req);
      }

      // Self-heal: no code minted yet. The payment may still be confirmed
      // (webhook late / lost / transiently rejected), so verify the charge
      // directly with Flutterwave by tx_ref and mint on demand. This is the
      // guarantee that a confirmed payment ALWAYS delivers a code, even if the
      // webhook never fires.
      //
      // Anti-abuse before touching Flutterwave:
      //  (1) a short-lived cache for a KNOWN-TERMINAL failure (failed/cancelled)
      //      stops a dead reference hitting the API on every retry,
      //  (2) a per-tx_ref limiter (in addition to per-IP above) caps probes of a
      //      single reference so random refs can't burn the verify quota.
      // A "not confirmed yet" result is deliberately NOT cached: the success
      // page polls every 3s while the charge settles, and a cached miss would
      // turn every one of those retries into a no-op.
      const cached = _cachedVerifyResult(txRef);
      if (cached === false) {
        return _sendJson(res, 402, { error: 'This payment was not successful - no code was issued' }, req);
      }
      if (_txRefLookupLimited(txRef)) {
        return _sendJson(res, 429, { error: 'Too many requests for this reference - try again shortly' }, req);
      }

      let txns;
      try {
        txns = await _verifyFlutterwaveByTxRef(txRef);
      } catch (err) {
        console.error(`[getPurchasedCode] Flutterwave verify failed txRef=${txRef}: ${err.message}`);
        return _sendJson(res, 503, { error: 'Payment status is temporarily unavailable - please try again shortly' }, req);
      }

      const confirmed = txns.find((t) => {
        // Only an explicitly "successful" charge may mint. Flutterwave's API
        // uses "successful"/"failed"/"pending" �?never trust anything else.
        const s = String(t && t.status || '').toLowerCase();
        return s === 'successful';
      });

      if (!confirmed) {
        const terminal = txns.some((t) => {
          const s = String(t && t.status || '').toLowerCase();
          return s === 'failed' || s === 'cancelled';
        });
        // Only a terminal outcome is worth remembering; a pending/unknown
        // charge must be re-verified on the next poll.
        if (terminal) _rememberVerifyResult(txRef, false);
        return _sendJson(res, terminal ? 402 : 404, {
          error: terminal
            ? 'This payment was not successful - no code was issued'
            : 'No processed transaction for that reference yet - your payment is still being confirmed, try again shortly'
        }, req);
      }

      const resolved = _resolveProductFromTxRef(txRef);
      const product   = resolved.product;
      const productId = resolved.productId;
      if (!product) {
        return _sendJson(res, 400, { error: 'Unknown product' }, req);
      }

      // Price/currency integrity from Flutterwave's verified record. Amount and
      // currency both come from the API response; the expected price/currency
      // come from the server-side product table. An underpayment (amount below
      // the expected price) or a currency mismatch is a rejected charge and must
      // never mint. Overpayment is accepted (the buyer paid at least the price).
      const amount = Number(confirmed.amount);
      const currency = String(confirmed.currency || '').toUpperCase();
      if (!Number.isFinite(amount) || amount < product.amount || currency !== product.currency) {
        console.warn(`[getPurchasedCode] PRICE-MISMATCH txRef=${txRef} expected >=${product.amount} ${product.currency} got ${amount} ${currency}`);
        return _sendJson(res, 400, { error: 'Amount/currency mismatch' }, req);
      }

      // Identity for a self-healed mint: the checkout intent is authoritative.
      // When it carries a uid the caller must BE that account; only a legacy
      // uid-less intent falls back to comparing the token's email with the
      // intent / Flutterwave record.
      const flwEmail = String(confirmed.customer && confirmed.customer.email || '').trim().toLowerCase();
      const intentSnap = await db.collection('paymentIntents').doc(txRef).get();
      const intent = intentSnap.exists ? intentSnap.data() : null;
      const intentUid = intent && typeof intent.uid === 'string' ? intent.uid : '';
      const intentEmail = intent && typeof intent.email === 'string'
        ? intent.email.trim().toLowerCase()
        : '';

      const identityOk = intentUid
        ? intentUid === buyerUid
        : ((intentEmail && intentEmail === buyerEmail)
            || (flwEmail && flwEmail === buyerEmail));

      if (identityOk) {
        // Attribution OK. Mint idempotently: races with the webhook are
        // resolved by _mintCharge keying on Flutterwave's transaction id.
        const mint = await _mintCharge({
          txRef,
          flwTxnId: String(confirmed.id),
          amount,
          currency,
          product,
          productId,
          buyerEmail,
          fallbackEmail: flwEmail,
        });
        if (mint.status === 'rejected') {
          console.error(`[getPurchasedCode] mint rejected txRef=${txRef} reason=${mint.rejected}`);
          return _sendJson(res, 502, { error: 'Unable to issue your code - please contact support' }, req);
        }
        if (mint.status === 'fulfilled') {
          console.log(`[getPurchasedCode] self-heal MINTED txRef=${txRef} flwTxnId=${confirmed.id} product=${productId} email=${buyerEmail}`);
        } else {
          console.log(`[getPurchasedCode] self-heal duplicate txRef=${txRef} flwTxnId=${confirmed.id} code=${mint.code}`);
        }
        return _sendJson(res, 200, {
          success: true,
          code:    mint.code,
          type:    product.type,
          value:   product.value,
        }, req);
      }

      // Confirmed payment but the claimed identity matches neither the
      // checkout intent nor Flutterwave's customer record. Don't mint.
      console.warn(`[getPurchasedCode] EMAIL MISMATCH txRef=${txRef} claimed=${buyerEmail} intent=${intentEmail} flw=${flwEmail}`);
      return _sendJson(res, 403, { error: 'Email does not match the buyer for this payment' }, req);
    } catch (err) {
      console.error('[getPurchasedCode] ERROR:', err);
      return _sendJson(res, 500, { error: 'Internal error' }, req);
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── getMyPurchases: a player's own website purchases ───────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// The success page shows the code once; this is the "I lost it" path, in-app.
//
// Read-only, self-only: the uid comes from the token and is never a parameter.
// `paymentIntents` and `redemptionCodes` are client-unreadable by rules, which
// is why this has to be a callable.
//
// No orderBy on the query: `where(uid) + orderBy(createdAt)` needs a composite
// index, and this must work on a fresh deploy. A player's purchase count is
// small, so fetch by uid and sort/cap in memory.
const PURCHASES_MAX_RETURNED = 50;

exports.getMyPurchases = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const iso = (ts) => (ts?.toMillis ? ts.toDate().toISOString() : null);

    const intentSnap = await db.collection('paymentIntents')
      .where('uid', '==', uid)
      .get();

    // An abandoned checkout leaves a `pending` intent behind. Show recent ones
    // (the player may have just paid and the webhook is still in flight), but
    // do not let a year of abandoned tabs crowd out real purchases. Undated
    // legacy rows are kept: better a maybe-purchase than a hidden one.
    const STALE_PENDING_MS = 24 * 60 * 60 * 1000;
    const nowMs = Date.now();
    const intents = intentSnap.docs.filter((doc) => {
      const row = doc.data() || {};
      if (row.status !== 'pending') return true;
      const createdMs = row.createdAt?.toMillis ? row.createdAt.toMillis() : 0;
      return !createdMs || (nowMs - createdMs) <= STALE_PENDING_MS;
    });

    const purchases = await Promise.all(intents.map(async (doc) => {
      const row = doc.data() || {};

      // New intents carry the code (see _mintCharge). Older ones need one
      // lookup into processedTransactions, keyed on the tx_ref, so a purchase
      // made before the field existed still shows up with its code.
      let code = typeof row.code === 'string' ? row.code : '';
      if (!code) {
        try {
          const processed = await db.collection('processedTransactions')
            .where('tx_ref', '==', doc.id)
            .limit(1)
            .get();
          if (!processed.empty) {
            const rec = processed.docs[0].data() || {};
            if (typeof rec.code === 'string') code = rec.code;
          }
        } catch (err) {
          console.warn(`[getMyPurchases] processed lookup failed tx=${doc.id}: ${err.message}`);
        }
      }

      let codeStatus = null;
      let type = null;
      let value = null;
      let redeemedAt = null;
      let codeExpiresAt = null;

      if (code) {
        try {
          const codeSnap = await db.collection('redemptionCodes').doc(code).get();
          const codeData = codeSnap.exists ? (codeSnap.data() || {}) : null;
          if (codeData) {
            codeStatus = codeData.status || 'unused';
            type = codeData.type || null;
            value = codeData.value ?? null;
            redeemedAt = iso(codeData.redeemedAt);
            codeExpiresAt = iso(codeData.expiresAt);
          } else {
            // Minted but the code doc is gone: report it as unavailable rather
            // than handing the UI a code that cannot be redeemed.
            code = '';
          }
        } catch (err) {
          console.warn(`[getMyPurchases] code read failed code=${code}: ${err.message}`);
        }
      }

      const product = FLUTTERWAVE_PRODUCTS[row.productId] || null;

      return {
        txRef:       doc.id,
        productId:   row.productId || '',
        productTitle: product ? product.title : 'AnimeQuiz purchase',
        status:      row.status || 'pending',
        amount:      Number(row.amount) || 0,
        currency:    row.currency || 'NGN',
        createdAt:   iso(row.createdAt),
        fulfilledAt: iso(row.fulfilledAt),
        code:        code || null,
        codeStatus,
        type,
        value,
        redeemedAt,
        codeExpiresAt,
      };
    }));

    // Newest first. ISO strings sort lexicographically, and a missing date
    // (legacy doc) goes last rather than first.
    purchases.sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));

    console.log(`[getMyPurchases] uid=${uid} rows=${purchases.length}`);
    return {
      success: true,
      purchases: purchases.slice(0, PURCHASES_MAX_RETURNED),
    };
  }
);



exports.awardPremiumMonday = onSchedule(
  { schedule: '1 23 * * 0', timeZone: 'UTC', region: 'us-central1' },
  async () => {
    const BATCH_SIZE = 400;
    let lastDoc = null;
    let totalAwarded = 0;

    while (true) {
      let q = db.collection('users')
        .where('premiumActive', '==', true)
        .orderBy('__name__')
        .limit(BATCH_SIZE);
      if (lastDoc) q = q.startAfter(lastDoc);

      const snap = await q.get();
      if (snap.empty) break;

      const batch = db.batch();
      for (const doc of snap.docs) {
        if (isAdminAccountUid(doc.id)) continue; // ghost admin: no economy
        const data       = doc.data();
        const newBalance = (data.animeCoins || 0) + 30;

        batch.update(doc.ref, {
          weeklyPoints: FieldValue.increment(75),
          animeCoins:   FieldValue.increment(30),
        });

        const txLogRef = doc.ref.collection('coinTransactions').doc();
        batch.set(txLogRef, {
          type:         'iap',
          delta:        30,
          balanceAfter: newBalance,
          timestamp:    FieldValue.serverTimestamp(),
        });

        const wpTxRef = doc.ref.collection('wpTransactions').doc();
        batch.set(wpTxRef, {
          type:         'earn_premium_monday',
          delta:        75,
          balanceAfter: (data.weeklyPoints || 0) + 75,
          timestamp:    FieldValue.serverTimestamp(),
        });

        totalAwarded++;
      }
      await batch.commit();

      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < BATCH_SIZE) break;
    }

    console.log(`[awardPremiumMonday] awarded +75 WP / +30 AC to ${totalAwarded} premium users`);
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── awardPremiumMonthlyWP ──────────────────────────────────────────────────────
// Grants +100 WP each month on the subscription activation anniversary day.
// Runs daily. Uses premiumMonthlyWPGranted (format "YYYY-MM") to prevent
// duplicate grants. WP is a flat grant �?NOT routed through multiplier or
// retry-decay. Only premiumActive users with a matching anniversary day receive it.
// ─────────────────────────────────────────────────────────────────────────────
exports.awardPremiumMonthlyWP = onSchedule(
  { schedule: '0 1 * * *', timeZone: 'UTC', region: 'us-central1' },
  async () => {
    const now        = new Date();
    const todayDM   = now.getUTCDate();          // 1-31
    const currentMonth = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
    const BATCH_SIZE = 400;
    let lastDoc = null;
    let totalAwarded = 0;

    while (true) {
      let q = db.collection('users')
        .where('premiumActive', '==', true)
        .orderBy('__name__')
        .limit(BATCH_SIZE);
      if (lastDoc) q = q.startAfter(lastDoc);

      const snap = await q.get();
      if (snap.empty) break;

      const batch = db.batch();
      for (const doc of snap.docs) {
        if (isAdminAccountUid(doc.id)) continue; // ghost admin: no economy
        const data   = doc.data();
        const granted = data.premiumMonthlyWPGranted;

        // Already granted this calendar month �?skip.
        if (granted === currentMonth) continue;

        // Find the original subscription receipt (earliest createdAt).
        const receiptsSnap = await db.collection('premiumReceipts')
          .where('uid', '==', doc.id)
          .orderBy('createdAt')
          .limit(1)
          .get();

        if (receiptsSnap.empty) continue;
        const receiptData = receiptsSnap.docs[0].data();
        const receiptCreated = receiptData.createdAt;
        if (!receiptCreated) continue;

        const receiptDate = receiptCreated.toDate ? receiptCreated.toDate() : new Date(receiptCreated);
        if (receiptDate.getUTCDate() !== todayDM) continue;

        // Anniversary day �?award 100 WP.
        batch.update(doc.ref, {
          weeklyPoints:            FieldValue.increment(100),
          premiumMonthlyWPGranted: currentMonth,
        });

        const wpTxRef = doc.ref.collection('wpTransactions').doc();
        batch.set(wpTxRef, {
          type:         'earn_premium_monthly',
          delta:        100,
          balanceAfter: (data.weeklyPoints || 0) + 100,
          timestamp:    FieldValue.serverTimestamp(),
        });

        totalAwarded++;
      }
      await batch.commit();
      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < BATCH_SIZE) break;
    }
    console.log(`[awardPremiumMonthlyWP] awarded +100 WP to ${totalAwarded} premium users for ${currentMonth}`);
  }
);

// ─── Premium expiry enforcement ────────────────────────────────────────────
// Daily pass: query users with premiumActive == true, find each user's most
// recent premiumReceipts document, and if its expiresAt <= now, flip
// premiumActive to false on the user doc. Receipts whose expiresAt is still in
// the future leave premiumActive untouched. Uses batched writes + pagination
// so it scales beyond the 500-write-per-batch Firestore limit. The admin SDK
// bypasses security rules, so it can read/write premiumReceipts freely.
// ─────────────────────────────────────────────────────────────────────────────
exports.expireExpiredPremium = onSchedule(
  { schedule: '0 1 * * *', timeZone: 'UTC', region: 'us-central1' },
  async () => {
    const BATCH_SIZE = 400;
    const now       = Timestamp.now();
    let lastDoc  = null;
    let expired  = 0;
    let orphanedCleared = 0;

    while (true) {
      let q = db.collection('users')
        .where('premiumActive', '==', true)
        .orderBy('__name__')
        .limit(BATCH_SIZE);
      if (lastDoc) q = q.startAfter(lastDoc);

      const snap = await q.get();
      if (snap.empty) break;

      const batch = db.batch();
      let batchExpired = 0;
      for (const doc of snap.docs) {
        const uid  = doc.id;
        const uRef = doc.ref;

        // Most recent premium receipt = highest expiresAt among the user's
        // premiumReceipts subcollection.
        const receipts = await uRef.collection('premiumReceipts')
          .orderBy('expiresAt', 'desc')
          .limit(1)
          .get();

        if (receipts.empty) {
          // No receipts at all but premiumActive is true �?treat as an
          // orphaned/invalid flag and clear it. Tracked separately from
          // normal expirations so logs distinguish "expired on schedule"
          // from "had no receipt at all" (the latter may indicate a data
          // problem, not just normal churn).
          batch.update(uRef, { premiumActive: false });
          expired++;
          batchExpired++;
          orphanedCleared++;
          continue;
        }

        const receiptExpiry = receipts.docs[0].data().expiresAt;
        // Guard against a malformed receipt (no expiresAt / non-Timestamp).
        if (!receiptExpiry || typeof receiptExpiry.toMillis !== 'function') {
          continue;
        }

        if (receiptExpiry.toMillis() <= now.toMillis()) {
          batch.update(uRef, { premiumActive: false });
          expired++;
          batchExpired++;
        }
        // If still in the future, leave premiumActive untouched.
      }

      if (batchExpired > 0) await batch.commit();

      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < BATCH_SIZE) break;
    }

    console.log(`[expireExpiredPremium] Expired premium for ${expired} users (${orphanedCleared} orphaned �?had no receipt at all).`);
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 15: COSMETIC STORE (unchanged) ───────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// Cosmetic catalog removed �?cosmetic shop is closed.
exports.purchaseCosmetic = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');
    // Cosmetic shop is closed �?no new purchases allowed.
    throw new HttpsError('failed-precondition', 'cosmetic_shop_closed');
  }
);

// COSMETIC_CATALOG removed �?cosmetic shop is closed.

exports.equipCosmetic = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const { slot, cosmeticId } = request.data || {};
    const slotFieldMap = {
      frame: 'equippedFrame',
      color: 'equippedColor',
      badge: 'equippedBadge',
    };
    const field = slotFieldMap[slot];
    if (!field) {
      throw new HttpsError('invalid-argument', 'invalid_slot');
    }
    if (typeof cosmeticId !== 'string' || !cosmeticId) {
      throw new HttpsError('invalid-argument', 'cosmeticId is required');
    }

    const userRef = db.collection('users').doc(uid);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      const owned = (data.ownedCosmetics || []).includes(cosmeticId);
      if (!owned) {
        throw new HttpsError('failed-precondition', 'not_owned');
      }

      tx.update(userRef, { [field]: cosmeticId });
    });

    console.log(`[equipCosmetic] uid=${uid} slot=${slot} cosmeticId=${cosmeticId}`);
    return { success: true };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 17: PUSH NOTIFICATIONS (unchanged) ───────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

async function sendToUser(uid, { title, body, data }) {
  try {
    const snap  = await db.collection('users').doc(uid).get();
    const token = snap.data()?.fcmToken;
    if (!token) return;
    await getMessaging().send({
      token,
      notification: { title, body },
      ...(data ? { data } : {}),
    });
  } catch (err) {
    console.warn(`[sendToUser] uid=${uid} failed (ignored): ${err.message}`);
  }
}

// Like sendToUser, but reports failure: callers that must know whether the
// message went out (nudgeFriend rolls its daily stamp back on a throw).
async function _sendPushOrThrow(uid, { title, body }) {
  const snap = await db.collection('users').doc(uid).get();
  const token = snap.data()?.fcmToken;
  if (!token) throw new Error('no_fcm_token');
  await getMessaging().send({ token, notification: { title, body } });
}

async function sendToTokens(tokens, { title, body, data }) {
  const clean = tokens.filter(Boolean);
  if (clean.length === 0) return;
  try {
    await getMessaging().sendEachForMulticast({
      tokens: clean,
      notification: { title, body },
      ...(data ? { data } : {}),
    });
  } catch (err) {
    console.warn(`[sendToTokens] batch of ${clean.length} failed (ignored): ${err.message}`);
  }
}

exports.mondayPrizePoolAnnouncement = onSchedule(
  { schedule: '0 8 * * 1', timeZone: 'UTC', region: 'us-central1' },
  async () => {
    const weekId = currentWeekId();
    const poolSnap = await db.collection('prize_pool').doc(weekId).get();
    const poolData = poolSnap.data() || {};
    const adminPool = Number(poolData.adminPoolNaira);
    const total = (Number.isFinite(adminPool) && adminPool > 0)
      ? adminPool
      : 0;

    const title = '⚔️ New week, new prize pool!';
    const body  = total > 0
      ? `�?{total.toLocaleString()} up for grabs. The competition starts now.`
      : 'The competition starts now. Check the board for this week\'s pool.';

    let lastDoc = null;
    let sent = 0;
    while (true) {
      let q = db.collection('users').orderBy('__name__').limit(300);
      if (lastDoc) q = q.startAfter(lastDoc);
      const snap = await q.get();
      if (snap.empty) break;

      const tokens = snap.docs
        .filter((d) => !isAdminAccountUid(d.id))
        .map((d) => d.data().fcmToken)
        .filter(Boolean);
      await sendToTokens(tokens, { title, body, data: { type: 'leaderboard' } });
      sent += tokens.length;

      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < 300) break;
    }
    console.log(`[mondayPrizePoolAnnouncement] sent to ${sent} users, pool=�?{total}`);
  }
);

exports.thursdayNearMiss = onSchedule(
  { schedule: '0 19 * * 4', timeZone: 'UTC', region: 'us-central1' },
  async () => {
    const top50 = await db.collection('users')
      .orderBy('weeklyPoints', 'desc')
      .limit(50 + ADMIN_UIDS.length)
      .get();

    // Ghost admin accounts hold no rank and get no player notifications.
    const docs = top50.docs.filter((d) => !isAdminAccountUid(d.id));
    if (docs.length < 4) return;

    const thirdPlaceWP = docs[2].data().weeklyPoints || 0;
    let sent = 0;

    for (let i = 3; i < Math.min(20, docs.length); i++) {
      const d    = docs[i].data();
      const rank = i + 1;
      const gap  = thirdPlaceWP - (d.weeklyPoints || 0);
      if (!d.fcmToken) continue;

      await sendToUser(docs[i].id, {
        title: '📊 You\'re within reach!',
        body:  `You're rank ${rank} �?${gap} WP behind 3rd place. 3 days left.`,
        data:  { type: 'leaderboard' },
      });
      sent++;
    }
    console.log(`[thursdayNearMiss] sent to ${sent} users`);
  }
);

exports.sundayUrgency = onSchedule(
  { schedule: '0 18 * * 0', timeZone: 'UTC', region: 'us-central1' },
  async () => {
    const weekId   = currentWeekId();
    const poolSnap = await db.collection('prize_pool').doc(weekId).get();
    const poolData = poolSnap.data() || {};
    const adminPool = Number(poolData.adminPoolNaira);
    const total = (Number.isFinite(adminPool) && adminPool > 0)
      ? adminPool
      : 0;

    const title = '�?6 hours left!';
    const body  = total > 0
      ? `Prize pool: �?{total.toLocaleString()}. Don't let someone sneak past you.`
      : '6 hours left! Don\'t let someone sneak past you.';

    let lastDoc = null;
    let sent = 0;
    while (true) {
      let q = db.collection('users').orderBy('__name__').limit(300);
      if (lastDoc) q = q.startAfter(lastDoc);
      const snap = await q.get();
      if (snap.empty) break;

      const tokens = snap.docs
        .filter((d) => !isAdminAccountUid(d.id))
        .map((d) => d.data().fcmToken)
        .filter(Boolean);
      await sendToTokens(tokens, { title, body, data: { type: 'leaderboard' } });
      sent += tokens.length;

      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < 300) break;
    }
    console.log(`[sundayUrgency] sent to ${sent} users, pool=�?{total}`);
  }
);

async function notifyWeeklyWinners(winners, weekId) {
  const winnerUidSet = new Set(winners.map((w) => w.uid));

  for (const w of winners) {
    await sendToUser(w.uid, {
      title: '🏆 You won!',
      body:  `You finished #${w.rank} and won �?{w.prize.toLocaleString()}. Claim in the app.`,
      data:  { type: 'winner_claim', weekId },
    });
  }

  if (winners.length === 0) return;
  const top = winners[0];
  const genericTitle = '🏆 This week\'s winner!';
  const genericBody  =
    `${top.username} from ${top.university || 'their university'} won ` +
    `�?{top.prize.toLocaleString()}! Can you beat them?`;

  let lastDoc = null;
  const BATCH_SIZE = 300;
  while (true) {
    let q = db.collection('users').orderBy('__name__').limit(BATCH_SIZE);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;

    const tokens = snap.docs
      .filter((d) => !winnerUidSet.has(d.id) && !isAdminAccountUid(d.id))
      .map((d) => d.data().fcmToken)
      .filter(Boolean);
    await sendToTokens(tokens, { title: genericTitle, body: genericBody, data: { type: 'leaderboard' } });

    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.docs.length < BATCH_SIZE) break;
  }
  console.log(`[notifyWeeklyWinners] notified ${winners.length} winners + broadcast to everyone else`);
}

async function _broadcastQMWindow(windowName, title, body) {
  let lastDoc = null;
  let sent = 0;
  while (true) {
    let q = db.collection('users')
      .where('fcmToken', '>', '')
      .orderBy('fcmToken')
      .orderBy('__name__')
      .limit(300);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;

    const tokens = snap.docs
      .filter((d) => !isAdminAccountUid(d.id))
      .map((d) => d.data().fcmToken)
      .filter(Boolean);
    await sendToTokens(tokens, { title, body });
    sent += tokens.length;

    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.docs.length < 300) break;
  }
  console.log(`[qmBroadcast:${windowName}] sent to ${sent} users`);
}

// ── Quick Match 24/7 notifications ──────────────────────────────────────
// No windows to open anymore: one morning broadcast when the daily token
// budget refreshes (06:00 UTC = 07:00 WAT) and one evening nudge for
// unspent tokens (see _remindQMUnspentTokens below).
exports.qmDailyTokensReady = onSchedule(
  { schedule: '0 6 * * *', timeZone: 'UTC', region: 'us-central1' },
  () => _broadcastQMWindow(
    'Daily Tokens', 'Quick Match tokens refreshed!',
    'You have 5 free battles today (8 with Premium). Play anytime.'
  )
);

// Evening nudge (20:00 UTC = 21:00 WAT): players holding unspent tokens
// from TODAY's daily budget get one reminder before the midnight reset.
// The qmWindowId field carries the WAT-day id, so matching it to today's
// day id selects exactly today's unspent budgets.
async function _remindQMUnspentTokens(title) {
  const todayId = getQMDayId(new Date());
  let lastDoc = null;
  let sent = 0;
  while (true) {
    let q = db.collection('users')
      .where('qmWindowId', '==', todayId)
      .where('qmTokens', '>', 0)
      .orderBy('qmTokens')
      .orderBy('__name__')
      .limit(300);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      if (isAdminAccountUid(doc.id)) continue; // ghost admin: no notifications
      const d = doc.data();
      if (!d.fcmToken) continue;
      const tokens = d.qmTokens;
      await sendToUser(doc.id, {
        title,
        body: `You still have ${tokens} Quick Match token${tokens === 1 ? '' : 's'} left �?they reset at midnight!`,
      });
      sent++;
    }

    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.docs.length < 300) break;
  }
  console.log(`[qmUnspentReminder] sent to ${sent} users`);
}

exports.qmUnspentTokenReminder = onSchedule(
  { schedule: '0 20 * * *', timeZone: 'UTC', region: 'us-central1' },
  () => _remindQMUnspentTokens(
    'Quick Match tokens expiring soon'
  )
);
// ─────────────────────────────────────────────────────────────────────────────
// ─── SECTION 18: EARLY ANIME UNLOCK ─────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

// Single source of truth for the early-unlock price (AC). Must match the
// homepage spend surface (lib/features/home/home_page.dart).
const EARLY_UNLOCK_COST = 5000;

exports.unlockAnimeEarly = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }

    const animeTitle = _normalizeTitle(request.data?.animeTitle);
    const catalog = await _loadAnimeCatalog();
    if (!animeTitle || !catalog.includes(animeTitle)) {
      throw new HttpsError('invalid-argument', 'invalid_anime');
    }

    const cost = EARLY_UNLOCK_COST;
    const userRef = db.collection('users').doc(uid);
    let result;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      if (!snap.exists) {
        throw new HttpsError('not-found', 'user_not_found');
      }

      const data = snap.data() || {};
      const unlockedAnimes = Array.isArray(data.unlockedAnimes)
        ? data.unlockedAnimes
        : [];

      if (unlockedAnimes.includes(animeTitle)) {
        result = {
          success: true,
          alreadyUnlocked: true,
          animeTitle,
          newBalance: data.animeCoins || 0,
        };
        return;
      }

      const currentCoins = data.animeCoins || 0;
      if (currentCoins < cost) {
        throw new HttpsError('resource-exhausted', 'insufficient_coins');
      }

      const newBalance = currentCoins - cost;

      tx.update(userRef, {
        animeCoins: FieldValue.increment(-cost),
        unlockedAnimes: FieldValue.arrayUnion(animeTitle),
      });
      tx.delete(userRef.collection('cooldowns').doc(animeTitle));

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type: 'spend_unlock',
        delta: -cost,
        balanceAfter: newBalance,
        timestamp: FieldValue.serverTimestamp(),
      });

      result = {
        success: true,
        alreadyUnlocked: false,
        animeTitle,
        coinsSpent: cost,
        newBalance,
      };
    });

    console.log(`[unlockAnimeEarly] uid=${uid} anime=${animeTitle}`);
    return result;
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── STEP 5b: MARK-AS-SEEN (no-repeat system, write side) ───────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Records native difficulty per question (missing �?'medium'), mirroring
// AnimeQuestion.fromDoc and the fetch-side bucket invariant exactly.
//
// SAFETY CONTRACT (approved decisions a/b/c):
//  (a) Callers MUST invoke as `_markQuestionsSeen(...).catch(log)` WITHOUT
//      await, AFTER the economy transaction commits. The helper ALSO
//      try/catches internally and never rethrows, so neither layer can throw
//      back into the caller �?no unhandled rejection is possible (every
//      .catch handler only calls console.error, so each derived promise
//      resolves). Worst case of any marking failure is a repeated question,
//      never a lost coin/WP award.
//  (b) Marking increments poolState.seenCount only (counted per bucket, so a
//      4-question bucket touch adds 4); totalCount is maintained solely by
//      resetSeenPool, which already computes it.
//  (c) Challenge marking happens once at resolution time in
//      _resolveChallengeCore (both players together). Ghost QMs are marked
//      in submitQuickMatchResult's ghost return (the resolve trigger skips
//      ghost docs, so core never sees them).
async function _markQuestionsSeen(uid, questionIds, questionMap) {
  try {
    if (!uid || !Array.isArray(questionIds) || questionIds.length === 0) {
      return;
    }
    const map = questionMap || {};
    const batch = db.batch();
    const bucketCounts = new Map();
    let sets = 0;
    for (const qid of questionIds) {
      if (typeof qid !== 'string' || qid.length === 0) continue;
      const q = map[qid] || {};
      const a = typeof q.animeTitle === 'string'
        ? q.animeTitle.trim().toLowerCase()
        : '';
      let d = typeof q.difficulty === 'string'
        ? q.difficulty.trim().toLowerCase()
        : 'medium';
      if (d !== 'easy' && d !== 'medium' && d !== 'hard') d = 'medium';
      if (!a) continue;
      batch.set(
        db.collection('users').doc(uid).collection('seenQuestions').doc(qid),
        { animeTitle: a, difficulty: d, seenAt: FieldValue.serverTimestamp() },
        { merge: true }
      );
      const key = `${a}_${d}`;
      bucketCounts.set(key, (bucketCounts.get(key) || 0) + 1);
      sets++;
    }
    if (sets === 0) return;
    for (const [key, n] of bucketCounts) {
      const sep = key.lastIndexOf('_');
      batch.set(
        db.collection('users').doc(uid).collection('questionPoolState').doc(key),
        {
          animeTitle: key.substring(0, sep),
          difficulty: key.substring(sep + 1),
          seenCount: FieldValue.increment(n),
        },
        { merge: true }
      );
    }
    await batch.commit();
    console.log(`[seen] uid=${uid} marked=${sets} buckets=${bucketCounts.size}`);
  } catch (e) {
    // NEVER rethrow: marking must not fail awards (see contract above).
    console.error(`[seen] mark failed (non-fatal) uid=${uid}: ${e.message}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ─── STEP 5a: SEEN-POOL RESET (no-repeat system, fetch side) ────────────────
// ─────────────────────────────────────────────────────────────────────────────
// New isolated callable �?no economy, no stakes, no prizes. The client calls
// this ONLY when a bucket's unseen pool runs short (see _resetTierBucketIfShort
// / medium-bucket reset in lib/core/services/firestore_service.dart). It
// batched-deletes that bucket's seen docs and refreshes its poolState
// counters. Mark-as-seen writes (submit flows) are Step 5b and NOT in this
// change �?nothing below touches submitQuizAnswers, submitDailyGauntlet,
// submitQuickMatchResult, or challenge resolution.
exports.resetSeenPool = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Unauthenticated');
    }

    const anime = typeof request.data?.animeTitle === 'string'
      ? request.data.animeTitle.trim().toLowerCase()
      : '';
    const difficulty = typeof request.data?.difficulty === 'string'
      ? request.data.difficulty.trim().toLowerCase()
      : '';
    if (!anime || !['easy', 'medium', 'hard'].includes(difficulty)) {
      throw new HttpsError('invalid-argument', 'invalid_pool_bucket');
    }

    // Batched delete of the bucket's seen docs (500/batch). Equality-only
    // queries �?no composite index required.
    const seenCol =
      db.collection('users').doc(uid).collection('seenQuestions');
    let deleted = 0;
    for (;;) {
      const snap = await seenCol
        .where('animeTitle', '==', anime)
        .where('difficulty', '==', difficulty)
        .limit(500)
        .get();
      if (snap.empty) break;
      const batch = db.batch();
      snap.docs.forEach((d) => batch.delete(d.ref));
      await batch.commit();
      deleted += snap.size;
      if (snap.size < 500) break;
    }

    // Refresh poolState counters. Medium buckets own the legacy untagged
    // docs too (fetch side consults <anime>::medium for every legacy draw),
    // so their total includes the legacy count.
    const qCol = db.collection('questions');
    const taggedCountSnap = await qCol
      .where('animeTitle', '==', anime)
      .where('difficulty', '==', difficulty)
      .count()
      .get();
    let legacyCount = 0;
    if (difficulty === 'medium') {
      const legSnap = await qCol
        .where('animeTitle', '==', anime)
        .get();
      legacyCount = legSnap.docs.filter((d) => {
        const data = d.data() || {};
        return !('difficulty' in data) || data.difficulty == null;
      }).length;
    }
    const total = (taggedCountSnap.data().count || 0) + legacyCount;

    await db
      .collection('users')
      .doc(uid)
      .collection('questionPoolState')
      .doc(`${anime}_${difficulty}`)
      .set({
        animeTitle: anime,
        difficulty,
        seenCount: 0,
        totalCount: total,
        exhaustedAt: FieldValue.serverTimestamp(),
      }, { merge: true });

    console.log(
      `[resetSeenPool] uid=${uid} bucket=${anime}/${difficulty} ` +
      `deleted=${deleted} total=${total}`
    );
    return { success: true, deleted, totalCount: total };
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// ─── Contact / bug reports / suggestions ─────────────────────────────────────
// One callable for every "talk to us" message. Writes are server-only: the
// feedback collection is unreadable and unwritable from clients (see
// firestore.rules), so a patched client cannot backfill, re-label or delete
// reports. Deliberately NOT build-gated: an outdated install is exactly the
// client most likely to be reporting that it is stuck.
const FEEDBACK_CATEGORIES = ['bug', 'suggestion', 'other'];
const FEEDBACK_SUBJECT_MAX = 120;
const FEEDBACK_MESSAGE_MIN = 10;
const FEEDBACK_MESSAGE_MAX = 2000;
const FEEDBACK_DAILY_LIMIT = 10;
const FEEDBACK_COOLDOWN_MS = 30 * 1000;

exports.submitFeedback = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError('unauthenticated', 'Sign in to send feedback.');
    }

    const data = request.data || {};
    const category = typeof data.category === 'string'
      ? data.category.trim().toLowerCase() : '';
    if (!FEEDBACK_CATEGORIES.includes(category)) {
      throw new HttpsError('invalid-argument', 'invalid_category');
    }

    const message = typeof data.message === 'string' ? data.message.trim() : '';
    if (message.length < FEEDBACK_MESSAGE_MIN) {
      throw new HttpsError(
        'invalid-argument',
        `message_too_short:${FEEDBACK_MESSAGE_MIN}`,
      );
    }
    if (message.length > FEEDBACK_MESSAGE_MAX) {
      throw new HttpsError(
        'invalid-argument',
        `message_too_long:${FEEDBACK_MESSAGE_MAX}`,
      );
    }

    // Subject is optional; the category is the fallback label for triage.
    const subjectRaw = typeof data.subject === 'string' ? data.subject.trim() : '';
    const subject = (subjectRaw || category).slice(0, FEEDBACK_SUBJECT_MAX);

    // Diagnostic context, best-effort. Never trusted for anything but triage.
    const platform = typeof data.platform === 'string'
      ? data.platform.slice(0, 16) : 'unknown';
    const appBuild = Number.isInteger(data.appBuild) ? data.appBuild : null;

    let docId = '';
    await db.runTransaction(async (tx) => {
      const userRef = db.collection('users').doc(uid);
      const userSnap = await tx.get(userRef);
      const user = userSnap.exists ? (userSnap.data() || {}) : {};

      // Flood guard: one message per 30s plus a per-WAT-day budget. Enforced
      // in the same transaction as the write so two parallel calls cannot
      // both pass the check.
      const lastAt = user.feedbackLastAt?.toDate?.();
      if (lastAt && Date.now() - lastAt.getTime() < FEEDBACK_COOLDOWN_MS) {
        throw new HttpsError(
          'resource-exhausted',
          'Please wait a moment before sending another message.',
        );
      }
      const today = _watDateString();
      const sentToday = user.feedbackDate === today
        ? Number(user.feedbackSentToday || 0) : 0;
      if (sentToday >= FEEDBACK_DAILY_LIMIT) {
        throw new HttpsError(
          'resource-exhausted',
          'You have reached today\'s feedback limit. Try again tomorrow.',
        );
      }

      const ref = db.collection('feedback').doc();
      docId = ref.id;
      tx.set(ref, {
        uid,
        username: user.username || 'Anonymous',
        email: user.email || request.auth?.token?.email || '',
        category,
        subject,
        message,
        platform,
        appBuild,
        status: 'new',
        createdAt: FieldValue.serverTimestamp(),
      });
      tx.set(userRef, {
        feedbackLastAt: FieldValue.serverTimestamp(),
        feedbackDate: today,
        feedbackSentToday: sentToday + 1,
      }, { merge: true });
    });

    console.log(`[submitFeedback] uid=${uid} category=${category} id=${docId}`);
    return { success: true, id: docId };
  }
);

// ─── SECTION: AUTH USER CLEANUP (orphan prevention) ─────────────────────────
// Fires AFTER a Firebase Auth user is deleted (console or Admin SDK) and
// recursively wipes users/{uid} + every subcollection (matches, coin/wp
// transactions, receipts, payoutDetails, ...) so deleted accounts can never
// linger on leaderboards or any other client-visible surface.
//
// Deleting an Auth user does NOT cascade to Firestore �?without this,
// every console Auth deletion leaves an orphan doc that the live boards
// keep rendering (observed in production: 7 orphans incl. current-week
// entrants; cleared 2026-09-21 via scripts/purge_users.js).
//
// DELIBERATELY UNTOUCHED (audit/financial trail):
//   leaderboardCycles ranked[] snapshots, leaderboardCycles/*/pendingClaim,
//   prize_pool. Cycle-scoped payout data is admin-visible only and must
//   survive account deletion.
// PAYOUT STATE UNTOUCHED: this trigger never writes paid state.
//
// v2 identity onUserDeleted (Eventarc, global trigger): the v2 SDK exposes
// no other Auth onDelete, and the v1 builder chain no longer exists in
// firebase-functions v7 �?so no region opt is passed (auth triggers are
// global by nature). Idempotent and retry-safe: re-wiping an already-wiped
// tree is a no-op.
const { onUserDeleted } = require('firebase-functions/v2/identity');

exports.cleanupDeletedUser = onUserDeleted(async (event) => {
  const uid = event.data?.uid;
  if (!uid) {
    console.warn('[cleanupDeletedUser] event without uid �?ignored');
    return;
  }

  const ref = db.collection('users').doc(uid);
  try {
    await db.recursiveDelete(ref);
    console.log(`[cleanupDeletedUser] wiped users/${uid} tree`);
    // Root-level feedback bears the uid/email too. deleteAccount already
    // wipes it on the self-service path; this covers console/Admin deletions.
    try {
      const removed = await _deleteQueryInBatches(
        db.collection('feedback').where('uid', '==', uid), 'feedback');
      if (removed > 0) {
        console.log(`[cleanupDeletedUser] deleted ${removed} feedback docs for ${uid}`);
      }
    } catch (err) {
      console.warn(`[cleanupDeletedUser] feedback cleanup failed uid=${uid}: ${err.message}`);
    }
    // Server-minted runs are root-level, so recursiveDelete on the user tree
    // does not reach them.
    try {
      const runs = await _deleteQueryInBatches(
        db.collection(QUIZ_RUNS).where('uid', '==', uid), 'quizRuns');
      if (runs > 0) {
        console.log(`[cleanupDeletedUser] deleted ${runs} quiz run(s) for ${uid}`);
      }
    } catch (err) {
      console.warn(`[cleanupDeletedUser] quizRuns cleanup failed uid=${uid}: ${err.message}`);
    }
  } catch (err) {
    // Surfaced in Cloud logs; manual fallback is scripts/purge_users.js
    // (dry-run default). Rethrown so the failure is visible as a function
    // error rather than a silent orphan.
    console.error(`[cleanupDeletedUser] FAILED users/${uid}: ${err.message}`);
    throw err;
  }
});
// ������ Test seam (no production effect) ������������������������������������������������������������������������������
// Exposes internals to functions/test/ when NODE_ENV=test. Never used at runtime.
// ─── Email verification: resend + sync (B1) ────────────────────────────────
// Firebase Auth has no server-side send API, so the client performs the actual
// sendEmailVerification() AFTER this callable approves the attempt. The
// callable owns the 60s/5-per-day budget; the Identity Platform beforeEmailSent
// blocking function (when enabled) is the server-side backstop.

async function _reserveVerificationEmail(uid) {
  const ref = db.collection('emailResend').doc(uid);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const d = snap.data() || {};
    const last = Number(d.lastSentAtMs) || 0;
    const dayStart = Number(d.dayStartMs) || 0;
    const dayCount = (!dayStart || now - dayStart >= CFG.DAY_MS)
      ? 0
      : (Number(d.dayCount) || 0);

    const waitSeconds = last > 0
      ? Math.ceil((last + CFG.EMAIL_RESEND_MIN_INTERVAL_SECONDS * 1000 - now) / 1000)
      : 0;
    if (waitSeconds > 0) {
      return {
        ok: false,
        retryAfterSeconds: waitSeconds,
        remainingToday: Math.max(0, CFG.EMAIL_RESEND_MAX_PER_DAY - dayCount),
      };
    }
    if (dayCount >= CFG.EMAIL_RESEND_MAX_PER_DAY) {
      return {
        ok: false,
        retryAfterSeconds: Math.max(
          1,
          Math.ceil((dayStart + CFG.DAY_MS - now) / 1000)
        ),
        remainingToday: 0,
      };
    }
    tx.set(ref, {
      lastSentAtMs: now,
      dayStartMs: dayStart && now - dayStart < CFG.DAY_MS ? dayStart : now,
      dayCount: dayCount + 1,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return {
      ok: true,
      retryAfterSeconds: 0,
      remainingToday: CFG.EMAIL_RESEND_MAX_PER_DAY - dayCount - 1,
    };
  });
}

exports.requestEmailVerification = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const email = _normalizeEmail(request.auth.token?.email || '');
    if (!email) {
      throw new HttpsError('failed-precondition', 'no_email_on_account');
    }
    if (_isEmailVerificationBypassed(email)) {
      return { ok: false, alreadyVerified: true, retryAfterSeconds: 0, remainingToday: 0 };
    }
    if (_isDisposableEmail(email)) {
      throw new HttpsError(
        'failed-precondition',
        'Use a permanent email address.',
        { reason: 'disposable_email' }
      );
    }
    if (await _emailVerifiedForUid(uid)) {
      return { ok: false, alreadyVerified: true, retryAfterSeconds: 0, remainingToday: 0 };
    }

    const reservation = await _reserveVerificationEmail(uid);
    if (!reservation.ok) {
      await _logAbuse({
        uid,
        ip: _clientIp(request),
        reason: 'email_resend_rate_limited',
        fnName: 'requestEmailVerification',
      });
    }
    return reservation;
  }
);

exports.syncEmailVerification = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    let user = null;
    try {
      user = await getAuth().getUser(uid);
    } catch (err) {
      console.warn(`[syncEmailVerification] getUser failed: ${err.message}`);
    }
    if (!user?.emailVerified) {
      return { emailVerified: false, emailNormalized: null, mustRefreshToken: false };
    }

    const normalized = _normalizeEmail(user.email || '');
    const emailHash = normalized ? _emailHash(normalized) : null;

    const userRef = db.collection('users').doc(uid);
    const prevHash = (await userRef.get()).data()?.emailHash || null;

    if (emailHash) {
      const claimRef = db.collection('emailIdentities').doc(emailHash);
      const claimSnap = await claimRef.get();
      if (claimSnap.exists && claimSnap.data()?.uid !== uid) {
        throw new HttpsError(
          'already-exists',
          'An account with this email already exists.',
          { reason: 'email_already_registered' }
        );
      }
      if (!claimSnap.exists) {
        await claimRef.set({
          uid,
          emailNormalized: normalized,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
    }

    // An email change (prepareEmailChange → verifyBeforeUpdateEmail) moves the
    // uniqueness claim. The old claim is released only when it still belongs to
    // this account, so the previous address can be used for a new signup.
    if (prevHash && emailHash && prevHash !== emailHash) {
      const oldRef = db.collection('emailIdentities').doc(prevHash);
      const oldSnap = await oldRef.get();
      if (oldSnap.exists && oldSnap.data()?.uid === uid) await oldRef.delete();
    }

    await userRef.set({
      emailVerified: true,
      emailVerifiedAt: FieldValue.serverTimestamp(),
      ...(user.email ? { email: user.email } : {}),
      ...(normalized ? { emailNormalized: normalized } : {}),
      ...(emailHash ? { emailHash } : {}),
    }, { merge: true });

    return {
      emailVerified: true,
      emailNormalized: normalized,
      mustRefreshToken: true,
    };
  }
);

// Gate for "change email" on the verification screen. Only an unverified
// account can change its address there. The new address is checked here
// (format, disposable list, uniqueness claim) and counted against the same
// resend budget; the client then calls verifyBeforeUpdateEmail, which is the
// only thing that actually changes the Auth email.
exports.prepareEmailChange = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const user = await getAuth().getUser(uid);
    if (user.emailVerified) {
      throw new HttpsError('failed-precondition', 'This account is already verified.');
    }

    const next = _normalizeEmail(request.data?.newEmail || '');
    if (!next) {
      throw new HttpsError('invalid-argument', 'Enter a valid email address.');
    }
    if (next === _normalizeEmail(user.email || '')) {
      throw new HttpsError('failed-precondition', 'That is already your email address.');
    }
    if (_isDisposableEmail(next)) {
      throw new HttpsError(
        'failed-precondition',
        'Use a permanent email address.',
        { reason: 'disposable_email' }
      );
    }
    const claim = await db.collection('emailIdentities').doc(_emailHash(next)).get();
    if (claim.exists && claim.data()?.uid !== uid) {
      throw new HttpsError(
        'already-exists',
        'An account with this email already exists.',
        { reason: 'email_already_registered' }
      );
    }

    const reservation = await _reserveVerificationEmail(uid);
    if (!reservation.ok) {
      await _logAbuse({
        uid,
        ip: _clientIp(request),
        reason: 'email_resend_rate_limited',
        fnName: 'prepareEmailChange',
      });
    }
    return reservation;
  }
);

// ─── Sign-in / password-reset failure limits (advisory layer) ──────────────
// Firebase Auth fires no hook on a WRONG password, so the counter is reported
// by the client. The lock is enforced server-side by beforeUserSignedIn when
// Identity Platform is enabled; this callable pair is the fallback and the
// source of retryAfterSeconds for the UI.

async function _bumpAuthFailure(key) {
  const ref = db.collection('authFailures').doc(key);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const d = snap.data() || {};
    const count = (Number(d.count) || 0) + 1;
    const lockedUntilMs = count >= CFG.AUTH_FAILURE_MAX
      ? now + CFG.AUTH_LOCK_MINUTES * 60 * 1000
      : 0;
    tx.set(ref, {
      count,
      lockedUntilMs,
      updatedAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(now + 2 * CFG.DAY_MS),
    }, { merge: true });
    return { count, lockedUntilMs };
  });
}

exports.checkAuthAttempt = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const normalized = _normalizeEmail(request.data?.email || '');
    const ip = _clientIp(request);
    if (!normalized) {
      return { allowed: true, retryAfterSeconds: 0, remainingAttempts: CFG.AUTH_FAILURE_MAX };
    }
    const keys = [`email:${_emailHash(normalized)}`];
    if (_ipHash(ip)) keys.push(`ip:${_ipHash(ip)}`);

    const snaps = await Promise.all(keys.map((k) => db.collection('authFailures').doc(k).get()));
    let lockedUntil = 0;
    let maxCount = 0;
    snaps.forEach((snap) => {
      const d = snap.data() || {};
      lockedUntil = Math.max(lockedUntil, Number(d.lockedUntilMs) || 0);
      maxCount = Math.max(maxCount, Number(d.count) || 0);
    });

    const remainingMs = lockedUntil - Date.now();
    return {
      allowed: remainingMs <= 0,
      retryAfterSeconds: remainingMs > 0 ? Math.ceil(remainingMs / 1000) : 0,
      remainingAttempts: Math.max(0, CFG.AUTH_FAILURE_MAX - maxCount),
    };
  }
);

exports.reportAuthFailure = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const normalized = _normalizeEmail(request.data?.email || '');
    const kind = request.data?.kind === 'password_reset' ? 'password_reset' : 'signin';
    const ip = _clientIp(request);
    const ipHash = _ipHash(ip);

    let lockedUntilMs = 0;
    let count = 0;
    if (normalized) {
      const res = await _bumpAuthFailure(`email:${_emailHash(normalized)}`);
      count = res.count;
      lockedUntilMs = Math.max(lockedUntilMs, res.lockedUntilMs);
    }
    if (ipHash) {
      const res = await _bumpAuthFailure(`ip:${ipHash}`);
      count = Math.max(count, res.count);
      lockedUntilMs = Math.max(lockedUntilMs, res.lockedUntilMs);
    }
    if (lockedUntilMs > Date.now()) {
      await _logAbuse({
        uid: request.auth?.uid || null,
        ip,
        reason: 'auth_failure_lockout',
        fnName: kind,
        meta: { count },
      });
    }
    return {
      locked: lockedUntilMs > Date.now(),
      retryAfterSeconds: lockedUntilMs > Date.now()
        ? Math.ceil((lockedUntilMs - Date.now()) / 1000)
        : 0,
    };
  }
);

exports.reportAuthSuccess = onSecureCall(
  { region: 'us-central1' },
  async (request) => {
    const normalized = _normalizeEmail(request.data?.email || '');
    if (normalized) {
      await db.collection('authFailures').doc(`email:${_emailHash(normalized)}`)
        .set({
          count: 0,
          lockedUntilMs: 0,
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
    }
    return { success: true };
  }
);

// ─── Unverified-account cleanup (B5) ───────────────────────────────────────
// Hard 7-day deletion with a creation-epoch guard so accounts that existed
// before the email-verification build are never touched. Batched: Auth
// deleteUsers in 500s, Firestore cleanup per account.
async function _purgeAccountAuxDocs(uid, emailNormalized, deviceHash) {
  if (emailNormalized) {
    await db.collection('emailIdentities').doc(_emailHash(emailNormalized))
      .delete().catch(() => {});
  }
  if (deviceHash) {
    try {
      const ref = db.collection('telemetry').doc('devices')
        .collection('accounts').doc(deviceHash);
      const snap = await ref.get();
      if (snap.exists) {
        const uids = (snap.data()?.uids || []).filter((u) => u !== uid);
        await ref.set({ uids, count: uids.length }, { merge: true });
      }
    } catch (err) {
      console.warn(`[cleanupUnverified] device index failed uid=${uid}: ${err.message}`);
    }
  }
  await _deleteQueryInBatches(
    db.collection('usernames').where('uid', '==', uid), 'usernames'
  ).catch(() => 0);
  await db.recursiveDelete(db.collection('users').doc(uid)).catch(() => {});
}

exports.cleanupUnverifiedAccounts = onSchedule(
  { schedule: 'every day 03:20', timeZone: 'UTC', region: 'us-central1' },
  async () => {
    const cfg = await _readServerConfig('security');
    if (cfg.unverifiedCleanupEnabled === false) {
      console.log('[cleanupUnverifiedAccounts] disabled by server_config/security');
      return;
    }

    const cutoff = Date.now() - CFG.UNVERIFIED_ACCOUNT_TTL_DAYS * CFG.DAY_MS;
    let pageToken;
    let deleted = 0;
    let scanned = 0;

    do {
      const page = await getAuth().listUsers(1000, pageToken);
      const victims = [];
      for (const user of page.users) {
        scanned += 1;
        if (user.emailVerified) continue;
        if (_isEmailVerificationBypassed(user.email || '')) continue;
        const createdMs = _msOf(user.metadata?.creationTime);
        if (!createdMs) continue;
        if (createdMs < _unverifiedCleanupEpochMs) continue;
        if (createdMs >= cutoff) continue;
        victims.push(user);
      }

      for (let i = 0; i < victims.length; i += 500) {
        const chunk = victims.slice(i, i + 500);
        const result = await getAuth().deleteUsers(chunk.map((u) => u.uid));
        if (result && result.failureCount > 0) {
          console.warn(
            `[cleanupUnverifiedAccounts] ${result.failureCount} Auth deletions failed`
          );
        }
        for (const user of chunk) {
          const normalized = _normalizeEmail(user.email || '');
          let deviceHash = null;
          try {
            const snap = await db.collection('users').doc(user.uid).get();
            deviceHash = snap.data()?.deviceHash || null;
          } catch (_) { /* best effort */ }
          await _purgeAccountAuxDocs(user.uid, normalized, deviceHash);
          deleted += 1;
        }
      }
      pageToken = page.pageToken;
    } while (pageToken);

    console.log(
      `[cleanupUnverifiedAccounts] scanned=${scanned} deleted=${deleted} ` +
      `ttlDays=${CFG.UNVERIFIED_ACCOUNT_TTL_DAYS}`
    );
  }
);

// Firestore TTL policies are the primary reclaim mechanism; this sweeper is
// the fallback for projects where the TTL policy has not been created yet.
exports.cleanupAbuseState = onSchedule(
  { schedule: 'every 60 minutes', region: 'us-central1' },
  async () => {
    const now = Timestamp.now();
    const collections = ['abuse_log', 'rate_limits', 'authFailures', 'challengePairs'];
    let removed = 0;
    for (const name of collections) {
      for (let i = 0; i < 20; i += 1) {
        const snap = await db.collection(name)
          .where('expiresAt', '<', now)
          .limit(400)
          .get();
        if (snap.empty) break;
        const batch = db.batch();
        snap.docs.forEach((doc) => batch.delete(doc.ref));
        await batch.commit();
        removed += snap.docs.length;
        if (snap.docs.length < 400) break;
      }
    }
    console.log(`[cleanupAbuseState] removed=${removed}`);
  }
);

// ─── House top-3 engine (admin-owned premium grinders) ────────────────────
// Three permanent UIDs in house_config/global.accounts. Normal player docs:
// premiumActive=true, paid entry set by houseEnsureEntry, never ADMIN_UIDS,
// never leaderboardExcluded. All WP flows through _applyDailyWPSoftCap so
// wpEarnedToday/wpTransactions/soft-cap math matches real submits.
const HOUSE_DEFAULTS = {
  enabled: true, neverLose: true, maxDailyRaw: 350, reserve: 180,
  gap1: 95, gap2: 75, gap3: 70, paused: [],
  mode: 'steady',
};
const HOUSE_WAT_WINDOWS = [[8, 10], [13, 15], [19, 22]];
const HOUSE_NAME_POOL = [
  'QuizKing_NG', 'NaijaBrain', 'LagosLegend', 'ChidiPlays', 'AdaezeWins',
  'TundeTakesAll', 'NgoziKnows', 'EmekaExact', 'FunmiFast', 'SeunSharp',
  'KemiKorrect', 'IbrahimIQ', 'AishaAce', 'OluchiOracle', 'DapoD Drill',
  'ZainabZap', 'ChuksChamp', 'BisiBrainbox', 'YemiYonder', 'NadiaNails',
  'SeyiSmart', 'TobiTriumph', 'HalimaHot', 'ObiOracle', 'LolaLogic',
  'FemiFire', 'GraceGenius', 'HausaHustle', 'IgboIntel', 'YorubaYoda',
  'WATWarrior', 'MidnightMaven', 'SoloSniper', 'BlitzBoss', 'DuelDuke',
  'SparSage', 'AnimeAceNG', 'OtakuOdogwu', 'SenpaiSeyi', 'KawaiiKemi',
  'ShonenShark', 'GeninGuru', 'HokageHabi', 'TitanTunde', 'PiratePraise',
];
async function _houseGlobal() {
  const snap = await db.collection('house_config').doc('global').get();
  const d = snap.exists ? snap.data() : {};
  return {
    ...HOUSE_DEFAULTS, ...(d || {}),
    accounts: Array.isArray(d?.accounts) ? d.accounts.slice(0, 3) : [],
    personas: d?.personas || {},
  };
}
function _watHour(now = new Date()) {
  return new Date(now.getTime() + 60 * 60 * 1000).getUTCHours();
}
function _inHouseWindow(now = new Date()) {
  const h = _watHour(now) + new Date(now.getTime() + 60 * 60 * 1000).getUTCMinutes() / 60;
  return HOUSE_WAT_WINDOWS.some(([a, b]) => h >= a && h <= b + 0.5);
}
function _houseJitter(n) { return randomInt(n + 1); }
async function _houseAward(uid, wpRaw, acDelta, source) {
  const ref = db.collection('users').doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return;
    const d = snap.data() || {};
    const todayWAT = _watDateString(new Date());
    const earnedToday = _resolveDailyWPEarned(d, todayWAT);
    const { award, newEarnedToday } = _applyDailyWPSoftCap(wpRaw, earnedToday);
    tx.set(ref, {
      weeklyPoints: (Number(d.weeklyPoints) || 0) + award,
      totalScore: (Number(d.totalScore) || 0) + award,
      wpEarnedToday: newEarnedToday, wpEarnedDate: todayWAT,
      animeCoins: Math.max(0, (Number(d.animeCoins) || 0) + (acDelta || 0)),
      premiumActive: true,
      stats: {
        ...(d.stats || {}),
        gamesPlayed: (Number(d.stats?.gamesPlayed) || 0) + 1,
        gamesWon: (Number(d.stats?.gamesWon) || 0) + (award >= 40 ? 1 : 0),
      },
    }, { merge: true });
    const wtx = db.collection('users').doc(uid).collection('wpTransactions').doc();
    tx.set(wtx, { amount: award, raw: wpRaw, source, at: FieldValue.serverTimestamp(), watDay: todayWAT });
    if (acDelta) {
      const ctx = db.collection('users').doc(uid).collection('coinTransactions').doc();
      tx.set(ctx, { delta: acDelta, source, at: FieldValue.serverTimestamp() });
    }
  });
}
async function _houseBoard(weekId) {
  const snap = await db.collection('users')
    .where('leaderboardEntryWeekId', '==', weekId)
    .orderBy('weeklyPoints', 'desc').limit(30).get();
  return snap.docs.map((d) => ({ uid: d.id, ...(d.data() || {}) }));
}
exports.houseAdmin = onSecureCall({ region: 'us-central1' }, async (request) => {
  if (!request.auth?.uid || !ADMIN_UIDS.includes(request.auth.uid)) throw new HttpsError('permission-denied', 'Forbidden');
  const op = String(request.data?.op || 'get');
  const gref = db.collection('house_config').doc('global');
  const glob = await _houseGlobal();
  if (op === 'get') {
    const weekId = currentWeekId();
    const board = await _houseBoard(weekId);
    const houses = board.filter((r) => glob.accounts.includes(r.uid));
    const reals = board.filter((r) => !glob.accounts.includes(r.uid) && !isAdminAccountUid(r.uid));
    return { success: true, global: { ...glob }, weekId, houses, topReal: reals.slice(0, 5) };
  }
  if (op === 'save') {
    try {
      const patch = {};
      for (const k of ['enabled', 'neverLose', 'maxDailyRaw', 'reserve', 'gap1', 'gap2', 'gap3']) {
        const v = request.data?.[k];
        if (v !== undefined) patch[k] = v;
      }
      if (Array.isArray(request.data?.accounts)) patch.accounts = request.data.accounts.map(String).slice(0, 3);
      if (Array.isArray(request.data?.paused)) patch.paused = request.data.paused.map(String);
      if (request.data?.personas !== undefined && typeof request.data.personas === 'object') patch.personas = request.data.personas;
      patch.updatedAt = FieldValue.serverTimestamp(); patch.updatedBy = request.auth.uid;
      console.log(`[houseAdmin] save by ${request.auth.uid} keys=${Object.keys(patch).join(',')}`);
      await gref.set(patch, { merge: true });
      return { success: true };
    } catch (err) {
      console.error(`[houseAdmin] save FAILED by ${request.auth?.uid}:`, err);
      throw new HttpsError('internal', `save_failed:${err.message || err}`);
    }
  }
  if (op === 'nudge') {
    const uid = String(request.data?.uid || '');
    const wp = Math.max(10, Math.min(250, Number(request.data?.wp) || 50));
    if (!glob.accounts.includes(uid)) throw new HttpsError('invalid-argument', 'Not a house account');
    await _houseAward(uid, wp, 0, 'house_nudge');
    return { success: true, uid, wp };
  }
  if (op === 'rotate') {
    const uid = String(request.data?.uid || request.data?.rotateUid || '');
    const targets = uid ? [uid] : glob.accounts;
    const usedSnap = await db.collection('usernames').get().catch(() => null);
    const used = new Set((usedSnap?.docs || []).map((d) => d.id.toLowerCase()));
    for (const hid of targets) {
      const pick = HOUSE_NAME_POOL[_houseJitter(HOUSE_NAME_POOL.length - 1)] + _houseJitter(99);
      const key = pick.toLowerCase();
      if (used.has(key)) continue;
      await db.collection('usernames').doc(key).set({ uid: hid, username: pick });
      await db.collection('users').doc(hid).set({ username: pick }, { merge: true });
    }
    return { success: true };
  }
  throw new HttpsError('invalid-argument', 'Unknown op');
});
async function _houseTickCore(now = new Date(), isSnipe = false) {
  const glob = await _houseGlobal();
  if (!glob.enabled || glob.accounts.length === 0) return { skipped: 'disabled' };
  const weekId = currentWeekId();
  if (!isSnipe && !_inHouseWindow(now)) return { skipped: 'window' };
  const board = await _houseBoard(weekId);
  const byUid = new Map(board.map((r) => [r.uid, r]));
  const reals = board.filter((r) => !glob.accounts.includes(r.uid) && !isAdminAccountUid(r.uid));
  const r4 = reals.length ? (Number(reals[0].weeklyPoints) || 0) : 900;
  const velocity = reals.length > 3 ? Math.max(0, (Number(reals[0].weeklyPoints) || 0) - (Number(reals[3].weeklyPoints) || 0)) / 4 : 60;
  const projected = Math.max(r4 * 1.22 + 80, r4 + velocity * 7 * 1.15, 1700);
  const targets = [
    projected + glob.gap1 + glob.gap2 + _houseJitter(35),
    projected + glob.gap2 + _houseJitter(25),
    projected + _houseJitter(25),
  ];
  const dayIdx = (new Date().getUTCDay() + 6) % 7;
  const curve = [0.18, 0.34, 0.52, 0.68, 0.82, 0.93, 1.0][dayIdx] || 1.0;
  const todayWAT = _watDateString(now);
  for (let i = 0; i < glob.accounts.length; i++) {
    const hid = glob.accounts[i];
    if ((glob.paused || []).includes(hid)) continue;
    // Per-house desync: houses never tick in lockstep.
    if (!isSnipe && _houseJitter(99) < 22) continue;
    const cur = Number(byUid.get(hid)?.weeklyPoints) || 0;
    let want = Math.min(targets[i] * curve, targets[i]);
    // Steady mode: hold the lead all week. Snipe is backup only — if the
    // house already leads by its gap, the snipe tick no-ops via deficit<25.
    if (isSnipe) want = targets[i];
    const deficit = Math.round(want - cur);
    if (deficit < 25) continue;
    const earnSnap = await db.collection('users').doc(hid).get().catch(() => null);
    const earnedToday = _resolveDailyWPEarned(earnSnap?.data() || {}, todayWAT);
    const reserveHold = isSnipe ? 0 : Math.min(120, (glob.reserve || 180) * 0.15);
    const room = Math.max(0, glob.maxDailyRaw - earnedToday - reserveHold);
    if (room < 20 && !isSnipe) continue;
    const chunk = isSnipe
      ? Math.min(deficit, 320, glob.reserve || 180)
      : Math.min(deficit, 120 + _houseJitter(80), room, 220);
    if (chunk < 15) continue;
    const mix = _houseJitter(99);
    const ac = mix < 25 ? 12 : (mix < 50 ? -40 : 8);
    await _houseAward(hid, chunk, ac, isSnipe ? 'house_snipe' : 'house_pace');
    const st = db.collection('house_state').doc(hid);
    await st.set({ targetTotal: Math.round(targets[i]), lastTick: FieldValue.serverTimestamp(), deficit }, { merge: true });
  }
  return { success: true, weekId, r4, targets };
}
exports.houseTick = onSchedule({ schedule: 'every 15 minutes', region: 'us-central1' }, async () => {
  await _houseEnsureEntryCore();
  await _houseTickCore(new Date(), false);
  await _houseDuelCore();
});
exports.houseSnipe = onSchedule({ schedule: 'every 3 minutes', region: 'us-central1' }, async () => {
  const wat = new Date(Date.now() + 60 * 60 * 1000);
  const day = wat.getUTCDay();
  const h = wat.getUTCHours() + wat.getUTCMinutes() / 60;
  if (!(day === 0 && h >= 19.5 && h <= 21.98)) return;
  await _houseTickCore(new Date(), true);
});
async function _houseEnsureEntryCore() {
  const glob = await _houseGlobal();
  if (!glob.accounts.length) return;
  const weekId = currentWeekId();
  for (const hid of glob.accounts) {
    const ref = db.collection('users').doc(hid);
    const snap = await ref.get().catch(() => null);
    if (!snap?.exists) continue;
    if (snap.data()?.leaderboardEntryWeekId === weekId) continue;
    await ref.set({
      leaderboardEntryWeekId: weekId, leaderboardEntryEmail: `house+${hid.slice(0, 6)}@local`,
      premiumActive: true,
    }, { merge: true });
    await db.collection('users').doc(hid).collection('leaderboardReceipts').doc(weekId).set({
      weekId, source: 'house', at: FieldValue.serverTimestamp(),
    }, { merge: true });
  }
}
exports.houseEnsureEntry = onSchedule({ schedule: 'every 60 minutes', region: 'us-central1' }, async () => {
  await _houseEnsureEntryCore();
});
async function _houseDuelCore() {
  const glob = await _houseGlobal();
  if (!glob.enabled || !glob.accounts.length) return;
  const houseSet = new Set(glob.accounts);
  const snap = await db.collection('challenges').where('status', 'in', ['waiting', 'opponent_joined']).limit(30).get().catch(() => null);
  if (!snap || snap.empty) return;
  for (const doc of snap.docs) {
    const c = doc.data() || {};
    const opp = String(c.opponentUid || c.opponent || '');
    const creator = String(c.creatorUid || c.creator || '');
    const hid = houseSet.has(opp) ? opp : (houseSet.has(creator) ? creator : null);
    if (!hid) continue;
    if ((glob.paused || []).includes(hid)) continue;
    const stake = Number(c.wpStake) || 0;
    if (stake > 120 && _houseJitter(99) < 70) continue;
    if (_houseJitter(99) < 18) continue;
  }
}

// ─── Identity Platform blocking functions (opt-in) ─────────────────────────
// Enable with ENABLE_IDENTITY_BLOCKING=true once Identity Platform is on the
// project. Deploying these without it fails, so the default is off and the
// advisory callables above remain the active layer.
if (process.env.ENABLE_IDENTITY_BLOCKING === 'true') {
  const identity = require('firebase-functions/v2/identity');

  exports.beforeEmailSent = identity.beforeEmailSent(async (event) => {
    const normalized = _normalizeEmail(event.data?.email || '');
    if (!normalized) return;
    const hit = await _hitRateLimit(
      `email_send:${_emailHash(normalized)}`,
      CFG.EMAIL_RESEND_MAX_PER_DAY,
      CFG.DAY_MS
    );
    if (!hit.allowed) {
      throw new HttpsError(
        'resource-exhausted',
        'Too many emails requested. Try again later.',
        { retryAfterSeconds: hit.retryAfterSeconds }
      );
    }
  });

  exports.beforeUserSignedIn = identity.beforeUserSignedIn(async (event) => {
    const normalized = _normalizeEmail(event.data?.email || '');
    if (!normalized) return;
    const snap = await db.collection('authFailures')
      .doc(`email:${_emailHash(normalized)}`).get();
    const lockedUntilMs = Number(snap.data()?.lockedUntilMs) || 0;
    if (lockedUntilMs > Date.now()) {
      throw new HttpsError(
        'permission-denied',
        'Too many failed attempts. Try again later.',
        { retryAfterSeconds: Math.ceil((lockedUntilMs - Date.now()) / 1000) }
      );
    }
  });
}

if (process.env.NODE_ENV === 'test') {
  module.exports._resolveChallengeCore = _resolveChallengeCore;
  module.exports._testHelpers = {
    _applyDailyWPSoftCap,
    _resolveDailyWPEarned,
    currentWeekId,
    _watDateString,
    // Email/abuse seams.
    _CFG: CFG,
    _normalizeEmail,
    _emailHash,
    _deviceHash,
    _isDisposableEmail,
    _assertEmailVerified,
    _hitRateLimit,
    _setUnverifiedCleanupEpoch: (ms) => {
      _unverifiedCleanupEpochMs = Number(ms) || 0;
    },
    // The Android gate config is cached for 60s. Tests that flip
    // app_config/android.minBuild need an immediate re-read.
    _resetAndroidConfigCache: () => {
      _androidConfigCache = { at: 0, value: null };
    },
    // Script parity: scripts/seed_server_config.js must write exactly these
    // defaults so it cannot drift from the functions' fallback values.
    FRAUD_DEFAULTS,
    SOLO_DECAY_THRESHOLD_DEFAULT,
    // P1 anti-cheat seams.
    _readEnforcement,
    _recordAntiCheatSignal,
    _applyDecay,
    _getPlayIntegrityConfig,
    _verifyPlayIntegrity,
    _recordPayoutAccount,
    _payoutAccountHash,
    _resetIntegrityLogCache: () => _integrityMissLogged.clear(),
  };
}
