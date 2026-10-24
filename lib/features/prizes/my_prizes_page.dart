// lib/features/prizes/my_prizes_page.dart
//
// "My Prizes" — a winner's own payout history, newest week first.
//
// Moved off the Rankings page: a leaderboard explains who is winning, while a
// player's own winnings belong with their account. Reached from
// Profile → My Prizes (the gold button under the Redeem Code card).
//
// Only cycles where the signed-in player appears in the server's `ranked[]`
// snapshot are shown; nothing here is computed client-side, and "Paid" appears
// only when `ranked[].paid == true`. Tapping a card opens the claim screen for
// that week. The prize amount always comes from the server's stored `share`.
//
// Layout follows the rest of the app: a gradient hero mirroring the weekly
// PrizePoolCard (headline figure over a two-column stat strip), the
// LeaderboardSectionHeader-style list header, and `AppCard` rows with a gold
// accent for prizes that still need the player to act.
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/services/firestore_service.dart';
import '../../core/services/prize_pool_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_empty_state.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/app_skeleton.dart';
import '../../core/widgets/shared_widgets.dart' show SectionHeader;
import '../../core/widgets/weekly_points_pill.dart';
import '../leaderboard/weekly_leaderboard_page.dart';
import 'payout_claim_page.dart';
import 'winner_announcement_page.dart';

/// Medal colour for a 1-based weekly rank. Ranks outside the podium stay
/// neutral so a top-10 finish never reads as a podium finish.
Color _rankColor(int rank) => switch (rank) {
      1 => AppColors.gold,
      2 => AppColors.silver,
      3 => AppColors.bronze,
      _ => AppColors.textMuted,
    };

/// Week ids are the server's Monday date strings ("2025-05-19"). The UI shows
/// the month and day only — the year is noise in a history that spans weeks,
/// and the raw ISO string reads like a database key.
const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _weekLabel(String weekId) {
  final parts = weekId.split('-');
  if (parts.length != 3) return weekId;
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (month == null || day == null || month < 1 || month > 12) {
    return weekId;
  }
  return '${_months[month - 1]} $day';
}

/// Server-derived display state for one prize row. The label never claims more
/// than the server knows: `paid` is the only "Paid" source, `marked` means the
/// admin recorded the transfer, `pending` is a submitted-but-unsent claim, and
/// `expired` is a forfeited share (the 3-day window has closed, so no reclaim).
class _PrizeStatus {
  final String label;
  final Color color;
  final IconData icon;

  const _PrizeStatus(this.label, this.color, this.icon);

  factory _PrizeStatus.of(WinnerClaimSummary s) {
    if (s.paid) {
      return const _PrizeStatus(
          'Paid', AppColors.correct, Icons.check_circle_rounded);
    }
    // `ranked[]` carries every entrant, and only the paid places get a
    // non-zero share. A rank outside the top five is still listed here, but it
    // must never read as claimable money — the claim screen shows the same
    // "no prize this week" outcome.
    if (s.share <= 0) {
      return const _PrizeStatus(
          'No prize', AppColors.textMuted, Icons.remove_circle_outline_rounded);
    }
    switch (s.claimStatus) {
      case 'marked':
        return const _PrizeStatus(
            'Transfer sent', AppColors.secondary, Icons.local_shipping_rounded);
      case 'pending':
        return const _PrizeStatus(
            'Awaiting payment', AppColors.accent, Icons.hourglass_top_rounded);
      case 'expired':
        return const _PrizeStatus('Expired · forfeited', AppColors.textMuted,
            Icons.event_busy_rounded);
      default:
        return const _PrizeStatus(
            'Claim available', AppColors.gold, Icons.redeem_rounded);
    }
  }
}

class MyPrizesPage extends StatefulWidget {
  const MyPrizesPage({super.key});

  @override
  State<MyPrizesPage> createState() => _MyPrizesPageState();
}

class _MyPrizesPageState extends State<MyPrizesPage> {
  late Future<List<WinnerClaimSummary>> _future;
  late Future<LastWeekResult?> _announcementFuture;

