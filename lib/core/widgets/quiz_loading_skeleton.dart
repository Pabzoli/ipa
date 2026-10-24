import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'app_skeleton.dart';

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
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.page, AppSpacing.xl, AppSpacing.page, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppSkeleton(height: 12, width: 140, radius: AppRadii.sm),
              const SizedBox(height: 20),
              AppSkeleton(
                  height: 156, width: double.infinity, radius: AppRadii.feature),
              const SizedBox(height: 20),
              AppSkeleton(
                  height: 56, width: double.infinity, radius: AppRadii.xl),
              const SizedBox(height: 10),
              AppSkeleton(
                  height: 56, width: double.infinity, radius: AppRadii.xl),
              const SizedBox(height: 10),
              AppSkeleton(
                  height: 56, width: double.infinity, radius: AppRadii.xl),
              const SizedBox(height: 10),
              AppSkeleton(
                  height: 56, width: double.infinity, radius: AppRadii.xl),
            ],
          ),
        ),
      ),
    );
  }
}