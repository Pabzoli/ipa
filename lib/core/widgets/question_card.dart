// =============================================================================
// widgets/question_card.dart
// =============================================================================
// What changed and why:
//
//  WATERMARK ANIMATION
//  • The ghost question-number watermark is now wrapped in AnimatedSwitcher
//    (250 ms FadeTransition). When the question advances the old number fades
//    out and the new one fades in — previously it snapped with no transition.
//
//  CARD WIDGET
//  • Uses Material 3 Card widget with surfaceContainerHigh colour role comment.
//    Currently AppColors.surface is used directly; the TODO marks where to
//    migrate once the app adopts a full ColorScheme.
//  • elevation: 0 with manual BoxShadow — gives us precise control over the
//    premium double-shadow that defines the card's depth.
//
//  SEMANTICS
//  • The question text has a Semantics node with the full text for screen
//    readers; the decorative watermark is excluded from semantics.
//  • The anime title chip is read as "Anime: [title]".
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../features/quiz/quiz_controller.dart';

class QuestionCardWidget extends StatelessWidget {
  const QuestionCardWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();
    final q    = ctrl.currentQuestion;
    if (q == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 20, AppSpacing.lg, AppSpacing.lg),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.feature),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 32,
              offset:     const Offset(0, 8),
            ),
            BoxShadow(
              color:
                  AppColors.primary.withValues(alpha: 0.07),
              blurRadius:   40,
              spreadRadius: -4,
            ),
          ],
        ),
        child: Card(
          // TODO: migrate to Theme.of(context).colorScheme.surfaceContainerHigh
          color:     AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.feature),
            side: BorderSide(
              color: AppColors.primary.withValues(alpha: 0.18),
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
            child: Stack(
              children: [
                // Animated ghost watermark — decorative only, excluded from a11y
                Positioned(
                  top:   -10,
                  right: -4,
                  child: ExcludeSemantics(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: Text(
                        '${ctrl.qIndex + 1}',
                        key:   ValueKey(ctrl.qIndex),
                        style: TextStyle(
                          color:
                              AppColors.primary.withValues(alpha: 0.06),
                          fontSize:   100,
                          fontWeight: FontWeight.w900,
                          height:     1,
                        ),
                      ),
                    ),
                  ),
                ),
                // Card content
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AnimeTitleChip(title: q.animeTitle),
                    const SizedBox(height: 18),
                    Semantics(
                      label: q.question,
                      child: Text(
                        q.question,
                        style: TextStyle(
                          color:         AppColors.textPrimary,
                          fontSize:      19.sp,
                          fontWeight:    FontWeight.w700,
                          height:        1.5,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Anime title chip ───────────────────────────────────────────────────────

class _AnimeTitleChip extends StatelessWidget {
  final String title;
  const _AnimeTitleChip({required this.title});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Anime: $title',
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: 5),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.primary.withValues(alpha: 0.2),
              AppColors.primary.withValues(alpha: 0.08),
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            color:         AppColors.primaryText,
            fontSize:      10.sp,
            fontWeight:    FontWeight.w800,
            letterSpacing: 1.8,
          ),
        ),
      ),
    );
  }
}
