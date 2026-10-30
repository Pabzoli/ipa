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

  /// A rounded border must use one colour on every side — Flutter asserts on
  /// mixed colours with a `borderRadius`, and the paint throws, taking the
  /// card's child (all of its text) down with it. The accent is therefore a
  /// 4px stripe painted behind the content, not a heavier left border.
  Border get _border =>
      Border.all(color: borderColor ?? AppColors.divider, width: 1);

  static const double _accentWidth = 4;

  /// Pads [child] [padding] and, when [accentColor] is set, lays the accent
  /// stripe inside the card's rounded clip so it never doubles as a border.
  Widget _content(BorderRadius effectRadius) {
    if (accentColor == null) {
      return Padding(padding: padding, child: child);
    }

    return ClipRRect(
      borderRadius: effectRadius,
      child: Stack(
        children: [
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            width: _accentWidth,
            child: ColoredBox(color: accentColor!),
          ),
          Padding(
            padding: padding,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: _accentWidth),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectRadius = radius ?? BorderRadius.circular(_defaultRadius);
    final decoration = BoxDecoration(
      color: color ?? AppColors.surface,
      gradient: gradient,
      borderRadius: effectRadius,
      border: _border,
      boxShadow: tier == AppCardTier.elevated
          ? [
              BoxShadow(
                // Dark keeps the original black26; light gets a much softer
                // tinted shadow, since 15% black reads as a hard drop shadow
                // on a white surface.
                color: AppColors.isDark ? Colors.black26 : AppColors.shadow,
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ]
          : null,
    );

    final content = _content(effectRadius);

    if (onTap == null) {
      return Container(
        decoration: decoration,
        child: content,
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
          child: content,
        ),
      ),
    );
  }
}
