import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../../core/constants/referral_economy.dart';
import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_card.dart';

/// Totals for the Referrals page: rewarded, coins earned and pending, plus
/// the rolling 30-day cap usage.
class ReferralStatsCard extends StatelessWidget {
  final int pendingCount;
  final int rewardedCount;
  final int coinsEarned;
  final int rewardedInWindow;

  const ReferralStatsCard({
    super.key,
    required this.pendingCount,
    required this.rewardedCount,
    required this.coinsEarned,
    required this.rewardedInWindow,
  });

  @override
  Widget build(BuildContext context) {
    final capProgress =
        (rewardedInWindow / kReferralMonthlyCap).clamp(0.0, 1.0);
    final capFull = rewardedInWindow >= kReferralMonthlyCap;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatTile(value: '$rewardedCount', label: 'Rewarded'),
              _StatTile(value: '$coinsEarned', label: 'AC earned'),
              _StatTile(value: '$pendingCount', label: 'Pending'),
            ],
          ),
          SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Text('Last 30 days', style: AppTypography.bodySmall),
              const Spacer(),
              Text(
                '$rewardedInWindow/$kReferralMonthlyCap',
                style: AppTypography.labelLarge.copyWith(
                  color: capFull ? AppColors.wrong : AppColors.textSecondary,
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(6.r),
            child: LinearProgressIndicator(
              value: capProgress,
              minHeight: 6,
              backgroundColor: AppColors.divider,
              color: capFull ? AppColors.wrong : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String value;
  final String label;

  const _StatTile({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: AppTypography.heading3),
          ),
          SizedBox(height: AppSpacing.xs),
          Text(label, textAlign: TextAlign.center, style: AppTypography.bodySmall),
        ],
      ),
    );
  }
}
