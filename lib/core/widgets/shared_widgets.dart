import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../theme/app_theme.dart';

// ─── Gradient Button ─────────────────────────────────────────────────────────
class GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final List<Color> colors;
  final IconData? icon;
  final bool isLoading;
  final double height;

  const GradientButton({
    super.key,
    required this.label,
    this.onTap,
    this.colors = const [AppColors.primary, Color(0xFFFF6B6B)],
    this.icon,
    this.isLoading = false,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: onTap == null
                ? [AppColors.textMuted, AppColors.textMuted]
                : colors,
          ),
          borderRadius: BorderRadius.circular(16.r),
          boxShadow: onTap == null
              ? []
              : [
                  BoxShadow(
                    color: colors.first.withValues(alpha: 0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Center(
          child: isLoading
              ? SizedBox(
                  width: 22.w,
                  height: 22.h,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: Colors.white, size: 20.r),
                      SizedBox(width: 8.w),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16.sp,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ─── Glass Card ───────────────────────────────────────────────────────────────
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(
          color: borderColor ?? AppColors.divider,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            // Dark keeps the original black26; light uses the soft token.
            color: AppColors.isDark ? Colors.black26 : AppColors.shadow,
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ─── Stat Chip ────────────────────────────────────────────────────────────────
class StatChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const StatChip({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 10.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.readable(color), size: 18.r),
          SizedBox(width: 8.w),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: AppColors.readable(color),
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Score Badge ──────────────────────────────────────────────────────────────
class ScoreBadge extends StatelessWidget {
  final int score;
  final IconData icon;

  const ScoreBadge({super.key, required this.score, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.readable(AppColors.accent), size: 16.r),
          SizedBox(width: 6.w),
          Text(
            '$score',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 14.sp,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Animated Background ─────────────────────────────────────────────────────
class AnimatedHeroBackground extends StatelessWidget {
  final Widget child;
  const AnimatedHeroBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints.expand(),
      decoration: AppDecorations.heroBg,
      child: Stack(
        children: [
          // Decorative orbs
          Positioned(
            top: -80.h,
            right: -60.w,
            child: _Orb(
                size: 280.r, color: AppColors.primary.withValues(alpha: 0.15)),
          ),
          Positioned(
            bottom: 100.h,
            left: -80.w,
            child: _Orb(
                size: 220.r, color: AppColors.secondary.withValues(alpha: 0.1)),
          ),
          Positioned(
            top: 200.h,
            left: 60.w,
            child: _Orb(
                size: 100.r, color: AppColors.accent.withValues(alpha: 0.08)),
          ),
          child,
        ],
      ),
    );
  }
}

class _Orb extends StatelessWidget {
  final double size;
  final Color color;
  const _Orb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }
}

// ─── Section Header ───────────────────────────────────────────────────────────
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const SectionHeader({super.key, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4.w,
          height: 20.h,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(2.r),
          ),
        ),
        SizedBox(width: 10.w),
        Text(
          title,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18.sp,
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

// ─── Timer Ring ───────────────────────────────────────────────────────────────
class TimerRing extends StatelessWidget {
  final int seconds;
  final int maxSeconds;

  const TimerRing({
    super.key,
    required this.seconds,
    this.maxSeconds = 10,
  });

  Color get _color {
    final ratio = seconds / maxSeconds;
    if (ratio > 0.5) return AppColors.readable(AppColors.correct);
    if (ratio > 0.25) return AppColors.readable(AppColors.accent);
    return AppColors.readable(AppColors.wrong);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64.w,
      height: 64.h,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: seconds / maxSeconds,
            strokeWidth: 5,
            backgroundColor: AppColors.divider,
            valueColor: AlwaysStoppedAnimation(_color),
          ),
          Text(
            '$seconds',
            style: TextStyle(
              color: _color,
              fontSize: 20.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
