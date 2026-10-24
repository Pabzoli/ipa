// ── Solo (homepage) difficulty economy ─────────────────────────────────────
// Mirrors SOLO_DIFFICULTY_REWARDS in functions/index.js.
// Change both together. Single source of truth for homepage solo rewards.
//
// Mixes are WEIGHTED (not strict): each difficulty leans heavily toward its
// tier but keeps a couple of off-tier questions so runs still feel varied
// and short pools degrade gracefully via the existing legacy/cross-tier
// backfill in FirestoreService._dealSlots.
//
// Rewards scale aggressively on hard: hard questions are brutal enough that
// players will burn AC on Timer Pause (20 AC) / hints (10 AC) mid-run, so a
// strong hard clear must return a clear AC profit plus a WP haul worth the
// spend. Medium is a straight ~1.5x over easy; hard is ~2.7x WP / ~4.4x AC.

/// Valid homepage solo difficulty ids (stored lowercase).
const List<String> kSoloDifficulties = ['easy', 'medium', 'hard'];

/// Question mix per difficulty for a 10-question solo run.
/// Keys: 'easy' | 'medium' | 'hard' → per-tier counts (sum = 10).
const Map<String, Map<String, int>> kSoloDifficultyMixes = {
  'easy': {'easy': 7, 'medium': 2, 'hard': 1},
  'medium': {'easy': 3, 'medium': 4, 'hard': 3},
  'hard': {'easy': 1, 'medium': 2, 'hard': 7},
};

/// Flat per-run rewards per difficulty (before solo decay + daily soft cap).
/// wpFast/wpSlow are per-correct-answer WP split by the existing anti-bot
/// timing rule (fast <1.5s → wpFast, otherwise wpSlow). Kept per difficulty
/// so the timing rule composes with the difficulty multiplier instead of
/// being replaced by it.
class SoloDifficultyReward {
  final int wpFast;
  final int wpSlow;
  final int completionWP;
  final int perfectBonusWP;
  final int acEarned;

  const SoloDifficultyReward({
    required this.wpFast,
    required this.wpSlow,
    required this.completionWP,
    required this.perfectBonusWP,
    required this.acEarned,
  });
}

const Map<String, SoloDifficultyReward> kSoloDifficultyRewards = {
  // Baseline — matches the pre-difficulty solo economy exactly.
  'easy': SoloDifficultyReward(
    wpFast: 8,
    wpSlow: 15,
    completionWP: 20,
    perfectBonusWP: 10,
    acEarned: 8,
  ),
  // ~1.5x over easy (22 = floor(15 * 1.5)).
  'medium': SoloDifficultyReward(
    wpFast: 12,
    wpSlow: 22,
    completionWP: 30,
    perfectBonusWP: 15,
    acEarned: 12,
  ),
  // Generous on purpose: a hard clear should comfortably cover 1–2 Timer
  // Pauses (20 AC each) and still profit. ~2.5x fast / ~2.7x slow WP,
  // ~4.4x AC vs easy. Max raw: 10×40 + 50 + 30 = 480 WP + 35 AC.
  'hard': SoloDifficultyReward(
    wpFast: 20,
    wpSlow: 40,
    completionWP: 50,
    perfectBonusWP: 30,
    acEarned: 35,
  ),
};

/// Normalizes a raw difficulty id to a valid tier, defaulting to easy
/// (the pre-difficulty baseline) for legacy callers / bad input.
String normalizeSoloDifficulty(String? raw) {
  final v = (raw ?? '').trim().toLowerCase();
  if (kSoloDifficulties.contains(v)) return v;
  return 'easy';
}

// ── Homepage spend surfaces ─────────────────────────────────────────────────
// Mirrors the amounts enforced server-side in functions/index.js
// (`spendCoins` type 'spend_cooldown' = 100; EARLY_UNLOCK_COST = 5000).

/// Flat AC cost to skip one anime's cooldown lock (`spend_cooldown`).
const int kCooldownSkipCost = 100;

/// AC cost to permanently unlock one anime early (`unlockAnimeEarly`).
const int kEarlyUnlockCost = 5000;

/// Max raw WP for a perfect all-slow run at [difficulty] (before decay/cap).
/// Used for UI previews only — the server is authoritative.
int soloDifficultyMaxWP(String difficulty) {
  final r = kSoloDifficultyRewards[normalizeSoloDifficulty(difficulty)]!;
  return 10 * r.wpSlow + r.completionWP + r.perfectBonusWP;
}
