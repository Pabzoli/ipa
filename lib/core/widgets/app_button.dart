import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../theme/app_theme.dart';

enum AppButtonVariant {
  primary,
  secondary,
  outline,
  text,
  gradient,
}

enum AppButtonSize {
  small,
  medium,
  large,
}

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.medium,
    this.loading = false,
    this.icon,
    this.width,
    this.height,
    this.color,
    this.gradientColors,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final bool loading;
  final Widget? icon;
  final double? width;
  final double? height;
  final Color? color;
  final List<Color>? gradientColors;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null && !loading;

    Color backgroundColor;
    Color foregroundColor;
    Color? borderColor;
    Gradient? gradient;

    switch (variant) {
      case AppButtonVariant.primary:
        backgroundColor = isEnabled
            ? (color ?? AppColors.primary)
            : AppColors.divider;
        foregroundColor = isEnabled ? Colors.white : AppColors.textMuted;
        borderColor = null;
        gradient = null;
        break;
      case AppButtonVariant.secondary:
        backgroundColor = isEnabled
            ? (color ?? AppColors.secondary)
            : AppColors.divider;
        foregroundColor = isEnabled ? Colors.white : AppColors.textMuted;
        borderColor = null;
        gradient = null;
        break;
      case AppButtonVariant.gradient:
        backgroundColor = isEnabled
            ? (color ?? AppColors.primary)
            : AppColors.divider;
        foregroundColor = isEnabled ? Colors.white : AppColors.textMuted;
        borderColor = null;
        gradient = isEnabled
            ? LinearGradient(
                colors: gradientColors ??
                    [color ?? AppColors.primary, AppColors.crimsonBright],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null;
        break;
      case AppButtonVariant.outline:
        backgroundColor = Colors.transparent;
        foregroundColor =
            isEnabled ? (color ?? AppColors.primary) : AppColors.textMuted;
        borderColor =
            isEnabled ? (color ?? AppColors.primary) : AppColors.divider;
        gradient = null;
        break;
      case AppButtonVariant.text:
        backgroundColor = Colors.transparent;
        foregroundColor =
            isEnabled ? (color ?? AppColors.primary) : AppColors.textMuted;
        borderColor = null;
        gradient = null;
        break;
    }

    double fontSize;
    double verticalPadding;
    double horizontalPadding;
    double iconSize;
    final radius = AppRadii.lg;

    switch (size) {
      case AppButtonSize.small:
        fontSize = 12.sp;
        verticalPadding = AppSpacing.sm;
        horizontalPadding = AppSpacing.md;
        iconSize = 16.r;
        break;
      case AppButtonSize.medium:
        fontSize = 14.sp;
        verticalPadding = AppSpacing.md;
        horizontalPadding = AppSpacing.lg;
        iconSize = 18.r;
        break;
      case AppButtonSize.large:
        fontSize = 16.sp;
        verticalPadding = AppSpacing.lg;
        horizontalPadding = AppSpacing.xl;
        iconSize = 20.r;
        break;
    }

    final effectiveHeight = height ?? (size == AppButtonSize.small ? 40.0 : size == AppButtonSize.medium ? 48.0 : 56.0);

    final child = loading
        ? SizedBox(
            width: iconSize,
            height: iconSize,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                IconTheme(
                  data: IconThemeData(color: foregroundColor, size: iconSize),
                  child: icon!,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Text(
                label,
                style: TextStyle(
                  fontFamily: AppTypography.fontFamily,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  color: foregroundColor,
                ),
              ),
            ],
          );

    final edge = borderColor;

    Widget button = Container(
      padding: EdgeInsets.symmetric(
        vertical: verticalPadding,
        horizontal: horizontalPadding,
      ),
      constraints: BoxConstraints(
        minHeight: effectiveHeight,
        maxHeight: height ?? effectiveHeight,
        minWidth: width ?? 0,
      ),
      decoration: BoxDecoration(
        color: gradient == null ? backgroundColor : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: edge == null ? null : Border.all(color: edge, width: 1.5),
        boxShadow: (variant == AppButtonVariant.primary ||
                variant == AppButtonVariant.secondary ||
                variant == AppButtonVariant.gradient) &&
            isEnabled
            ? [
                BoxShadow(
                  color: backgroundColor.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : [],
      ),
      child: Center(child: child),
    );

    return Semantics(
      button: true,
      enabled: isEnabled,
      label: label,
      child: GestureDetector(
        onTap: isEnabled ? onPressed : null,
        child: button,
      ),
    );
  }
}