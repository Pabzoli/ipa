import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_theme.dart';
import 'leaderboard_pool_card.dart';

/// The signed-in player's standing on this week's board.
///
/// This is the anchor of the whole screen: everything else on the page exists
/// to give this card something to be measured against.
///
/// Rank comes from [WeeklyStanding] rather than from the visible row list,
/// which is capped at 100. Previously a player ranked #150 was shown "#—",
/// on the one page whose entire purpose is telling them their rank — while the
/// home header pill, fed by a different query, showed "#150" correctly. Both
/// now come from the same walk of the same ordering, so they cannot disagree.
class YourPositionCard extends StatelessWidget {
  /// Live standing. [WeeklyStanding.none] when the player has no entry.
  final WeeklyStanding standing;

  /// The player's own weekly points, kept live from the provider so the card
  /// moves the moment a quiz is submitted, before the board stream catches up.
  final int myWeeklyPoints;

  /// Display name.
  final String displayName;

  /// Whether the player holds an entry this week.
  final bool isEligible;

  /// Shown only when [isEligible] is false.
  final Widget? entryCta;

  /// Resolved by the parent; see the campus/global tabs.
  const YourPositionCard({
    super.key,
    required this.standing,
    required this.myWeeklyPoints,
    required this.displayName,
    required this.isEligible,
    this.entryCta,
  });

  bool get _hasRank => standing.rank > 0;

  @override
  Widget build(BuildContext context) {
    final rank = standing.rank;
    final total = standing.totalPlayers;
    final toOvertake = standing.pointsToOvertake;
    final nextName = standing.nextRankUsername;

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _RankBadge(rank: rank),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.2,
                              height: 1.15,
                            ),
                          ),
                        ),
                        SizedBox(width: 6.w),
                        const _YouBadge(),
                      ],
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      _subtitle(rank: rank, total: total),
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // ── The chase: how far to the next rank ──────────────────────
          // The single most useful thing this page can tell an entrant.
          // "You're #47" is a fact; "+83 pts to pass #46" is a goal. Rank 1
          // renders the leadership variant rather than nothing at all, which
          // is what gating on `toOvertake != null` used to do.
          if (_hasRank) ...[
            SizedBox(height: 12.h),
            _NextRankGap(
              pointsToOvertake: toOvertake,
              rivalName: nextName,
              isRankOne: rank == 1,
            ),
          ],

          // ── No entry: explain, then offer the one path that works ────
          if (!isEligible) ...[
            SizedBox(height: 12.h),
            Container(
              padding:
                  EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(
                  color: AppColors.secondary.withValues(alpha: 0.24),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: AppColors.secondary, size: 14.r),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(
                      "You're not eligible for prizes this week",
                      style: TextStyle(
                        color: AppColors.secondary,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (entryCta != null) ...[
              SizedBox(height: 10.h),
              entryCta!,
            ],
          ],
        ],
      ),
    );
  }

  String _subtitle({required int rank, required int total}) {
    if (rank <= 0) return '$myWeeklyPoints pts this week';
    if (total > 0) {
      // The real cohort size, not the 100-row window — otherwise a player at
      // #90 of 240 is told they are in the "top 38%" of a list that only
      // contains 100 people.
      final pct = ((rank / total) * 100).ceil().clamp(1, 99);
      return '$total entrants · top $pct% · $myWeeklyPoints pts';
    }
    return '$myWeeklyPoints pts this week';
  }
}

class _RankBadge extends StatelessWidget {
  final int rank;

  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) {
    final known = rank > 0;
    final color = known ? LeaderboardPalette.forRank(rank) : AppColors.primary;

    return Semantics(
      label: known ? 'Your rank $rank' : 'Unranked',
      excludeSemantics: true,
      child: Container(
        width: 46.r,
        height: 46.r,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            known ? '#$rank' : '#—',
            style: TextStyle(
              color: color,
              fontSize: 16.sp,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _YouBadge extends StatelessWidget {
  const _YouBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5.r),
      ),
      child: Text(
        'YOU',
        style: TextStyle(
          color: AppColors.primary,
          fontSize: 8.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// The "N pts to pass X" call to action.
class _NextRankGap extends StatelessWidget {
  final int? pointsToOvertake;
  final String? rivalName;
  final bool isRankOne;

  const _NextRankGap({
    required this.pointsToOvertake,
    required this.rivalName,
    required this.isRankOne,
  });

  @override
  Widget build(BuildContext context) {
    if (isRankOne) {
      return _GapShell(
        icon: Icons.workspace_premium_rounded,
        color: LeaderboardPalette.gold,
        text: 'You lead the board.',
      );
    }

    final name =
        (rivalName == null || rivalName!.isEmpty) ? 'the player above' : rivalName!;

    // No overtake target resolved (an unranked neighbour, or a failed query):
    // state the goal rather than inventing a number.
    final points = pointsToOvertake;
    final text = points == null
        ? 'Next rank is within reach — keep scoring.'
        : '$points pts to pass $name';

    return _GapShell(
      icon: Icons.trending_up_rounded,
      color: AppColors.correct,
      text: text,
    );
  }
}

class _GapShell extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _GapShell({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 9.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 15.r),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 11.5.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}