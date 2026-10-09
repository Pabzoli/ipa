import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/services/firestore_service.dart';
import '../../../core/services/prize_pool_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../prizes/payout_claim_page.dart';
import 'leaderboard_pool_card.dart';

/// "My prizes" — the winner's own payout state, newest week first.
///
/// Only cycles where the signed-in player appears in the server's
/// `ranked[]` snapshot are shown; nothing here is computed client-side, and
/// "Paid" appears only when `ranked[].paid == true`. Tapping a row opens the
/// claim screen for that week.
///
/// The future is created once in [initState] rather than inline in `build`.
/// It used to be built inline, which only avoided re-firing a Firestore read
/// on every rebuild by accident: the widget happened to be `const`, so Flutter
/// canonicalised it and skipped the rebuild entirely. Any non-const
/// refactor — or a sibling rebuilding it — would have turned this into one
/// read per frame.
class MyPrizesBanner extends StatefulWidget {
  final int maxShown;

  /// Bumped by the page on pull-to-refresh / retry. Changing it re-runs the
  /// query, so a payout the admin just approved becomes visible without
  /// needing a restart.
  final int refreshSignal;

  const MyPrizesBanner({
    super.key,
    this.maxShown = 3,
    this.refreshSignal = 0,
  });

  @override
  State<MyPrizesBanner> createState() => _MyPrizesBannerState();
}

class _MyPrizesBannerState extends State<MyPrizesBanner> {
  late Future<List<WinnerClaimSummary>> _future;
  int _expanded = 0;

  @override
  void initState() {
    super.initState();
    _future = FirestoreService.instance.getMyWinnerCycles();
  }

  @override
  void didUpdateWidget(covariant MyPrizesBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      _reload();
    }
  }

  void _reload() {
    setState(() => _future = FirestoreService.instance.getMyWinnerCycles());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<WinnerClaimSummary>>(
      future: _future,
      builder: (context, snap) {
        // Nothing to show while loading, and nothing to show if never a winner.
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        final cycles = snap.data ?? const <WinnerClaimSummary>[];
        if (cycles.isEmpty) return const SizedBox.shrink();

        final visible = _expanded == 0
            ? cycles.take(widget.maxShown).toList()
            : cycles;

        return Container(
          padding: EdgeInsets.all(14.r),
          decoration: BoxDecoration(
            color: LeaderboardPalette.gold.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(
              color: LeaderboardPalette.gold.withValues(alpha: 0.30),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.emoji_events_rounded,
                      color: LeaderboardPalette.gold, size: 16.r),
                  SizedBox(width: 8.w),
                  Text(
                    'My prizes',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const Spacer(),
                  if (cycles.length > widget.maxShown)
                    TextButton(
                      onPressed: () =>
                          setState(() => _expanded = _expanded == 0 ? 1 : 0),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        minimumSize: const Size(0, 28),
                        padding: EdgeInsets.symmetric(horizontal: 8.r),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        _expanded == 0 ? 'See all' : 'See less',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: 10.h),
              for (var i = 0; i < visible.length; i++) ...[
                if (i > 0) SizedBox(height: 8.h),
                PrizeRow(summary: visible[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class PrizeRow extends StatelessWidget {
  final WinnerClaimSummary summary;

  const PrizeRow({super.key, required this.summary});

  String get _label {
    if (summary.paid) return 'Paid';
    switch (summary.claimStatus) {
      case 'approved':
        return 'Transfer submitted';
      case 'pending':
        return 'Awaiting approval';
      case 'expired':
        return summary.canClaim ? 'Expired · reclaim' : 'Expired';
      default:
        return 'Claim available';
    }
  }

  Color get _color {
    if (summary.paid) return AppColors.correct;
    switch (summary.claimStatus) {
      case 'approved':
        return AppColors.secondary;
      case 'pending':
        return AppColors.accent;
      case 'expired':
        return AppColors.textMuted;
      default:
        return LeaderboardPalette.gold;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Week of ${summary.weekId}, rank ${summary.rank}, '
          '${PrizePoolService.formatExact(summary.share)}, $_label',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PayoutClaimPage(weekId: summary.weekId),
            ),
          ),
          child: Container(
            padding:
                EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Week of ${summary.weekId} · Rank #${summary.rank}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12.sp,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2.h),
                      // The actual figure, not an abbreviation: this is money
                      // the player can claim.
                      Text(
                        '${PrizePoolService.formatExact(summary.share)} · $_label',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _color,
                          fontSize: 11.sp,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded,
                    color: AppColors.textMuted, size: 13.r),
              ],
            ),
          ),
        ),
      ),
    );
  }
}