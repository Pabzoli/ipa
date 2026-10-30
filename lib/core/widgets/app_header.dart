import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../theme/app_theme.dart';
import 'app_back_button.dart';

class AppHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? count;
  final Widget? leading;
  final bool showBack;
  final VoidCallback? onBack;
  final bool showClose;
  final VoidCallback? onClose;
  final Widget? trailing;
  final TextStyle? titleStyle;
  final EdgeInsetsGeometry padding;

  const AppHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.count,
    this.leading,
    this.showBack = false,
    this.onBack,
    this.showClose = false,
    this.onClose,
    this.trailing,
    this.titleStyle,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.page,
      vertical: AppSpacing.md,
    ),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null)
            leading!
          else if (showBack)
            AppBackButton(onPressed: onBack, tooltip: 'Back')
          else if (showClose)
            IconButton(
              onPressed: onClose ?? () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.close, size: 22.r),
              color: AppColors.textPrimary,
              tooltip: 'Close',
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: titleStyle ?? AppTypography.heading1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle!,
                    style: AppTypography.bodyMedium
                        .copyWith(color: AppColors.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: AppSpacing.md),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(AppRadii.full),
              ),
              child: Text(
                count!,
                style: AppTypography.labelMedium
                    .copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.md),
            trailing!,
          ],
        ],
      ),
    );
  }
}
