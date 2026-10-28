import 'package:flutter_test/flutter_test.dart';
import 'package:quiz/core/services/prize_pool_service.dart';

/// A literal, executable transcription of the pool-sizing rule in
/// `runWeeklyReset` (functions/index.js).
///
/// This is deliberately a re-implementation rather than a call into the app's
/// own code: if someone edits `PrizePoolService.projectPrizePool` and the two
/// diverge, these tests fail. That is the whole point — the leaderboard shows
/// this number to players as what #1 is competing for, and the same rule
/// decides what they are actually paid on Sunday. Silent drift means quoting
/// players a number they never receive.
Map<String, double> _cfPool({
  num? entryCodeRevenue,
  num? adminPoolNaira,
  num? guaranteedFloor,
}) {
  // const adminPool   = Number(poolData.adminPoolNaira);
  final admin = adminPoolNaira?.toDouble() ?? double.nan;
  // const isFixedPool = Number.isFinite(adminPool) && adminPool > 0;
  final isFixedPool = admin.isFinite && admin > 0;
  // const revenuePool = Math.max(entryRevenue * 0.70, floor);
  final revenue = entryCodeRevenue?.toDouble() ?? 0;
  final floor = guaranteedFloor?.toDouble() ?? 0;
  final revenuePool = revenue * 0.70 > floor ? revenue * 0.70 : floor;
  // const prizePool   = isFixedPool ? adminPool : revenuePool;
  return {'amount': isFixedPool ? admin : revenuePool};
}

double _cfPoolAmount({
  num? entryCodeRevenue,
  num? adminPoolNaira,
  num? guaranteedFloor,
}) =>
    _cfPool(
      entryCodeRevenue: entryCodeRevenue,
      adminPoolNaira: adminPoolNaira,
      guaranteedFloor: guaranteedFloor,
    )['amount']!;