  @override
  void initState() {
    super.initState();
    _future = FirestoreService.instance.getMyWinnerCycles();
    _announcementFuture = FirestoreService.instance.getLastWeekWinners();
  }

  /// Pull-to-refresh: re-runs the query so a payout the admin just approved
  /// becomes visible without a restart. `getMyWinnerCycles` already degrades to
  /// an empty list on failure, so there is nothing to surface here.
  Future<void> _reload() async {
    final future = FirestoreService.instance.getMyWinnerCycles();
    final announcement = FirestoreService.instance.getLastWeekWinners();
    setState(() {
      _future = future;
      _announcementFuture = announcement;
    });
    try {
      await future;
    } catch (_) {
      // Rendered as the empty state; swallowed so it never escapes as an
      // unhandled async error.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text(
          'My Prizes',
          style: AppTypography.titleLarge.copyWith(fontWeight: FontWeight.w900),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 12.r),
            child: const WeeklyPointsPill(),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<WinnerClaimSummary>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const _PrizesSkeleton();
            }
            final cycles = snap.data ?? const <WinnerClaimSummary>[];
            return RefreshIndicator(
              color: AppColors.primary,
              backgroundColor: AppColors.surface,
              onRefresh: _reload,
              child: cycles.isEmpty
                  ? _EmptyPrizes(announcementFuture: _announcementFuture)
                  : _PrizesList(
                      cycles: cycles,
                      announcementFuture: _announcementFuture,
                    ),
            );
          },
        ),
      ),
    );
  }
}

// ─── Non-empty body ─────────────────────────────────────────────────────────
class _PrizesList extends StatelessWidget {
  final List<WinnerClaimSummary> cycles;
  final Future<LastWeekResult?> announcementFuture;

  const _PrizesList({
    required this.cycles,
    required this.announcementFuture,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 32.r),
      children: [
        _AnnouncementLink(future: announcementFuture),
        _WinningsHero(cycles: cycles),
        SizedBox(height: 22.h),
        SectionHeader(title: 'Payout history'),
        SizedBox(height: 10.h),
        for (var i = 0; i < cycles.length; i++) ...[
          if (i > 0) SizedBox(height: 8.h),
          _PrizeCard(summary: cycles[i]),
        ],
        SizedBox(height: 16.h),
        const _ClaimDeadlineNote(),
      ],
    );
  }
}

// ─── Announcement link ──────────────────────────────────────────────────────
/// Entry point to [WinnerAnnouncementPage] for last week's winners — the same
/// page the Monday gate shows on launch, re-openable from here at any time.
/// Hidden while the fetch is pending or when there is no announcement yet.
class _AnnouncementLink extends StatelessWidget {
  const _AnnouncementLink({required this.future});

  final Future<LastWeekResult?> future;

