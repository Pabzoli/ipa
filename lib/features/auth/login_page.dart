import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/widgets/shared_widgets.dart';
import 'auth_service.dart';
import 'auth_widgets.dart';
import 'email_verification_page.dart';
import 'register_form.dart';
import 'terms_acceptance_page.dart';

// ─── Auth Gate ────────────────────────────────────────────────────────────────
// The single gate between the login screen and the app:
//   • signed out            → LoginPage (sign in or create an account)
//   • signed in, unverified → EmailVerificationPage (nothing else is reachable)
//   • signed in, verified, no termsAcceptedAt → TermsAcceptancePage (one-time)
//   • signed in, verified, terms accepted     → the app
class AuthGate extends StatefulWidget {
  final Widget home;
  const AuthGate({super.key, required this.home});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Fetched once and reused. A fresh stream per build would make StreamBuilder
  // reset to ConnectionState.waiting on every rebuild (keyboard, theme, etc.),
  // which looks like the app restarting.
  late final Stream<User?> _authStream = AuthService.instance.authStateChanges;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SplashScreen();
        }
        if (snapshot.data == null) return const LoginPage();

        // Read the live user: reload() updates currentUser in place, and the
        // verification screen calls setState here once it confirms.
        // Test accounts bypass the link flow entirely.
        final gateUser = FirebaseAuth.instance.currentUser;
        final gateEmail = (gateUser?.email ?? '').trim().toLowerCase();
        const bypass = <String>{'1@gmail.com', '2@gmail.com'};
        final verified =
            gateUser?.emailVerified == true || bypass.contains(gateEmail);
        if (!verified) {
          return EmailVerificationPage(
            onVerified: () {
              if (mounted) setState(() {});
            },
          );
        }
        return _TermsGate(home: _PostLoginGate(home: widget.home));
      },
    );
  }
}

// ─── Terms Gate ─────────────────────────────────────────────────────────────
// Only reached by verified accounts. Pre-terms profiles have no
// `termsAcceptedAt`; they see the one-time acceptance screen (same checkbox
// and links as signup) before entering the app. Acceptance is stamped
// server-side by `acceptTerms`, so the stream below flips on its own once
// the write lands.
class _TermsGate extends StatelessWidget {
  final Widget home;
  const _TermsGate({required this.home});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const LoginPage();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _SplashScreen();
        }
        // Fail open on errors or a not-yet-created profile: the offline wall
        // and AuthGate already cover connectivity and sign-in.
        if (snapshot.hasError || !(snapshot.data?.exists == true)) {
          return home;
        }
        final data = snapshot.data!.data();
        if (data == null || data['termsAcceptedAt'] == null) {
          return TermsAcceptancePage(onAccepted: () {});
        }
        return home;
      },
    );
  }
}

// ─── Post-login Gate ──────────────────────────────────────────────────────────
// Only reached by verified accounts. Runs the daily login bonus once.
class _PostLoginGate extends StatefulWidget {
  final Widget home;
  const _PostLoginGate({required this.home});

  @override
  State<_PostLoginGate> createState() => _PostLoginGateState();
}

class _PostLoginGateState extends State<_PostLoginGate> {
  int _pendingBonusCoins = 0;
  bool _bonusAnimScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkDailyLoginBonus());
  }

  Future<void> _checkDailyLoginBonus() async {
    try {
      final result =
          await context.read<UserDataProvider>().checkAndAwardDailyLogin();
      if (!mounted || result.coinsAwarded == 0) return;
      setState(() => _pendingBonusCoins = result.coinsAwarded);
    } catch (e) {
      debugPrint('[AuthGate] daily bonus check error (ignored): $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pendingBonusCoins > 0 && !_bonusAnimScheduled) {
      _bonusAnimScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pendingBonusCoins == 0) return;
        CoinEarnAnimation.show(context, amount: _pendingBonusCoins);
        setState(() => _pendingBonusCoins = 0);
      });
    }
    return widget.home;
  }
}

