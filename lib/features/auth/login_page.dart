import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/widgets/app_button.dart';
import '../../core/services/firestore_service.dart';
import '../../core/providers/user_data_provider.dart';
import 'auth_service.dart';

// ─── Auth Gate ────────────────────────────────────────────────────────────────
class AuthGate extends StatefulWidget {
  final Widget home;
  const AuthGate({super.key, required this.home});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Fetched once and reused. If this were re-read from
  // AuthService.instance.authStateChanges inside build(), every rebuild of
  // AuthGate (e.g. the keyboard opening/closing and nudging MediaQuery,
  // theme changes, etc.) would hand StreamBuilder a *new* Stream instance.
  // StreamBuilder treats that as a brand-new subscription, so it briefly
  // resets to ConnectionState.waiting and re-shows the splash screen before
  // the new stream reports the current user again — which is exactly what
  // looks like the app "restarting" when you merely tap into the email
  // field and the keyboard slides up.
  late final Stream<User?> _authStream =
      AuthService.instance.authStateChanges;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SplashScreen();
        }
        if (!snapshot.hasData) return const LoginPage();
        return _PostLoginGate(home: widget.home);
      },
    );
  }
}

// ─── Post-login Gate ──────────────────────────────────────────────────────────
// No longer blocks on university selection: campus is picked inside the
// Rankings → My Campus tab. This gate only handles the daily login bonus.
class _PostLoginGate extends StatefulWidget {
  final Widget home;
  const _PostLoginGate({required this.home});

  @override
  State<_PostLoginGate> createState() => _PostLoginGateState();
}

class _PostLoginGateState extends State<_PostLoginGate> {
  int  _pendingBonusCoins   = 0;
  bool _bonusAnimScheduled  = false;

  @override
  void initState() {
    super.initState();
    _checkDailyLoginBonus();
  }

  Future<void> _checkDailyLoginBonus() async {
    try {
      final result = await context
          .read<UserDataProvider>()
          .checkAndAwardDailyLogin();
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
              _LogoMark(),
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
  final _formKey   = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();

  bool _obscure      = true;
  bool _loading      = false;
  bool _showRegister = false;

  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;

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
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await AuthService.instance.signIn(
        email:    _emailCtrl.text,
        password: _passCtrl.text,
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) _showError(_authError(e.code));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resetPassword() async {
    if (_emailCtrl.text.trim().isEmpty) {
      _showError('Enter your email first');
      return;
    }
    await AuthService.instance.sendPasswordReset(_emailCtrl.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password reset email sent!')),
      );
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.wrong),
    );
  }

