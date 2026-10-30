import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/theme/app_theme.dart';
import 'app_button.dart';

class QuizErrorView extends StatefulWidget {
  final String message;
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
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.wrong.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.wrong.withValues(alpha: 0.25),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Text('⚠️', style: TextStyle(fontSize: 32.sp)),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                widget.message,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 15.sp,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 220,
              child: AppButton(
                label: 'Try Again',
                icon: Icon(Icons.refresh_rounded, size: 18),
                variant: AppButtonVariant.gradient,
                size: AppButtonSize.large,
                loading: _retrying,
                onPressed: _handleRetry,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
