import 'package:flutter/material.dart';

import '../../../../../../core/theme/app_theme.dart';
import '../../../../data/model/referral_entry.dart';
import 'referral_section_card.dart';
import 'rewarded_referral_tile.dart';

/// Every referral that already paid out, newest first.
class RewardedReferralsSection extends StatelessWidget {
  final List<ReferralEntry> entries;

  const RewardedReferralsSection({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    return ReferralSectionCard(
      title: 'Rewarded',
      count: entries.length,
      child: entries.isEmpty
          ? Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text('No rewards yet.', style: AppTypography.bodySmall),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, entry) in entries.indexed) ...[
                  if (index > 0)
                    const Divider(
                      height: AppSpacing.lg,
                      thickness: 1,
                      color: AppColors.divider,
                    ),
                  RewardedReferralTile(
                    inviteeUsername: entry.inviteeUsername,
                    isLegacy: entry.isLegacy,
                    rewardedAt: entry.rewardedAt,
                    rewardAmount: entry.rewardAmount,
                  ),
                ],
              ],
            ),
    );
  }
}
