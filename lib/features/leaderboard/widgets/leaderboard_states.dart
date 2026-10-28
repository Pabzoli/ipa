import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_empty_state.dart';
import 'leaderboard_sheets.dart' show showLeaderboardPurchaseSheet;

/// A labelled section divider used across the leaderboard tabs.
class LeaderboardSectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final String? trailing;

  const LeaderboardSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 26.r,
          height: 26.r,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8.r),
          ),
          child: Icon(icon, color: AppColors.readable(color), size: 15.r),
        ),
        SizedBox(width: 9.w),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.2,
            ),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }
}

/// The call to action that gets a non-entrant into the board.
///
/// On web this completes the payment inline through Flutterwave. On mobile the
/// in-app purchase path is not reachable, so it hands off to the hosted shop,
/// which previously meant the button did literally nothing at all: the handler
/// returned early on non-web platforms with no snackbar and no fallback, so a
/// tap on a very visible primary button produced zero feedback.
///
/// Both branches live here so there is exactly one CTA implementation and one
/// place to change if the distribution model does. The whole web/mobile split
/// is gated on [kLeaderboardAllowsExternalEntryLink], so a future Play Store
/// release is a one-line change.
class LeaderboardEntryCta extends StatelessWidget {
  final bool isBusy;

  /// Set when the player cannot buy right now (e.g. signed out), so the reason
  /// is explained rather than the tap failing silently.
  final String? disabledReason;

  const LeaderboardEntryCta({
    super.key,
    this.isBusy = false,
    this.disabledReason,
  });

  /// Web completes the payment inline. On mobile the hand-off to the hosted
  /// shop is only allowed while [kLeaderboardAllowsExternalEntryLink] is set
  /// (sideloaded APKs, which carry no Play billing obligation). A future Play
  /// build sets that flag false and this becomes the in-app path instead — the
  /// switch is actually read here, not just documented.
  bool get _usesExternalLink => !kIsWeb && kLeaderboardAllowsExternalEntryLink;

  String get _label =>
      _usesExternalLink ? kEntryCtaLabelExternal : kEntryCtaLabelWeb;

  @override
  Widget build(BuildContext context) {
    final blocked = disabledReason != null || isBusy;

    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: blocked ? null : () => _activate(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.surfaceAlt,
          disabledForegroundColor: AppColors.textMuted,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
        ),
        child: isBusy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_usesExternalLink) ...[
                    const Icon(Icons.open_in_new_rounded, size: 16),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      _label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _activate(BuildContext context) async {
    if (disabledReason != null) {
      _snack(context, disabledReason!);
      return;
    }

    if (_usesExternalLink) {
      await _openShop(context);
      return;
    }

    if (kIsWeb) {
      await showLeaderboardPurchaseSheet(context);
      return;
    }

    // Non-web build with the external link switched off (a Play Store build):
    // nothing here can complete a purchase yet, so say so plainly instead of
    // opening a page that cannot finish the job.
    _snack(
      context,
      'Leaderboard entries are not available in this version. Redeem an entry '
      'code under Profile → Redeem Code.',
    );
  }

  /// Hands the player to the hosted shop in an external browser, so they return
  /// to the app afterwards rather than being stranded in an in-app web view.
  Future<void> _openShop(BuildContext context) async {
    // Captured before the await so the confirmation still has a messenger if
    // this State has since been disposed.
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(kShopUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          opened
              ? kEntryCtaExternalHint
              : 'Could not open the shop. Please visit our website to buy an '
                  'entry.',
          style: const TextStyle(fontFamily: 'Nunito'),
        ),
        backgroundColor: opened ? null : AppColors.wrong,
      ),
    );
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontFamily: 'Nunito')),
        backgroundColor: AppColors.wrong,
      ),
    );
  }
}

/// The empty board.
///
/// An empty cohort means different things to different people: for the admin,
/// or the first entrant, nobody has entered yet. For someone who has not paid,
/// it means they have not paid. Showing "no players yet" to the second group
/// was the old behaviour, and the pay-to-enter explanation is far more useful
/// to them.
class BoardEmptyState extends StatelessWidget {
  final bool isEligible;
  final bool isAdmin;
  final Widget cta;

  const BoardEmptyState({
    super.key,
    required this.isEligible,
    required this.isAdmin,
    required this.cta,
  });

  @override
  Widget build(BuildContext context) {
    if (isEligible || isAdmin) {
      return const AppEmptyState(
        icon: Icons.emoji_events_outlined,
        title: 'No players yet',
      );
    }

    return SingleChildScrollView(
      // Scrollable: on a short screen the icon, copy and CTA exceed the
      // remaining viewport and previously produced a RenderFlex overflow.
      child: Padding(
        padding: EdgeInsets.fromLTRB(32.r, 24.r, 32.r, 32.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80.r,
              height: 80.r,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.divider),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.lock_outline_rounded,
                  color: AppColors.readable(AppColors.accent), size: 36.r),
            ),
            SizedBox(height: 16.h),
            Text(
              'Pay to enter the leaderboard',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6.h),
            Text(
              'Only paid players appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.sp,
                height: 1.4,
              ),
            ),
            SizedBox(height: 16.h),
            cta,
          ],
        ),
      ),
    );
  }
}

/// The hour between the weekly reset and the week-id rollover.
///
/// `weeklyReset` has already snapshotted and zeroed every player's points, but
/// `currentWeekId()` still names the closed cycle, so the board on screen would
/// show everyone on zero. Saying "closing" is the honest render: nothing can
/// change the result, and the numbers land on Monday.
class WeekClosingState extends StatelessWidget {
  const WeekClosingState({super.key});

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.hourglass_top_rounded,
      color: AppColors.readable(AppColors.accent),
      title: 'Week closing',
      message: 'Scores are locked for this week and results are published on '
          'Monday.',
    );
  }
}

/// The board failed to load.
///
/// Without this the Global tab fell through to "no players yet" on any query
/// failure, so a missing Firestore composite index, a revoked session and a
/// dropped connection all rendered as an empty leaderboard. That hides a real
/// config problem behind a reassuring lie.
class BoardErrorState extends StatelessWidget {
  final Object? error;
  final VoidCallback? onRetry;

  const BoardErrorState({super.key, this.error, this.onRetry});

  /// Firestore names the required composite index in the error for a query it
  /// cannot serve. Worth calling out explicitly, because the fix is a deploy,
  /// not something the player can do.
  bool get _looksLikeMissingIndex {
    final message = error?.toString().toLowerCase() ?? '';
    final mentionsIndex = message.contains('index');
    final looksLikeMissingDoc = message.contains('requires') ||
        message.contains('composite') ||
        message.contains('failed-precondition');
    return mentionsIndex && looksLikeMissingDoc;
  }

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: _looksLikeMissingIndex
          ? Icons.build_outlined
          : Icons.cloud_off_rounded,
      title: 'Could not load the leaderboard',
      color: AppColors.readable(AppColors.accent),
      message: _looksLikeMissingIndex
          ? 'This leaderboard needs a Firestore composite index before it can '
              'load. It has been reported - please try again shortly.'
          : 'Check your connection and try again.',
      action: onRetry == null
          ? null
          : SizedBox(
              height: 44,
              child: ElevatedButton(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                ),
                child: const Text(
                  'Try again',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
    );
  }
}

/// Centred spinner, for the brief states where nothing is known yet.
class BoardSpinner extends StatelessWidget {
  const BoardSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );
  }
}
