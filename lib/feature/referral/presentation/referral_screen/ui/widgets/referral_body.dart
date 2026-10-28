import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../../core/constants/referral_economy.dart';
import '../../../../../../core/constants/share_links.dart';
import '../../../../../../core/services/share_service.dart';
import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_button.dart';
import '../../../../../../core/widgets/app_empty_state.dart';
import '../../../../../../core/widgets/share_card.dart';
import '../../../../data/model/referral_cashout.dart';
import '../../../../data/model/referral_entry.dart';
import 'expired_referrals_section.dart';
import 'pending_referrals_section.dart';
import 'referral_cashout_card.dart';
import 'referral_cashout_sheet.dart';
import 'referral_code_card.dart';
import 'referral_stats_card.dart';
import 'rewarded_referrals_section.dart';

/// Content of the referral screen: code card, totals, then the pending /
/// rewarded / expired referral sections.
class ReferralBody extends StatelessWidget {
  final Future<List<ReferralEntry>> entriesFuture;

  /// The inviter's short invite code, loaded separately from the entries so a
  /// slow mint never blocks the list.
  final Future<String> codeFuture;

  /// The player's own cashout claim (null when none was submitted), loaded
  /// separately so the card can render before the list resolves.
  final Future<ReferralCashoutClaim?> cashoutFuture;

  final Future<void> Function() onRefresh;

  const ReferralBody({
    super.key,
    required this.entriesFuture,
    required this.codeFuture,
    required this.cashoutFuture,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ReferralEntry>>(
      future: entriesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }
        if (snapshot.hasError) {
          return AppEmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load referrals',
            message: 'Check your connection and try again.',
            action: AppButton(label: 'Try again', onPressed: onRefresh),
          );
        }

        final entries = snapshot.data ?? const <ReferralEntry>[];
        final now = DateTime.now();

        final pending = <ReferralEntry>[];
        final rewarded = <ReferralEntry>[];
        final expired = <ReferralEntry>[];
        for (final entry in entries) {
          if (entry.isRewarded) {
            rewarded.add(entry);
          } else if (entry.isExpiredAt(now)) {
            expired.add(entry);
          } else {
            pending.add(entry);
          }
        }
        pending.sort((a, b) => _dateDesc(a.createdAt, b.createdAt));
        rewarded.sort((a, b) => _dateDesc(a.rewardedAt, b.rewardedAt));
        expired.sort((a, b) => _dateDesc(a.expiresAt, b.expiresAt));

        final cutoff = now.subtract(kReferralRollingWindow);
        final coinsEarned = rewarded.fold<int>(
          0,
          (sum, entry) => sum + entry.rewardAmount,
        );
        final rewardedInWindow = rewarded
            .where((entry) => entry.rewardedAt?.isAfter(cutoff) ?? false)
            .length;
        final qualifiedForCashout = entries
            .where((entry) => entry.leaderboardEntryPurchased)
            .length;

        return RefreshIndicator(
          color: AppColors.primary,
          backgroundColor: AppColors.surface,
          onRefresh: onRefresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
            children: [
              FutureBuilder<String>(
                future: codeFuture,
                builder: (context, codeSnap) {
                  // While the mint is in flight (or failed) the code is '',
                  // and ReferralCodeCard disables copy/share for it.
                  final code = codeSnap.data ?? '';
                  return ReferralCodeCard(
                    code: code,
                    onCopy: () => _copyCode(context, code),
                    onShare: () => _shareCode(context, code),
                  );
                },
              ),
              SizedBox(height: AppSpacing.lg),

              // Cashout milestone. Rendered above the list (and even when the
              // player has no referrals yet) because it is the page's headline
              // promise. The bar never shows a target or a count.
              FutureBuilder<ReferralCashoutClaim?>(
                future: cashoutFuture,
                builder: (context, claimSnap) {
                  final state = ReferralCashoutState(
                    qualifiedCount: qualifiedForCashout,
                    claim: claimSnap.data,
                  );
                  return ReferralCashoutCard(
                    state: state,
                    claimLoading:
                        claimSnap.connectionState == ConnectionState.waiting,
                    onClaim: () => _openCashoutClaim(context, state),
                  );
                },
              ),

              if (entries.isEmpty)
                const _NoReferralsState()
              else ...[
                const SizedBox(height: AppSpacing.lg),
                ReferralStatsCard(
                  pendingCount: pending.length,
                  rewardedCount: rewarded.length,
                  coinsEarned: coinsEarned,
                  rewardedInWindow: rewardedInWindow,
                ),
                const SizedBox(height: AppSpacing.lg),
                PendingReferralsSection(entries: pending),
                const SizedBox(height: AppSpacing.lg),
                RewardedReferralsSection(entries: rewarded),
                if (expired.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  ExpiredReferralsSection(entries: expired),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _openCashoutClaim(
    BuildContext context,
    ReferralCashoutState state,
  ) async {
    final submitted = await showReferralCashoutSheet(context, state: state);
    if (submitted != true || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Cashout claim submitted. You will be notified on status change.'),
      ),
    );
    await onRefresh();
  }

  Future<void> _copyCode(BuildContext context, String code) {
    return ShareService.instance.copyText(
      context,
      code,
      message: 'Referral code copied!',
    );
  }

  Future<void> _shareCode(BuildContext context, String code) async {
    await ShareService.instance.shareCard(
      context,
      card: ShareCard.forReferral(code),
      logicalSize: kShareCardSize,
      fileName: 'animequiz-referral-card',
      text: referralShareMessage(code),
      subject: 'Join me on AnimeQuiz',
    );
  }
}

// ─── Empty state ───────────────────────────────────────────────────────────
class _NoReferralsState extends StatelessWidget {
  const _NoReferralsState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 48.h),
      child: Column(
        children: [
          Icon(
            Icons.group_add_rounded,
            color: AppColors.textMuted,
            size: 40.r,
          ),
          SizedBox(height: AppSpacing.lg),
          Text('No referrals yet', style: AppTypography.titleMedium),
        ],
      ),
    );
  }
}

int _dateDesc(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}
