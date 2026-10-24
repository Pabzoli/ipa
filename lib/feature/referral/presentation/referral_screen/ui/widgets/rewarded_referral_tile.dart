import 'package:flutter/material.dart';

import '../../../../../../core/theme/app_theme.dart';

/// One paid-out referral. Legacy rows (pre-record payouts reconstructed from
/// the coin ledger) have no invitee identity and are labelled accordingly.
class RewardedReferralTile extends StatelessWidget {
  final String? inviteeUsername;
  final bool isLegacy;
  final DateTime? rewardedAt;
  final int rewardAmount;

  const RewardedReferralTile({
    super.key,
    required this.inviteeUsername,
    required this.isLegacy,
    required this.rewardedAt,
    required this.rewardAmount,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isLegacy ? 'Earlier referral' : (inviteeUsername ?? 'A friend'),
                style: AppTypography.titleMedium.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: 2),
              Text(_formatDate(rewardedAt), style: AppTypography.bodySmall),
            ],
          ),
        ),
        Text(
          '+$rewardAmount AC',
          style: AppTypography.titleMedium.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

String _formatDate(DateTime? date) {
  if (date == null) return '—';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = date.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}
