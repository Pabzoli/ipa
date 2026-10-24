// ── Gauntlet v4.8 economy ────────────────────────────────────────────────────
// Mirrors GAUNTLET_MILESTONES, GAUNTLET_RETRY_COST_* and GAUNTLET_MAX_RETRIES
// in functions/index.js. Change both together. Single source of truth for all
// Gauntlet reward labels and retry UI.

/// Streak-day → reward label, mirroring GAUNTLET_MILESTONES (functions/index.js).
/// Awarded once per streak run at the listed day counts. Keep this the ONLY
/// client copy so the home card and the confirm dialog can never disagree.
const Map<int, String> kGauntletMilestones = {
  3: '40🪙',
  7: '100🪙 + 50 WP',
  14: '200🪙 + 100 WP + 🖼️',
  30: '500🪙 + Premium',
};

/// Maximum paid retries per WAT day (index 0..5 → 6 retries).
const int kGauntletMaxRetries = 6;

/// FREE curve — always paid, escalates 40 → 756.
const List<int> kGauntletRetryCostFree = [40, 72, 130, 234, 420, 756];

/// PREMIUM curve — first retry (index 0) is free, then 40 → 203.
const List<int> kGauntletRetryCostPremium = [0, 40, 60, 90, 135, 203];

/// Returns the AC cost for the current retry, or null when no retries remain.
/// [retryIndex] is the 0-based paid-retry index for today (0 = next retry is
/// retry number 1). [isPremium] selects the curve. [isFreeAttempt] is true
/// when the free daily attempt has NOT yet been consumed today.
int? gauntletRetryCost({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) {
  if (isFreeAttempt) return 0; // first run is always free
  if (retryIndex >= kGauntletMaxRetries) return null; // cap reached
  return isPremium
      ? kGauntletRetryCostPremium[retryIndex]
      : kGauntletRetryCostFree[retryIndex];
}

/// Human label for the current retry state.
///
/// - isFreeAttempt is true → "FREE" (start)
///
/// - premium retry 1 (retryIndex is 0, isPremium is true) → "FREE"
/// - otherwise → "[cost] AC" or "No retries left"
String gauntletRetryLabel({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) {
  final cost = gauntletRetryCost(
    retryIndex: retryIndex,
    isPremium: isPremium,
    isFreeAttempt: isFreeAttempt,
  );
  if (cost == null) return 'No retries left today';
  if (cost == 0) return 'FREE';
  return '$cost AC';
}

/// Button label variant — includes "Retry" prefix except for the free start.
String gauntletRetryButtonLabel({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) {
  if (isFreeAttempt) return 'Start \u00b7 Free';
  final cost = gauntletRetryCost(
    retryIndex: retryIndex,
    isPremium: isPremium,
    isFreeAttempt: isFreeAttempt,
  );
  if (cost == null) return 'No retries left';
  if (cost == 0) return 'Retry \u00b7 FREE';
  return 'Retry \u00b7 $cost AC';
}

/// Returns effective retryIndex for today: 0 if the stored date mismatches [todayWAT].
int effectiveGauntletRetryIndex({
  required int storedIndex,
  required String storedDate,
  required String todayWAT,
}) {
  if (storedDate != todayWAT) return 0;
  return storedIndex;
}

/// WAT date string helper (mirrors FirestoreService._watDateString).
String gauntletTodayWAT() {
  final wat = DateTime.now().toUtc().add(const Duration(hours: 1));
  final m = wat.month.toString().padLeft(2, '0');
  final d = wat.day.toString().padLeft(2, '0');
  return '${wat.year}-$m-$d';
}
