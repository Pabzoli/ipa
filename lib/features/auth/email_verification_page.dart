import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_sheet.dart';
import 'auth_service.dart';
import 'auth_widgets.dart';

/// Shown by AuthGate to every signed-in account whose email is not verified.
/// It is the only screen such an account can reach: no solo play, no app.
///
/// The resend budget is owned by the server. The countdown uses the
/// `retryAfterSeconds` it returns, so the UI cannot drift from the limit.
class EmailVerificationPage extends StatefulWidget {
  final VoidCallback onVerified;

  const EmailVerificationPage({super.key, required this.onVerified});

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  bool _sending = false;
  bool _checking = false;
  bool _signingOut = false;
  String? _error;
  String? _notice;
  int _secondsLeft = 0;
  int? _remainingToday;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    setState(() => _secondsLeft = seconds.clamp(0, 86400));
    if (_secondsLeft <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _secondsLeft = (_secondsLeft - 1).clamp(0, 86400));
      if (_secondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _resend() async {
    if (_sending || _secondsLeft > 0) return;
    setState(() {
      _sending = true;
      _error = null;
      _notice = null;
    });
    try {
      final data = await AuthService.instance.sendVerificationEmail();
      if (!mounted) return;
      if (data['alreadyVerified'] == true) {
        await _checkVerified();
        return;
      }
      final ok = data['ok'] == true;
      setState(() {
        _sending = false;
        _remainingToday = (data['remainingToday'] as num?)?.toInt();
        _notice = ok
            ? 'Email sent. Check your inbox and spam folder.'
            : null;
        if (!ok) {
          _error = (data['remainingToday'] as num?) == 0
              ? 'You have reached today\'s limit for verification emails. Try again tomorrow.'
              : 'Please wait before requesting another email.';
        }
      });
      final wait = (data['retryAfterSeconds'] as num?)?.toInt() ?? 0;
      _startCountdown(ok ? 60 : wait);
    } on AuthFlowException catch (e) {
      if (mounted) setState(() { _sending = false; _error = e.message; });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Could not send the email. Check your connection and try again.';
      });
    }
  }

  Future<void> _checkVerified() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final verified = await AuthService.instance.refreshEmailVerification();
      if (!mounted) return;
      if (verified) {
        widget.onVerified();
        return;
      }
      setState(() {
        _checking = false;
        _error = 'Not verified yet. Open the link in the email, then try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = 'Could not check verification. Try again in a moment.';
      });
    }
  }

  Future<void> _changeEmail() async {
    final changed = await showAppSheet<bool>(
      context,
      builder: (_) => const _ChangeEmailSheet(),
    );
    if (changed == true && mounted) {
      setState(() {
        _error = null;
        _notice =
            'We sent a confirmation link to the new address. Open it, then '
            'come back and tap "I\'ve verified".';
      });
    }
  }

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final email = AuthService.instance.accountEmail;
    final busy = _checking || _sending || _signingOut;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        title: const Text('Verify your email'),
        backgroundColor: AppColors.surfaceDim,
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: busy ? null : _signOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.all(AppSpacing.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.mark_email_unread_rounded,
                size: 56.r,
                color: AppColors.primary,
              ),
              SizedBox(height: AppSpacing.lg),
              Text(
                'Verify your email to continue',
                style: AppTypography.heading3,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: AppSpacing.sm),
              Text(
                'AnimeQuiz is available once your email is verified.',
                style: AppTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: AppSpacing.xl),
              if (email.isEmpty)
                AppCard(
                  child: Column(
                    children: [
                      Text(
                        'We could not read the email on this account.',
                        style: AppTypography.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: AppSpacing.md),
                      AppButton(
                        label: 'Sign out and try again',
                        variant: AppButtonVariant.outline,
                        onPressed: busy ? null : _signOut,
                      ),
                    ],
                  ),
                )
              else
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('We sent a link to', style: AppTypography.bodySmall),
                      SizedBox(height: AppSpacing.xs),
                      Text(email, style: AppTypography.titleMedium),
                      SizedBox(height: AppSpacing.md),
                      Text(
                        'Open the link on this device, then tap "I\'ve verified". '
                        'If it is not in your inbox, check spam or resend below.',
                        style: AppTypography.bodyMedium,
                      ),
                      SizedBox(height: AppSpacing.md),
                      Text(
                        'Accounts that never verify are deleted 7 days after signup.',
                        style: AppTypography.bodySmall,
                      ),
                    ],
                  ),
                ),
              if (_notice != null) ...[
                SizedBox(height: AppSpacing.md),
                Text(
                  _notice!,
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.successText,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              AuthInlineError(message: _error),
              SizedBox(height: AppSpacing.xl),
              AppButton(
                label: _checking ? 'Checking…' : "I've verified",
                loading: _checking,
                onPressed: busy || email.isEmpty ? null : _checkVerified,
              ),
              SizedBox(height: AppSpacing.md),
              AppButton(
                label: _secondsLeft > 0
                    ? 'Resend in ${_secondsLeft}s'
                    : 'Resend verification email',
                variant: AppButtonVariant.outline,
                loading: _sending,
                onPressed: busy || _secondsLeft > 0 || email.isEmpty
                    ? null
                    : _resend,
              ),
              if (_remainingToday != null) ...[
                SizedBox(height: AppSpacing.sm),
                Text(
                  '$_remainingToday sends left today',
                  style: AppTypography.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
              SizedBox(height: AppSpacing.md),
              AppButton(
                label: 'Wrong email? Change it',
                variant: AppButtonVariant.text,
                onPressed: busy || email.isEmpty ? null : _changeEmail,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for the new address and the current password (Firebase needs a recent
/// sign-in to change the email). Pops `true` once the link has been sent.
class _ChangeEmailSheet extends StatefulWidget {
  const _ChangeEmailSheet();

  @override
  State<_ChangeEmailSheet> createState() => _ChangeEmailSheetState();
}

class _ChangeEmailSheetState extends State<_ChangeEmailSheet> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await AuthService.instance.changeUnverifiedEmail(
        newEmail: _emailCtrl.text,
        password: _passCtrl.text,
      );
      if (!mounted) return;
      if (data['ok'] != true) {
        final wait = (data['retryAfterSeconds'] as num?)?.toInt() ?? 0;
        setState(() {
          _loading = false;
          _error = wait > 0
              ? 'Please wait ${wait}s before requesting another email.'
              : 'You have reached today\'s limit for verification emails.';
        });
        return;
      }
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      _fail(switch (e.code) {
        'wrong-password' || 'invalid-credential' => 'That password is not correct.',
        'invalid-email' => 'That email address is not valid.',
        'email-already-in-use' => 'Another account already uses that email.',
        'too-many-requests' => 'Too many attempts. Try again later.',
        'network-request-failed' => 'No connection. Check your internet and try again.',
        _ => e.message ?? 'Could not change your email. Try again.',
      });
    } on AuthFlowException catch (e) {
      _fail(e.message);
    } on FirebaseFunctionsException catch (e) {
      // The server's messages are written for the player.
      _fail(e.message ?? 'Could not change your email. Try again.');
    } catch (_) {
      _fail('Could not change your email. Check your connection and try again.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppSheet(
      title: 'Change your email',
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'We will send a confirmation link to the new address. Your sign-in '
              'email changes only after you open that link.',
              style: AppTypography.bodyMedium,
            ),
            SizedBox(height: AppSpacing.lg),
            AuthTextField(
              controller: _emailCtrl,
              label: 'New email',
              icon: Icons.email_outlined,
              keyboardType: TextInputType.emailAddress,
              enabled: !_loading,
              textInputAction: TextInputAction.next,
              validator: (v) =>
                  (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
            ),
            SizedBox(height: AppSpacing.md),
            AuthTextField(
              controller: _passCtrl,
              label: 'Current password',
              icon: Icons.lock_outline,
              obscureText: true,
              enabled: !_loading,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
            ),
            AuthInlineError(message: _error),
            SizedBox(height: AppSpacing.lg),
            AppButton(
              label: 'Send link',
              loading: _loading,
              onPressed: _loading ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
