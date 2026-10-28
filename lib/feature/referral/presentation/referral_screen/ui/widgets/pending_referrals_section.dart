import 'package:flutter/material.dart';

import '../../../../../../core/theme/app_theme.dart';
import '../../../../data/model/referral_entry.dart';
import 'pending_referral_tile.dart';
import 'referral_section_card.dart';

/// Every invitee who has not finished qualifying (including rows waiting on
/// the inviter's 30-day referral cap).
class PendingReferralsSection extends StatelessWidget {
  final List<ReferralEntry> entries;

  const PendingReferralsSection({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    return ReferralSectionCard(
      title: 'Pending',
      count: entries.length,
      child: entries.isEmpty
          ? Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text('Nobody pending.', style: AppTypography.bodySmall),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, entry) in entries.indexed) ...[
                  if (index > 0) const _RowDivider(),
                  PendingReferralTile(
                    inviteeUsername: entry.inviteeUsername,
                    quizzesCompleted: entry.quizzesCompleted,
                    quizzesRequired: entry.quizzesRequired,
                    quizDays: entry.quizDays,
                    daysRequired: entry.daysRequired,
                    expiresAt: entry.expiresAt,
                    capWaiting: entry.isGateMet,
                  ),
                ],
              ],
            ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: AppSpacing.lg,
      thickness: 1,
      color: AppColors.divider,
    );
  }
}
