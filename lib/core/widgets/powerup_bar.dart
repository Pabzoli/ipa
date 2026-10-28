// =============================================================================
// widgets/powerup_bar.dart
// =============================================================================
// Timer Pause power-up (freeze until answered):
//   • Freezes the countdown at its current value until the player answers.
//   • No seconds are added, no auto-resume — one use per question.
//   • Compact pill styling beside the timer (positioned by TimerWithPowerup).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/quiz/quiz_controller.dart';

/// The timer‑pause button – used inline next to the timer.
/// It appears only when the timer is urgent and hasn't been paused yet.
class TimerPauseButton extends StatefulWidget {
  final int coins;
  final VoidCallback onTap;

  const TimerPauseButton({
    super.key,
    required this.coins,
    required this.onTap,
  });

  @override
  State<TimerPauseButton> createState() => _TimerPauseButtonState();
}

class _TimerPauseButtonState extends State<TimerPauseButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
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
      label: 'Pause timer for $kTimerPauseCost coins',
      button: true,
      child: ScaleTransition(
        scale: _scale,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            padding:
                EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 10.r),
            decoration: BoxDecoration(
              color: canAfford
                  ? AppColors.secondary.withValues(alpha: 0.14)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.full),
              border: Border.all(
                color: canAfford
                    ? AppColors.secondary.withValues(alpha: 0.55)
                    : AppColors.divider,
                width: 1.5,
              ),
              boxShadow: canAfford
                  ? [
                      BoxShadow(
                        color: AppColors.secondary.withValues(alpha: 0.22),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : [],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.pause_rounded,
                  color: canAfford ? AppColors.secondary : AppColors.textMuted,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Pause  \u00b7  $kTimerPauseCost AC',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: canAfford
                            ? AppColors.secondary
                            : AppColors.textMuted,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.sp,
                        letterSpacing: 0.2,
                      ),
                    ),
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
