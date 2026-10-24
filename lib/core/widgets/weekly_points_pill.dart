import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/user_data_provider.dart';
import '../theme/app_theme.dart';

/// Compact pill: ⚡ + live weekly points ("N WP").
///
/// Shows a dash when the player has no entry on this week's board. Pass
/// [label] to replace the value entirely (e.g. the admin account).
/// Reads [UserDataProvider] directly, so it can be dropped into any header
/// inside the app's provider tree.
class WeeklyPointsPill extends StatelessWidget {
  final String? label;

  const WeeklyPointsPill({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    final userData = context.watch<UserDataProvider>();
    final text = label ??
        (userData.isLeaderboardEligible
            ? '${userData.weeklyPoints} WP'
            : '—');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt_rounded, color: AppColors.accent, size: 16),
          const SizedBox(width: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
