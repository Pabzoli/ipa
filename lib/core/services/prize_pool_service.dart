/// Utility class — prize pool calculations, formatting, countdown.
/// Stateless; no Firestore access here (that lives in FirestoreService).
class PrizePoolService {
  PrizePoolService._();

  // ─── Prize distribution (percentages) ────────────────────────────────────
  static const Map<int, double> _percentages = {
    1: 0.40,
    2: 0.25,
    3: 0.15,
    4: 0.10,
    5: 0.10,
  };

  /// Returns prize amount (in naira) for each rank given the total pool.
  static Map<int, double> calculatePrizes(double totalNaira) {
    return _percentages.map((rank, pct) => MapEntry(rank, totalNaira * pct));
  }

  /// Returns prize for a specific rank, or 0 if rank doesn't win.
  static double prizeForRank(int rank, double totalNaira) {
    return (totalNaira * (_percentages[rank] ?? 0.0));
  }

  // ─── Formatting ───────────────────────────────────────────────────────────
  static String formatNaira(double amount) {
    if (amount >= 1000000) {
      return '₦${(amount / 1000000).toStringAsFixed(1)}M';
    }
    if (amount >= 1000) {
      return '₦${(amount / 1000).toStringAsFixed(1)}K';
    }
    return '₦${amount.toStringAsFixed(0)}';
  }

  static String formatCompact(double amount) {
    if (amount >= 1000) {
      return '₦${(amount / 1000).toStringAsFixed(amount % 1000 == 0 ? 0 : 1)}K';
    }
    return '₦${amount.toStringAsFixed(0)}';
  }

  // ─── Countdown ────────────────────────────────────────────────────────────
  /// Next Sunday at 23:59 UTC (Monday midnight WAT).
  static DateTime nextResetDate() {
    final now        = DateTime.now().toUtc();
    // Days until next Sunday (weekday: Mon=1 … Sun=7)
    final daysToSun  = (7 - now.weekday) % 7;
    final nextSunday = DateTime.utc(now.year, now.month, now.day + daysToSun, 23, 59);
    // If it's already Sunday after 23:59, add 7 days
    return nextSunday.isBefore(now)
        ? nextSunday.add(const Duration(days: 7))
        : nextSunday;
  }

  static Duration timeUntilReset() {
    final diff = nextResetDate().difference(DateTime.now().toUtc());
    return diff.isNegative ? Duration.zero : diff;
  }

  static String formatCountdown(Duration d) {
    if (d.inDays > 0) {
      return '${d.inDays}d ${d.inHours % 24}h left';
    }
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes % 60}m left';
    }
    return '${d.inMinutes}m left';
  }

  // ─── Rank labels ──────────────────────────────────────────────────────────
  static String rankOrdinal(int rank) {
    switch (rank) {
      case 1: return '1st';
      case 2: return '2nd';
      case 3: return '3rd';
      default: return '${rank}th';
    }
  }

  static String rankEmoji(int rank) {
    switch (rank) {
      case 1: return '🥇';
      case 2: return '🥈';
      case 3: return '🥉';
      default: return '🎖️';
    }
  }
}