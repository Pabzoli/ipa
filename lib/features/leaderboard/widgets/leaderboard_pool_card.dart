import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/services/prize_pool_service.dart';
import '../../../core/theme/app_theme.dart';

/// Rank colours in one place.
///
/// Gold/silver/bronze were previously redefined inline in three separate
/// widgets in the leaderboard file, with the podium using its own copies — a
/// change to one would silently disagree with the others.
abstract final class LeaderboardPalette {
  static const gold = AppColors.gold;
  static const silver = AppColors.silver;
  static const bronze = AppColors.bronze;

  /// Rival / head-to-head accent.
  static const rival = AppColors.rival;

  /// The signed-in player.
  static const mine = AppColors.primary;

  /// Colour for a 1-based rank. Ranks outside the podium stay neutral.
  static Color forRank(int? rank) => switch (rank) {
        1 => gold,
        2 => silver,
        3 => bronze,
        _ => AppColors.textMuted,
      };
}

/// The live countdown to the weekly reset.
///
/// Owns its own [Timer] rather than receiving a `Duration` from an ancestor.
/// This is the whole point of the widget existing: the countdown used to live
/// in the page's state, whose `setState` every second rebuilt the entire
/// Global tab — including all ~100 rank rows — once per second, on a screen
/// the user may be simply looking at. Isolating it means the list only
/// rebuilds when the data actually changes.
///
/// Ticks at a one-second cadence, which is enough to move the "3h 12m" label,
/// but only calls `setState` when the rendered second changes so the parent is
/// unaffected and no redundant frames are scheduled within a second.
class CountdownChip extends StatefulWidget {
  final bool compact;

  const CountdownChip({super.key, this.compact = false});

  @override
  State<CountdownChip> createState() => _CountdownChipState();
}

