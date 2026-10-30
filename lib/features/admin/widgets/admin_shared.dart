// lib/features/admin/widgets/admin_shared.dart
//
// Shared chrome for the redesigned admin console. All admin tabs use these so
// payouts, referrals and the house engine read as one product.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_card.dart';

/// Human naira formatting shared by every admin surface. Amounts always come
/// from the server — this only renders them.
String adminNaira(num amount) {
  final fixed = amount.toStringAsFixed(2);
  final parts = fixed.split('.');
  final digits = parts[0].split('').reversed.toList();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && i % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  final intPart = buf.toString().split('').reversed.join();
  final frac = parts[1] == '00' ? '' : '.${parts[1]}';
  return '₦$intPart$frac';
}

String adminTime(DateTime? t) {
  if (t == null) return '—';
  final l = t.toLocal();
  final m = l.month.toString().padLeft(2, '0');
  final d = l.day.toString().padLeft(2, '0');
  final h = l.hour.toString().padLeft(2, '0');
  final min = l.minute.toString().padLeft(2, '0');
  return '${l.year}-$m-$d $h:$min';
}

/// Page header used at the top of every admin tab body. Replaces the three
/// different AppBar title styles with one gradient hero.
class AdminHero extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget? trailing;

  const AdminHero({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.lg.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.cardGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadii.xl.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 44.r,
            height: 44.r,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadii.md.r),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.30),
              ),
            ),
            child: Icon(icon, color: AppColors.primary, size: 22.r),
          ),
          SizedBox(width: AppSpacing.md.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.titleLarge),
                SizedBox(height: 2.h),
                Text(
                  subtitle,
                  style: AppTypography.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: AppSpacing.sm.w),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Single stat tile for the overview grid and summary strips.
class AdminStat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const AdminStat({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = AppCard(
      padding: EdgeInsets.all(AppSpacing.md.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15.r, color: AppColors.readable(color)),
              const Spacer(),
              if (onTap != null)
                Icon(
                  Icons.arrow_outward_rounded,
                  size: 14.r,
                  color: AppColors.textMuted,
                ),
            ],
          ),
          SizedBox(height: AppSpacing.sm.h),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.titleLarge.copyWith(
              color: AppColors.readable(color),
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 2.h),
          Text(label, style: AppTypography.bodySmall),
        ],
      ),
    );
    if (onTap == null) return card;
    return GestureDetector(onTap: onTap, child: card);
  }
}

/// Section heading used above every admin list.
class AdminSectionTitle extends StatelessWidget {
  final String title;
  final String? trailing;
  final VoidCallback? onTrailingTap;

  const AdminSectionTitle({
    super.key,
    required this.title,
    this.trailing,
    this.onTrailingTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: AppTypography.labelLarge)),
        if (trailing != null)
          GestureDetector(
            onTap: onTrailingTap,
            child: Text(
              trailing!,
              style: AppTypography.labelMedium.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
      ],
    );
  }
}

/// Pill status chip shared by payout / referral / house queues.
class AdminChip extends StatelessWidget {
  final String label;
  final Color color;

  const AdminChip({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.full.r),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: AppTypography.labelSmall.copyWith(
          color: AppColors.readable(color),
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

/// Segmented filter row shared by payouts + referrals.
class AdminFilters extends StatelessWidget {
  final List<String> options;
  final String active;
  final ValueChanged<String> onSelect;
  final Map<String, int>? counts;

  const AdminFilters({
    super.key,
    required this.options,
    required this.active,
    required this.onSelect,
    this.counts,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm.r,
      runSpacing: AppSpacing.sm.r,
      children: [
        for (final o in options)
          GestureDetector(
            onTap: () => onSelect(o),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
              decoration: BoxDecoration(
                color: o == active
                    ? AppColors.primary.withValues(alpha: 0.14)
                    : AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadii.full.r),
                border: Border.all(
                  color: o == active
                      ? AppColors.primary.withValues(alpha: 0.5)
                      : AppColors.divider,
                ),
              ),
              child: Text(
                counts != null && counts!.containsKey(o)
                    ? '$o · ${counts![o]}'
                    : o,
                style: AppTypography.labelMedium.copyWith(
                  color: o == active
                      ? AppColors.readable(AppColors.primary)
                      : AppColors.textSecondary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Loading / denied / error states shared by every admin tab.
class AdminStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onRetry;

  const AdminStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel = 'Try again',
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xl.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64.r,
              height: 64.r,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.divider),
              ),
              child: Icon(icon, color: AppColors.textMuted, size: 28.r),
            ),
            SizedBox(height: AppSpacing.md.h),
            Text(title, style: AppTypography.titleMedium),
            SizedBox(height: AppSpacing.xs.h),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall,
            ),
            SizedBox(height: AppSpacing.lg.h),
            TextButton(onPressed: onRetry, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

class AdminLoading extends StatelessWidget {
  const AdminLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: AppColors.primary),
    );
  }
}
