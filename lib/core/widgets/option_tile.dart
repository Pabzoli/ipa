// =============================================================================
// widgets/option_tile.dart
// =============================================================================
// What changed and why:
//
//  PRESS SCALE
//  • GestureDetector tracks onTapDown/onTapUp/onTapCancel.
//  • AnimatedScale at 0.97 on press-down (150 ms, Curves.easeOut).
//    This mirrors the physical press feel used by Duolingo, Linear, and
//    other premium apps. Subtle enough to not feel toy-like.
//
//  STATE TRANSITIONS
//  • AnimatedContainer (220 ms) on border/background colour — same as before
//    but now the colour source is derived from a single _tileColors() helper
//    that's easy to read and unit-test.
//
//  SEMANTICS
//  • Each tile announces "Option A: [text]" plus state suffix
//    (— correct / — wrong / — eliminated) when applicable.
//  • button: true only when the tile is interactive.
//  • selected: mirrors ctrl.selectedOption.
//  • Eliminated tiles are IgnorePointer + ExcludeSemantics so screen
//    readers skip them naturally.
//
//  SEPARATION
//  • _TileColors is a plain data class — no Widget logic mixed in.
//  • _TileContent is a const-constructible leaf widget.
//  • OptionTileWidget (the StatefulWidget) is the only place that tracks
//    press state and calls the controller.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../features/quiz/quiz_controller.dart';

// ── Option tile (StatefulWidget — tracks press state) ─────────────────────

class OptionTileWidget extends StatefulWidget {
  final int optionIndex;
  const OptionTileWidget({super.key, required this.optionIndex});

  @override
  State<OptionTileWidget> createState() => _OptionTileWidgetState();
}

class _OptionTileWidgetState extends State<OptionTileWidget> {
  bool _pressed = false;

  static const _labels = ['A', 'B', 'C', 'D', 'E', 'F'];

  @override
  Widget build(BuildContext context) {
    final ctrl  = context.watch<QuizController>();
    final q     = ctrl.currentQuestion;
    if (q == null) return const SizedBox.shrink();

    final i       = widget.optionIndex;
    final label   = i < _labels.length ? _labels[i] : '${i + 1}';
    final elim    = ctrl.currentEliminated;
    final correct = q.correctAnswerIndex;

    // ── Eliminated option ──────────────────────────────────────────────────
    if (elim.contains(i)) {
      return ExcludeSemantics(
        child: IgnorePointer(
          child: Opacity(
            opacity: 0.22,
            child: _TileContent(
              colors: _TileColors(
                border:     AppColors.divider,
                bg:         AppColors.surface,
                text:       AppColors.textMuted,
                badge:      AppColors.textMuted,
                badgeFill:  false,
                shadows:    const [],
                trailing:   null,
              ),
              label:         label,
              text:          q.options[i],
              strikethrough: true,
            ),
          ),
        ),
      );
    }

    // ── Derive visual state ────────────────────────────────────────────────
    final colors = _resolveColors(
      i:              i,
      correct:        correct,
      selectedOption: ctrl.selectedOption,
      showResult:     ctrl.showResult,
    );

    final isInteractive = !ctrl.showResult && !ctrl.isNavigating;

    final semanticSuffix = ctrl.showResult
        ? (i == correct
            ? ' — correct'
            : i == ctrl.selectedOption
                ? ' — wrong'
                : '')
        : '';

    return Semantics(
      label:    'Option $label: ${q.options[i]}$semanticSuffix',
      button:   isInteractive,
      selected: i == ctrl.selectedOption,
      enabled:  isInteractive,
      child: GestureDetector(
        onTapDown: isInteractive
            ? (_) => setState(() => _pressed = true)
            : null,
        onTapUp: isInteractive
            ? (_) {
                setState(() => _pressed = false);
                ctrl.selectOption(i);
              }
            : null,
        onTapCancel: isInteractive
            ? () => setState(() => _pressed = false)
            : null,
        child: AnimatedScale(
          scale:    _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve:    Curves.easeOut,
          child: _TileContent(
            colors:        colors,
            label:         label,
            text:          q.options[i],
            strikethrough: false,
          ),
        ),
      ),
    );
  }

  // ── Color resolver ─────────────────────────────────────────────────────────

