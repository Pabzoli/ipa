// lib/core/widgets/progress_segments.dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../theme/app_theme.dart';
import '../../features/quiz/quiz_controller.dart';

class QuizProgressSegments extends StatelessWidget {
  const QuizProgressSegments({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();

    return Semantics(
      label: 'Progress: question ${ctrl.qIndex + 1} of ${ctrl.totalQuestions}',
      child: Padding(
        padding: EdgeInsets.fromLTRB(16.r, 12.r, 16.r, 0),
        child: Row(
          children: List.generate(ctrl.totalQuestions, (i) {
            // Colour reflects whether it was actually answered correctly,
            // not just "visited" — same information richness as Rankings.
            Color color;
            if (i < ctrl.answerResults.length) {
              final result = ctrl.answerResults[i];
              // Null = answered but correctness withheld (Blitz/challenge).
              color = result == null
                  ? AppColors.textMuted
                  : (result ? AppColors.correct : AppColors.wrong);
            } else if (i == ctrl.qIndex) {
              color = AppColors.primary;
            } else {
              color = AppColors.divider;
            }

            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                    right: i < ctrl.totalQuestions - 1 ? 4.r : 0),
                child: _Segment(
                  color: color,
                  isCurrent: i == ctrl.qIndex,
                  justFilled: i == ctrl.selectedAnswers.length - 1,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ─── Individual segment ─────────────────────────────────────────────────────
class _Segment extends StatefulWidget {
  final Color color;
  final bool isCurrent;
  final bool justFilled;
  const _Segment({
    required this.color,
    required this.isCurrent,
    required this.justFilled,
  });

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _scale = const AlwaysStoppedAnimation(1.0);
  }

  @override
  void didUpdateWidget(_Segment old) {
    super.didUpdateWidget(old);
    // Pulse only the instant a segment gets its result colour — kinetic
    // feedback tied to real state, not decoration.
    if (!old.justFilled && widget.justFilled) {
      _scale = TweenSequence<double>([
        TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.4), weight: 35),
        TweenSequenceItem(tween: Tween(begin: 1.4, end: 1.0), weight: 65),
      ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _scale,
      builder: (_, child) =>
          Transform.scale(scaleY: _scale.value, child: child),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        height: widget.isCurrent ? 5 : 4,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.full),
          color: widget.color,
        ),
      ),
    );
  }
}
