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
        return _UniversityGate(home: home);
      },
    );
  }
}

// ─── University Gate ──────────────────────────────────────────────────────────
class _UniversityGate extends StatefulWidget {
  final Widget home;
  const _UniversityGate({required this.home});

  @override
  State<_UniversityGate> createState() => _UniversityGateState();
}

class _UniversityGateState extends State<_UniversityGate> {
  bool _checked         = false;
  bool _needsUniversity = false;

  int  _pendingBonusCoins   = 0;
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
        _needsUniversity = uni == null;
      });
    } catch (_) {
      if (mounted) setState(() => _checked = true);
    }
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
    if (!_checked) return const _SplashScreen();

    if (_needsUniversity) {
      return _UniversitySetupPage(
        onComplete: () => setState(() => _needsUniversity = false),
      );
    }

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
              const SizedBox(height: 32),
              const CircularProgressIndicator(color: AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── University Setup Page ────────────────────────────────────────────────────
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
      // FIX: transparent so AnimatedHeroBackground shows edge-to-edge
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: AnimatedHeroBackground(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: _LogoMark()),
                  const SizedBox(height: 40),
                  const Text(
                    'One quick thing…',
                    style: TextStyle(
                      color:      AppColors.textPrimary,
                      fontSize:   30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tell us your university so you can compete on the '
                    'Campus Leaderboard and see how your school stacks up '
                    'against rivals across Nigeria.',
                    style: TextStyle(
                      color:    AppColors.textSecondary,
                      fontSize: 15,
                      height:   1.5,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Campus rivalry preview
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

                  GlassCard(
                    child: _UniversityDropdown(
                      value:     _selected,
                      onChanged: (v) => setState(() => _selected = v),
                    ),
                  ),
                  const SizedBox(height: 24),

                  GradientButton(
                    label:     'Set My University',
                    onTap:     _save,
                    isLoading: _loading,
                    icon:      Icons.school_rounded,
                    colors: const [Color(0xFF6C63FF), Color(0xFF3ECFCF)],
                  ),
                  const SizedBox(height: 16),

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
      // FIX 1: Background extends behind status bar and bottom nav bar
      extendBodyBehindAppBar: true,
      extendBody: true,
      // FIX 2: Transparent so the AnimatedHeroBackground covers everything
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
    // FIX 3: SafeArea moved here so the inner content respects device insets
    // while AnimatedHeroBackground covers the full screen edge-to-edge
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            // FIX 4: ConstrainedBox + IntrinsicHeight ensures the Column
            // fills the full viewport height so there are no empty dark gaps
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Form(
                    key: formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Flexible top space — centers content vertically
                        const Spacer(flex: 2),

                        // ── Logo ──────────────────────────────────────────
                        Center(child: _LogoMark()),
                        const SizedBox(height: 40),

                        // ── Heading ───────────────────────────────────────
                        const Text(
                          'Welcome back',
                          style: TextStyle(
                            color:         AppColors.textPrimary,
                            fontSize:      34,
                            fontWeight:    FontWeight.w900,
                            letterSpacing: -1,
                            height:        1.1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Sign in to continue your anime journey',
                          style: TextStyle(
                            color:    AppColors.textSecondary,
                            fontSize: 15,
                            height:   1.4,
                          ),
                        ),
                        const SizedBox(height: 32),

                        // ── Credential card ───────────────────────────────
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
                              const SizedBox(height: 14),
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
                              const SizedBox(height: 4),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: onForgot,
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 8),
                                  ),
                                  child: const Text(
                                    'Forgot password?',
                                    style: TextStyle(
                                      color:      AppColors.secondary,
                                      fontWeight: FontWeight.w600,
                                      fontSize:   13,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 20),

                        // ── Sign-in button ────────────────────────────────
                        GradientButton(
                          label:     'Sign In',
                          onTap:     onLogin,
                          isLoading: loading,
                          icon:      Icons.login_rounded,
                        ),

                        const SizedBox(height: 28),

                        // ── Register link ─────────────────────────────────
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              "Don't have an account? ",
                              style: TextStyle(
                                color:    AppColors.textSecondary,
                                fontSize: 14,
                              ),
                            ),
                            GestureDetector(
                              onTap: onRegister,
                              child: const Text(
                                'Create one',
                                style: TextStyle(
                                  color:      AppColors.primary,
                                  fontWeight: FontWeight.w700,
                                  fontSize:   14,
                                ),
                              ),
                            ),
                          ],
                        ),

                        // Flexible bottom space
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
    // FIX: Same full-screen approach as _LoginForm
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
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
                          const SizedBox(width: 4),
                          const Text(
                            'Create Account',
                            style: TextStyle(
                              color:      AppColors.textPrimary,
                              fontSize:   28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Padding(
                        padding: EdgeInsets.only(left: 44),
                        child: Text(
                          'Join thousands of anime fans',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 14),
                        ),
                      ),
                      const SizedBox(height: 28),

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
                            const SizedBox(height: 14),
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
                            const SizedBox(height: 14),
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
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                              validator: (v) => (v == null || v.length < 6)
                                  ? 'Password must be at least 6 characters'
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            _AuthField(
                              controller:  _confCtrl,
                              label:       'Confirm Password',
                              icon:        Icons.lock_outline,
                              obscureText: _obscure,
                              validator:   (v) => v != _passCtrl.text
                                  ? 'Passwords do not match'
                                  : null,
                            ),
                            const SizedBox(height: 14),

                            // ── University dropdown ────────────────────
                            _UniversityDropdown(
                              value:     _selectedUniversity,
                              onChanged: (v) =>
                                  setState(() => _selectedUniversity = v),
                              isRequired: false,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),

                      // ── Campus rivalry teaser ─────────────────────────
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
                                    color:    AppColors.textMuted,
                                    fontSize: 11.5),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

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
                      const SizedBox(height: 16),
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
      value:         value,
      isExpanded:    true,
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
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
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
        // Outer glow ring
        Container(
          width:  84,
          height: 84,
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
              width:  72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, Color(0xFFFF6B6B)],
                  begin:  Alignment.topLeft,
                  end:    Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color:      AppColors.primary.withOpacity(0.45),
                    blurRadius: 28,
                    spreadRadius: 2,
                    offset:     const Offset(0, 10),
                  ),
                ],
              ),
              child: const Icon(Icons.quiz_rounded,
                  color: Colors.white, size: 36),
            ),
          ),
        ),
        const SizedBox(height: 14),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [AppColors.primary, Color(0xFFFF6B6B)],
          ).createShader(bounds),
          child: const Text(
            'AnimeQuiz',
            style: TextStyle(
              color:         Colors.white, // masked by shader
              fontSize:      24,
              fontWeight:    FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}