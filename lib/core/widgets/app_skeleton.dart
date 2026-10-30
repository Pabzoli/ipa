import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AppSkeleton extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const AppSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = AppRadii.lg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
