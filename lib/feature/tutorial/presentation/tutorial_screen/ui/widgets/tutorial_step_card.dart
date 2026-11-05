import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_card.dart';

/// Icon + title + body + bullets for one tutorial page.
///
/// Pure content widget — paging, dots and CTA live in the screen so this
/// stays identical for first-run and replay.
class TutorialStepCard extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String body;
  final List<String> bullets;

  const TutorialStepCard({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.body,
    required this.bullets,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: AppCardTier.elevated,
      accentColor: accent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44.r,
            height: 44.r,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Icon(icon, color: accent, size: 22.r),
          ),
          SizedBox(height: AppSpacing.md),
          Text(title, style: AppTypography.heading3),
          SizedBox(height: AppSpacing.sm),
          Text(body, style: AppTypography.bodyMedium),
          if (bullets.isNotEmpty) ...[
            SizedBox(height: AppSpacing.md),
            for (final bullet in bullets)
              Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 5.h),
                      child: Container(
                        width: 6.r,
                        height: 6.r,
                        decoration: BoxDecoration(
                          color: accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    SizedBox(width: 10.w),
                    Expanded(
                      child: Text(
                        bullet,
                        style: AppTypography.bodyMedium.copyWith(
                          color: AppColors.textPrimary,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
