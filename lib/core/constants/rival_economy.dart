// lib/core/constants/rival_economy.dart
//
// Single Dart source for every number the Payout Rules table shows.
// Each value mirrors a constant in functions/index.js (see the comment on
// each line). Change both together — the client values are display-only;
// the Cloud Function transaction is authoritative.

/// First-to-N wins a best-of series. Server: SERIES_WINS_REQUIRED.
const int kSeriesWinsRequired = 3;

/// +100 AC to the series winner. Server: SERIES_AC_PRIZE.
const int kSeriesAcPrize = 100;

/// Series prize anti-farm window. Server: SERIES_PRIZE_COOLDOWN_MS (7 days).
const Duration kSeriesPrizeCooldown = Duration(days: 7);

/// Stale series expiry. Server: RIVALRY_EXPIRY_MS (14 days).
const Duration kRivalryExpiry = Duration(days: 14);

/// Upset bounty gap + bonus. Server: BOUNTY_WP_GAP / BOUNTY_WP_BONUS.
const int kBountyWpGap = 200;
const int kBountyWpBonus = 25;

/// Flat WP participation. Server: CHALLENGE_WIN_WP / CHALLENGE_DRAW_WP.
const int kDuelFlatWinWp = 50;
const int kDuelFlatDrawWp = 25;

/// Spar flat reward. Server: SPAR_WP_WIN.
const int kSparWinWp = 5;

/// Spar daily budget. Server: SPAR_DAILY_FREE / SPAR_DAILY_PREMIUM.
const int kSparDailyFree = 10;
const int kSparDailyPremium = 15;

/// Ghost (Quick Match) flat rewards. Server: QM_* constants.
const int kGhostAcWin = 35;
const int kGhostAcDraw = 15;
const int kGhostAcLose = 0;
const int kGhostWpWin = 35;
const int kGhostWpDraw = 15;
const int kGhostWpLose = 5;

/// Premium WP multiplier. Server: 1.20 floor() in _resolveChallengeCore.
const double kPremiumWpMultiplier = 1.20;

/// Daily WP soft cap: full below, 20% (min 1) at/above. Server: WP_DAILY_SOFT_CAP.
const int kWpDailySoftCap = 300;

/// Weekly hard cap applied at reset. Server: WP_WEEKLY_CAP.
const int kWpWeeklyCap = 10000;

/// Same-rival rematch cooldown. Server: WP_COOLDOWN_FREE/PREMIUM_HOURS.
/// Skipped inside an active series with games played.
const int kRivalCooldownFreeHours = 12;
const int kRivalCooldownPremiumHours = 6;

/// WP stake shape. Server: WP_MIN_STAKE / WP_STEP / WP_MAX_STAKE_*.
const int kWpMinStake = 5;
const int kWpStakeStep = 5;
const int kWpMaxStakeFree = 200;
const int kWpMaxStakePremium = 400;

/// Per-day WP staking cap (total WP a player may stake in one WAT day).
/// Server: WP_DAILY_CAP_FREE / WP_DAILY_CAP_PREMIUM.
const int kWpDailyCapFree = 300;
const int kWpDailyCapPremium = 500;

/// AC stake shape. Server: AC_MIN_STAKE / AC_STAKE_STEP / AC_MAX_STAKE_*.
const int kAcMinStake = 20;
const int kAcStakeStep = 10;
const int kAcMaxStakeFree = 2000;
const int kAcMaxStakePremium = 5000;

/// Concurrent active-challenge cap. Server: ACTIVE_CHALLENGES_FREE / PREMIUM.
const int kActiveChallengesFree = 3;
const int kActiveChallengesPremium = 5;

/// Walkaway fee for quitting a live duel (challenge or Quick Match) before
/// your score is recorded. Server: QUIT_FEE_AC. Deducted in cancelRun on top
/// of forfeiting the match, floored at zero so a broke player can still
/// clear a stuck run. Without it, quitting to preview the fixed question set
/// and replaying it was profitable.
const int kChallengeQuitFeeAc = 100;

/// Daily staked-duel create / join budget. Server: DAILY_CHALLENGE_CREATE_* /
/// DAILY_CHALLENGE_JOIN_*. Keep the client copy in step with the server so a
/// player is never blocked (or promised a slot) at the wrong number.
const int kDailyCreateFree = 5;
const int kDailyCreatePremium = 8;
const int kDailyJoinFree = 5;
const int kDailyJoinPremium = 8;

/// Quick Match daily tokens. Server: QM_DAILY_TOKENS_FREE / PREMIUM.
const int kQmDailyFree = 5;
const int kQmDailyPremium = 8;
