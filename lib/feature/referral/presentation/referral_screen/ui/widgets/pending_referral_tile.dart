import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../../core/theme/app_theme.dart';

/// One invitee who has not finished qualifying yet.
///
/// [capWaiting] is true once the invitee met the gate but the inviter's
/// 30-day cap is full — that row must never read as expired.
class PendingReferralTile extends StatelessWidget {
  final String? inviteeUsername;
  final int quizzesCompleted;
  final int quizzesRequired;
  final int quizDays;
  final int daysRequired;
  final DateTime? expiresAt;
  final bool capWaiting;

  const PendingReferralTile({
    super.key,
    required this.inviteeUsername,
    required this.quizzesCompleted,
    required this.quizzesRequired,
    required this.quizDays,
    required this.daysRequired,
    required this.expiresAt,
    required this.capWaiting,
  });

  @override
  Widget build(BuildContext context) {
    final expiryLabel = _expiryLabel(expiresAt);
    final quizProgress =
        (quizzesCompleted / quizzesRequired).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                inviteeUsername ?? 'A friend',
                style: AppTypography.titleMedium.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!capWaiting && expiryLabel != null)
              Text(expiryLabel, style: AppTypography.labelSmall),
          ],
        ),
        SizedBox(height: 2.h),
        Text(
          capWaiting
              ? 'Qualified · waiting for monthly cap'
              : '$quizzesCompleted/$quizzesRequired quizzes · '
                  'day $quizDays/$daysRequired',
          style: AppTypography.bodySmall,
        ),
        if (!capWaiting) ...[
          SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(4.r),
            child: LinearProgressIndicator(
              value: quizProgress,
              minHeight: 4,
              backgroundColor: AppColors.divider,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

String? _expiryLabel(DateTime? expiresAt) {
  if (expiresAt == null) return null;
  final remaining = expiresAt.difference(DateTime.now());
  if (remaining.isNegative) return 'expires today';
  final days = (remaining.inHours / 24).ceil();
  return 'expires in ${days}d';
}