void main() {
  group('projectPrizePool — CF parity', () {
    // Every case is asserted against BOTH the literal CF transcription and an
    // explicit expected number, so a drift shows up as a specific failure
    // rather than "two implementations now agree with each other".
    void expectParity({
      num? entryCodeRevenue,
      num? adminPoolNaira,
      num? guaranteedFloor,
      required double expected,
      required PoolSource source,
    }) {
      final actual = PrizePoolService.projectPrizePool(
        entryCodeRevenue: entryCodeRevenue,
        adminPoolNaira: adminPoolNaira,
        guaranteedFloor: guaranteedFloor,
      );
      expect(actual.amount, expected, reason: 'projected amount');
      expect(actual.source, source, reason: 'pool source');
      expect(
        actual.amount,
        _cfPoolAmount(
          entryCodeRevenue: entryCodeRevenue,
          adminPoolNaira: adminPoolNaira,
          guaranteedFloor: guaranteedFloor,
        ),
        reason: 'client projection must equal the Cloud Function',
      );
    }

    test('revenue only: 70% of entry revenue', () {
      expectParity(
        entryCodeRevenue: 10000,
        guaranteedFloor: 0,
        expected: 7000,
        source: PoolSource.revenue,
      );
    });

    test('admin fixed pool REPLACES the revenue figure', () {
      expectParity(
        entryCodeRevenue: 100000,
        adminPoolNaira: 25000,
        guaranteedFloor: 0,
        expected: 25000,
        source: PoolSource.adminFixed,
      );
    });

    test('admin fixed pool wins even when the floor is higher', () {
      expectParity(
        entryCodeRevenue: 1000,
        adminPoolNaira: 5000,
        guaranteedFloor: 50000,
        expected: 5000,
        source: PoolSource.adminFixed,
      );
    });

    test('adminPoolNaira of 0 is NOT an override (CF requires > 0)', () {
      expectParity(
        entryCodeRevenue: 10000,
        adminPoolNaira: 0,
        guaranteedFloor: 0,
        expected: 7000,
        source: PoolSource.revenue,
      );
    });

    test('negative adminPoolNaira is NOT an override', () {
      expectParity(
        entryCodeRevenue: 10000,
        adminPoolNaira: -500,
        guaranteedFloor: 0,
        expected: 7000,
        source: PoolSource.revenue,
      );
    });

    test('low revenue is lifted to the guaranteed floor', () {
      expectParity(
        entryCodeRevenue: 1000,
        guaranteedFloor: 20000,
        expected: 20000,
        source: PoolSource.floor,
      );
    });

    test('floor exactly equal to the revenue pool keeps the revenue source',
        () {
      // 70% of 10000 == 7000 == floor. The CF's Math.max returns 7000 either
      // way, so only the amount is contractual; the label is ours to choose.
      expectParity(
        entryCodeRevenue: 10000,
        guaranteedFloor: 7000,
        expected: 7000,
        source: PoolSource.revenue,
      );
    });

    test('no revenue and no floor yields a zero pool', () {
      expectParity(
        entryCodeRevenue: 0,
        guaranteedFloor: 0,
        expected: 0,
        source: PoolSource.revenue,
      );
    });

    test('missing fields (null) degrade to zero, never NaN', () {
      final p = PrizePoolService.projectPrizePool(
        entryCodeRevenue: null,
        adminPoolNaira: null,
        guaranteedFloor: null,
      );
      expect(p.amount, 0);
      expect(p.amount.isNaN, isFalse);
    });

    test('missing revenue but a floor still surfaces the floor', () {
      expectParity(
        entryCodeRevenue: null,
        guaranteedFloor: 30000,
        expected: 30000,
        source: PoolSource.floor,
      );
    });

    test('exposes the inputs it was given for honest labelling', () {
      final p = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 20000,
        adminPoolNaira: 15000,
        guaranteedFloor: 5000,
      );
      expect(p.entryCodeRevenue, 20000);
      expect(p.guaranteedFloor, 5000);
      expect(p.adminPoolNaira, 15000);
      expect(p.isFixed, isTrue);
      expect(p.isFloored, isFalse);
    });
  });

  group('Prize distribution', () {
    test('percentages sum to exactly 1.0 (whole pool is allocated)', () {
      final sum = PrizePoolService.prizePercentages.values
          .fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-12));
    });

    test('per-rank shares match the CF round-trip to the kobo', () {
      // CF: parseFloat((prizePool * prizePct(rank)).toFixed(2))
      const pool = 12345.67;
      double cfShare(int rank) {
        const pcts = {1: 0.50, 2: 0.30, 3: 0.20};
        return double.parse((pool * pcts[rank]!).toStringAsFixed(2));
      }

      for (var rank = 1; rank <= 3; rank++) {
        expect(
          PrizePoolService.roundShare(
            PrizePoolService.prizeForRank(rank, pool),
          ),
          cfShare(rank),
          reason: 'rank $rank share',
        );
      }
    });

    test('rank 4+ wins nothing', () {
      expect(PrizePoolService.prizeForRank(4, 100000), 0);
      expect(PrizePoolService.percentLabel(4), '');
    });

    test('percent labels come from the same table as the maths', () {
      expect(PrizePoolService.percentLabel(1), '50%');
      expect(PrizePoolService.percentLabel(2), '30%');
      expect(PrizePoolService.percentLabel(3), '20%');
    });

    test('exactly three ranks share the pool', () {
      expect(PrizePoolService.prizePercentages.keys, [1, 2, 3]);
    });
  });

  group('Countdown boundary — must match the weeklyReset cron', () {
    // weeklyReset: schedule '0 23 * * 0', timeZone 'UTC' (functions/index.js).
    test('resetHourUtc is pinned to 23 UTC', () {
      expect(PrizePoolService.resetHourUtc, 23);
    });

    test('mid-week points at the coming Sunday 23:00', () {
      // Wednesday 2025-06-11 12:00 UTC
      final now = DateTime.utc(2025, 6, 11, 12);
      final next = PrizePoolService.nextResetDate(now: now);
      expect(next, DateTime.utc(2025, 6, 15, 23));
      expect(next.weekday, DateTime.sunday);
    });

    test('Sunday before 23:00 still targets today', () {
      // Sunday 2025-06-15 20:00 UTC — three hours of competition left.
      final now = DateTime.utc(2025, 6, 15, 20);
      final next = PrizePoolService.nextResetDate(now: now);
      expect(next, DateTime.utc(2025, 6, 15, 23));
      expect(
        PrizePoolService.timeUntilReset(now: now),
        const Duration(hours: 3),
      );
    });

    test('Sunday at 23:30 rolls forward a full week', () {
      // Past the reset: the board is snapshotted and zeroed, so the next thing
      // the countdown may reference is next Sunday.
      final now = DateTime.utc(2025, 6, 15, 23, 30);
      final next = PrizePoolService.nextResetDate(now: now);
      expect(next, DateTime.utc(2025, 6, 22, 23));
    });

    test('does NOT count to 23:59 (the original bug)', () {
      // One minute before the reset the remaining time must be ~1 minute.
      // Counting to 23:59 would report 60 minutes and tell players they had
      // an hour to compete after their points had been zeroed.
      final now = DateTime.utc(2025, 6, 15, 22, 59);
      final left = PrizePoolService.timeUntilReset(now: now);
      expect(left.inMinutes, 1);
      expect(left.inMinutes, lessThan(5));
    });

    test('isFinalising covers reset -> week roll, not a 59s window', () {
      // Still open: a minute of competition left.
      expect(
        PrizePoolService.isFinalisingAt(DateTime.utc(2025, 6, 15, 22, 59)),
        isFalse,
      );
      // The instant the reset runs, points are snapshotted and zeroed.
      expect(
        PrizePoolService.isFinalisingAt(DateTime.utc(2025, 6, 15, 23, 0)),
        isTrue,
      );
      // ...through to the end of Sunday UTC.
      expect(
        PrizePoolService.isFinalisingAt(DateTime.utc(2025, 6, 15, 23, 30)),
        isTrue,
      );
      // Monday 00:00 UTC rolls the week — a fresh board is live.
      expect(
        PrizePoolService.isFinalisingAt(DateTime.utc(2025, 6, 16, 0, 0)),
        isFalse,
      );
    });

    test('countdown text never renders a bare "0m left"', () {
      expect(
        PrizePoolService.formatCountdown(Duration.zero),
        'Finalising',
      );
      expect(
        PrizePoolService.formatCountdown(const Duration(seconds: -5)),
        'Finalising',
      );
    });

    test('weekStartUtc is the most recent Monday 00:00', () {
      // Late Sunday is still the week that started on the previous Monday.
      final sunday = PrizePoolService.weekStartUtc();
      expect(sunday.weekday, DateTime.monday);
      expect(sunday.hour, 0);
      expect(sunday.minute, 0);
      expect(
        DateTime.now().toUtc().difference(sunday).inDays,
        inInclusiveRange(0, 6),
      );
    });
  });

  group('Formatting', () {
    test('sub-1000 amounts are never rendered as a fraction of K', () {
      // The old formatter produced "₦0.4K" for 400 naira.
      expect(PrizePoolService.formatNaira(400), '₦400');
      expect(PrizePoolService.formatCompact(400), '₦400');
      expect(PrizePoolService.formatNaira(999), '₦999');
    });

    test('whole thousands drop the trailing .0', () {
      expect(PrizePoolService.formatNaira(4000), '₦4K');
      expect(PrizePoolService.formatNaira(1500), '₦1.5K');
      expect(PrizePoolService.formatNaira(2500000), '₦2.5M');
    });

    test('zero and invalid inputs render as ₦0, never ₦NaN', () {
      expect(PrizePoolService.formatNaira(0), '₦0');
      expect(PrizePoolService.formatCompact(double.nan), '₦0');
      expect(PrizePoolService.formatCompact(double.infinity), '₦0');
      expect(PrizePoolService.formatExact(double.nan), '₦0');
    });

    test('formatExact is the citable form for a real payout', () {
      expect(PrizePoolService.formatExact(12500), '₦12,500');
      expect(PrizePoolService.formatExact(1000000), '₦1,000,000');
      expect(PrizePoolService.formatExact(999), '₦999');
      // Rounds to the kobo like the stored share.
      expect(PrizePoolService.formatExact(1234.567), '₦1,235');
    });
  });
}