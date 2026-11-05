import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/theme/app_theme.dart';

/// Small gold crown shown next to the names of premium members.
///
/// Used on the leaderboard (podium cards, rank rows, your-position card) and
/// the Friends tab. Icon-only on purpose: the rows already carry YOU / RIVAL /
/// PASS ME tags, and a second word tag would crowd them.
class PremiumMark extends StatelessWidget {
  /// Icon size before scaling. Rows pass the default; tighter spots pass less.
  final double size;

  const PremiumMark({super.key, this.size = 12});

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.workspace_premium_rounded,
      size: size.r,
      color: AppColors.readable(AppColors.gold),
      semanticLabel: 'Premium member',
    );
  }
}
