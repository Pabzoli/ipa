import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_button.dart';

/// Confirmation shown after a feedback submission succeeds.
class SupportSentView extends StatelessWidget {
  const SupportSentView({
    super.key,
    required this.replyEmail,
    required this.onSendAnother,
  });

  final String replyEmail;
  final VoidCallback onSendAnother;

  @override
  Widget build(BuildContext context) {
    final replyLine = replyEmail.isEmpty
        ? 'If we need more detail, we will get back to you.'
        : 'If we need more detail, we will reply to $replyEmail.';

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24.r, 40.h, 24.r, 32.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 92.r,
              height: 92.r,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.correct.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.correct.withValues(alpha: 0.35),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.correct.withValues(alpha: 0.18),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(
                Icons.check_rounded,
                color: AppColors.readable(AppColors.correct),
                size: 46.r,
              ),
            ),
          ),
          SizedBox(height: 22.h),
          Text(
            'Message sent',
            textAlign: TextAlign.center,
            style: AppTypography.heading2,
          ),
          SizedBox(height: 8.h),
          Text(
            'Thanks for taking the time. We read every report — bug, idea or '
            'question — and use them to make the app better.',
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium,
          ),
          SizedBox(height: 6.h),
          Text(
            replyLine,
            textAlign: TextAlign.center,
            style: AppTypography.bodySmall,
          ),
          SizedBox(height: 28.h),
          AppButton(
            label: 'Send another message',
            icon: const Icon(Icons.edit_outlined),
            onPressed: onSendAnother,
          ),
          SizedBox(height: 8.h),
          AppButton(
            label: 'Back to app',
            variant: AppButtonVariant.text,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}
