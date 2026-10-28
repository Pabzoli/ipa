import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/shared_widgets.dart';
import '../legal/legal_pages.dart';
import 'auth_service.dart';
import 'auth_widgets.dart';

/// One-time re-acceptance screen for accounts created before terms were
/// stamped (no `termsAcceptedAt` on the user doc). Shown once, after the
/// email-verification gate and before the app. Same checkbox and links as
/// signup; acceptance is stamped server-side via `acceptTerms`.
class TermsAcceptancePage extends StatefulWidget {
  final VoidCallback onAccepted;
  const TermsAcceptancePage({super.key, required this.onAccepted});

  @override
  State<TermsAcceptancePage> createState() => _TermsAcceptancePageState();
}

class _TermsAcceptancePageState extends State<TermsAcceptancePage> {
  late final TapGestureRecognizer _termsTap;
  late final TapGestureRecognizer _privacyTap;

  bool _agreed = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _termsTap = TapGestureRecognizer()
      ..onTap = () => _open(const TermsOfServicePage());
    _privacyTap = TapGestureRecognizer()
      ..onTap = () => _open(const PrivacyPolicyPage());
  }

  @override
  void dispose() {
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  void _open(Widget page) {
    Navigator.of(context).push(AppPageRoute(builder: (_) => page));
  }

  Future<void> _accept() async {
    if (!_agreed || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AuthService.instance.acceptTerms();
      widget.onAccepted();
    } on AuthFlowException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not save your acceptance. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      backgroundColor: Colors.transparent,
      body: AnimatedHeroBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(28.r, 24.r, 28.r, 24.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const AuthLogoMark(),
                SizedBox(height: 32.h),
                Text('Terms Update', style: AppTypography.heading1),
                SizedBox(height: 12.h),
                Text(
                  'We have updated our Terms of Service and Privacy Policy. '
                  'Please accept them once to continue using AnimeQuiz.',
                  style: AppTypography.bodyMedium,
                ),
                SizedBox(height: 24.h),
                GlassCard(
                  child: _TermsAcceptCheckbox(
                    value: _agreed,
                    enabled: !_loading,
                    onChanged: (v) => setState(() => _agreed = v),
                    termsTap: _termsTap,
                    privacyTap: _privacyTap,
                  ),
                ),
                AuthInlineError(message: _error),
                SizedBox(height: 20.h),
                AppButton(
                  label: 'Accept & Continue',
                  onPressed: _agreed && !_loading ? _accept : null,
                  loading: _loading,
                  icon: Icon(Icons.check_rounded, size: 20.r),
                  variant: AppButtonVariant.gradient,
                  width: double.infinity,
                  height: 56.h,
                ),
                SizedBox(height: 12.h),
                Center(
                  child: TextButton(
                    onPressed: _loading
                        ? null
                        : () async {
                            await AuthService.instance.signOut();
                          },
                    child: Text(
                      'Sign out',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Same checkbox copy and links as the sign-up form.
class _TermsAcceptCheckbox extends StatelessWidget {
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final TapGestureRecognizer termsTap;
  final TapGestureRecognizer privacyTap;

  const _TermsAcceptCheckbox({
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.termsTap,
    required this.privacyTap,
  });

  @override
  Widget build(BuildContext context) {
    final base = AppTypography.bodyMedium.copyWith(color: AppColors.textPrimary);
    final link = base.copyWith(
      color: AppColors.primaryText,
      fontWeight: FontWeight.w800,
      decoration: TextDecoration.underline,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24.r,
          height: 24.r,
          child: Checkbox(
            value: value,
            activeColor: AppColors.primary,
            onChanged: enabled ? (v) => onChanged(v ?? false) : null,
          ),
        ),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: 2.r),
            child: Text.rich(
              TextSpan(
                style: base,
                children: [
                  const TextSpan(text: 'I agree to the '),
                  TextSpan(text: 'Terms of Service', style: link, recognizer: termsTap),
                  const TextSpan(text: ' and '),
                  TextSpan(text: 'Privacy Policy', style: link, recognizer: privacyTap),
                  const TextSpan(text: '.'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
