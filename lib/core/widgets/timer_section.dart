// =============================================================================
// widgets/timer_section.dart
// =============================================================================
// Timer Pause power-up (freeze until answered):
//  • TimerWithPowerup combines the timer ring and the pause button.
//  • The button appears only when canShowTimerPause is true.
//  • When paused, the countdown is frozen and a "Paused" badge is shown.
//  • A fixed‑width placeholder keeps the timer centered.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../features/quiz/quiz_controller.dart';
import 'powerup_bar.dart'; // TimerPauseButton

// ── Existing TimerSection (kept for reference, but not used) ──

class TimerSection extends StatelessWidget {
  const TimerSection({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();

    return Padding(
      padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 0),
      child: Semantics(
        label: '${ctrl.timerSeconds} seconds remaining',
        liveRegion: true,
        child: Center(
          child: _UrgencyRingWrapper(
            seconds: ctrl.timerSeconds,
            isUrgent: ctrl.timerIsUrgent,
            isCritical: ctrl.timerIsCritical,
          ),
        ),
      ),
    );
  }
}

// ── New: Timer + Powerup in a compact, centered row ──────────────────────

class TimerWithPowerup extends StatelessWidget {
  const TimerWithPowerup({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();
    // Approximate width of the button (Pause · 20 AC with padding)
    const double buttonPlaceholderWidth = 148.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 8.r),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useStack = constraints.maxWidth < 360;
          if (useStack) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: ctrl.isTimerPaused
                      ? 'Timer paused with ${ctrl.timerSeconds} seconds remaining'
                      : '${ctrl.timerSeconds} seconds remaining',
                  liveRegion: true,
                  child: _UrgencyRingWrapper(
                    seconds: ctrl.timerSeconds,
                    isUrgent: ctrl.timerIsUrgent,
                    isCritical: ctrl.timerIsCritical,
                    isPaused: ctrl.isTimerPaused,
                  ),
                ),
                if (ctrl.isTimerPaused) ...[
                  SizedBox(height: 6.h),
                  const _PausedBadge(),
                ] else if (ctrl.canShowTimerPause) ...[
                  SizedBox(height: 8.h),
                  TimerPauseButton(
                    coins: ctrl.animeCoins,
                    onTap: ctrl.useTimerPause,
                  ),
                ],
              ],
            );
          }
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Timer ring – fixed size, no stretching
              Semantics(
                label: ctrl.isTimerPaused
                    ? 'Timer paused with ${ctrl.timerSeconds} seconds remaining'
                    : '${ctrl.timerSeconds} seconds remaining',
                liveRegion: true,
                child: _UrgencyRingWrapper(
                  seconds: ctrl.timerSeconds,
                  isUrgent: ctrl.timerIsUrgent,
                  isCritical: ctrl.timerIsCritical,
                  isPaused: ctrl.isTimerPaused,
                ),
              ),
              SizedBox(width: 16.w),
              // Fixed‑width placeholder ensures the timer never shifts
              SizedBox(
                width: buttonPlaceholderWidth,
                child: AnimatedOpacity(
                  opacity: (ctrl.canShowTimerPause || ctrl.isTimerPaused)
                      ? 1.0
                      : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: Center(
                    child: ctrl.isTimerPaused
                        ? const _PausedBadge()
                        : ctrl.canShowTimerPause
                            ? TimerPauseButton(
                                coins: ctrl.animeCoins,
                                onTap: ctrl.useTimerPause,
                              )
                            : const SizedBox.shrink(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Ring wrapper ────────────────────────────────────────────────────────────

class _PausedBadge extends StatelessWidget {
  const _PausedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(
          color: AppColors.secondary.withValues(alpha: 0.55),
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.pause_rounded, size: 14, color: AppColors.secondary),
          SizedBox(width: 4),
          Text(
            'Paused',
            style: TextStyle(
              color: AppColors.secondary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _UrgencyRingWrapper extends StatelessWidget {
  final int seconds;
  final bool isUrgent;
  final bool isCritical;
  final bool isPaused;

  const _UrgencyRingWrapper({
    required this.seconds,
    required this.isUrgent,
    required this.isCritical,
    this.isPaused = false,
  });

  Color get _glowColor {
    if (isCritical) return AppColors.wrong;
    if (isUrgent) return AppColors.amber;
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isCritical ? 1.06 : 1.0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: _glowColor.withValues(
                  alpha: isCritical
                      ? 0.35
                      : isUrgent
                          ? 0.20
                          : 0.10),
              blurRadius: isCritical ? 24 : 16,
              spreadRadius: isCritical ? 2 : 0,
            ),
          ],
        ),
        child: TimerRing(seconds: seconds),
      ),
    );
  }
}
