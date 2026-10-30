import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/shared_widgets.dart';
import '../legal/legal_pages.dart';
import 'auth_service.dart';
import 'auth_widgets.dart';

/// Create-account form. Submitting signs the player in and sends the
/// verification email; AuthGate then shows the verification screen.
class RegisterForm extends StatefulWidget {
  final VoidCallback onBack;
  const RegisterForm({super.key, required this.onBack});

  @override
  State<RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<RegisterForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _referralCodeCtrl = TextEditingController();

  late final TapGestureRecognizer _termsTap;
  late final TapGestureRecognizer _privacyTap;

  bool _obscure = true;
  bool _loading = false;
  bool _agreed = false;
  bool _showOptional = false;
  String? _error;
  String? _selectedUniversity;

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
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _referralCodeCtrl.dispose();
    super.dispose();
  }

  void _open(Widget page) {
    Navigator.of(context).push(AppPageRoute(builder: (_) => page));
  }

  Future<void> _register() async {
    if (!_agreed) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AuthService.instance.signUp(
        email: _emailCtrl.text,
        password: _passCtrl.text,
        username: _nameCtrl.text,
        termsAccepted: _agreed,
        university: _selectedUniversity,
        referredBy: _referralCodeCtrl.text,
      );
    } on SignUpException catch (e) {
      _fail(e.message);
    } on FirebaseAuthException catch (e) {
      _fail(_authError(e.code, e.message));
    } catch (_) {
      _fail(
          'Could not create your account. Check your connection and try again.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
  }

  String _authError(String code, String? fallback) {
    switch (code) {
      case 'email-already-in-use':
        return 'An account with this email already exists. Sign in instead.';
      case 'weak-password':
        return 'Choose a stronger password (at least 6 characters).';
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'network-request-failed':
        return 'No connection. Check your internet and try again.';
      default:
        return fallback ?? 'Registration failed. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _agreed && !_loading;
    return SafeArea(
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(28.r, 8.r, 28.r, 24.r),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  AppBackButton(
                    onPressed: _loading ? null : widget.onBack,
                    tooltip: 'Back to sign in',
                  ),
                  SizedBox(width: 4.w),
                  Expanded(
                    child: Text(
                      'Create Account',
                      style: AppTypography.heading2,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8.h),
              Text(
                'Only 3 fields to get started.',
                style: AppTypography.bodySmall,
              ),
              SizedBox(height: 20.h),
              GlassCard(
                child: Column(
                  children: [
                    AuthTextField(
                      controller: _nameCtrl,
                      label: 'Username',
                      icon: Icons.person_outline,
                      enabled: !_loading,
                      textInputAction: TextInputAction.next,
                      validator: (v) => (v == null || v.trim().length < 3)
                          ? 'Username must be at least 3 characters'
                          : null,
                    ),
                    SizedBox(height: 14.h),
                    AuthTextField(
                      controller: _emailCtrl,
                      label: 'Email',
                      icon: Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      enabled: !_loading,
                      textInputAction: TextInputAction.next,
                      validator: (v) => (v == null || !v.contains('@'))
                          ? 'Enter a valid email'
                          : null,
                    ),
                    SizedBox(height: 14.h),
                    AuthTextField(
                      controller: _passCtrl,
                      label: 'Password',
                      icon: Icons.lock_outline,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.newPassword],
                      enabled: !_loading,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _register(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: AppColors.textMuted,
                          size: 20.r,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      validator: (v) => (v == null || v.length < 6)
                          ? 'Password must be at least 6 characters'
                          : null,
                    ),
                  ],
                ),
              ),
              SizedBox(height: 8.h),
              TextButton.icon(
                onPressed: _loading
                    ? null
                    : () => setState(() => _showOptional = !_showOptional),
                icon: Icon(
                  _showOptional
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: AppColors.textMuted,
                  size: 20.r,
                ),
                label: Text(
                  _showOptional
                      ? 'Hide optional details'
                      : 'Add university or referral code (optional)',
                  style: AppTypography.bodySmall.copyWith(
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_showOptional) ...[
                GlassCard(
                  child: Column(
                    children: [
                      _UniversityDropdown(
                        value: _selectedUniversity,
                        enabled: !_loading,
                        onChanged: (v) =>
                            setState(() => _selectedUniversity = v),
                      ),
                      SizedBox(height: 14.h),
                      AuthTextField(
                        controller: _referralCodeCtrl,
                        label: 'Referral code (optional)',
                        icon: Icons.person_add_rounded,
                        enabled: !_loading,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _register(),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 8.h),
              ],
              SizedBox(height: 8.h),
              _TermsCheckbox(
                value: _agreed,
                enabled: !_loading,
                onChanged: (v) => setState(() => _agreed = v),
                termsTap: _termsTap,
                privacyTap: _privacyTap,
              ),
              AuthInlineError(message: _error),
              SizedBox(height: 20.h),
              AppButton(
                label: 'Create Account',
                onPressed: canSubmit ? _register : null,
                loading: _loading,
                icon: Icon(Icons.person_add_rounded, size: 20.r),
                variant: AppButtonVariant.gradient,
                width: double.infinity,
                height: 56.h,
              ),
              SizedBox(height: 12.h),
              Center(
                child: TextButton(
                  onPressed: _loading ? null : widget.onBack,
                  child: Text(
                    'Already have an account? Sign in',
                    style: TextStyle(
                      color: AppColors.primaryText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TermsCheckbox extends StatelessWidget {
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final TapGestureRecognizer termsTap;
  final TapGestureRecognizer privacyTap;

  const _TermsCheckbox({
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.termsTap,
    required this.privacyTap,
  });

  @override
  Widget build(BuildContext context) {
    final base =
        AppTypography.bodyMedium.copyWith(color: AppColors.textPrimary);
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
                  TextSpan(
                      text: 'Terms of Service',
                      style: link,
                      recognizer: termsTap),
                  const TextSpan(text: ' and '),
                  TextSpan(
                      text: 'Privacy Policy',
                      style: link,
                      recognizer: privacyTap),
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

class _UniversityDropdown extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  const _UniversityDropdown({
    required this.value,
    required this.onChanged,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      dropdownColor: AppColors.surface,
      icon: Icon(Icons.expand_more_rounded,
          color: AppColors.textMuted, size: 20.r),
      decoration: InputDecoration(
        labelText: 'University',
        prefixIcon:
            Icon(Icons.school_outlined, color: AppColors.textMuted, size: 20.r),
        contentPadding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 14.r),
      ),
      style: TextStyle(color: AppColors.textPrimary, fontSize: 15.sp),
      hint: Text(
        'Select your university',
        style: TextStyle(color: AppColors.textMuted),
      ),
      items: kNigerianUniversities
          .map(
            (u) => DropdownMenuItem(
              value: u,
              child: Text(u, style: TextStyle(color: AppColors.textPrimary)),
            ),
          )
          .toList(),
      onChanged: enabled ? onChanged : null,
    );
  }
}
