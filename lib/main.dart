import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/theme/app_theme.dart';
import 'core/providers/theme_provider.dart';
import 'core/providers/user_data_provider.dart';
import 'core/providers/solo_difficulty_provider.dart';
import 'core/services/ad_service.dart';
import 'core/services/app_check_service.dart';
import 'core/services/app_update_service.dart';
import 'core/services/firestore_service.dart';
import 'core/services/notification_service.dart';
import 'core/widgets/update_required_screen.dart';
import 'features/auth/login_page.dart';
import 'features/home/home_page.dart';
import 'features/player/player_statistics_provider.dart';
import 'features/prizes/winner_announcement_page.dart';
import 'firebase_options.dart';

/// SharedPreferences key tracking which weekId the user has already seen.
const _kAnnouncementKey = 'lastSeenAnnouncementWeekId';

/// Global navigator key for minimal FCM tap navigation (Phase 3).
/// Used ONLY by NotificationService to push the claim/result screen on
/// notification taps. All other navigation stays exactly as it was.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Appearance preference is read FIRST, before any other service can write a
  // preference: ThemeProvider seeds an existing install to dark and a fresh one
  // to system by checking whether the prefs store is empty. Reading here also
  // lets the very first Flutter frame paint the right palette (and status-bar
  // icons) instead of flashing dark and correcting itself.
  final themeProvider = await ThemeProvider.load();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // App Check must be activated BEFORE any other Firebase service is touched,
  // so its token can be attached to the first Firestore/Storage/Functions call.
  // Server-side enforcement is opt-in (monitor mode by default), so a failure
  // here is logged rather than fatal.
  await AppCheckService.instance.activate();

  // Resolve our own build number/platform BEFORE anything can transact, and
  // register the foreground-resume re-check. Both are needed before runApp so
  // the gate is live on the very first frame rather than a moment later.
  await AppUpdateService.instance.init();
  AppUpdateService.instance.attachLifecycleGate();

  // AdMob must be initialised after Firebase.
  await MobileAds.instance.initialize();
  AdService.instance.preloadAll();

  // Status bar and Android navigation bar are owned by
  // `applySystemUiOverlay`, which ThemeProvider.load() already applied above
  // for the resolved brightness.

  runApp(
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      builder: (context, child) {
        return MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => themeProvider),
            ChangeNotifierProvider(create: (_) => PlayerStatisticsProvider()),
            ChangeNotifierProvider(create: (_) => UserDataProvider()),
            ChangeNotifierProvider(create: (_) => SoloDifficultyProvider()..load()),
          ],
          child: const AnimeQuizApp(),
        );
      },
    ),
  );
}

// ─── Root App ─────────────────────────────────────────────────────────────────
class AnimeQuizApp extends StatefulWidget {
  const AnimeQuizApp({super.key});

  @override
  State<AnimeQuizApp> createState() => _AnimeQuizAppState();
}

class _AnimeQuizAppState extends State<AnimeQuizApp> {
  @override
  void initState() {
    super.initState();
    // First gate read, forced past the resume throttle. Deferred to the first
    // frame so the splash renders immediately and the Firestore round-trip
    // never delays startup.
    //
    // Deliberately fires here rather than in _AppShell: this runs BEFORE
    // authentication, so an outdated install is walled over the login screen
    // instead of being allowed to sign in first. check() fails open, so a slow
    // or failed read leaves the app fully usable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppUpdateService.instance.check(force: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = context.watch<ThemeProvider>().resolvedBrightness;

    // Keep the static token palette in step with ThemeData. Idempotent —
    // ThemeProvider applies it before notifying; this call guarantees the first
    // frame and any other rebuild path start from the resolved brightness.
    AppColors.use(brightness);

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.0)),
      child: MaterialApp(
        title: 'AnimeQuiz',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.forBrightness(brightness),
        // A palette swap cannot be interpolated by AnimatedTheme — a crossfade
        // would paint new chrome over old token colours for ~200 ms.
        themeAnimationDuration: Duration.zero,
        navigatorKey: appNavigatorKey,

      // ── AuthGate is permanent — never recreated ───────────────────────────
      // _AnnouncementGate sits inside it so it only runs post-authentication.
      // The offline and update overlays are applied via builder below, which
      // wraps the navigator OUTPUT rather than the navigator itself. This
      // means the Navigator stack is never torn down on connectivity or
      // version changes, which was the root cause of all previous screen
      // freezes.
      home: AuthGate(home: const _AnnouncementGate()),

      // ── Offline / update / loading overlay sits ABOVE the navigator ───────
      // We never replace child — we either show it or cover it so gesture
      // recognisers on the existing stack are never destroyed.
      builder: (context, child) {
        return ListenableBuilder(
          listenable: AppUpdateService.instance,
          builder: (context, _) {
            return Consumer<UserDataProvider>(
              builder: (context, userData, _) {
                if (!userData.connectivityChecked) return const _SplashScreen();
                if (!userData.isOnline)            return const _OfflineWall();
                // Outdated Android build: hard wall, no dismiss affordance.
                // Ordered below the offline wall on purpose — the update check
                // needs the network, and offline is the more actionable
                // message, so it keeps priority.
                final update = AppUpdateService.instance.state;
                if (update.updateRequired) {
                  return UpdateRequiredScreen(state: update);
                }
                return child!;
              },
            );
          },
        );
      },
    ),
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

    // BUG FIX: Save weekId to SharedPreferences BEFORE showing announcement.
    // Previously, the save happened AFTER showing the page, which meant:
    // 1. If app crashes before save completes, user sees announcement again
    // 2. If user dismisses quickly and app closes before save, same issue
    // Now marking as seen FIRST, then showing announcement (user can re-view
    // leaderboard via leaderboard button even after dismissing announcement).
    await prefs.setString(_kAnnouncementKey, result.weekId);

    if (!mounted) return;

    // The announcement no longer offers a "View leaderboard" action, so the
    // push simply waits for the player to close the page.
    await Navigator.of(context).push<void>(
      PageRouteBuilder(
        pageBuilder:        (_, __, ___) => WinnerAnnouncementPage(result: result),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
        fullscreenDialog:   true,
      ),
    );

    _markReady();
    return;
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

