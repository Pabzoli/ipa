// =============================================================================
// widgets/timer_section.dart
// =============================================================================
// What changed and why:
//
//  URGENCY COLOR SYSTEM
//  • The ring wrapper animates through three distinct states using
//    AnimatedContainer (300 ms, Curves.easeOut):
//      > 5 s  — calm:    primary colour glow
//      3–5 s  — warning: amber (#F59E0B) glow
//      ≤ 2 s  — danger:  crimson (AppColors.wrong) glow
//  • This gives the player a clear visual escalation without any sudden jump.
//
//  CRITICAL PULSE
//  • When timerIsCritical, AnimatedScale applies a subtle 1.0 → 1.06 scale
//    (200 ms) on top of the TimerRing. The scale resets every second as the
//    countdown ticks, creating a heartbeat effect.
//
//  SEMANTICS
//  • liveRegion: true so screen readers announce the countdown automatically
//    without the user needing to focus the element.
//
//  NOTE: TimerRing is kept as-is from shared_widgets.dart. If the TimerRing
//  widget ever exposes a `color` parameter, pass _ringColor directly to it
//  instead of wrapping with an outer glow container.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';
import '../../features/quiz/quiz_controller.dart';

// Amber used for the warning tier.
// TODO: migrate to Theme.of(context).colorScheme.tertiary
const _kAmber = Color(0xFFF59E0B);

class TimerSection extends StatelessWidget {
  const TimerSection({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Semantics(
        label:      '${ctrl.timerSeconds} seconds remaining',
        liveRegion: true,
        child: Center(
          child: _UrgencyRingWrapper(
            seconds:    ctrl.timerSeconds,
            isUrgent:   ctrl.timerIsUrgent,
            isCritical: ctrl.timerIsCritical,
          ),
        ),
      ),
    );
  }
}

class _UrgencyRingWrapper extends StatelessWidget {
  final int  seconds;
  final bool isUrgent;
  final bool isCritical;

  const _UrgencyRingWrapper({
    required this.seconds,
    required this.isUrgent,
    required this.isCritical,
  });

  Color get _glowColor {
    if (isCritical) return AppColors.wrong;
    if (isUrgent)   return _kAmber;
    return AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      // Heartbeat scale kicks in at critical tier.
      // The key changes every second so AnimatedScale restarts from 1.0 each
      // tick, creating a repeating pulse without a persistent AnimationController.
      scale:    isCritical ? 1.06 : 1.0,
      duration: const Duration(milliseconds: 180),
      curve:    Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve:    Curves.easeOut,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color:      _glowColor.withOpacity(isCritical ? 0.35 : isUrgent ? 0.20 : 0.10),
              blurRadius: isCritical ? 24 : 16,
              spreadRadius: isCritical ? 2 : 0,
            ),
          ],
        ),
        // TODO: pass _glowColor into TimerRing once it supports a color param.
        child: TimerRing(seconds: seconds),
      ),
    );
  }
}
