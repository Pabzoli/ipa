// lib/core/widgets/series_progress_bar.dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../constants/rival_economy.dart';
import '../theme/app_theme.dart';

/// Best-of series progress, shared by the Battle hub card, the Rivalries list
/// and the per-rival Rivalry page.
///
/// The player's wins fill brand red from the left, the rival's fill app orange
/// from the right, around the running score. [compact] shrinks it for list
/// rows; set [unavailable] when the series score could not be read (renders a
/// dash).
class SeriesProgressBar extends StatelessWidget {
  final int myWins;
  final int opWins;
  final int target;
  final bool compact;
  final bool unavailable;

  const SeriesProgressBar({
    super.key,
    required this.myWins,
    required this.opWins,
    this.target = kSeriesWinsRequired,
    this.compact = false,
    this.unavailable = false,
  });

  static const Color _mine = AppColors.primary;
  static Color get _theirs => AppColors.readable(AppColors.accent);

  @override
  Widget build(BuildContext context) {
    final pipSize = compact ? 7.0.r : 9.0.r;
    final gap = compact ? 3.0.r : 4.0.r;
    final scoreStyle = TextStyle(
      color: unavailable ? AppColors.textMuted : AppColors.textPrimary,
      fontSize: compact ? 11.sp : 14.sp,
      fontWeight: FontWeight.w900,
      height: 1,
    );

    return Row(
      children: [
        Expanded(
          child: _Pips(
            filled: myWins,
            target: target,
            color: _mine,
            size: pipSize,
            gap: gap,
            reversed: false,
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8.r : 10.r),
          child: Text(unavailable ? '—' : '$myWins–$opWins', style: scoreStyle),
        ),
        Expanded(
          child: _Pips(
            filled: opWins,
            target: target,
            color: _theirs,
            size: pipSize,
            gap: gap,
            reversed: true,
          ),
        ),
      ],
    );
  }
}

class _Pips extends StatelessWidget {
  final int filled;
  final int target;
  final Color color;
  final double size;
  final double gap;
  final bool reversed;

  const _Pips({
    required this.filled,
    required this.target,
    required this.color,
    required this.size,
    required this.gap,
    required this.reversed,
  });

  @override
  Widget build(BuildContext context) {
    final count = target < 1 ? 1 : target;
    final active = filled.clamp(0, count);
    final pips = <Widget>[
      for (var i = 0; i < count; i++)
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < active ? color : AppColors.divider,
            boxShadow: i < active
                ? [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6)]
                : null,
          ),
        ),
    ];
    final ordered = reversed ? pips.reversed.toList() : pips;

    return Row(
      mainAxisAlignment:
          reversed ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        for (var i = 0; i < ordered.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          ordered[i],
        ],
      ],
    );
  }
}
