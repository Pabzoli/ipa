/// Where a projected prize-pool figure came from, so the UI can be honest about
/// whether the admin has fixed this week's pool or it floats with sales.
enum PoolSource {
  /// `prize_pool/{weekId}.adminPoolNaira` was set: a fixed amount that
  /// REPLACES the revenue-based figure outright.
  adminFixed,

  /// 70% of leaderboard-entry revenue, above the guaranteed floor.
  revenue,

  /// Entry revenue was too low, so the pool sits at the developer-funded
  /// `app_config/leaderboard_entry_config.guaranteedFloor`.
  floor,
}

/// The result of projecting this week's prize pool.
class PoolProjection {
  /// Naira available to the top 3 this week.
  final double amount;

  /// Which branch of the CF rule produced [amount].
  final PoolSource source;

  /// Cumulative leaderboard-entry revenue booked so far this week.
  final double entryCodeRevenue;

  /// `app_config/leaderboard_entry_config.guaranteedFloor` (may be 0).
  final double guaranteedFloor;

  /// The admin's fixed override, when one is set.
  final double? adminPoolNaira;

  const PoolProjection({
    required this.amount,
    required this.source,
    required this.entryCodeRevenue,
    required this.guaranteedFloor,
    required this.adminPoolNaira,
  });

  /// True when the admin pinned the pool regardless of how many entries sell.
  bool get isFixed => source == PoolSource.adminFixed;

  /// True when the pool is currently sitting on the guaranteed floor rather
  /// than on real sales — i.e. the figure is a subsidy, not revenue.
  bool get isFloored => source == PoolSource.floor;
}

/// Utility class — prize pool projection, formatting, countdown.
///
/// Stateless; no Firestore access here (that lives in FirestoreService).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// CONTRACT WITH THE BACKEND
/// [projectPrizePool] is a client-side mirror of the pool-sizing rule in
/// `runWeeklyReset` (functions/index.js, the block that computes `prizePool`).
/// The two MUST stay in step, because the leaderboard shows this number as a
/// live projection and the same rule decides what winners are actually paid at
/// the Sunday reset. `test/prize_pool_service_test.dart` pins the cases against
/// the CF's literal behaviour so a change on either side fails loudly.
///
/// The CF rule, verbatim:
/// ```js
/// const adminPool   = Number(poolData.adminPoolNaira);
/// const isFixedPool = Number.isFinite(adminPool) && adminPool > 0;
/// const revenuePool = Math.max(entryRevenue * 0.70, floor);
/// const prizePool   = isFixedPool ? adminPool : revenuePool;
/// ```
/// Note what it does NOT use: `prize_pool.totalNaira` is legacy ad revenue,
/// never read by the reset. Deriving the displayed pool from it (as the UI
/// previously did) showed players a completely different number from the one
/// they would be paid.
class PrizePoolService {
  PrizePoolService._();

  // ─── Prize distribution (percentages) ────────────────────────────────────
  /// Rank → share of the pool. Sums to 1.0.
  ///
  /// Mirrors `prizePct(rank)` in functions/index.js.
  static const Map<int, double> prizePercentages = <int, double>{
    1: 0.50,
    2: 0.30,
    3: 0.20,
  };

  /// Share of this week's leaderboard-entry revenue that funds the pool.
  /// The remaining 30% is the house cut. Mirrored from `index.js`.
  static const double revenueShare = 0.70;

  /// Returns prize amount (in naira) for each rank given the total pool.
  static Map<int, double> calculatePrizes(double totalNaira) {
    return prizePercentages.map(
      (rank, pct) => MapEntry(rank, totalNaira * pct),
    );
  }

  /// Returns prize for a specific rank, or 0 if rank doesn't win.
  static double prizeForRank(int rank, double totalNaira) {
    return totalNaira * (prizePercentages[rank] ?? 0.0);
  }

  /// The share string rendered when a pool is still zero, e.g. "50%".
  static String percentLabel(int rank) {
    final pct = prizePercentages[rank];
    if (pct == null) return '';
    return '${(pct * 100).round()}%';
  }

  // ─── Live pool projection (CF parity) ─────────────────────────────────────

  /// Projects this week's prize pool using exactly the inputs and priority
  /// order the weekly reset uses. Safe to call every frame with live values.
  ///
  /// Null / NaN / Infinity inputs are coerced to 0 exactly as `Number(x) || 0`
  /// does in the CF, so a missing field can never poison the figure.
  static PoolProjection projectPrizePool({
    required num? entryCodeRevenue,
    num? adminPoolNaira,
    num? guaranteedFloor,
  }) {
    final revenue = _coerce(entryCodeRevenue);
    final floor = _coerce(guaranteedFloor);
    final admin = _coerce(adminPoolNaira);

    // Priority 1 — an admin-set fixed pool REPLACES the revenue figure.
    if (admin > 0) {
      return PoolProjection(
        amount: admin,
        source: PoolSource.adminFixed,
        entryCodeRevenue: revenue,
        guaranteedFloor: floor,
        adminPoolNaira: admin,
      );
    }

    // Priority 2 — 70% of entry revenue, never below the floor.
    final revenuePool = revenue * revenueShare;
    if (floor > revenuePool) {
      return PoolProjection(
        amount: floor,
        source: PoolSource.floor,
        entryCodeRevenue: revenue,
        guaranteedFloor: floor,
        adminPoolNaira: null,
      );
    }

    return PoolProjection(
      amount: revenuePool,
      source: PoolSource.revenue,
      entryCodeRevenue: revenue,
      guaranteedFloor: floor,
      adminPoolNaira: null,
    );
  }