// ─── Splash Screen ────────────────────────────────────────────────────────────
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: AnimatedHeroBackground(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AuthLogoMark(),
              SizedBox(height: 32.h),
              const CircularProgressIndicator(color: AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Login Page ───────────────────────────────────────────────────────────────
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _obscure = true;
  bool _loading = false;
  bool _showRegister = false;
  String? _error;
  String? _notice;

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_loading) return;
    if (!_formKey.currentState!.validate()) return;
    final email = _emailCtrl.text.trim();
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });

    try {
      // Advisory lockout check. It fails open: an unreachable limiter must
      // never stop a legitimate sign-in.
      final attempt = await AuthService.instance.checkAuthAttempt(email);
      if (attempt['allowed'] == false) {
        final wait = ((attempt['retryAfterSeconds'] as num?)?.toInt() ?? 0);
        _fail(
          'Too many failed attempts. Try again in ${(wait / 60).ceil()} '
          'minute${wait > 60 ? 's' : ''}.',
        );
        return;
      }

      await AuthService.instance.signIn(email: email, password: _passCtrl.text);
      AuthService.instance.reportAuthSuccess(email);
      // AuthGate takes over from here (verification screen or the app).
    } on FirebaseAuthException catch (e) {
      if (const {
        'wrong-password',
        'invalid-credential',
        'user-not-found',
      }.contains(e.code)) {
        AuthService.instance.reportAuthFailure(email);
      }
      _fail(_authError(e.code));
    } catch (_) {
      _fail('Could not sign you in. Check your connection and try again.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
  }

  Future<void> _resetPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _error = 'Enter your email above, then tap Forgot password.';
        _notice = null;
      });
      return;
    }
    setState(() {
      _error = null;
      _notice = null;
    });
    try {
      await AuthService.instance.sendPasswordReset(email);
      if (mounted) {
        setState(() => _notice = 'If an account exists, a reset email is on its way.');
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = _authError(e.code));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not send the reset email. Try again.');
      }
    }
  }

  String _authError(String code) {
    switch (code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email or password is not correct.';
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Try again later.';
      case 'network-request-failed':
        return 'No connection. Check your internet and try again.';
      default:
        return 'Sign-in failed. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      backgroundColor: Colors.transparent,
      body: AnimatedHeroBackground(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            transitionBuilder: (child, anim) => SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.05, 0),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: _showRegister
                ? RegisterForm(
                    key: const ValueKey('register'),
                    onBack: () => setState(() {
                      _showRegister = false;
                      _error = null;
                    }),
                  )
                : _LoginForm(
                    key: const ValueKey('login'),
                    formKey: _formKey,
                    emailCtrl: _emailCtrl,
                    passCtrl: _passCtrl,
                    obscure: _obscure,
                    loading: _loading,
                    error: _error,
                    notice: _notice,
                    onToggleObscure: () => setState(() => _obscure = !_obscure),
                    onLogin: _login,
                    onForgot: _resetPassword,
                    onRegister: () => setState(() {
                      _showRegister = true;
                      _error = null;
                      _notice = null;
                    }),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Login Form ───────────────────────────────────────────────────────────────
class _LoginForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController emailCtrl;
  final TextEditingController passCtrl;
  final bool obscure;
  final bool loading;
  final String? error;
  final String? notice;
  final VoidCallback onToggleObscure;
  final VoidCallback onLogin;
  final VoidCallback onForgot;
  final VoidCallback onRegister;

  const _LoginForm({
    super.key,
    required this.formKey,
    required this.emailCtrl,
    required this.passCtrl,
    required this.obscure,
    required this.loading,
    required this.error,
    required this.notice,
    required this.onToggleObscure,
    required this.onLogin,
    required this.onForgot,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(28.r, 24.r, 28.r, 24.r),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AuthLogoMark(),
              SizedBox(height: 32.h),
              Text('Welcome back', style: AppTypography.heading1),
              SizedBox(height: 24.h),
              GlassCard(
                child: Column(
                  children: [
                    AuthTextField(
                      controller: emailCtrl,
                      label: 'Email',
                      icon: Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      enabled: !loading,
                      textInputAction: TextInputAction.next,
                      validator: (v) => (v == null || !v.contains('@'))
                          ? 'Enter a valid email'
                          : null,
                    ),
                    SizedBox(height: 14.h),
                    AuthTextField(
                      controller: passCtrl,
                      label: 'Password',
                      icon: Icons.lock_outline,
                      obscureText: obscure,
                      autofillHints: const [AutofillHints.password],
                      enabled: !loading,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => onLogin(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: AppColors.textMuted,
                          size: 20.r,
                        ),
                        onPressed: onToggleObscure,
                      ),
                      validator: (v) => (v == null || v.length < 6)
                          ? 'Password must be at least 6 characters'
                          : null,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: loading ? null : onForgot,
                        child: Text(
                          'Forgot password?',
                          style: TextStyle(
                            color: AppColors.secondary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13.sp,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              AuthInlineError(message: error),
              if (notice != null) ...[
                SizedBox(height: AppSpacing.md),
                Text(
                  notice!,
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.successText,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              SizedBox(height: 20.h),
              AppButton(
                label: 'Sign In',
                onPressed: loading ? null : onLogin,
                loading: loading,
                icon: Icon(Icons.login_rounded, size: 20.r),
                variant: AppButtonVariant.gradient,
                width: double.infinity,
                height: 56.h,
              ),
              SizedBox(height: 24.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Don't have an account? ",
                    style: AppTypography.bodyMedium,
                  ),
                  TextButton(
                    onPressed: loading ? null : onRegister,
                    child: Text(
                      'Create one',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.sp,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
