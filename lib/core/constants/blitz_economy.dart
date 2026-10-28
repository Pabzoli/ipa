// ── Gauntlet Blitz (90s time-attack) economy ─────────────────────────────────
// Mirrors BLITZ_* / GAUNTLET_RETRY_COST_* / GAUNTLET_MAX_RETRIES /
// GAUNTLET_FREE_ENTRY_MAX in functions/index.js. Change both together.
// Single source of truth for all Blitz reward labels and retry UI.
//
// Format: one 90-second run, up to 30 questions (difficulty ramp 10/10/10).
// Answer as many as you can — unanswered questions score nothing.
// There is no streak and no milestones: each retry is a priced gamble with
// an escalating entry fee and tiered AC payouts.

/// Run length in seconds.
const int kBlitzSeconds = 90;

/// Maximum questions minted per run.
const int kBlitzMaxQuestions = 30;

/// Question mix per run: 10 easy, 10 medium, 10 hard (in that ramp order).
const Map<String, int> kBlitzMix = {'easy': 10, 'medium': 10, 'hard': 10};

/// WP per correct answer, by question difficulty.
const Map<String, int> kBlitzWpByDifficulty = {
  'easy': 5,
  'medium': 8,
  'hard': 12,
};

/// Hard cap on raw run WP before retry decay / premium / daily soft cap.
const int kBlitzRawWpCap = 200;

/// Flat completion bonus when at least [kBlitzCompletionMinAnswered]
/// questions were answered (correct or not).
const int kBlitzCompletionWp = 10;

/// Minimum answered questions for the completion bonus.
const int kBlitzCompletionMinAnswered = 5;

/// Gamble payout tiers: minimum correct count (inclusive) → AC earned.
/// Mirrors BLITZ_AC_TIERS in functions/index.js.
class BlitzAcTier {
  final int minCorrect;
  final int ac;

  const BlitzAcTier(this.minCorrect, this.ac);
}

const List<BlitzAcTier> kBlitzAcTiers = [
  BlitzAcTier(0, 2),
  BlitzAcTier(5, 8),
  BlitzAcTier(9, 15),
  BlitzAcTier(13, 25),
  BlitzAcTier(17, 40),
  BlitzAcTier(21, 60),
];

/// AC earned for [correctCount] correct answers.
int blitzAcEarned(int correctCount) {
  var ac = 0;
  for (final tier in kBlitzAcTiers) {
    if (correctCount >= tier.minCorrect) ac = tier.ac;
  }
  return ac;
}

/// Maximum AC earnable in one run (top tier).
int get kBlitzMaxAc => kBlitzAcTiers.last.ac;

/// Maximum paid retries per WAT day (index 0..5 → 6 retries).
const int kBlitzMaxRetries = 6;

/// FREE curve — always paid, escalates 40 → 756.
const List<int> kBlitzRetryCostFree = [40, 72, 130, 234, 420, 756];

/// PREMIUM curve — first retry (index 0) is free, then 40 → 203.
const List<int> kBlitzRetryCostPremium = [0, 40, 60, 90, 135, 203];

/// Free entries per WAT day (first attempt + crash tolerance).
/// Mirrors GAUNTLET_FREE_ENTRY_MAX in functions/index.js.
const int kBlitzFreeEntryMax = 3;

/// Returns the AC cost for the current retry, or null when no retries remain.
/// [retryIndex] is the 0-based paid-retry index for today (0 = next retry is
/// retry number 1). [isPremium] selects the curve. [isFreeAttempt] is true
/// when the free daily attempt has NOT yet been consumed today.
int? blitzRetryCost({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) {
  if (isFreeAttempt) return 0; // first run is always free
  if (retryIndex >= kBlitzMaxRetries) return null; // cap reached
  return isPremium
      ? kBlitzRetryCostPremium[retryIndex]
      : kBlitzRetryCostFree[retryIndex];
}

/// Human label for the current retry state.
///
/// - isFreeAttempt is true → "FREE" (start)
///
/// - premium retry 1 (retryIndex is 0, isPremium is true) → "FREE"
/// - otherwise → "[cost] AC" or "No retries left"
String blitzRetryLabel({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) {
  final cost = blitzRetryCost(
    retryIndex: retryIndex,
    isPremium: isPremium,
    isFreeAttempt: isFreeAttempt,
  );
  if (cost == null) return 'No retries left today';
  if (cost == 0) return 'FREE';
  return '$cost AC';
}

/// Button label variant — includes "Retry" prefix except for the free start.
String blitzRetryButtonLabel({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) {
  if (isFreeAttempt) return 'Start \u00b7 Free';
  final cost = blitzRetryCost(
    retryIndex: retryIndex,
    isPremium: isPremium,
    isFreeAttempt: isFreeAttempt,
  );
  if (cost == null) return 'No retries left';
  if (cost == 0) return 'Retry \u00b7 FREE';
  return 'Retry \u00b7 $cost AC';
}

/// Returns effective retryIndex for today: 0 if the stored date mismatches [todayWAT].
int effectiveBlitzRetryIndex({
  required int storedIndex,
  required String storedDate,
  required String todayWAT,
}) {
  if (storedDate != todayWAT) return 0;
  return storedIndex;
}

/// WAT date string helper (mirrors FirestoreService._watDateString).
String blitzTodayWAT() {
  final wat = DateTime.now().toUtc().add(const Duration(hours: 1));
  final m = wat.month.toString().padLeft(2, '0');
  final d = wat.day.toString().padLeft(2, '0');
  return '${wat.year}-$m-$d';
}