  _TileColors _resolveColors({
    required int  i,
    required int  correct,
    required int  selectedOption,
    required bool showResult,
  }) {
    if (showResult) {
      if (i == correct) {
        return _TileColors(
          border:    AppColors.correct,
          bg:        AppColors.correct.withValues(alpha: 0.13),
          text:      AppColors.correct,
          badge:     AppColors.correct,
          badgeFill: true,
          shadows: [
            BoxShadow(
              color: AppColors.correct.withValues(alpha: 0.2),
              blurRadius: 20,
              offset:     const Offset(0, 4),
            ),
          ],
          trailing: Icon(
            Icons.check_circle_rounded,
            color: AppColors.correct,
            size:  22,
          ),
        );
      }

      if (i == selectedOption) {
        return _TileColors(
          border:    AppColors.wrong,
          bg:        AppColors.wrong.withValues(alpha: 0.11),
          text:      AppColors.wrong,
          badge:     AppColors.wrong,
          badgeFill: true,
          shadows: [
            BoxShadow(
              color: AppColors.wrong.withValues(alpha: 0.15),
              blurRadius: 14,
              offset:     const Offset(0, 3),
            ),
          ],
          trailing: Icon(
            Icons.cancel_rounded,
            color: AppColors.wrong,
            size:  22,
          ),
        );
      }

      // Revealed-but-not-selected after answer shown
      return _TileColors(
        border:    AppColors.divider.withValues(alpha: 0.4),
        bg:        AppColors.surface.withValues(alpha: 0.35),
        text:      AppColors.textMuted.withValues(alpha: 0.5),
        badge:     AppColors.textMuted.withValues(alpha: 0.4),
        badgeFill: false,
        shadows:   const [],
        trailing:  null,
      );
    }

    if (i == selectedOption) {
      return _TileColors(
        border:    AppColors.secondary,
        bg:        AppColors.secondary.withValues(alpha: 0.1),
        text:      AppColors.secondary,
        badge:     AppColors.secondary,
        badgeFill: true,
        shadows: [
          BoxShadow(
            color: AppColors.secondary.withValues(alpha: 0.15),
            blurRadius: 12,
            offset:     const Offset(0, 3),
          ),
        ],
        trailing: null,
      );
    }

    // Default idle state
    return _TileColors(
      border:    AppColors.divider,
      bg:        AppColors.surface,
      text:      AppColors.textPrimary,
      badge:     AppColors.textSecondary,
      badgeFill: false,
      shadows:   const [],
      trailing:  null,
    );
  }
}

// ── Data class: resolved tile colours + decorations ───────────────────────

class _TileColors {
  final Color          border;
  final Color          bg;
  final Color          text;
  final Color          badge;
  final bool           badgeFill;
  final List<BoxShadow> shadows;
  final Widget?        trailing;

  const _TileColors({
    required this.border,
    required this.bg,
    required this.text,
    required this.badge,
    required this.badgeFill,
    required this.shadows,
    required this.trailing,
  });
}

// ── Stateless leaf: renders tile from pre-resolved colours ─────────────────

class _TileContent extends StatelessWidget {
  final _TileColors colors;
  final String      label;
  final String      text;
  final bool        strikethrough;

  const _TileContent({
    required this.colors,
    required this.label,
    required this.text,
    required this.strikethrough,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve:    Curves.easeOut,
      decoration: BoxDecoration(
        color:        colors.bg,
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border:       Border.all(color: colors.border, width: 1.5),
        boxShadow:    colors.shadows,
      ),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          child: Row(
            children: [
              // Letter badge
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width:  34,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.badgeFill
                      ? colors.badge.withValues(alpha: 0.25)
                      : colors.badge.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: colors.badge.withValues(
                      alpha: colors.badgeFill ? 0.6 : 0.3,
                    ),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      style: TextStyle(
                        color:         colors.badge,
                        fontWeight:    FontWeight.w900,
                        fontSize:      13.sp,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color:           colors.text,
                    fontSize:        15.sp,
                    fontWeight:      FontWeight.w600,
                    height:          1.35,
                    decoration:      strikethrough
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    decorationColor: colors.text,
                  ),
                ),
              ),
              if (colors.trailing != null) ...[
                const SizedBox(width: 10),
                colors.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
