import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../../core/constants/referral_economy.dart';
import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_button.dart';
import '../../../../../../core/widgets/app_card.dart';
import '../../../../../../core/widgets/app_sheet.dart';
import '../../../../data/model/referral_cashout.dart';

/// The referral cashout milestone card.
///
/// Deliberately NEVER prints the qualifying count or the target: the bar moves
/// on an easing curve (fast at first, slow near the end) and the exact
/// conditions live in the Terms of Service. The server is the only authority
/// on whether a claim is allowed.
class ReferralCashoutCard extends StatelessWidget {
  final ReferralCashoutState state;

  /// True while the claim doc is being read. The CTA is withheld until the
  /// state is known, so a fully qualified player never sees a Claim button
  /// that would immediately change to "already submitted".
  final bool claimLoading;

  final VoidCallback onClaim;

  const ReferralCashoutCard({
    super.key,
    required this.state,
    this.claimLoading = false,
    required this.onClaim,
  });

  @override
  Widget build(BuildContext context) {
    final claim = state.claim;
    final unlocked = state.canClaim;

    return AppCard(
      tier: AppCardTier.elevated,
      accentColor: claim?.isPaid == true ? AppColors.correct : AppColors.primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34.r,
                height: 34.r,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.savings_rounded,
                  color: AppColors.readable(AppColors.primary),
                  size: 18.r,
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Cash out ₦${_formatNaira(kReferralCashoutAmountNaira)}',
                  style: AppTypography.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'About this cashout',
                onPressed: () => _showInfo(context),
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.info_outline_rounded,
                  color: AppColors.textMuted,
                  size: 18.r,
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm),
          Text(
            'Invite friends. When enough of them buy a leaderboard entry on '
            'their own account, your cashout unlocks.',
            style: AppTypography.bodySmall,
          ),
          SizedBox(height: AppSpacing.md),

          // The bar. No numbers, no target — just motion on a curve that slows
          // down as it approaches the milestone.
          ClipRRect(
            borderRadius: BorderRadius.circular(8.r),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: state.progress),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value.clamp(0.0, 1.0),
                minHeight: 9.r,
                backgroundColor: AppColors.divider,
                color: AppColors.primary,
                semanticsLabel: 'Referral cashout progress',
                semanticsValue: '${(value * 100).round()}%',
              ),
            ),
          ),
          SizedBox(height: AppSpacing.md),

          if (claimLoading)
            Row(
              children: [
                SizedBox(
                  width: 14.r,
                  height: 14.r,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.readable(AppColors.primary),
                  ),
                ),
                SizedBox(width: AppSpacing.sm),
                Text(
                  'Checking your cashout…',
                  style: AppTypography.bodySmall,
                ),
              ],
            )
          else if (claim == null)
            unlocked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Cashout unlocked',
                        style: AppTypography.labelLarge.copyWith(
                          color: AppColors.correct,
                        ),
                      ),
                      SizedBox(height: AppSpacing.sm),
                      AppButton(
                        label:
                            'Claim ₦${_formatNaira(kReferralCashoutAmountNaira)}',
                        onPressed: onClaim,
                        icon: Icon(
                          Icons.account_balance_rounded,
                          size: 17.r,
                        ),
                      ),
                    ],
                  )
                : Text(
                    'Every friend who joins with your code and buys an entry '
                    'moves this bar.',
                    style: AppTypography.bodySmall.copyWith(
                      color: AppColors.textMuted,
                    ),
                  )
          else if (claim.isPending)
            _StatusLine(
              icon: Icons.hourglass_top_rounded,
              color: AppColors.amber,
              title: 'Claim submitted',
              message:
                  'Your claim for ₦${_formatNaira(claim.amount)} is under review.',
            )
          else if (claim.isPaid)
            _StatusLine(
              icon: Icons.check_circle_rounded,
              color: AppColors.correct,
              title: '₦${_formatNaira(claim.amount)} paid',
              message: 'Check your account for confirmation.',
            )
          else
            _StatusLine(
              icon: Icons.cancel_rounded,
              color: AppColors.wrong,
              title: 'Claim rejected',
              message: claim.rejectionReason == null ||
                      claim.rejectionReason!.isEmpty
                  ? 'Contact support if you think this is a mistake.'
                  : claim.rejectionReason!,
            ),
        ],
      ),
    );
  }

  Future<void> _showInfo(BuildContext context) {
    return showAppSheet<void>(
      context,
      builder: (_) => AppSheet(
        title: 'About this cashout',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Invite friends with your referral code. Friends count once '
              'they have signed up with your code and completed the required '
              'action on their own account.',
              style: AppTypography.bodyMedium,
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              'The bar shows your progress. When it is full you can submit '
              'a claim.',
              style: AppTypography.bodySmall,
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              'When the bar is full you can claim '
              '₦${_formatNaira(kReferralCashoutAmountNaira)}. The full conditions '
              'are in the Terms of Service.',
              style: AppTypography.bodySmall,
            ),
            SizedBox(height: AppSpacing.lg),
            AppButton(
              label: 'Got it',
              variant: AppButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String message;

  const _StatusLine({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.readable(color), size: 18.r),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTypography.labelLarge.copyWith(
                  color: AppColors.readable(color),
                ),
              ),
              SizedBox(height: 2.h),
              Text(message, style: AppTypography.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatNaira(int amount) {
  final digits = amount.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