class _CountdownChipState extends State<CountdownChip> {
  Timer? _timer;
  Duration _left = PrizePoolService.timeUntilReset();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final next = PrizePoolService.timeUntilReset();
      if (next.inSeconds == _left.inSeconds) return;
      setState(() => _left = next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final finalising = _left <= Duration.zero;
    final color = finalising ? AppColors.textSecondary : AppColors.accent;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 8.r : 9.r,
        vertical: widget.compact ? 3.r : 4.r,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            finalising ? Icons.hourglass_top_rounded : Icons.schedule_rounded,
            color: AppColors.readable(color),
            size: (widget.compact ? 10 : 11).r,
          ),
          SizedBox(width: 4.w),
          Text(
            PrizePoolService.formatCountdown(_left),
            style: TextStyle(
              color: AppColors.readable(color),
              fontSize: (widget.compact ? 9 : 10).sp,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

/// The weekly prize-pool card.
///
/// Shows a **projection**, not a promise: the figure is
/// [PoolProjection.amount], recomputed from the same rule the Sunday reset
/// uses. The distinction matters because the previous implementation derived
/// every naira figure on this page from `prize_pool.totalNaira` — a legacy
/// ad-revenue field the reset never reads — so the board advertised a number
/// that bore no relation to what winners were actually paid.
///
/// Last week's finalised pool sits underneath as a reference anchor, so a
/// player can sanity-check the projection against something real rather than
/// taking an estimate on faith.
class PrizePoolCard extends StatelessWidget {
  final PoolProjection projection;

  /// `leaderboardCycles/{previousWeekId}.prizePool`, or null when no cycle has
  /// been calculated yet.
  final double? lastWeekPool;

  /// The Monday date string for the current cycle.
  final String weekId;

  /// Whether the underlying `prize_pool` document exists yet.
  final bool poolOpen;

  /// Whether anyone has entered this week's board yet.
  ///
  /// Changes the copy entirely. With no entrants, "Guaranteed minimum" reads as
  /// a promise that somebody will be paid — but an empty week pays nobody,
  /// because the reset allocates the floor to a cycle whose `ranked` array is
  /// empty, and an empty share list means no transfers and no carryover. The
  /// honest framing is an opening price, not a payout.
  final bool isBoardEmpty;

  const PrizePoolCard({
    super.key,
    required this.projection,
    required this.lastWeekPool,
    required this.weekId,
    required this.poolOpen,
    required this.isBoardEmpty,
  });

  /// The line under the headline figure.
  ///
  /// With entrants, this describes how the number was reached. Without, it
  /// invites the first entry instead — and, importantly, does not imply the
  /// money is already committed to someone.
  String get _qualifier {
    if (isBoardEmpty) {
      if (projection.amount > 0) {
        return 'Be the first to enter. Prize pool starts at '
            '${PrizePoolService.formatNaira(projection.amount)}';
      }
      return 'Be the first to enter.';
    }
    return switch (projection.source) {
      // A fixed pool is a hard number the admin committed to.
      PoolSource.adminFixed => 'Fixed for this week',
      // On the floor means the figure is a developer subsidy, not sales.
      PoolSource.floor => 'Guaranteed minimum · projected',
      PoolSource.revenue => 'Projected · finalised Monday',
    };
  }

  @override
  Widget build(BuildContext context) {
    final prizes = PrizePoolService.calculatePrizes(projection.amount);
    final hasPool = projection.amount > 0;

    return Container(
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: label + live countdown on one row ────────────────
          Row(
            children: [
              Expanded(
                child: Text(
                  'WEEKLY PRIZE POOL',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              SizedBox(width: 8.w),
              const CountdownChip(),
            ],
          ),
          SizedBox(height: 8.h),

          // ── Headline figure ─────────────────────────────────────────
          if (!poolOpen && !hasPool)
            Text(
              'Opening soon',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 26.sp,
                fontWeight: FontWeight.w900,
                height: 1.0,
                letterSpacing: -0.8,
              ),
            )
          else
            Text(
              hasPool
                  ? PrizePoolService.formatNaira(projection.amount)
                  : '₦0',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 34.sp,
                fontWeight: FontWeight.w900,
                height: 1.0,
                letterSpacing: -1.0,
              ),
            ),
          SizedBox(height: 5.h),

          // Never let a projected figure read as guaranteed.
          Text(
            _qualifier,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w700,
            ),
          ),

          // ── Last week's actuals, as a trust anchor ──────────────────
          if (lastWeekPool != null && lastWeekPool! > 0) ...[
            SizedBox(height: 6.h),
            Row(
              children: [
                Icon(
                  Icons.history_rounded,
                  color: AppColors.textMuted,
                  size: 12.r,
                ),
                SizedBox(width: 4.w),
                Expanded(
                  child: Text(
                    // Display ONLY. Each week's pool is independent, with
                    // nothing carried forward, so this is worded as a
                    // completed past payment and is never added to this
                    // week's projection. Copy implying a carryover ("rolled
                    // over", "still in the pot") would be false.
                    'Last week paid '
                    '${PrizePoolService.formatNaira(lastWeekPool!)}',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          SizedBox(height: 4.h),
          Text(
            'Week of $weekId',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 16.h),

          Divider(height: 1, color: AppColors.divider),
          SizedBox(height: 14.h),

          // ── Per-rank share ───────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List.generate(
              PrizePoolService.prizePercentages.length,
              (i) {
                final rank = i + 1;
                return Expanded(
                  child: _PrizeSlot(
                    rank: rank,
                    // Rounded exactly like the snapshot's stored `share`, so
                    // the number on screen is the number in Firestore.
                    amount: PrizePoolService.roundShare(prizes[rank] ?? 0),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PrizeSlot extends StatelessWidget {
  final int rank;
  final double amount;

  const _PrizeSlot({required this.rank, required this.amount});

  @override
  Widget build(BuildContext context) {
    final color = LeaderboardPalette.forRank(rank);
    final podium = rank <= 3;

    return Semantics(
      // Read out the real figure, not the abbreviated one on screen.
      label: 'Rank $rank prize',
      value: amount > 0
          ? PrizePoolService.formatExact(amount)
          : PrizePoolService.percentLabel(rank),
      excludeSemantics: true,
      child: Column(
        children: [
          Container(
            width: 24.r,
            height: 24.r,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: podium ? 0.16 : 0.10),
              borderRadius: BorderRadius.circular(7.r),
            ),
            child: Text(
              '$rank',
              style: TextStyle(
                color: AppColors.readable(color),
                fontSize: 11.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(height: 5.h),
          // With a real pool, show the real prize. Truncating a player's
          // potential payout is worse than shrinking the text, so scale down
          // instead of ellipsising.
          if (amount > 0)
            SizedBox(
              height: 13.r,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  PrizePoolService.formatExact(amount),
                  maxLines: 1,
                  style: TextStyle(
                    color: podium ? AppColors.readable(color) : AppColors.textSecondary,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            )
          else
            Text(
              PrizePoolService.percentLabel(rank),
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
        ],
      ),
    );
  }
}