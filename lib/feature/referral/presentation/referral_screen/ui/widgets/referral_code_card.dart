import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../../core/constants/referral_economy.dart';
import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_button.dart';
import '../../../../../../core/widgets/app_card.dart';

/// Your referral code with copy and share.
class ReferralCodeCard extends StatelessWidget {
  final String code;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  const ReferralCodeCard({
    super.key,
    required this.code,
    required this.onCopy,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final hasCode = code.isNotEmpty;

    return AppCard(
      tier: AppCardTier.elevated,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your code', style: AppTypography.labelMedium),
          SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  hasCode ? code : '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.heading3.copyWith(letterSpacing: 1.2),
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                onPressed: hasCode ? onCopy : null,
                icon: Icon(
                  Icons.copy_rounded,
                  color: hasCode ? AppColors.textSecondary : AppColors.textMuted,
                  size: 20.r,
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.xs),
          Text(
            'You earn +$kReferralReferrerReward AC, your friend +$kReferralRefereeReward AC.',
            style: AppTypography.bodySmall,
          ),
          SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: 'Share code',
              icon: const Icon(Icons.share_rounded),
              onPressed: hasCode ? onShare : null,
            ),
          ),
        ],
      ),
    );
  }
}
