import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../theme/app_theme.dart';

/// Canonical header back button — matches Earn Coins.
///
///Icon: `arrow_back_ios_new_rounded`, 19.r, [AppColors.textPrimary],
/// splashRadius 22. Use everywhere a header back is needed so the app
/// keeps one back button style (and, paired with [AppPageRoute], one
/// transition animation).
class AppBackButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String? tooltip;

  const AppBackButton({super.key, this.onPressed, this.tooltip = 'Back'});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
      icon: Icon(
        Icons.arrow_back_ios_new_rounded,
        color: AppColors.textPrimary,
        size: 19.r,
      ),
      splashRadius: 22,
      tooltip: tooltip,
    );
  }
}
