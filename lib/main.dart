import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
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
import 'core/services/web_update_service.dart';
import 'feature/tutorial/presentation/tutorial_screen/ui/tutorial_screen.dart';
import 'feature/tutorial/tutorial_service.dart';
import 'features/auth/login_page.dart';
import 'features/home/home_page.dart';
import 'features/player/player_statistics_provider.dart';
import 'features/prizes/winner_announcement_page.dart';
import 'firebase_options.dart';

/// SharedPreferences key tracking which weekId the user has already seen.
const _kAnnouncementKey = 'lastSeenAnnouncementWeekId';

/// Global navigator key. Retained as the seam for a future web push/
/// notification implementation (see NotificationService). All ordinary
/// navigation uses `Navigator.of(context)` directly.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Web startup is boot-first: the first frame paints immediately from the
/// static HTML splash + [_BootApp], and Firebase/App Check/providers resolve
/// in the background. Nothing awaits before the first `runApp`, so a slow
/// network or Firebase outage can never leave the page blank.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BootApp());
  _initAndRun();
}

Future<void> _initAndRun() async {
  // Appearance preference is read FIRST, before any other service can write a
  // preference: ThemeProvider seeds an existing install to dark and a fresh one
  // to system by checking whether the prefs store is empty.
  final themeProvider = await ThemeProvider.load();

  // Portrait lock (PWA manifest holds it for installed apps; this covers the
  // engine level). Runs in the background init so it never delays first paint.
  try {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  } catch (_) {
    // Non-fatal: browsers without orientation support just ignore it.
  }

  try {
    await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    // Firebase is required for auth/data, but failing here must still leave
    // the boot splash replaced by the offline wall rather than a blank page.
    debugPrint('[main] Firebase init failed (non-fatal): $e');
  }

  // App Check attaches its token to the first Firestore/Functions call.
  // Server-side enforcement is monitor mode by default, so a failure here
  // is logged rather than fatal.
  await AppCheckService.instance.activate();

  await AppUpdateService.instance.init();
  AppUpdateService.instance.attachLifecycleGate();

  // Ads are web-only future work: AdService is a no-op seam (see
  // lib/core/services/ad_service.dart). Nothing to preload.
  AdService.instance.preloadAll();

  runApp(_Root(themeProvider: themeProvider));
}

/// First-frame app: static dark splash only. No providers, no Firebase, no
/// ScreenUtil — deliberately dependency-free so it paints in one frame.
class _BootApp extends StatelessWidget {
  const _BootApp();

  @override
  Widget build(BuildContext context) {
    AppColors.use(Brightness.dark);
    return MaterialApp(
      title: 'AnimeQuiz',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.forBrightness(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: const _SplashScreen(),
    );
  }
}

/// App root. Exists so the web design size can track the browser window:
/// [ScreenUtilInit.designSize] is fixed at construction, but a desktop window
/// can be resized after startup. Recomputing it here keeps `.w`/`.sp`
/// phone-proportioned instead of drifting.
class _Root extends StatefulWidget {
  const _Root({required this.themeProvider});

  final ThemeProvider themeProvider;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => setState(() {});

  /// Phone canvas width everything is designed against.
  static const double _kPhoneWidth = 480;

  static Size _designSize() {
    const fallback = Size(390, 844);
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      if (size.width <= 0) return fallback;
      // At or below phone width the stock design size applies, so phones and
      // narrow windows behave exactly as the mobile layout. Wider viewports
      // grow the design width proportionally, which holds the effective scale
      // at the 480-wide phone ratio instead of blowing every widget up.
      if (size.width <= _kPhoneWidth) return fallback;
      return Size(size.width * 390.0 / _kPhoneWidth, 844);
    } catch (_) {
      return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: _designSize(),
      minTextAdapt: true,
      builder: (context, child) {
        return MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => widget.themeProvider),
            ChangeNotifierProvider(create: (_) => PlayerStatisticsProvider()),
            ChangeNotifierProvider(create: (_) => UserDataProvider()),
            ChangeNotifierProvider(
                create: (_) => SoloDifficultyProvider()..load()),
          ],
          child: const AnimeQuizApp(),
        );
      },
    );
  }
}

// ─── Root App ─────────────────────────────────────────────────────────────────
class AnimeQuizApp extends StatefulWidget {
  const AnimeQuizApp({super.key});

  @override
  State<AnimeQuizApp> createState() => _AnimeQuizAppState();
}

class _AnimeQuizAppState extends State<AnimeQuizApp> {
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

