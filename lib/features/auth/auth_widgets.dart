import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';

/// Shared pieces for the login, sign-up and verification screens. Visual
/// values come from the app tokens; nothing here introduces a new style.

class AuthLogoMark extends StatelessWidget {
  const AuthLogoMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 84.w,
          height: 84.h,
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              colors: [Color(0x55FF6B6B), Colors.transparent],
            ),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Container(
              width: 72.w,
              height: 72.h,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, Color(0xFFFF6B6B)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(AppRadii.xl),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.45),
                    blurRadius: 28,
                    spreadRadius: 2,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(Icons.quiz_rounded, color: Colors.white, size: 36.r),
            ),
          ),
        ),
        SizedBox(height: 14.h),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [AppColors.primary, Color(0xFFFF6B6B)],
          ).createShader(bounds),
          child: Text(
            'AnimeQuiz',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

class AuthTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onFieldSubmitted;
  final String? Function(String?)? validator;
  final Widget? suffixIcon;
  final bool enabled;

  const AuthTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onFieldSubmitted,
    this.validator,
    this.suffixIcon,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      style: TextStyle(color: AppColors.textPrimary, fontSize: 15.sp),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: AppColors.textMuted, size: 20.r),
        suffixIcon: suffixIcon,
      ),
    );
  }
}

/// Inline error for a failed sign-in / sign-up / verification step. Sits next
/// to the action it belongs to instead of flashing a snackbar that is gone
/// before the player reads it.
class AuthInlineError extends StatelessWidget {
  final String? message;
  const AuthInlineError({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    if (message == null || message!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: AppSpacing.md),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.wrong.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.wrong.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 18.r, color: AppColors.errorText),
            SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message!,
                style: AppTypography.bodyMedium.copyWith(
                  color: AppColors.errorText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
