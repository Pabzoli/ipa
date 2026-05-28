import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_earn_animation.dart';      // ← NEW
import '../../core/services/firestore_service.dart';
import '../../core/providers/user_data_provider.dart';    // ← NEW
import 'auth_service.dart';

// ─── Auth Gate ────────────────────────────────────────────────────────────────
/// Entry point that listens to auth state and routes accordingly.
/// If a signed-in user hasn't set their university yet, they are shown a
/// one-time [_UniversitySetupPage] before reaching [home].
class AuthGate extends StatelessWidget {
  final Widget home;
  const AuthGate({super.key, required this.home});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.instance.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SplashScreen();
        }
        if (!snapshot.hasData) return const LoginPage();
        // User is signed in — gate on university presence
        return _UniversityGate(home: home);
      },
    );
  }
}

// ─── University Gate ──────────────────────────────────────────────────────────
/// Silently checks whether the current user has a university set.
/// If not, surfaces [_UniversitySetupPage] once, then hands off to [home].
///
/// Also runs the daily login bonus check (+5 AC) and shows
/// [CoinEarnAnimation] the first time [home] is rendered on a new calendar
/// day (WAT).
class _UniversityGate extends StatefulWidget {
  final Widget home;
  const _UniversityGate({required this.home});

  @override
  State<_UniversityGate> createState() => _UniversityGateState();
}

class _UniversityGateState extends State<_UniversityGate> {
  bool _checked         = false;
  bool _needsUniversity = false;

  // ── Daily login bonus ────────────────────────────────────────────────────────
  /// Coins earned this session (0 = already claimed today or error).
  int  _pendingBonusCoins   = 0;
  /// Ensures we schedule the animation overlay exactly once.
  bool _bonusAnimScheduled  = false;

  @override
  void initState() {
    super.initState();
    _checkUniversity();
    _checkDailyLoginBonus();
  }

  Future<void> _checkUniversity() async {
    try {
      final uni = await FirestoreService.instance.getCurrentUserUniversity();
      if (!mounted) return;
      setState(() {
        _checked         = true;
        // null means the field has never been written (brand-new signup that
        // somehow skipped the form, or an older user account).
        _needsUniversity = uni == null;
      });
    } catch (_) {
      // If the Firestore read fails for any reason, don't block the user.
      if (mounted) setState(() => _checked = true);
    }
  }