  /// Mirrors the CF's `Number(x) || 0`: non-finite and negative values collapse
  /// to 0. `Number(null)` is 0 and `Number(undefined)` is NaN, so both land on
  /// 0 rather than propagating.
  static double _coerce(num? value) {
    final d = value?.toDouble() ?? 0;
    if (!d.isFinite || d < 0) return 0;
    return d;
  }

  // ─── Formatting ───────────────────────────────────────────────────────────

  /// Rounds a naira amount the way the CF rounds a stored `share`
  /// (`parseFloat(x.toFixed(2))`) so a displayed per-rank prize matches the
  /// persisted figure to the kobo.
  static double roundShare(double amount) {
    if (!amount.isFinite) return 0;
    return double.parse(amount.toStringAsFixed(2));
  }

  static String formatNaira(double amount) {
    return _compact(amount);
  }

  static String formatCompact(double amount) {
    return _compact(amount);
  }

  static String _compact(double amount) {
    if (!amount.isFinite || amount <= 0) return '₦0';
    if (amount >= 1000000) {
      return '₦${(amount / 1000000).toStringAsFixed(1)}M';
    }
    if (amount >= 1000) {
      // Whole thousands read better without a trailing ".0" ("₦4K", not
      // "₦4.0K"); fractional thousands keep one decimal ("₦1.2K").
      final k = amount / 1000;
      final text =
          k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1);
      return '₦${text}K';
    }
    return '₦${amount.toStringAsFixed(0)}';
  }

  /// Full-precision naira with thousands separators, for prize amounts the user
  /// could actually be paid (e.g. "₦12,500").
  ///
  /// Compact forms are for headline figures only — "₦12.5K" is fine on a
  /// badge but misleading next to a claim the player can cash out.
  static String formatExact(double amount) {
    if (!amount.isFinite || amount <= 0) return '₦0';
    final rounded = roundShare(amount);
    final digits = rounded.toStringAsFixed(0);
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return '₦$buffer';
  }

  // ─── Countdown ────────────────────────────────────────────────────────────

  /// Hour-of-day (UTC) at which the weekly reset runs and competition freezes.
  ///
  /// MUST match the `weeklyReset` cron in functions/index.js (`0 23 * * 0`,
  /// UTC). Counting to any later hour — 23:59 was the original bug — tells
  /// players they still have time to compete after their points have already
  /// been snapshotted and zeroed.
  static const int resetHourUtc = 23;

  /// Start of the current leaderboard week: the most recent Monday 00:00 UTC.
  ///
  /// Mirrors `currentWeekId()` in functions/index.js. Both derive the boundary
  /// from UTC; WAT is UTC+1, so WAT Monday 00:00 is still Sunday 23:00 UTC and
  /// the week genuinely rolls at the reset, not a second later.
  ///
  /// [now] is injectable purely so week boundaries can be tested
  /// deterministically; production always leaves it null.
  static DateTime weekStartUtc({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    final midnight =
        DateTime.utc(current.year, current.month, current.day);
    return midnight.subtract(Duration(days: current.weekday - 1));
  }

  /// The next reset instant: the coming Sunday at [resetHourUtc]:00 UTC,
  /// rolling on by 7 days once that moment has passed.
  ///
  /// [now] is injectable purely so the Sunday-23:00 boundary can be tested
  /// deterministically; production always leaves it null.
  static DateTime nextResetDate({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    // Days until the coming Sunday (Mon=1 … Sun=7).
    final daysToSun = (DateTime.sunday - current.weekday) % 7;
    final target = DateTime.utc(
      current.year,
      current.month,
      current.day + daysToSun,
      resetHourUtc,
    );
    return target.isAfter(current)
        ? target
        : target.add(const Duration(days: 7));
  }

  static Duration timeUntilReset({DateTime? now}) {
    final diff =
        nextResetDate(now: now).difference((now ?? DateTime.now()).toUtc());
    return diff.isNegative ? Duration.zero : diff;
  }

  /// True during the "closed but not yet rolled" window: from the reset instant
  /// (Sunday [resetHourUtc]:00 UTC) until the week id advances at Monday
  /// 00:00 UTC.
  ///
  /// In that hour the points have already been snapshotted and zeroed by
  /// `weeklyReset`, so nothing a player does can still change the board — but
  /// `currentWeekId()` still names the finalised week, so the UI keeps showing
  /// it. Rendering a running countdown here would tell players they have an
  /// hour left to compete, which is exactly the lie the old 23:59 target told
  /// everyone. The board instead reads "Finalising".
  static bool isFinalisingAt(DateTime now) {
    final utc = now.toUtc();
    return utc.weekday == DateTime.sunday && utc.hour >= resetHourUtc;
  }

  static bool get isFinalising => isFinalisingAt(DateTime.now());

  static String formatCountdown(Duration d) {
    if (d <= Duration.zero) return 'Finalising';
    if (d.inDays > 0) {
      return '${d.inDays}d ${d.inHours % 24}h left';
    }
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes % 60}m left';
    }
    return '${d.inMinutes}m left';
  }
}