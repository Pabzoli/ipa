import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../theme/app_theme.dart';

class AppChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  const AppChip({
    super.key,
    required this.label,
    this.icon,
    this.color = AppColors.primary,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = selected ? color : AppColors.textMuted;
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            color: accent,
            size: 16.r,
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
        Text(
          label,
          style: AppTypography.labelMedium.copyWith(color: accent),
        ),
      ],
    );

    final Widget pill = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: selected
            ? color.withValues(alpha: 0.15)
            : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(
          color: selected
              ? color.withValues(alpha: 0.4)
              : AppColors.divider,
        ),
      ),
      child: content,
    );

    if (onTap == null) return pill;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.full),
        splashColor: color.withValues(alpha: 0.12),
        child: pill,
      ),
    );
  }
}