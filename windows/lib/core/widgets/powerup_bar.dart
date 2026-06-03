// =============================================================================
// widgets/powerup_bar.dart
// =============================================================================
// What changed and why:
//
//  FIX: AnimatedContainer → AnimatedSize
//  • The original AnimatedContainer used a hardcoded height (72 + bottom).
//    That value was slightly smaller than the button's true rendered height
//    (internal vertical padding 16+16 + icon row ~20 + outer padding 8+16
//    = ~76 + bottom), which caused the bottom edge to be clipped on device.
//  • AnimatedSize solves this permanently: height is always derived from the
//    child's intrinsic size, so no arithmetic can be wrong. When
//    canShowTimerPause flips, the child swaps between SizedBox.shrink() and
//    the real content, and AnimatedSize smoothly interpolates the height.
//  • ClipRect wraps AnimatedSize to give a clean wipe edge during the
//    transition (without it, shadows can leak outside the growing bounds).
//  • alignment: Alignment.bottomCenter pins the child to the bottom of the
//    growing container, creating a "slide up from below" reveal.
//
//  BOTTOM INSET
//  • max(16.0, bottom) ensures at least 16 dp padding even on devices that
//    report viewPadding.bottom == 0 (e.g. tablets without a home indicator).
//
//  PULSING
//  • The pulse AnimationController lives inside _TimerPauseButton (StatefulWidget)
//    and is disposed when the bar collapses and the subtree unmounts.
//
//  SEMANTICS
//  • Semantics label reads "+5 seconds for N coins" for screen readers.
// =============================================================================

import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/quiz/quiz_controller.dart';

class PowerupBar extends StatelessWidget {
  const PowerupBar({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl   = context.watch<QuizController>();
    final bottom = MediaQuery.of(context).viewPadding.bottom;

    // ClipRect keeps shadows inside the growing bounds during the animation.
    return ClipRect(
      child: AnimatedSize(
        duration:  const Duration(milliseconds: 250),
        curve:     Curves.easeOut,
        // bottomCenter: child sticks to the bottom of the growing container,
        // so the button appears to slide UP into view from below.
        alignment: Alignment.bottomCenter,
        child: ctrl.canShowTimerPause
            ? Padding(
                // max(16, bottom) guarantees clearance on tablets (bottom == 0).
                padding: EdgeInsets.fromLTRB(20, 8, 20, max(16.0, bottom)),
                child: _TimerPauseButton(
                  coins: ctrl.animeCoins,
                  onTap: ctrl.useTimerPause,
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

// ── Timer pause button ─────────────────────────────────────────────────────

class _TimerPauseButton extends StatefulWidget {
  final int          coins;
  final VoidCallback onTap;
  const _TimerPauseButton({required this.coins, required this.onTap});

  @override
  State<_TimerPauseButton> createState() => _TimerPauseButtonState();
}

class _TimerPauseButtonState extends State<_TimerPauseButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double>   _scale;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.97, end: 1.03).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canAfford = widget.coins >= kTimerPauseCost;

    return Semantics(
      label:  '+5 seconds for $kTimerPauseCost coins',
      button: true,
      child: ScaleTransition(
        scale: _scale,
        child: GestureDetector(
          onTap:    widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve:    Curves.easeOut,
            width:    double.infinity,
            padding:  const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: canAfford
                  ? AppColors.secondary.withOpacity(0.14)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: canAfford
                    ? AppColors.secondary.withOpacity(0.55)
                    : AppColors.divider,
                width: 1.5,
              ),
              boxShadow: canAfford
                  ? [
                      BoxShadow(
                        color:      AppColors.secondary.withOpacity(0.22),
                        blurRadius: 16,
                        offset:     const Offset(0, 4),
                      ),
                    ]
                  : [],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.hourglass_top_rounded,
                  color: canAfford ? AppColors.secondary : AppColors.textMuted,
                  size:  18,
                ),
                const SizedBox(width: 8),
                Text(
                  '+5 seconds  ·  ${kTimerPauseCost}🪙',
                  style: TextStyle(
                    color: canAfford
                        ? AppColors.secondary
                        : AppColors.textMuted,
                    fontWeight:    FontWeight.w700,
                    fontSize:      15,
                    letterSpacing: 0.2,
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