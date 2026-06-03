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
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
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
          const SizedBox(width: 8),
          _HintButton(
            coins:     ctrl.animeCoins,
            hintsLeft: ctrl.hintsLeft,
            exhausted: ctrl.hintsExhausted,
            onTap:     ctrl.useHint,
          ),
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
          child: const Icon(
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
                style: const TextStyle(
                  color:      AppColors.textPrimary,
                  fontSize:   22,
                  fontWeight: FontWeight.w900,
                  height:     1,
                ),
              ),
              TextSpan(
                text: ' / $total',
                style: const TextStyle(
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

  // TODO: migrate to Theme.of(context).colorScheme.tertiary (gold role)
  static const _gold = Color(0xFFFBBF24);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$balance anime coins',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color:        _gold.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(color: _gold.withOpacity(0.3), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🪙', style: TextStyle(fontSize: 14)),
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
              child: Text(
                '$balance',
                // Key forces AnimatedSwitcher to treat each new value as a
                // different child, triggering the slide-up transition.
                key:   ValueKey(balance),
                style: const TextStyle(
                  color:         _gold,
                  fontWeight:    FontWeight.w800,
                  fontSize:      14,
                  letterSpacing: -0.3,
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
  final VoidCallback onTap;

  const _HintButton({
    required this.coins,
    required this.hintsLeft,
    required this.exhausted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final canAfford = coins >= kHintCost;
    final active    = !exhausted && canAfford;
    final accent    = active ? AppColors.secondary : AppColors.textMuted;

    final tooltip = exhausted
        ? 'No hints left this quiz'
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
            padding:  const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: active
                  ? AppColors.secondary.withOpacity(0.1)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active
                    ? AppColors.secondary.withOpacity(0.35)
                    : AppColors.divider,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.lightbulb_rounded,
                    key:   ValueKey(active),
                    color: accent,
                    size:  15,
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
                  child: Text(
                    exhausted ? '0' : '$hintsLeft',
                    key:   ValueKey(hintsLeft),
                    style: TextStyle(
                      color:         accent,
                      fontWeight:    FontWeight.w800,
                      fontSize:      14,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                if (!exhausted) ...[
                  const SizedBox(width: 4),
                  Text(
                    '−${kHintCost}🪙',
                    style: TextStyle(
                      color:      accent.withOpacity(0.6),
                      fontSize:   10,
                      fontWeight: FontWeight.w700,
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