class _AppShellState extends State<_AppShell> with WidgetsBindingObserver {
  bool _statsInited = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Cold-open: show an app open ad after the first frame so the shell has
    // settled and the UserDataProvider has finished its initial fetch.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryShowAppOpenAd());
    // Phase 3 minimal FCM: permission/token registration + tap navigation.
    // _AppShell only exists post-authentication, so the token is saved for
    // the signed-in user. Best-effort — failures never block the shell.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.init(navigatorKey: appNavigatorKey);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground resume — show an app open ad if one is ready.
    if (state == AppLifecycleState.resumed) {
      _tryShowAppOpenAd();
    }
  }

  void _tryShowAppOpenAd() {
    if (!mounted) return;
    final isPremium = context.read<UserDataProvider>().premiumActive;
    AdService.instance.showAppOpenAdIfReady(isPremium: isPremium);
  }

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
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth > 600;
        final iconSize = isTablet ? 96.0 : 72.0;
        final titleSize = isTablet ? 40.0 : 32.0;
        final subtitleSize = isTablet ? 16.0 : 14.0;
        final spacingUnit = isTablet ? 1.2 : 1.0;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('🎌', style: TextStyle(fontSize: iconSize)),
            SizedBox(height: 20 * spacingUnit),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'AnimeQuiz',
                style: TextStyle(
                  color:         AppColors.textPrimary,
                  fontSize:      titleSize,
                  fontWeight:    FontWeight.w900,
                  letterSpacing: -1.0,
                  fontFamily:    'Nunito',
                ),
              ),
            ),
            SizedBox(height: 6 * spacingUnit),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'Test your anime knowledge',
                style: TextStyle(
                  color:      AppColors.textMuted,
                  fontSize:   subtitleSize,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'Nunito',
                ),
              ),
            ),
            SizedBox(height: 44 * spacingUnit),
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
      },
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
                padding: EdgeInsets.symmetric(horizontal: 24.r),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isTablet = constraints.maxWidth > 600;
                    final iconSize = isTablet ? 120.0 : 100.0;
                    final iconInnerSize = isTablet ? 58.0 : 48.0;
                    final titleSize = isTablet ? 28.0 : 24.0;
                    final subtitleSize = isTablet ? 17.0 : 15.0;
                    final mutedSize = isTablet ? 15.0 : 13.0;
                    final spacingUnit = isTablet ? 1.1 : 1.0;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Icon with layered glow rings
                        Container(
                          width:  iconSize,
                          height: iconSize,
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
                          child: Icon(
                            Icons.wifi_off_rounded,
                            color: AppColors.wrong,
                            size:  iconInnerSize,
                          ),
                        ),
                        SizedBox(height: 32 * spacingUnit),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'No Internet Connection',
                            style: TextStyle(
                              color:         AppColors.textPrimary,
                              fontSize:      titleSize,
                              fontWeight:    FontWeight.w900,
                              letterSpacing: -0.3,
                              fontFamily:    'Nunito',
                            ),
                          ),
                        ),
                        SizedBox(height: 12 * spacingUnit),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'AnimeQuiz requires an internet connection.\nPlease reconnect to continue.',
                            style: TextStyle(
                              color:      AppColors.textSecondary,
                              fontSize:   subtitleSize,
                              height:     1.6,
                              fontFamily: 'Nunito',
                            ),
                          ),
                        ),
                        SizedBox(height: 40 * spacingUnit),
                        const _PulsingDot(),
                        SizedBox(height: 12 * spacingUnit),
                        Text(
                          'Waiting for connection…',
                          style: TextStyle(
                            color:      AppColors.textMuted,
                            fontSize:   mutedSize,
                            fontFamily: 'Nunito',
                          ),
                        ),
                      ],
                    );
                  },
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