  Future<void> _open(BuildContext context, LastWeekResult result) async {
    await Navigator.of(context).push<void>(
      AppPageRoute<void>(
        builder: (_) => WinnerAnnouncementPage(result: result),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LastWeekResult?>(
      future: future,
      builder: (context, snap) {
        final result = snap.data;
        if (result == null || result.winners.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: EdgeInsets.only(bottom: 14.h),
          child: Semantics(
            button: true,
            label: "Last week's champions announcement",
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.xl),
              child: Ink(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.gold.withValues(alpha: 0.10),
                      AppColors.gold.withValues(alpha: 0.03),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(AppRadii.xl),
                  border: Border.all(
                    color: AppColors.gold.withValues(alpha: 0.30),
                  ),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadii.xl),
                  onTap: () => _open(context, result),
                  child: Padding(
                    padding: EdgeInsets.all(14.r),
                    child: Row(
                      children: [
                        const _IconTile(
                          icon: Icons.campaign_rounded,
                          color: AppColors.gold,
                        ),
                        SizedBox(width: 12.w),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                "Last week's champions",
                                style: AppTypography.titleMedium.copyWith(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14.sp,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              SizedBox(height: 3.h),
                              Text(
                                'Last week',
                                style: AppTypography.labelMedium.copyWith(
                                  color: AppColors.textMuted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8.w),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: AppColors.gold,
                          size: 20.r,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Winnings hero ──────────────────────────────────────────────────────────
/// The account-level summary: how much is still owed to the player, with
/// paid/won counters underneath.
///
/// Only server fields are used — `share` is the stored prize amount, `paid`
/// the stored transfer flag, and a share is "outstanding" only while it is
/// unpaid, non-zero and not forfeited. A zero-share row (ranked past the paid
/// places) never inflates the totals.
class _WinningsHero extends StatelessWidget {
  final List<WinnerClaimSummary> cycles;

  const _WinningsHero({required this.cycles});

  @override
  Widget build(BuildContext context) {
    final outstandingRows = cycles
        .where((c) => !c.paid && c.share > 0 && c.claimStatus != 'expired')
        .toList();
    final outstanding =
        outstandingRows.fold<double>(0, (sum, c) => sum + c.share);

    final paidTotal = cycles
        .where((c) => c.paid && c.share > 0)
        .fold<double>(0, (sum, c) => sum + c.share);

    final wonCount = cycles.where((c) => c.share > 0).length;

    return Container(
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: AppColors.cardGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(
            color: AppColors.gold.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconTile(
                icon: Icons.emoji_events_rounded,
                color: AppColors.gold,
                size: 34,
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Text(
                  'PRIZE WINNINGS',
                  style: AppTypography.labelSmall.copyWith(
                    fontSize: 10.sp,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              // Same "cycle tag" treatment the weekly PrizePoolCard uses, so
              // the two money screens read as one family.
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6.r),
                ),
                child: Text(
                  'PAID MANUALLY',
                  style: AppTypography.labelSmall.copyWith(
                    fontSize: 9.sp,
                    letterSpacing: 0.6,
                    color: AppColors.secondary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 16.h),
          Text(
            'AWAITING PAYOUT',
            style: AppTypography.labelSmall.copyWith(
              fontSize: 10.sp,
              letterSpacing: 1.1,
            ),
          ),
          SizedBox(height: 4.h),
          // The real figure, never abbreviated: this is money the player can
          // still be paid.
          Text(
            PrizePoolService.formatExact(outstanding),
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
              color: AppColors.textPrimary,
              fontSize: 32.sp,
              fontWeight: FontWeight.w900,
              height: 1.0,
              letterSpacing: -1.0,
            ),
          ),
          if (outstanding > 0) ...[
            SizedBox(height: 6.h),
            Text(
              outstandingRows.length == 1
                  ? '1 weekly prize is still to be sent to your bank.'
                  : '${outstandingRows.length} weekly prizes are still to be '
                      'sent to your bank.',
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.textMuted,
                fontSize: 11.5.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          SizedBox(height: 16.h),
          const Divider(height: 1, color: AppColors.divider),
          SizedBox(height: 14.h),
          Row(
            children: [
              Expanded(
                child: _HeroStat(
                  label: 'PRIZES WON',
                  value: '$wonCount',
                ),
              ),
              Container(
                width: 1,
                height: 30.h,
                color: AppColors.divider,
              ),
              Expanded(
                child: _HeroStat(
                  label: 'PAID TO YOU',
                  value: PrizePoolService.formatExact(paidTotal),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  final String label;
  final String value;

  const _HeroStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTypography.labelSmall.copyWith(
            fontSize: 9.5.sp,
            letterSpacing: 0.9,
          ),
        ),
        SizedBox(height: 5.h),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.titleMedium.copyWith(
            fontWeight: FontWeight.w900,
            fontSize: 15.sp,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}

// ─── One prize ──────────────────────────────────────────────────────────────
class _PrizeCard extends StatelessWidget {
  final WinnerClaimSummary summary;

  const _PrizeCard({required this.summary});

  void _open(BuildContext context) {
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => PayoutClaimPage(weekId: summary.weekId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _PrizeStatus.of(summary);
    final rankColor = _rankColor(summary.rank);
    final amount = PrizePoolService.formatExact(summary.share);
    // Gold accent only where the player still has something to do: it is the
    // one visual signal that separates "act on this" from "already settled".
    final actionable = summary.canClaim && summary.share > 0;

    return Semantics(
      button: true,
      label: 'Week of ${_weekLabel(summary.weekId)}, rank ${summary.rank}, '
          '$amount, ${status.label}',
      child: AppCard(
        onTap: () => _open(context),
        padding: EdgeInsets.all(12.r),
        radius: BorderRadius.circular(AppRadii.lg),
        accentColor: actionable ? AppColors.gold : null,
        child: Row(
          children: [
            _RankMedal(rank: summary.rank, color: rankColor),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    amount,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.titleMedium.copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: 16.sp,
                      letterSpacing: -0.2,
                      // A settled row steps back so unpaid prizes lead the eye.
                      color: summary.paid
                          ? AppColors.textSecondary
                          : AppColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 3.h),
                  Text(
                    'Week of ${_weekLabel(summary.weekId)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.labelMedium.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 10.w),
            _StatusChip(status: status),
          ],
        ),
      ),
    );
  }
}

/// Rank disc: "#3" over a "RANK" caption, tinted with the medal colour.
class _RankMedal extends StatelessWidget {
  final int rank;
  final Color color;

  const _RankMedal({required this.rank, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46.r,
      height: 46.r,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '#$rank',
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
              color: color,
              fontSize: 13.sp,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
          Text(
            'RANK',
            style: TextStyle(
              fontFamily: AppTypography.fontFamily,
              color: AppColors.textMuted,
              fontSize: 7.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final _PrizeStatus status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 5.r),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(color: status.color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, color: status.color, size: 11.r),
          SizedBox(width: 4.w),
          Text(
            status.label,
            style: AppTypography.labelSmall.copyWith(
              color: status.color,
              fontSize: 9.5.sp,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Shared little pieces ───────────────────────────────────────────────────
class _IconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _IconTile({required this.icon, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size.r,
      height: size.r,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: (size * 0.52).r),
    );
  }
}

// ─── Deadline note ──────────────────────────────────────────────────────────
class _ClaimDeadlineNote extends StatelessWidget {
  const _ClaimDeadlineNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              color: AppColors.secondary, size: 15.r),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              'Claim within 3 days of the week closing — after that your share '
              'is forfeited.',
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.textSecondary,
                fontSize: 11.sp,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Loading skeleton ───────────────────────────────────────────────────────
/// Mirrors the loaded layout (hero + a few rows) so the screen does not jump
/// when the data lands.
class _PrizesSkeleton extends StatelessWidget {
  const _PrizesSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 32.r),
      children: [
        AppSkeleton(height: 168.h, radius: AppRadii.xl),
        SizedBox(height: 22.h),
        AppSkeleton(width: 140.w, height: 18.h, radius: AppRadii.sm),
        SizedBox(height: 10.h),
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) SizedBox(height: 8.h),
          AppSkeleton(height: 72.h, radius: AppRadii.lg),
        ],
      ],
    );
  }
}

// ─── Empty state ────────────────────────────────────────────────────────────
class _EmptyPrizes extends StatelessWidget {
  const _EmptyPrizes({required this.announcementFuture});

  final Future<LastWeekResult?> announcementFuture;

  @override
  Widget build(BuildContext context) {
    // Scrollable so the RefreshIndicator still works with nothing to show.
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0),
          sliver: SliverToBoxAdapter(
            child: _AnnouncementLink(future: announcementFuture),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: AppEmptyState(
            icon: Icons.emoji_events_outlined,
            color: AppColors.gold,
            title: 'No prizes yet',
            message: 'Finish in the paid ranks of a weekly leaderboard and '
                'your winnings will appear here, ready to claim.',
            action: AppButton(
              label: 'View weekly rankings',
              variant: AppButtonVariant.outline,
              color: AppColors.gold,
              icon: const Icon(Icons.leaderboard_rounded),
              onPressed: () => Navigator.of(context).push(
                AppPageRoute(builder: (_) => const WeeklyLeaderboardPage()),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
