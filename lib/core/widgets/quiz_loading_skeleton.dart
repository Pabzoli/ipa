// =============================================================================
// widgets/quiz_loading_skeleton.dart
// =============================================================================
// What changed and why:
//
//  FROM SPINNER → SKELETON
//  • A lone CircularProgressIndicator tells the user nothing about what they
//    are waiting for. The skeleton mirrors the actual layout (title chip +
//    question card rectangle + four option rectangles) so the transition from
//    loading to loaded is seamless — content appears in-place.
//
//  PULSE IMPLEMENTATION
//  • Single AnimationController drives an opacity tween (0.30 → 0.70).
//  • repeat(reverse: true) creates an organic breathing pulse.
//  • All skeleton blocks share the same opacity via AnimatedBuilder so there
//    is only ONE animation object, not one per block.
//  • No shimmer package required — achieves the same communicative effect with
//    first-party Flutter APIs.
//
//  PROPORTIONS
//  • Block sizes are chosen to match the real widgets they represent:
//    - 16 h × 80 w  → anime title chip
//    - 160 h full   → question card body
//    - 56 h full × 4 → option tiles
//  • Radii match the real widget radii (28 for card, 20 for options, 8 for chip).
// =============================================================================

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

class QuizLoadingSkeletonView extends StatefulWidget {
  const QuizLoadingSkeletonView({super.key});

  @override
  State<QuizLoadingSkeletonView> createState() =>
      _QuizLoadingSkeletonViewState();
}

class _QuizLoadingSkeletonViewState extends State<QuizLoadingSkeletonView>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.30, end: 0.70).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (_, __) => Opacity(
        opacity: _opacity.value,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              // Header row mock
              _ShimmerBlock(height: 12, width: 140, radius: 8),
              SizedBox(height: 20),
              // Question card mock
              _ShimmerBlock(height: 156, width: double.infinity, radius: 28),
              SizedBox(height: 20),
              // Option tiles mock
              _ShimmerBlock(height: 56, width: double.infinity, radius: 20),
              SizedBox(height: 10),
              _ShimmerBlock(height: 56, width: double.infinity, radius: 20),
              SizedBox(height: 10),
              _ShimmerBlock(height: 56, width: double.infinity, radius: 20),
              SizedBox(height: 10),
              _ShimmerBlock(height: 56, width: double.infinity, radius: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Shimmer block ──────────────────────────────────────────────────────────

class _ShimmerBlock extends StatelessWidget {
  final double height;
  final double width;
  final double radius;

  const _ShimmerBlock({
    required this.height,
    required this.width,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width:  width,
      decoration: BoxDecoration(
        // TODO: migrate to Theme.of(context).colorScheme.surfaceContainerHighest
        color:        AppColors.divider,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
