// =============================================================================
// widgets/progress_segments.dart
// =============================================================================
// What changed and why:
//
//  COMPLETION PULSE
//  • Each segment is a StatefulWidget (_Segment) that detects when it
//    transitions from current → done via didUpdateWidget.
//  • On that transition a TweenSequence pulses the segment's scale:
//    1.0 → 1.4 → 1.0 over 300 ms (Curves.easeOut). This gives kinetic
//    feedback as the player moves through the quiz.
//
//  SEMANTICS
//  • The Row is wrapped in a single Semantics node that reads
//    "Progress: question N of M" so screen readers don't enumerate
//    10 individual decorative bars.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/quiz/quiz_controller.dart';

class QuizProgressSegments extends StatelessWidget {
  const QuizProgressSegments({super.key});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();

    return Semantics(
      label: 'Progress: question ${ctrl.qIndex + 1} of ${ctrl.totalQuestions}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(
          children: List.generate(ctrl.totalQuestions, (i) {
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _Segment(
                  isCurrent: i == ctrl.qIndex,
                  isDone:    i < ctrl.qIndex,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ── Individual segment ─────────────────────────────────────────────────────

class _Segment extends StatefulWidget {
  final bool isCurrent;
  final bool isDone;
  const _Segment({required this.isCurrent, required this.isDone});

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 300),
    );
    // Neutral scale — controller only plays on completion pulse.
    _scale = Tween<double>(begin: 1.0, end: 1.0).animate(_ctrl);
  }

  @override
  void didUpdateWidget(_Segment old) {
    super.didUpdateWidget(old);
    // Pulse only when this segment transitions from current → done.
    if (!old.isDone && widget.isDone) {
      _scale = TweenSequence<double>([
        TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.35), weight: 35),
        TweenSequenceItem(tween: Tween(begin: 1.35, end: 1.0),  weight: 65),
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
    return ScaleTransition(
      scale: _scale,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve:    Curves.easeOut,
        height:   widget.isCurrent ? 5 : 4,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          color: widget.isDone
              ? AppColors.primary.withOpacity(0.7)
              : widget.isCurrent
                  ? AppColors.primary
                  : AppColors.divider,
        ),
      ),
    );
  }
}