        // ── Offline / loading overlay sits ABOVE the navigator ────────────────
        // We never replace child — we either show it or cover it so gesture
        // recognisers on the existing stack are never destroyed.
        builder: (context, child) {
          return Consumer<UserDataProvider>(
            builder: (context, userData, _) {
              final Widget content;
              if (!userData.connectivityChecked) {
                content = const _SplashScreen();
              } else if (!userData.isOnline) {
                content = const _OfflineWall();
              } else {
                content = child!;
              }
              // Web presents the app as a centred phone-width column so a
              // desktop window looks like the mobile app instead of a
              // stretched page. Phones (<=480 logical px) are unaffected.
              // Height is taken from the incoming constraints (the true
              // dynamic viewport, i.e. the 100dvh equivalent — never a
              // stale mq.size.height snapshot), so a browser-chrome resize
              // can never leave the column taller than the visible window
              // — the failure that pushed the bottom nav below the fold
              // and cut the anime grid.
              return LayoutBuilder(
                builder: (context, constraints) {
                  final mq = MediaQuery.of(context);
                  final isWide = mq.size.width > _RootState._kPhoneWidth;
                  final columnWidth =
                      isWide ? _RootState._kPhoneWidth : mq.size.width;
                  final height = constraints.maxHeight.isFinite
                      ? constraints.maxHeight
                      : mq.size.height;
                  return Container(
                    color: AppColors.surfaceDim,
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      // minHeight == maxHeight == viewport height pins the
                      // phone column to exactly one dynamic viewport unit
                      // (100dvh): it can neither collapse short (which
                      // left a gap under short tabs) nor grow taller than
                      // the window (which pushed the nav below the fold).
                      constraints: BoxConstraints(
                        minWidth: columnWidth,
                        maxWidth: columnWidth,
                        minHeight: height,
                        maxHeight: height,
                      ),
                      child: Container(
                        // On wide screens draw the phone frame edges so
                        // the centred column reads as a mobile app. Phones
                        // span the full width, so no border is drawn there.
                        decoration: isWide
                            ? BoxDecoration(
                                border: Border.symmetric(
                                  vertical: BorderSide(
                                    color: AppColors.divider,
                                  ),
                                ),
                              )
                            : null,
                        child: MediaQuery(
                          data: mq.copyWith(
                            size: Size(columnWidth, height),
                          ),
                          child: content,
                        ),
                      ),
                    ),
                  );
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
      final prefs = await SharedPreferences.getInstance();
      final lastSeen = prefs.getString(_kAnnouncementKey);
      final result = await FirestoreService.instance.getLastWeekWinners();

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
          pageBuilder: (_, __, ___) => WinnerAnnouncementPage(result: result),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 400),
          fullscreenDialog: true,
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
    // Cold-open hook for a future web-ads provider: fires after the first
    // frame so the shell has settled. Currently a no-op seam.
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryShowAppOpenAd());
    // Push-notification seam (currently a no-op on web). _AppShell only
    // exists post-authentication, so a future implementation can register
    // the token for the signed-in user here. Best-effort — failures never
    // block the shell.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.init(navigatorKey: appNavigatorKey);
    });
    // Web update notice: baseline the running build shortly after launch,
    // so a later deploy prompts a refresh instead of stranding the session
    // on stale code.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) WebUpdateService.instance.checkAndNotify(context);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowTutorial());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground resume hook for a future web-ads provider (no-op today).
    if (state == AppLifecycleState.resumed) {
      _tryShowAppOpenAd();
      // A resume is the most likely moment to discover a deploy that
      // landed while the tab was backgrounded.
      WebUpdateService.instance.checkAndNotify(context);
    }
  }

  void _tryShowAppOpenAd() {
    if (!mounted) return;
    final isPremium = context.read<UserDataProvider>().premiumActive;
    AdService.instance.showAppOpenAdIfReady(isPremium: isPremium);
  }

  Future<void> _maybeShowTutorial() async {
    if (!mounted) return;
    final shouldShow = await TutorialService.shouldShow();
    if (!mounted || !shouldShow) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TutorialScreen()),
    );
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
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 850),
              curve: Curves.easeOutCubic,
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
                  color: AppColors.textPrimary,
                  fontSize: titleSize,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.0,
                  fontFamily: 'Nunito',
                ),
              ),
            ),
            SizedBox(height: 6 * spacingUnit),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                'Test your anime knowledge',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: subtitleSize,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'Nunito',
                ),
              ),
            ),
            SizedBox(height: 44 * spacingUnit),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                color: AppColors.primary,
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
                          width: iconSize,
                          height: iconSize,
                          decoration: BoxDecoration(
                            color: AppColors.wrong.withValues(alpha: 0.10),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.wrong.withValues(alpha: 0.28),
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.wrong.withValues(alpha: 0.12),
                                blurRadius: 24,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.wifi_off_rounded,
                            color: AppColors.wrong,
                            size: iconInnerSize,
                          ),
                        ),
                        SizedBox(height: 32 * spacingUnit),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'No Internet Connection',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: titleSize,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.3,
                              fontFamily: 'Nunito',
                            ),
                          ),
                        ),
                        SizedBox(height: 12 * spacingUnit),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'AnimeQuiz requires an internet connection.\nPlease reconnect to continue.',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: subtitleSize,
                              height: 1.6,
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
                            color: AppColors.textMuted,
                            fontSize: mutedSize,
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
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
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
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: AppColors.wrong,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
