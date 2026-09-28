import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum AppCardTier { standard, elevated, feature }

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final AppCardTier tier;
  final Color? accentColor;
  final Color? borderColor;
  final Color? color;
  final Gradient? gradient;
  final VoidCallback? onTap;
  final BorderRadius? radius;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.tier = AppCardTier.standard,
    this.accentColor,
    this.borderColor,
    this.color,
    this.gradient,
    this.onTap,
    this.radius,
  });

  double get _defaultRadius => switch (tier) {
        AppCardTier.standard => AppRadii.lg,
        AppCardTier.elevated => AppRadii.xl,
        AppCardTier.feature => AppRadii.feature,
      };

  Border get _border => accentColor == null
      ? Border.all(color: borderColor ?? AppColors.divider, width: 1)
      : Border(
          left: BorderSide(color: accentColor!, width: 4),
          top: const BorderSide(color: AppColors.divider, width: 1),
          right: const BorderSide(color: AppColors.divider, width: 1),
          bottom: const BorderSide(color: AppColors.divider, width: 1),
        );

  @override
  Widget build(BuildContext context) {
    final effectRadius = radius ?? BorderRadius.circular(_defaultRadius);
    final decoration = BoxDecoration(
      color: color ?? AppColors.surface,
      gradient: gradient,
      borderRadius: effectRadius,
      border: _border,
      boxShadow: tier == AppCardTier.elevated
          ? const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ]
          : null,
    );

    if (onTap == null) {
      return Container(
        padding: padding,
        decoration: decoration,
        child: child,
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: Ink(
        decoration: decoration,
        child: InkWell(
          onTap: onTap,
          borderRadius: effectRadius,
          splashColor: AppColors.primary.withValues(alpha: 0.12),
          highlightColor: AppColors.primary.withValues(alpha: 0.08),
          child: Padding(
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}