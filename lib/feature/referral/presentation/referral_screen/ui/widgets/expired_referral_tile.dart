import 'package:flutter/material.dart';

import '../../../../../../core/theme/app_theme.dart';

/// One invitee who never met the gate before the 2-day deadline.
class ExpiredReferralTile extends StatelessWidget {
  final String? inviteeUsername;
  final int quizzesCompleted;
  final int quizzesRequired;

  const ExpiredReferralTile({
    super.key,
    required this.inviteeUsername,
    required this.quizzesCompleted,
    required this.quizzesRequired,
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
                inviteeUsername ?? 'A friend',
                style: AppTypography.titleMedium.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: 2),
              Text(
                'Stopped at $quizzesCompleted/$quizzesRequired quizzes',
                style: AppTypography.bodySmall,
              ),
            ],
          ),
        ),
        Text('Expired', style: AppTypography.labelSmall),
      ],
    );
  }
}
