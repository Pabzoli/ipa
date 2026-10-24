// lib/features/friends/friend_widgets.dart
//
// Shared row pieces for the Friends board and the Add Friend page, so both
// screens read as one feature.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/app_card.dart';

String friendInitial(String name) =>
    name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

/// Section label with an optional count pill ("Incoming  2") and an optional
/// trailing action (the Friends board's compact "Add" chip).
class FriendSectionTitle extends StatelessWidget {
  final String title;
  final int? count;
  final Widget? trailing;

  const FriendSectionTitle({
    super.key,
    required this.title,
    this.count,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: AppTypography.titleLarge),
        if (count != null) ...[
          SizedBox(width: AppSpacing.sm),
          Container(
            padding:
                EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2.r),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(AppRadii.full),
            ),
            child: Text(
              '$count',
              style: AppTypography.labelMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// One muted line of guidance where a list would otherwise be empty.
class FriendInlineNote extends StatelessWidget {
  final String text;
  const FriendInlineNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Text(text, style: AppTypography.bodySmall),
    );
  }
}

/// Rank number for the board. Top three use the medal tokens.
class RankBadge extends StatelessWidget {
  final int? rank;
  const RankBadge({super.key, required this.rank});

  @override
  Widget build(BuildContext context) {
    final color = switch (rank) {
      1 => AppColors.gold,
      2 => AppColors.silver,
      3 => AppColors.bronze,
      _ => AppColors.textMuted,
    };
    return Container(
      width: 26.r,
      height: 26.r,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          rank?.toString() ?? '–',
          style: AppTypography.labelLarge.copyWith(
            color: color,
            fontSize: 12.5.sp,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

/// Compact pill action used inside a board row (Spar / Nudge / Add).
///
/// Deliberately smaller than [AppButton]: a row is a ranking line, not a
/// panel, so it carries one small explicit action instead of a footer of
/// buttons.
class FriendActionChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;

  const FriendActionChip({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final tint = enabled ? color : AppColors.textMuted;
    final radius = BorderRadius.circular(AppRadii.full);

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: radius,
          child: Container(
            height: 28.r,
            padding: EdgeInsets.symmetric(horizontal: 10.r),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: radius,
              border: Border.all(color: tint.withValues(alpha: 0.38)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  SizedBox(
                    width: 12.r,
                    height: 12.r,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(tint),
                    ),
                  )
                else if (icon != null)
                  Icon(icon, size: 13.r, color: tint),
                if (loading || icon != null) SizedBox(width: 4.r),
                Text(
                  label,
                  style: AppTypography.labelSmall.copyWith(
                    color: tint,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A player row: leading avatar or rank, name + subtitle, optional trailing
/// action, and an optional [footer] line below the main row (used for chips
/// and actions that would crowd a narrow screen). [highlighted] marks the
/// signed-in player's own row.
///
/// Used by Add Friend for request rows. The Friends board uses its own compact
/// row: a ranking list should not be a wall of action buttons.
class FriendTile extends StatelessWidget {
  final String name;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? footer;
  final VoidCallback? onTap;
  final bool highlighted;

  const FriendTile({
    super.key,
    required this.name,
    this.subtitle,
    this.leading,
    this.trailing,
    this.footer,
    this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    final mainRow = Row(
      children: [
        leading ?? AppAvatar(label: friendInitial(name), size: 40.r),
        SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.labelLarge,
              ),
              if (hasSubtitle) ...[
                SizedBox(height: 2.r),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodySmall,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          SizedBox(width: AppSpacing.sm),
          trailing!,
        ],
      ],
    );
    return AppCard(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      tier: AppCardTier.standard,
      color: highlighted ? AppColors.primarySoft : null,
      borderColor: highlighted ? AppColors.primaryBorder : null,
      onTap: onTap,
      child: footer == null
          ? mainRow
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                mainRow,
                SizedBox(height: AppSpacing.sm),
                footer!,
              ],
            ),
    );
  }
}