  /// Calls [UserDataProvider.checkAndAwardDailyLogin] and stores the result
  /// so [build] can trigger the coin animation once home is shown.
  Future<void> _checkDailyLoginBonus() async {
    try {
      final coins = await context
          .read<UserDataProvider>()
          .checkAndAwardDailyLogin();
      if (!mounted || coins == 0) return;
      setState(() => _pendingBonusCoins = coins);
    } catch (e) {
      debugPrint('[AuthGate] daily bonus check error (ignored): $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) return const _SplashScreen();

    if (_needsUniversity) {
      return _UniversitySetupPage(
        onComplete: () => setState(() => _needsUniversity = false),
      );
    }

    // ── Show coin animation on the first frame after home is rendered ─────────
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
      body: AnimatedHeroBackground(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _LogoMark(),
              const SizedBox(height: 32),
              const CircularProgressIndicator(color: AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── University Setup Page (existing-user one-time prompt) ───────────────────
class _UniversitySetupPage extends StatefulWidget {
  final VoidCallback onComplete;
  const _UniversitySetupPage({required this.onComplete});

  @override
  State<_UniversitySetupPage> createState() => _UniversitySetupPageState();
}

class _UniversitySetupPageState extends State<_UniversitySetupPage>
    with SingleTickerProviderStateMixin {
  String? _selected;
  bool    _loading = false;

  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_selected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select your university first.')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      await FirestoreService.instance.updateUniversity(_selected!);
      widget.onComplete();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Skip saves an empty string so [_UniversityGate] won't prompt again,
  /// but the user won't appear in any campus leaderboard.
  Future<void> _skip() async {
    setState(() => _loading = true);
    try {
      await FirestoreService.instance.updateUniversity('');
      widget.onComplete();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedHeroBackground(
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Logo ──────────────────────────────────────────────────
                  Center(child: _LogoMark()),
                  const SizedBox(height: 40),

                  // ── Heading ───────────────────────────────────────────────
                  const Text(
                    'One quick thing…',
                    style: TextStyle(
                      color:      AppColors.textPrimary,
                      fontSize:   30,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tell us your university so you can compete on the '
                    'Campus Leaderboard and see how your school stacks up '
                    'against rivals across Nigeria.',
                    style: TextStyle(
                      color:  AppColors.textSecondary,
                      fontSize: 15,
                      height:   1.5,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // ── Campus rivalry preview ────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF6C63FF).withOpacity(0.15),
                          const Color(0xFF3ECFCF).withOpacity(0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: const Color(0xFF6C63FF).withOpacity(0.3)),
                    ),
                    child: Row(
                      children: const [
                        Text('🎓', style: TextStyle(fontSize: 28)),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'UNILAG leads OAU · 124,500 – 98,200\n'
                            'Your school could be #1 next week.',
                            style: TextStyle(
                              color:    AppColors.textPrimary,
                              fontSize: 13,
                              height:   1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 28),

                  // ── Dropdown ──────────────────────────────────────────────
                  GlassCard(
                    child: _UniversityDropdown(
                      value:    _selected,
                      onChanged: (v) => setState(() => _selected = v),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Save button ───────────────────────────────────────────
                  GradientButton(
                    label:     'Set My University',
                    onTap:     _save,
                    isLoading: _loading,
                    icon:      Icons.school_rounded,
                    colors: const [Color(0xFF6C63FF), Color(0xFF3ECFCF)],
                  ),

                  const SizedBox(height: 16),

                  // ── Skip ─────────────────────────────────────────────────
                  Center(
                    child: TextButton(
                      onPressed: _loading ? null : _skip,
                      child: const Text(
                        'Skip for now',
                        style: TextStyle(
                          color:      AppColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
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
      body: AnimatedHeroBackground(
        child: SafeArea(
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
      ),
    );
  }
}

// ─── Login Form Widget ────────────────────────────────────────────────────────
class _LoginForm extends StatelessWidget {
  final GlobalKey<FormState>    formKey;
  final TextEditingController   emailCtrl;
  final TextEditingController   passCtrl;
  final bool                    obscure;
  final bool                    loading;
  final VoidCallback            onToggleObscure;
  final VoidCallback            onLogin;
  final VoidCallback            onForgot;
  final VoidCallback            onRegister;

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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 40),
            Center(child: _LogoMark()),
            const SizedBox(height: 48),
            const Text(
              'Welcome back',
              style: TextStyle(
                color:      AppColors.textPrimary,
                fontSize:   32,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Sign in to continue your anime journey',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
            ),
            const SizedBox(height: 36),
            GlassCard(
              child: Column(
                children: [
                  _AuthField(
                    controller:   emailCtrl,
                    label:        'Email',
                    icon:         Icons.email_outlined,
                    keyboardType: TextInputType.emailAddress,
                    validator:    (v) => (v == null || !v.contains('@'))
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: 16),
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
                        size:  20,
                      ),
                      onPressed: onToggleObscure,
                    ),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'Password must be at least 6 characters'
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: onForgot,
                      child: const Text(
                        'Forgot password?',
                        style: TextStyle(
                          color:      AppColors.secondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            GradientButton(
              label:     'Sign In',
              onTap:     onLogin,
              isLoading: loading,
              icon:      Icons.login_rounded,
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  "Don't have an account? ",
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                GestureDetector(
                  onTap: onRegister,
                  child: const Text(
                    'Create one',
                    style: TextStyle(
                      color:      AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
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

  bool    _obscure            = true;
  bool    _loading            = false;
  String? _selectedUniversity;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confCtrl.dispose();
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
      );
      // AuthGate will automatically navigate on auth state change
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            // ── Back row ─────────────────────────────────────────────────
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: AppColors.textPrimary),
                  onPressed: widget.onBack,
                ),
                const SizedBox(width: 4),
                const Text(
                  'Create Account',
                  style: TextStyle(
                    color:      AppColors.textPrimary,
                    fontSize:   28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.only(left: 44),
              child: Text(
                'Join thousands of anime fans',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
            ),
            const SizedBox(height: 32),

            // ── Form card ─────────────────────────────────────────────────
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
                  const SizedBox(height: 16),
                  _AuthField(
                    controller:   _emailCtrl,
                    label:        'Email',
                    icon:         Icons.email_outlined,
                    keyboardType: TextInputType.emailAddress,
                    validator:    (v) => (v == null || !v.contains('@'))
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: 16),
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
                        size:  20,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'Password must be at least 6 characters'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  _AuthField(
                    controller:  _confCtrl,
                    label:       'Confirm Password',
                    icon:        Icons.lock_outline,
                    obscureText: _obscure,
                    validator:   (v) => v != _passCtrl.text
                        ? 'Passwords do not match'
                        : null,
                  ),
                  const SizedBox(height: 16),

                  // ── University dropdown ────────────────────────────────
                  _UniversityDropdown(
                    value:     _selectedUniversity,
                    onChanged: (v) => setState(() => _selectedUniversity = v),
                    isRequired: false,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // ── Campus rivalry teaser ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: const [
                  Icon(Icons.school_outlined,
                      color: AppColors.textMuted, size: 13),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Optional — lets you compete on the Campus Leaderboard '
                      'and track your university\'s rivalry.',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            GradientButton(
              label:     'Create Account',
              onTap:     _register,
              isLoading: _loading,
              icon:      Icons.person_add_rounded,
              colors:    const [Color(0xFF457B9D), Color(0xFF1D3557)],
            ),
            const SizedBox(height: 20),
            Center(
              child: GestureDetector(
                onTap: widget.onBack,
                child: const Text(
                  'Already have an account? Sign in',
                  style: TextStyle(
                    color:      AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── University Dropdown ──────────────────────────────────────────────────────
/// A styled [DropdownButtonFormField] that matches the [_AuthField] look.
/// Used in both the sign-up form and the one-time setup page.
class _UniversityDropdown extends StatelessWidget {
  final String?             value;
  final ValueChanged<String?> onChanged;
  final bool                isRequired;

  const _UniversityDropdown({
    required this.value,
    required this.onChanged,
    this.isRequired = true,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value:        value,
      isExpanded:   true,
      dropdownColor: AppColors.surface,
      icon: const Icon(Icons.expand_more_rounded,
          color: AppColors.textMuted, size: 20),
      decoration: InputDecoration(
        labelText: 'University',
        prefixIcon: const Icon(Icons.school_outlined,
            color: AppColors.textMuted, size: 20),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
      hint: const Text(
        'Select your university',
        style: TextStyle(color: AppColors.textMuted),
      ),
      items: kNigerianUniversities
          .map(
            (u) => DropdownMenuItem(
              value: u,
              child: Text(u,
                  style:
                      const TextStyle(color: AppColors.textPrimary)),
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
  final TextEditingController     controller;
  final String                    label;
  final IconData                  icon;
  final bool                      obscureText;
  final TextInputType?            keyboardType;
  final String? Function(String?)? validator;
  final Widget?                   suffixIcon;

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
      style: const TextStyle(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText:  label,
        prefixIcon: Icon(icon, color: AppColors.textMuted, size: 20),
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
          width:  72,
          height: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.primary, Color(0xFFFF6B6B)],
              begin:  Alignment.topLeft,
              end:    Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color:      AppColors.primary.withOpacity(0.4),
                blurRadius: 24,
                offset:     const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.quiz_rounded,
              color: Colors.white, size: 36),
        ),
        const SizedBox(height: 12),
        const Text(
          'AnimeQuiz',
          style: TextStyle(
            color:         AppColors.textPrimary,
            fontSize:      22,
            fontWeight:    FontWeight.w900,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}