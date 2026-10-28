// =============================================================================
// widgets/quiz_header.dart
// =============================================================================
// What changed and why:
//
//  COIN PILL
//  • Coin balance now updates via AnimatedSwitcher with a vertical slide-up
//    transition (200 ms). When coins change, the new value slides in from
//    below and the old value exits upward — legible and physically grounded.
//
//  HINT BUTTON
//  • AnimatedContainer transitions colour + border when enabled/disabled
//    (200 ms) so the state change is never a sudden jump.
//  • AnimatedSwitcher on the hint count digit — same slide-up mechanic as
//    the coin pill for consistency.
//  • Tooltip label adapts to all three states: exhausted / can't afford / ready.
//
//  CLOSE BUTTON
//  • Minimum tap target raised to 40×40 (was 38×38; 40 is our floor).
//  • Semantics label added for screen readers.
//
//  QUESTION COUNTER
//  • Semantics wraps the RichText so assistive tech reads "Question 3 of 10".
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../features/quiz/quiz_controller.dart';

class QuizHeader extends StatelessWidget {
  final VoidCallback onQuit;
  const QuizHeader({super.key, required this.onQuit});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm, AppSpacing.md, AppSpacing.lg, 0),
      child: Row(
        children: [
          _CloseButton(onTap: onQuit),
          const SizedBox(width: 14),
          _QuestionCounter(
            current: ctrl.qIndex + 1,
            total:   ctrl.totalQuestions,
          ),
          const Spacer(),
          _CoinPill(balance: ctrl.animeCoins),
          // Hints are disabled in Blitz — hide the button so the header
          // stays clean during the 90s run.
          if (!ctrl.isGauntlet) ...[
            const SizedBox(width: 8),
            _HintButton(
              coins:     ctrl.animeCoins,
              hintsLeft: ctrl.hintsLeft,
              exhausted: ctrl.hintsExhausted,
              isLoading: ctrl.isHintLoading,
              onTap:     ctrl.useHint,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Close button ───────────────────────────────────────────────────────────

class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:  'Quit quiz',
      button: true,
      child: GestureDetector(
        onTap:     onTap,
        behavior:  HitTestBehavior.opaque,
        child: Container(
          width:  40,
          height: 40,
          decoration: BoxDecoration(
            color:  AppColors.surface,
            shape:  BoxShape.circle,
            border: Border.all(color: AppColors.divider, width: 1),
          ),
          child: Icon(
            Icons.close_rounded,
            color: AppColors.textMuted,
            size:  18,
          ),
        ),
      ),
    );
  }
}

// ── Question counter ───────────────────────────────────────────────────────

class _QuestionCounter extends StatelessWidget {
  final int current;
  final int total;
  const _QuestionCounter({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Question $current of $total',
      child: ExcludeSemantics(
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: '$current',
                style: TextStyle(
                  color:      AppColors.textPrimary,
                  fontSize:   22,
                  fontWeight: FontWeight.w900,
                  height:     1,
                ),
              ),
              TextSpan(
                text: ' / $total',
                style: TextStyle(
                  color:      AppColors.textMuted,
                  fontSize:   14,
                  fontWeight: FontWeight.w600,
                  height:     1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Coin pill ──────────────────────────────────────────────────────────────

class _CoinPill extends StatelessWidget {
  final int balance;
  const _CoinPill({required this.balance});

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.coinGold;
    return Semantics(
      label: '$balance anime coins',
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: 7),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border:
              Border.all(color: accent.withValues(alpha: 0.3), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('🪙', style: TextStyle(fontSize: 14.sp)),
            const SizedBox(width: 5),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) => SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.5),
                  end:   Offset.zero,
                ).animate(animation),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                key:   ValueKey(balance),
                child: Text(
                  '$balance',
                  // Key forces AnimatedSwitcher to treat each new value as a
                  // different child, triggering the slide-up transition.
                  style: TextStyle(
                    color:         AppColors.readable(accent),
                    fontWeight:    FontWeight.w800,
                    fontSize:      14.sp,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Hint button ────────────────────────────────────────────────────────────

class _HintButton extends StatelessWidget {
  final int          coins;
  final int          hintsLeft;
  final bool         exhausted;
  final bool         isLoading;
  final VoidCallback onTap;

  const _HintButton({
    required this.coins,
    required this.hintsLeft,
    required this.exhausted,
    this.isLoading = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final canAfford = coins >= kHintCost;
    final active    = !exhausted && canAfford && !isLoading;
    final accent    = active || isLoading
        ? AppColors.secondary
        : AppColors.textMuted;

    final tooltip = isLoading
        ? 'Finding a wrong option…'
        : exhausted
            ? 'No hints left for this question'
            : !canAfford
                ? 'Need $kHintCost 🪙'
                : 'Hint  −$kHintCost 🪙  ($hintsLeft left)';

    return Semantics(
      label:   tooltip,
      button:  true,
      enabled: active,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap:    active ? onTap : null,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve:    Curves.easeOut,
            padding:  EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: active || isLoading
                  ? AppColors.secondary.withValues(alpha: 0.1)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: active || isLoading
                    ? AppColors.secondary.withValues(alpha: 0.35)
                    : AppColors.divider,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: isLoading
                      ? SizedBox(
                          key: const ValueKey('hint-loading'),
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: accent,
                          ),
                        )
                      : Icon(
                          Icons.lightbulb_rounded,
                          key: ValueKey(active),
                          color: accent,
                          size: 15,
                        ),
                ),
                const SizedBox(width: 5),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) => SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.5),
                      end:   Offset.zero,
                    ).animate(animation),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    key:   ValueKey(hintsLeft),
                    child: Text(
                      exhausted ? '0' : '$hintsLeft',
                      style: TextStyle(
                        color:         accent,
                        fontWeight:    FontWeight.w800,
                        fontSize:      14.sp,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                ),
                if (!exhausted) ...[
                  const SizedBox(width: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '−$kHintCost🪙',
                      style: TextStyle(
                        color:
                            accent.withValues(alpha: 0.6),
                        fontSize:   10.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
