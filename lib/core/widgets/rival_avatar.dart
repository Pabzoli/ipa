// lib/core/widgets/rival_avatar.dart
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A player avatar with a soft gradient ring — the identity mark for a rivalry,
/// shared by the Battle hub, the Rivalries list and the per-rival Rivalry page.
///
/// The app has no profile images (avatars are initial-based everywhere), so this
/// wraps a coloured initial in a two-stop ring. [highlight] adds a glow for the
/// single focal rival on a screen; [emoji] swaps the initial for a glyph.
class RivalAvatar extends StatelessWidget {
  final String name;
  final double size;
  final Color color;
  final bool highlight;
  final String? emoji;

  const RivalAvatar({
    super.key,
    required this.name,
    this.size = 44,
    this.color = AppColors.rival,
    this.highlight = false,
    this.emoji,
  });

  String get _label {
    if (emoji != null && emoji!.isNotEmpty) return emoji!;
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final ringWidth = size * 0.07;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(ringWidth),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, color.withValues(alpha: 0.30)],
        ),
        boxShadow: highlight
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: size * 0.4,
                ),
              ]
            : null,
      ),
      child: Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surface,
        ),
        child: Text(
          _label,
          style: TextStyle(
            color: color,
            fontSize: size * 0.4,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
      ),
    );
  }
}
