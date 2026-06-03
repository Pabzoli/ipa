// =============================================================================
// widgets/quiz_error_view.dart
// =============================================================================
// What changed and why:
//
//  ANIMATED RETRY
//  • The original error view had no feedback between tapping "Try Again" and
//    the loading state appearing — tapping felt unresponsive.
//  • AnimatedSwitcher (200 ms) swaps the GradientButton for a compact
//    CircularProgressIndicator when _retrying is true. The user gets instant
//    visual confirmation that the tap registered.
//  • _retrying is never manually reset to false because the error widget will
//    be replaced by the skeleton as soon as loadQuestions triggers a rebuild.
//
//  SEMANTICS
//  • The warning icon container is ExcludeSemantics (decorative emoji).
//  • The error message Text has an implicit semantics node.
//  • The retry button inherits its semantics from GradientButton's own label.
// =============================================================================

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shared_widgets.dart';

class QuizErrorView extends StatefulWidget {
  final String       message;
  final VoidCallback onRetry;

  const QuizErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  State<QuizErrorView> createState() => _QuizErrorViewState();
}

class _QuizErrorViewState extends State<QuizErrorView> {
  bool _retrying = false;

  void _handleRetry() {
    if (_retrying) return;
    setState(() => _retrying = true);
    widget.onRetry();
    // No need to reset _retrying — this widget is replaced by the skeleton
    // once loadQuestions sets isLoading = true and notifies listeners.
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Warning icon
            ExcludeSemantics(
              child: Container(
                width:  72,
                height: 72,
                decoration: BoxDecoration(
                  color:  AppColors.wrong.withOpacity(0.1),
                  shape:  BoxShape.circle,
                  border: Border.all(
                    color: AppColors.wrong.withOpacity(0.25),
                    width: 1.5,
                  ),
                ),
                child: const Center(
                  child: Text('⚠️', style: TextStyle(fontSize: 32)),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              widget.message,
              style: const TextStyle(
                color:    AppColors.textSecondary,
                fontSize: 15,
                height:   1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            // Button ↔ spinner swap
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve:  Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _retrying
                  ? const SizedBox(
                      key:    ValueKey('spinner'),
                      width:  44,
                      height: 44,
                      child:  CircularProgressIndicator(
                        color:       AppColors.primary,
                        strokeWidth: 2.5,
                        strokeCap:   StrokeCap.round,
                      ),
                    )
                  : GradientButton(
                      key:   ValueKey('button'),
                      label: 'Try Again',
                      icon:  Icons.refresh_rounded,
                      onTap: _handleRetry,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