  String _authError(String code) {
    switch (code) {
      case 'user-not-found':    return 'No account found with this email.';
      case 'wrong-password':    return 'Incorrect password.';
      case 'invalid-email':     return 'Invalid email address.';
      case 'user-disabled':     return 'This account has been disabled.';
      case 'too-many-requests': return 'Too many attempts. Try again later.';
      default:                  return 'Authentication failed. Please try again.';
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
                end:   Offset.zero,
              ).animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOut)),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: _showRegister
                ? RegisterForm(
                    key:    const ValueKey('register'),
                    onBack: () => setState(() => _showRegister = false),
                  )
                : _LoginForm(
                    key:              const ValueKey('login'),
                    formKey:          _formKey,
                    emailCtrl:        _emailCtrl,
                    passCtrl:         _passCtrl,
                    obscure:          _obscure,
                    loading:          _loading,
                    onToggleObscure:  () =>
                        setState(() => _obscure = !_obscure),
                    onLogin:          _login,
                    onForgot:         _resetPassword,
                    onRegister:       () =>
                        setState(() => _showRegister = true),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Login Form Widget ────────────────────────────────────────────────────────
class _LoginForm extends StatelessWidget {
  final GlobalKey<FormState>      formKey;
  final TextEditingController     emailCtrl;
  final TextEditingController     passCtrl;
  final bool                      obscure;
  final bool                      loading;
  final VoidCallback              onToggleObscure;
  final VoidCallback              onLogin;
  final VoidCallback              onForgot;
  final VoidCallback              onRegister;

  const _LoginForm({
    super.key,
    required this.formKey,
    required this.emailCtrl,
    required this.passCtrl,
    required this.obscure,
    required this.loading,
    required this.onToggleObscure,
    required this.onLogin,
    required this.onForgot,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 28.r),
                  child: Form(
                    key: formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Spacer(flex: 2),

                        Center(child: _LogoMark()),
                        SizedBox(height: 40.h),

                        Text(
                          'Welcome back',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 32.sp,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -1,
                            height: 1.1,
                          ),
                        ),
                        SizedBox(height: 32.h),

                        GlassCard(
                          child: Column(
                            children: [
                              _AuthField(
                                controller:   emailCtrl,
                                label:        'Email',
                                icon:         Icons.email_outlined,
                                keyboardType: TextInputType.emailAddress,
                                validator:    (v) =>
                                    (v == null || !v.contains('@'))
                                        ? 'Enter a valid email'
                                        : null,
                              ),
                              SizedBox(height: 14.h),
                              _AuthField(
                                controller:  passCtrl,
                                label:       'Password',
                                icon:        Icons.lock_outline,
                                obscureText: obscure,
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    obscure
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    color: AppColors.textMuted,
                                    size:  20.r,
                                  ),
                                  onPressed: onToggleObscure,
                                ),
                                validator: (v) => (v == null || v.length < 6)
                                    ? 'Password must be at least 6 characters'
                                    : null,
                              ),
                              SizedBox(height: 4.h),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: onForgot,
                                  style: TextButton.styleFrom(
                                      padding: EdgeInsets.symmetric(
                                          horizontal: 4.r, vertical: 8.r),
                                    ),
                                  child: Text(
                                    'Forgot password?',
                                    style: TextStyle(
                                      color:      AppColors.secondary,
                                      fontWeight: FontWeight.w600,
                                      fontSize:   13.sp,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        SizedBox(height: 20.h),

                        AppButton(
                          label: 'Sign In',
                          onPressed: onLogin,
                          loading: loading,
                          icon: Icon(Icons.login_rounded, size: 20.r),
                          variant: AppButtonVariant.gradient,
                          width: double.infinity,
                          height: 56.h,
                        ),

                        SizedBox(height: 28.h),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              "Don't have an account? ",
                              style: TextStyle(
                                color:    AppColors.textSecondary,
                                fontSize: 14.sp,
                              ),
                            ),
                            InkWell(
                              onTap: onRegister,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.xs),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: 4.r, vertical: 2.r),
                                child: Text(
                                  'Create one',
                                  style: TextStyle(
                                    color:      AppColors.primary,
                                    fontWeight: FontWeight.w700,
                                    fontSize:   14.sp,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),

                        const Spacer(flex: 1),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Register Form ────────────────────────────────────────────────────────────
class RegisterForm extends StatefulWidget {
  final VoidCallback onBack;
  const RegisterForm({super.key, required this.onBack});

  @override
  State<RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<RegisterForm> {
  final _formKey   = GlobalKey<FormState>();
  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _confCtrl  = TextEditingController();
  final _referralCodeCtrl = TextEditingController();

  bool    _obscure            = true;
  bool    _loading            = false;
  String? _selectedUniversity;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confCtrl.dispose();
    _referralCodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await AuthService.instance.signUp(
        email:      _emailCtrl.text,
        password:   _passCtrl.text,
        username:   _nameCtrl.text,
        university: _selectedUniversity,
        referredBy: _referralCodeCtrl.text,
      );
    } on SignUpException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:         Text(e.message),
            backgroundColor: AppColors.wrong,
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:         Text(e.message ?? 'Registration failed'),
            backgroundColor: AppColors.wrong,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: 28.r, vertical: 16.r),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Back row ──────────────────────────────────────
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new,
                                color: AppColors.textPrimary),
                            onPressed: widget.onBack,
                            padding: EdgeInsets.zero,
                          ),
                          SizedBox(width: 4.w),
                          Text(
                            'Create Account',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 26.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                              height: 1.05,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 28.h),

                      // ── Form card ─────────────────────────────────────
                      GlassCard(
                        child: Column(
                          children: [
                            _AuthField(
                              controller: _nameCtrl,
                              label:      'Username',
                              icon:       Icons.person_outline,
                              validator:  (v) =>
                                  (v == null || v.trim().length < 3)
                                      ? 'Username must be at least 3 characters'
                                      : null,
                            ),
                            SizedBox(height: 14.h),
                            _AuthField(
                              controller:   _emailCtrl,
                              label:        'Email',
                              icon:         Icons.email_outlined,
                              keyboardType: TextInputType.emailAddress,
                              validator:    (v) =>
                                  (v == null || !v.contains('@'))
                                      ? 'Enter a valid email'
                                      : null,
                            ),
                            SizedBox(height: 14.h),
                            _AuthField(
                              controller:  _passCtrl,
                              label:       'Password',
                              icon:        Icons.lock_outline,
                              obscureText: _obscure,
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  color: AppColors.textMuted,
                                  size:  20.r,
                                ),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                              validator: (v) => (v == null || v.length < 6)
                                  ? 'Password must be at least 6 characters'
                                  : null,
                            ),
                            SizedBox(height: 14.h),
                            _AuthField(
                              controller:  _confCtrl,
                              label:       'Confirm Password',
                              icon:        Icons.lock_outline,
                              obscureText: _obscure,
                              validator:   (v) => v != _passCtrl.text
                                  ? 'Passwords do not match'
                                  : null,
                            ),
                            SizedBox(height: 14.h),

                            _UniversityDropdown(
                              value:     _selectedUniversity,
                              onChanged: (v) =>
                                  setState(() => _selectedUniversity = v),
                              isRequired: false,
                            ),
                            SizedBox(height: 14.h),

                            _AuthField(
                              controller:  _referralCodeCtrl,
                              label:       'Referral code (optional)',
                              icon:        Icons.person_add_rounded,
                              keyboardType: TextInputType.text,
                            ),
                            SizedBox(height: 6.h),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Earn rewards together when they join.',
                                style: TextStyle(
                                    color:    AppColors.textMuted,
                                    fontSize: 11.5.sp),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 8.h),

                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4.r),
                        child: Row(
                          children: [
                            Icon(Icons.school_outlined,
                                color: AppColors.textMuted, size: 13.r),
                            SizedBox(width: 6.w),
                            Expanded(
                              child: Text(
                                'Lets you compete on the Campus Leaderboard '
                                'and track your university\'s rivalry.',
                                style: TextStyle(
                                    color:    AppColors.textMuted,
                                    fontSize: 11.5.sp),
                              ),
                            ),
                          ],
                        ),
                      ),

                      SizedBox(height: 20.h),

                      AppButton(
                        label: 'Create Account',
                        onPressed: _register,
                        loading: _loading,
                        icon: Icon(Icons.person_add_rounded, size: 20.r),
                        variant: AppButtonVariant.gradient,
                        gradientColors: const [
                          Color(0xFF457B9D),
                          Color(0xFF1D3557),
                        ],
                        width: double.infinity,
                        height: 56.h,
                      ),
                      SizedBox(height: 20.h),
                      Center(
                        child: InkWell(
                          onTap: widget.onBack,
                          borderRadius: BorderRadius.circular(AppRadii.xs),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 4.r, vertical: 2.r),
                            child: Text(
                              'Already have an account? Sign in',
                              style: TextStyle(
                                color:      AppColors.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 16.h),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── University Dropdown ──────────────────────────────────────────────────────
class _UniversityDropdown extends StatelessWidget {
  final String?               value;
  final ValueChanged<String?> onChanged;
  final bool                  isRequired;

  const _UniversityDropdown({
    required this.value,
    required this.onChanged,
    this.isRequired = true,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded:    true,
      dropdownColor: AppColors.surface,
      icon: Icon(Icons.expand_more_rounded,
          color: AppColors.textMuted, size: 20.r),
      decoration: InputDecoration(
        labelText: 'University',
        prefixIcon: Icon(Icons.school_outlined,
            color: AppColors.textMuted, size: 20.r),
        contentPadding:
            EdgeInsets.symmetric(horizontal: 12.r, vertical: 14.r),
      ),
      style: TextStyle(color: AppColors.textPrimary, fontSize: 15.sp),
      hint: const Text(
        'Select your university',
        style: TextStyle(color: AppColors.textMuted),
      ),
      items: kNigerianUniversities
          .map(
            (u) => DropdownMenuItem(
              value: u,
              child: Text(u,
                  style: const TextStyle(color: AppColors.textPrimary)),
            ),
          )
          .toList(),
      onChanged: onChanged,
      validator: isRequired
          ? (v) => v == null ? 'Please select your university' : null
          : null,
    );
  }
}

// ─── Reusable Auth Field ──────────────────────────────────────────────────────
class _AuthField extends StatelessWidget {
  final TextEditingController      controller;
  final String                     label;
  final IconData                   icon;
  final bool                       obscureText;
  final TextInputType?             keyboardType;
  final String? Function(String?)? validator;
  final Widget?                    suffixIcon;

  const _AuthField({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText  = false,
    this.keyboardType,
    this.validator,
    this.suffixIcon,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller:   controller,
      obscureText:  obscureText,
      keyboardType: keyboardType,
      validator:    validator,
      style: TextStyle(color: AppColors.textPrimary, fontSize: 15.sp),
      decoration: InputDecoration(
        labelText:  label,
        prefixIcon: Icon(icon, color: AppColors.textMuted, size: 20.r),
        suffixIcon: suffixIcon,
      ),
    );
  }
}

// ─── Logo Mark ────────────────────────────────────────────────────────────────
class _LogoMark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width:  84.w,
          height: 84.h,
          decoration: BoxDecoration(
            gradient: const RadialGradient(
              colors: [
                Color(0x55FF6B6B),
                Colors.transparent,
              ],
            ),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Container(
              width:  72.w,
              height: 72.h,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, Color(0xFFFF6B6B)],
                  begin:  Alignment.topLeft,
                  end:    Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(AppRadii.xl),
                boxShadow: [
                  BoxShadow(
                    color:
                        AppColors.primary.withValues(alpha: 0.45),
                    blurRadius: 28,
                    spreadRadius: 2,
                    offset:     const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(Icons.quiz_rounded,
                  color: Colors.white, size: 36.r),
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
              color:         Colors.white,
              fontSize:      24.sp,
              fontWeight:    FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}