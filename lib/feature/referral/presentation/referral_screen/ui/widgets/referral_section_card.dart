import 'package:flutter/material.dart';

import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_card.dart';

/// Section shell used by the pending / rewarded / expired lists: the title,
/// a muted count, then the rows.
class ReferralSectionCard extends StatelessWidget {
  final String title;
  final int count;
  final Widget child;

  const ReferralSectionCard({
    super.key,
    required this.title,
    required this.count,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: AppTypography.titleMedium),
              ),
              Text(
                '$count',
                style: AppTypography.labelLarge.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}
