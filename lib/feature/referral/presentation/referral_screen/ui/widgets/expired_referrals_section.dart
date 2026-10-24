import 'package:flutter/material.dart';

import '../../../../../../core/theme/app_theme.dart';
import '../../../../data/model/referral_entry.dart';
import 'expired_referral_tile.dart';
import 'referral_section_card.dart';

/// Invitees who never met the gate before their 2-day deadline. Rows waiting
/// on the referral cap are NOT here — see [PendingReferralsSection].
class ExpiredReferralsSection extends StatelessWidget {
  final List<ReferralEntry> entries;

  const ExpiredReferralsSection({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    return ReferralSectionCard(
      title: 'Expired',
      count: entries.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, entry) in entries.indexed) ...[
            if (index > 0)
              const Divider(
                height: 24,
                thickness: 1,
                color: AppColors.divider,
              ),
            ExpiredReferralTile(
              inviteeUsername: entry.inviteeUsername,
              quizzesCompleted: entry.quizzesCompleted,
              quizzesRequired: entry.quizzesRequired,
            ),
          ],
        ],
      ),
    );
  }
}
