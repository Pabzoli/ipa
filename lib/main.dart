import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/theme/app_theme.dart';
import 'core/providers/user_data_provider.dart';
import 'core/services/ad_service.dart';
import 'core/services/firestore_service.dart';
import 'features/auth/login_page.dart';
import 'features/home/home_page.dart';
import 'features/player/player_statistics_provider.dart';
import 'features/prizes/winner_announcement_page.dart';
import 'firebase_options.dart';

/// SharedPreferences key tracking which weekId the user has already seen.
const _kAnnouncementKey = 'lastSeenAnnouncementWeekId';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // AdMob must be initialised after Firebase.
  await MobileAds.instance.initialize();
  AdService.instance.preloadAll();

  // Transparent status bar with light icons to show through our dark gradient.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor:          Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PlayerStatisticsProvider()),
        ChangeNotifierProvider(create: (_) => UserDataProvider()..init()),
      ],
      child: const AnimeQuizApp(),
    ),
  );
}

// ─── Root App ─────────────────────────────────────────────────────────────────
class AnimeQuizApp extends StatelessWidget {
  const AnimeQuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AnimeQuiz',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,

      // ── AuthGate is permanent — never recreated ───────────────────────────
      // _AnnouncementGate sits inside it so it only runs post-authentication.
      // The offline overlay is applied via builder below, which wraps the
      // navigator OUTPUT rather than the navigator itself. This means the
      // Navigator stack is never torn down on connectivity changes, which
      // was the root cause of all previous screen freezes.
      home: AuthGate(home: const _AnnouncementGate()),

      // ── Offline/loading overlay sits ABOVE the navigator ──────────────────
      // We never replace child — we either show it or cover it so gesture
      // recognisers on the existing stack are never destroyed.
      builder: (context, child) {
        return Consumer<UserDataProvider>(
          builder: (context, userData, _) {
            if (!userData.connectivityChecked) return const _SplashScreen();
            if (!userData.isOnline)            return const _OfflineWall();
            return child!;
          },
        );
      },
    );
  }
}

// ─── Announcement Gate ────────────────────────────────────────────────────────
/// Runs once per authenticated session.
///
/// On Mondays it checks whether the user has already seen the current week's
/// winner announcement; if not, it shows [WinnerAnnouncementPage] with a fade
/// transition before handing off to [_AppShell].
///
/// All Firestore / SharedPreferences errors are swallowed so a bad network
/// response never blocks the user from reaching the home screen.
class _AnnouncementGate extends StatefulWidget {
  const _AnnouncementGate();

  @override
  State<_AnnouncementGate> createState() => _AnnouncementGateState();
}

class _AnnouncementGateState extends State<_AnnouncementGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _maybeShowAnnouncement();
  }

  Future<void> _maybeShowAnnouncement() async {
  if (DateTime.now().weekday != DateTime.monday) {
    _markReady();
    return;
  }

  try {
    final prefs    = await SharedPreferences.getInstance();
    final lastSeen = prefs.getString(_kAnnouncementKey);
    final result   = await FirestoreService.instance.getLastWeekWinners();

    if (result == null ||
        result.winners.isEmpty ||
        result.weekId == lastSeen) {
      _markReady();
      return;
    }

    await prefs.setString(_kAnnouncementKey, result.weekId);

    if (!mounted) return;

    await Navigator.of(context).push<String?>(
      PageRouteBuilder(
        pageBuilder:        (_, __, ___) => WinnerAnnouncementPage(result: result),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
        fullscreenDialog:   true,
      ),
    );
  } catch (_) {
    // Any error → skip silently, never block the user from home.
  }

  _markReady();
}

  void _markReady() {
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    // Show the splash screen while the Monday check / Firestore fetch runs.
    // This is usually imperceptible (<300 ms on a good connection).
    return _ready ? const _AppShell() : const _SplashScreen();
  }
}

// ─── App Shell ────────────────────────────────────────────────────────────────
class _AppShell extends StatefulWidget {
  const _AppShell();

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  bool _statsInited = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_statsInited) {
      _statsInited = true;
      context.read<PlayerStatisticsProvider>().init();
    }
  }

  @override
  Widget build(BuildContext context) => const HomePage();
}

// ─── Splash Screen ────────────────────────────────────────────────────────────
/// Shown while connectivity is being checked and on the initial Firestore
/// fetch for the Monday announcement.
///
/// Uses [TweenAnimationBuilder] for a lightweight entrance animation — no
/// extra [AnimationController] boilerplate needed, and the `child` parameter
/// ensures the Column tree is built exactly once.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: DecoratedBox(
        decoration: AppDecorations.heroBg,
        child: SizedBox.expand(
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween:    Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 850),
              curve:    Curves.easeOutCubic,
              // Static child built once and threaded through every frame.
              child: const _SplashContent(),
              builder: (context, v, child) => Opacity(
                opacity: v,
                child: Transform.translate(
                  offset: Offset(0, 18.0 * (1.0 - v)),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplashContent extends StatelessWidget {
  const _SplashContent();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('🎌', style: TextStyle(fontSize: 72)),
        SizedBox(height: 20),
        Text(
          'AnimeQuiz',
          style: TextStyle(
            color:         AppColors.textPrimary,
            fontSize:      32,
            fontWeight:    FontWeight.w900,
            letterSpacing: -1.0,
            fontFamily:    'Nunito',
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Test your anime knowledge',
          style: TextStyle(
            color:      AppColors.textMuted,
            fontSize:   14,
            fontWeight: FontWeight.w500,
            fontFamily: 'Nunito',
          ),
        ),
        SizedBox(height: 44),
        SizedBox(
          width:  22,
          height: 22,
          child: CircularProgressIndicator(
            color:       AppColors.primary,
            strokeWidth: 2.5,
          ),
        ),
      ],
    );
  }
}

// ─── Offline Wall ─────────────────────────────────────────────────────────────
/// Overlaid above the entire navigator when connectivity is lost.
/// Automatically disappears when [UserDataProvider.isOnline] flips back.
class _OfflineWall extends StatelessWidget {
  const _OfflineWall();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: DecoratedBox(
        decoration: AppDecorations.heroBg,
        child: SizedBox.expand(
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon with layered glow rings
                    Container(
                      width:  100,
                      height: 100,
                      decoration: BoxDecoration(
                        color:  AppColors.wrong.withValues(alpha: 0.10),
                        shape:  BoxShape.circle,
                        border: Border.all(
                          color: AppColors.wrong.withValues(alpha: 0.28),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:      AppColors.wrong.withValues(alpha: 0.12),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.wifi_off_rounded,
                        color: AppColors.wrong,
                        size:  48,
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      'No Internet Connection',
                      style: TextStyle(
                        color:         AppColors.textPrimary,
                        fontSize:      24,
                        fontWeight:    FontWeight.w900,
                        letterSpacing: -0.3,
                        fontFamily:    'Nunito',
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'AnimeQuiz requires an internet connection.\nPlease reconnect to continue.',
                      style: TextStyle(
                        color:      AppColors.textSecondary,
                        fontSize:   15,
                        height:     1.6,
                        fontFamily: 'Nunito',
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    const _PulsingDot(),
                    const SizedBox(height: 12),
                    const Text(
                      'Waiting for connection…',
                      style: TextStyle(
                        color:      AppColors.textMuted,
                        fontSize:   13,
                        fontFamily: 'Nunito',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.35, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width:  10,
        height: 10,
        decoration: const BoxDecoration(
          color: AppColors.wrong,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}