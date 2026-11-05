import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_service.dart';

/// Shown when the auto-ban system has suspended the account.
///
/// Copy stays generic on purpose: the server never tells the client *why* it
/// was flagged (that would be a cheat-detection oracle).
class BannedScreen extends StatelessWidget {
  const BannedScreen({super.key});

  Future<void> _signOut(BuildContext context) async {
    try {
      await AuthService.instance.signOut();
    } catch (_) {
      // Sign-out always proceeds locally; a backend failure is ignored.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: AnimatedHeroBackground(
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(28.r, 48.r, 28.r, 24.r),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.gpp_bad_outlined,
                  size: 64.r,
                  color: AppColors.textMuted,
                ),
                SizedBox(height: AppSpacing.xl),
                Text(
                  'Account under review',
                  style: AppTypography.heading1,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: AppSpacing.md),
                Text(
                  'This account has been temporarily suspended while we review '
                  'unusual activity. If you think this is a mistake, contact support.',
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: AppSpacing.xxl),
                AppButton(
                  label: 'Sign Out',
                  onPressed: () => _signOut(context),
                  variant: AppButtonVariant.secondary,
                  width: double.infinity,
                  height: 52.h,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
