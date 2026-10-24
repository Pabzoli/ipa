import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_balance_widget.dart';
import '../../core/widgets/weekly_points_pill.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/providers/solo_difficulty_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/prize_pool_service.dart';
import '../admin/admin_payout_dashboard.dart';
import '../auth/auth_service.dart';
import '../quiz/questions_page.dart';
import '../quiz/quiz_controller.dart'
    show kGauntletQuestionCount, kGauntletTiers;
import '../../core/constants/gauntlet_economy.dart';
import '../../core/constants/solo_economy.dart';
import '../../core/constants/anime_catalog.dart';
import '../player/pi_page.dart';
import '../../features/multiplayer/multiplayer_hub_page.dart';
import '../leaderboard/weekly_leaderboard_page.dart';
import '../premium/premium_upsell_screen.dart';

// ─── Anime grid filter (client-side only, no backend calls) ───────────────
enum _AnimeFilter { all, ready, cooldown }

// ═══════════════════════════════════════════════════════════════════════════
// HomePage is the app's root shell: a persistent bottom nav hosting four
// peer destinations — Home / Battle / Rankings / Profile.
// ═══════════════════════════════════════════════════════════════════════════
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  // Built lazily. A `static const` list would make the IndexedStack lay out and
  // mount all four tabs at app launch, so the leaderboard would run its first
  // Firestore read for every session whether or not the player ever looked at
  // Rankings. Each tab's State is now created on first visit and kept alive
  // afterwards, which is the point of the IndexedStack. (The widget objects are
  // cheap to build; it is the State, and its reads, that the visit gate defers.)
  late final List<Widget> _pages = <Widget>[
    _HomeTab(onOpenRankings: () => setState(() => _tab = 2)),
    const MultiplayerHubPage(),
    const WeeklyLeaderboardPage(),
    const PInform(),
  ];
  final Set<int> _visited = <int>{0};

  @override
  Widget build(BuildContext context) {
    _visited.add(_tab);

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: IndexedStack(
        index: _tab,
        children: [
          for (var i = 0; i < _pages.length; i++)
            if (_visited.contains(i)) _pages[i] else const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: _AppBottomNav(
        current: _tab,
        onSelect: (i) => setState(() => _tab = i),
      ),
    );
  }
}

// ─── Bottom Navigation ─────────────────────────────────────────────────────
class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem(this.icon, this.label);
}

class _AppBottomNav extends StatelessWidget {
  final int current;
  final ValueChanged<int> onSelect;
  const _AppBottomNav({required this.current, required this.onSelect});

  static const _items = <_NavItem>[
    _NavItem(Icons.home_rounded, 'Home'),
    _NavItem(Icons.sports_esports_rounded, 'Battle'),
    _NavItem(Icons.emoji_events_rounded, 'Rankings'),
    _NavItem(Icons.person_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: EdgeInsets.only(
            top: 10.h,
            bottom: MediaQuery.of(context).padding.bottom + 8.h,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceDim.withOpacity(0.92),
            border: const Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(_items.length, (i) {
              final active = i == current;
              final item = _items[i];
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: EdgeInsets.symmetric(
                          horizontal: 14.w, vertical: 5.h),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.primary.withOpacity(0.14)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14.r),
                      ),
                      child: Icon(item.icon,
                          size: 22.r,
                          color:
                              active ? AppColors.primary : AppColors.textMuted),
                    ),
                    SizedBox(height: 3.h),
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w700,
                        color: active ? AppColors.primary : AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Home tab
// ═══════════════════════════════════════════════════════════════════════════
class _HomeTab extends StatefulWidget {
  /// Switches the bottom-nav shell to the Rankings tab. The prize-pool card is
  /// the natural tap-through to it; without this the only way to Rankings was
  /// the nav bar itself, and the pool card looked interactive but was not.
  final VoidCallback onOpenRankings;

  const _HomeTab({required this.onOpenRankings});

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> with TickerProviderStateMixin {
  /// Live catalogue (app_config/anime_catalog), starting from the bundled list.
  List<String> _animeTitles = kAnimeCatalog;

  final Set<String> _selected = {};
  final Map<String, DateTime> _locks = {};
  Set<String> _unlockedForever = {};
  _AnimeFilter _filter = _AnimeFilter.all;
  late Timer _lockTimer;
  late AnimationController _entranceCtrl;
  late Animation<double> _entranceFade;
  late StreamSubscription<User?> _authSub;
  StreamSubscription<Map<String, DateTime>>? _cooldownSub;
  StreamSubscription<List<String>>? _catalogSub;

  /// Bumped once per second while any cooldown lock is active, so only the
  /// countdown pills rebuild rather than the whole tab.
  final ValueNotifier<int> _lockTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..forward();
    _entranceFade =
        CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOut);

    _lockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _locks.isEmpty) return; // idle: nothing counting down
      final now = DateTime.now();
      final expired =
          _locks.entries.where((e) => !e.value.isAfter(now)).toList();
      if (expired.isEmpty) {
        // Locks still ticking — refresh only the countdown pills.
        _lockTick.value++;
      } else {
        // A lock elapsed: status, filter counts and lock overlays all change,
        // so this one rebuild is genuine.
        setState(() {
          for (final e in expired) {
            _locks.remove(e.key);
          }
        });
      }
    });

    _catalogSub = FirestoreService.instance.animeCatalogStream().listen(
      (titles) {
        if (mounted) setState(() => _animeTitles = titles);
      },
      onError: (Object e) =>
          debugPrint('[HomeTab] anime catalog error (keeping bundled list): $e'),
    );

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      setState(() => _unlockedForever = {});
      _cooldownSub?.cancel();
      _cooldownSub = null;
      if (user == null) {
        setState(_locks.clear);
        return;
      }
      _cooldownSub = FirestoreService.instance.cooldownsStream().listen(
        (expiries) {
          if (!mounted) return;
          final now = DateTime.now();
          setState(() {
            _locks
              ..clear()
              ..addEntries(expiries.entries.where((e) => e.value.isAfter(now)));
          });
        },
        onError: (Object e) =>
            debugPrint('[HomeTab] cooldowns stream error (ignored): $e'),
      );
      _loadUnlockedAnimes();
    });
  }

  @override
  void dispose() {
    _lockTimer.cancel();
    _entranceCtrl.dispose();
    _authSub.cancel();
    _cooldownSub?.cancel();
    _catalogSub?.cancel();
    _lockTick.dispose();
    super.dispose();
  }

  Future<void> _loadUnlockedAnimes() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final list =
          (doc.data()?['unlockedAnimes'] as List?)?.cast<String>() ?? [];
      if (mounted) setState(() => _unlockedForever = list.toSet());
    } catch (e) {
      debugPrint('[HomeTab] _loadUnlockedAnimes error (ignored): $e');
    }
  }

  void _toggleSelection(String title) {
    if (_locks.containsKey(title)) return;
    setState(() => _selected.contains(title)
        ? _selected.remove(title)
        : _selected.add(title));
  }

  List<String> get _unlockedTitles => _animeTitles
      .where(
          (t) => !_locks.containsKey(t) || _locks[t]!.isBefore(DateTime.now()))
      .toList();

  bool _isTitleLocked(String title) {
    final t = _locks[title];
    return t != null && t.isAfter(DateTime.now());
  }

  List<String> get _visibleTitles {
    switch (_filter) {
      case _AnimeFilter.ready:
        return _animeTitles.where((t) => !_isTitleLocked(t)).toList();
      case _AnimeFilter.cooldown:
        return _animeTitles.where(_isTitleLocked).toList();
      case _AnimeFilter.all:
        return List<String>.from(_animeTitles);
    }
  }

  void _surpriseMe() {
    final pool = List<String>.from(_unlockedTitles);
    if (pool.length < 2) return;
    pool.shuffle();
    setState(() {
      _selected
        ..clear()
        ..addAll(pool.take(2));
    });
  }

  // ── Start Quiz ─────────────────────────────────────────────────────────
  Future<void> _startQuiz({
    bool isGauntlet = false,
    List<String>? titles,
    List<String>? questionIds,
    String? gauntletTicketId,
  }) async {
    if (isGauntlet) {
      if (questionIds == null || questionIds.length < kGauntletQuestionCount) {
        // Never fail silently — the user just confirmed + may have paid.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                "Couldn't load the Daily Gauntlet — please try again."),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.wrong,
          ),
        );
        return;
      }
      Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: QuestionsPage(
              selectedTitles: const [],
              questionIds: questionIds,
              mode: QuizMode.gauntlet,
              isGauntlet: true,
              gauntletTicketId: gauntletTicketId,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
      return;
    }

    final titlesToPlay = titles ?? _selected.toList();
    if (titlesToPlay.length < 2) return;

    // Capture the difficulty from the shared settings now — the tray clears
    // _selected but must not reset the difficulty choice.
    final difficultyToPlay = normalizeSoloDifficulty(
      context.read<SoloDifficultyProvider>().difficulty,
    );

    // The server records the cooldown (and refuses titles still locked), so
    // the lock can't be skipped by clearing app data. Nothing navigates unless
    // the lock was recorded.
    final Map<String, int> expiries;
    try {
      expiries =
          await FirestoreService.instance.startSoloCooldowns(titlesToPlay);
    } catch (e) {
      debugPrint('[HomeTab] startSoloCooldowns error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_cooldownStartErrorMessage(e))),
        );
      }
      return;
    }
    if (!mounted) return;

    setState(() {
      _selected.clear();
      expiries.forEach(
        (t, ms) => _locks[t] = DateTime.fromMillisecondsSinceEpoch(ms),
      );
    });

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, a, __) => FadeTransition(
          opacity: a,
          child: QuestionsPage(
            selectedTitles: titlesToPlay,
            soloDifficulty: difficultyToPlay,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  String _cooldownStartErrorMessage(Object e) {
    if (e is FirebaseFunctionsException) {
      if (e.code == 'failed-precondition' && e.message == 'cooldown_active') {
        return 'Some anime are still on cooldown — pick again.';
      }
      if (e.code == 'failed-precondition' &&
          (e.message ?? '').startsWith('App update required')) {
        return e.message!;
      }
    }
    return 'Something went wrong — please try again.';
  }

  // ── Daily Gauntlet entry point ──────────────────────────────────────────
  // Flow: preview (live stream, no charge) → confirm dialog → loading →
  // fetch question IDs (free, validated) → enterDailyGauntlet (authoritative
  // deduction + ticket) → quiz page. Charging happens ONLY after the user
  // confirms AND content is available, so a content failure never burns coins.
  bool _gauntletBusy = false;

  Future<void> _startDailyGauntlet() async {
    if (_gauntletBusy) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please sign in to play the Daily Gauntlet.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // ── 1. Preview (no charge, same source as the home card) ──────────
    // Capture premium BEFORE any async gap.
    final isPremiumCached = context.read<UserDataProvider>().premiumActive;
    int streak = 0;
    bool isFreeAttempt = true;
    int? retryCost = 0;
    try {
      final progress = await FirestoreService.instance
          .gauntletProgressStream()
          .first
          .timeout(const Duration(seconds: 6));
      streak = (progress['streak'] as int?) ?? 0;
      final usedToday = (progress['usedToday'] as bool?) ?? false;
      final retryIndex = (progress['retryIndex'] as int?) ?? 0;
      isFreeAttempt = !usedToday;
      retryCost = gauntletRetryCost(
        retryIndex: retryIndex,
        isPremium: isPremiumCached,
        isFreeAttempt: isFreeAttempt,
      );
    } catch (e) {
      // Offline / slow stream — fall back to a free preview so the dialog
      // still opens; the server remains authoritative at enter time.
      debugPrint('[HomeTab] gauntlet preview fallback (free): $e');
      streak = 0;
      isFreeAttempt = true;
      retryCost = 0;
    }

    if (!mounted) return;

    // At cap — no retries left today.
    if (!isFreeAttempt && retryCost == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No Gauntlet retries left today — come back tomorrow.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // ── 2. Confirm (redesigned to match the app) ───────────────────────
    final confirmed = await _showGauntletConfirmDialog(
      streak: streak,
      isFreeAttempt: isFreeAttempt,
      retryCost: retryCost ?? 0,
    );
    if (confirmed != true || !mounted) return;

    // ── 3. Load + enter with visible feedback ──────────────────────────
    _gauntletBusy = true;
    if (mounted) setState(() {});
    _showGauntletLoading();
    try {
      // Content first (free): a content failure must never burn coins.
      final pool = _animeTitles.toSet()..addAll(_unlockedForever);
      final questionIds =
          await FirestoreService.instance.fetchGauntletQuestionIds(
        unlockedTitles: pool.toList(),
        count: kGauntletQuestionCount,
      );

      // Then the authoritative deduction + ticket.
      final entryResult =
          await FirestoreService.instance.enterDailyGauntlet();
      final String? ticketId = entryResult['ticketId'] as String?;

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close loading
      _startQuiz(
        isGauntlet: true,
        questionIds: questionIds,
        gauntletTicketId: ticketId,
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint('[HomeTab] enterDailyGauntlet error: ${e.code} ${e.message}');
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close loading
      if (e.code == 'resource-exhausted' &&
          (e.message?.startsWith('insufficient_coins') ?? false)) {
        final needed = int.tryParse(e.message?.split(':').last ?? '') ?? 40;
        await showInsufficientCoinsSheet(context, needed: needed);
        return;
      }
      if (e.code == 'failed-precondition') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('No Gauntlet retries left today — come back tomorrow.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      if (e.code == 'not-found') {
        // The callable isn't deployed in us-central1 on this project.
        // Code is fine locally (enterDailyGauntlet is exported) — deploy:
        //   firebase deploy --only functions:enterDailyGauntlet,functions:submitDailyGauntlet
        debugPrint(
            '[HomeTab] enterDailyGauntlet NOT_FOUND — function not deployed. '
            'Run: firebase deploy --only '
            'functions:enterDailyGauntlet,functions:submitDailyGauntlet');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Daily Gauntlet is updating on the server — '
                'please try again in a minute.'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.wrong,
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              "Couldn't start the Daily Gauntlet — please try again."),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.wrong,
        ),
      );
    } catch (e) {
      debugPrint('[HomeTab] _startDailyGauntlet error: $e');
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_gauntletLoadErrorMessage(e)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.wrong,
        ),
      );
    } finally {
      _gauntletBusy = false;
      if (mounted) setState(() {});
    }
  }

  /// Friendly message for content failures (thrown BEFORE any charge).
  String _gauntletLoadErrorMessage(Object e) {
    final msg = e.toString();
    if (msg.contains('Not enough questions')) {
      return 'Not enough questions yet — try a normal quiz first.';
    }
    return "Couldn't load the Daily Gauntlet — please try again.";
  }

  /// Non-dismissible loading indicator shown while fetching + entering.
  void _showGauntletLoading() {
    showAppDialog<void>(
      context,
      barrierDismissible: false,
      builder: (_) => const AppDialog(
        icon: Icons.hourglass_top_rounded,
        iconColor: AppColors.amber,
        title: 'Preparing Gauntlet…',
        content: 'Fetching questions and reserving your entry.',
      ),
    );
  }

  /// Confirm dialog for the Daily Gauntlet.
  ///
  /// Built on [AppDialog] for the app's dialog shell, then styled to mirror the
  /// home tile: the same amber streak medallion and milestone rail, the WP
  /// ladder as chips read from [kGauntletTiers] (never a hardcoded copy of the
  /// server curve), and the entry cost as a plain fact row. Nothing is charged
  /// until this resolves true.
  Future<bool?> _showGauntletConfirmDialog({
    required int streak,
    required bool isFreeAttempt,
    required int retryCost,
  }) {
    const amber = AppColors.amber;
    final isFreeEntry = isFreeAttempt || retryCost == 0;

    // Milestone days ascend (3, 7, 14, 30); the first past the streak is what
    // the rail walks toward.
    int? nextDay;
    for (final day in kGauntletMilestones.keys) {
      if (streak < day) {
        nextDay = day;
        break;
      }
    }
    final milestoneLabel = nextDay == null
        ? 'All milestones claimed'
        : '${nextDay - streak}d → ${kGauntletMilestones[nextDay]}';
    final progress = _milestoneProgress(streak, nextDay);
    final totalWP = kGauntletTiers.fold<int>(0, (acc, t) => acc + t);

    final confirmLabel = isFreeAttempt
        ? 'Start · Free'
        : (retryCost == 0 ? 'Retry · FREE' : 'Retry · $retryCost AC');

    return showAppDialog<bool>(
      context,
      builder: (ctx) => AppDialog(
        icon: Icons.emoji_events_rounded,
        iconColor: amber,
        title: 'Daily Gauntlet',
        contentWidget: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Streak + milestone progress banner ──────────────────
            Container(
              padding: EdgeInsets.all(14.r),
              decoration: BoxDecoration(
                gradient: isFreeEntry
                    ? LinearGradient(
                        colors: [
                          amber.withValues(alpha: 0.20),
                          amber.withValues(alpha: 0.05),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: isFreeEntry ? null : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(
                  color: isFreeEntry
                      ? amber.withValues(alpha: 0.45)
                      : AppColors.divider,
                  width: isFreeEntry ? 1.5 : 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Streak medallion — the same shape as the home tile.
                      Container(
                        width: 52.r,
                        height: 52.r,
                        decoration: BoxDecoration(
                          color: amber
                              .withValues(alpha: isFreeEntry ? 0.16 : 0.07),
                          borderRadius: BorderRadius.circular(14.r),
                          border: Border.all(
                            color: amber.withValues(
                                alpha: isFreeEntry ? 0.34 : 0.16),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.local_fire_department_rounded,
                              color: isFreeEntry ? amber : AppColors.textMuted,
                              size: 15.r,
                            ),
                            Text(
                              '$streak',
                              style: TextStyle(
                                color:
                                    isFreeEntry ? amber : AppColors.textMuted,
                                fontSize: 18.sp,
                                fontWeight: FontWeight.w900,
                                height: 1.0,
                                letterSpacing: -0.3,
                              ),
                            ),
                            Text(
                              'DAY STREAK',
                              style: TextStyle(
                                color: amber.withValues(
                                    alpha: isFreeEntry ? 0.75 : 0.45),
                                fontSize: 6.sp,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.4,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              streak == 1
                                  ? '1 day in a row'
                                  : '$streak days in a row',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 14.sp,
                                fontWeight: FontWeight.w900,
                                height: 1.1,
                                letterSpacing: -0.2,
                              ),
                            ),
                            SizedBox(height: 4.h),
                            Text(
                              isFreeEntry
                                  ? 'Your free attempt is ready'
                                  : 'Your extra attempt today',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11.sp,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 14.h),
                  // Milestone rail — fills toward the next reward.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.full),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: progress),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      builder: (_, value, __) => Container(
                        width: double.infinity,
                        height: 5.r,
                        color: AppColors.divider,
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: value.clamp(0.0, 1.0).toDouble(),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  amber.withValues(alpha: 0.55),
                                  amber,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 7.h),
                  Row(
                    children: [
                      Text(
                        'NEXT MILESTONE',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 8.sp,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.7,
                        ),
                      ),
                      const Spacer(),
                      Flexible(
                        child: Text(
                          milestoneLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color:
                                isFreeEntry ? amber : AppColors.textSecondary,
                            fontSize: 10.sp,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            SizedBox(height: AppSpacing.lg),

            // ── WP ladder (read from kGauntletTiers) ────────────────
            Row(
              children: [
                Expanded(
                  child: Text(
                    'WP PER QUESTION',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 9.sp,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                Text(
                  'up to $totalWP WP',
                  style: TextStyle(
                    color: amber,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8.h),
            Row(
              children: [
                for (var i = 0; i < kGauntletTiers.length; i++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: i == kGauntletTiers.length - 1 ? 0 : 5.w,
                      ),
                      child: _WpChip(tier: kGauntletTiers[i]),
                    ),
                  ),
              ],
            ),

            SizedBox(height: AppSpacing.lg),

            // ── Facts ───────────────────────────────────────────────
            _GauntletDialogRow(
              icon: Icons.quiz_rounded,
              text: '$kGauntletQuestionCount mixed-anime questions',
            ),
            SizedBox(height: 8.h),
            _GauntletDialogRow(
              icon: isFreeEntry
                  ? Icons.card_giftcard_rounded
                  : Icons.monetization_on_rounded,
              text: isFreeEntry
                  ? 'Free entry — no coins needed'
                  : 'Entry: $retryCost AC · non-refundable if you quit',
            ),
            const SizedBox(height: AppSpacing.xl),
            // ── Actions (full-width, app-consistent) ────────────────
            SizedBox(
              width: double.infinity,
              child: AppButton(
                label: confirmLabel,
                variant: AppButtonVariant.primary,
                size: AppButtonSize.large,
                color: amber,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: AppButton(
                label: 'Not now',
                variant: AppButtonVariant.text,
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _spendBusy = false;

  // ── SPEND SURFACE 2: Cooldown Skip — flat 100 AC (v4.8) ─────────────────
  Future<void> _skipCooldown(String title) async {
    if (_spendBusy) return;
    final userData = context.read<UserDataProvider>();
    const cost = kCooldownSkipCost;

    if (userData.animeCoins < cost) {
      if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Skip Cooldown?',
          style: TextStyle(
              color: AppColors.textPrimary, fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Spend $cost🪙 to unlock "${title.toUpperCase()}" immediately?',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14.sp),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              '⏩ Skip  −$cost🪙',
              style: TextStyle(
                  color: AppColors.accent, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _spendBusy = true);
    try {
      await userData.spendCoins(
        cost,
        'spend_cooldown',
        extra: {'title': title},
      );
      if (!mounted) return;
      setState(() => _locks.remove(title));
    } on InsufficientCoinsException {
      if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
    } catch (e) {
      debugPrint('[HomeTab] _skipCooldown error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Something went wrong — please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _spendBusy = false);
    }
  }

  // ── SPEND SURFACE 4: Early Anime Unlock (5000 AC) ───────────────────────
  Future<void> _unlockEarly(String title) async {
    if (_spendBusy) return;
    const cost = kEarlyUnlockCost;
    final userData = context.read<UserDataProvider>();

    if (userData.animeCoins < cost) {
      if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Unlock Early?',
          style: TextStyle(
              color: AppColors.textPrimary, fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Spend $cost🪙 to permanently unlock "${title.toUpperCase()}"?\n\n'
          'This removes it from cooldown and adds it to your unlocked library.',
          style: TextStyle(
              color: AppColors.textSecondary, fontSize: 14.sp, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              '🔓 Unlock  −$cost🪙',
              style: const TextStyle(
                  color: AppColors.accent, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _spendBusy = true);
    try {
      final result = await FirestoreService.instance.unlockAnimeEarly(title);

      if (!mounted) return;

      setState(() {
        _locks.remove(title);
        _unlockedForever.add(title);
      });
      debugPrint('[HomeTab] _unlockEarly ok: ${result['newBalance']}');
    } on FirebaseFunctionsException catch (e) {
      debugPrint('[HomeTab] _unlockEarly CF error: ${e.code} ${e.message}');
      if (e.code == 'resource-exhausted' && e.message == 'insufficient_coins') {
        if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Something went wrong — please try again.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on InsufficientCoinsException {
      if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
    } catch (e) {
      debugPrint('[HomeTab] _unlockEarly error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Something went wrong — please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _spendBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final username = AuthService.instance.currentUser?.displayName ?? 'Trainer';
    final hasSelection = _selected.isNotEmpty;
    // Client-side filter counts (no backend calls).
    final now = DateTime.now();
    final cooldownCount =
        _animeTitles.where((t) {
          final lock = _locks[t];
          return lock != null && lock.isAfter(now);
        }).length;
    final readyCount = _animeTitles.length - cooldownCount;
    final visibleTitles = _visibleTitles;
    // Responsive columns: fall back to 2 on very narrow screens (<360px)
    // so poster cards never squeeze below ~100px.
    final screenWidth = MediaQuery.sizeOf(context).width;
    final crossAxisCount = screenWidth < 360 ? 2 : 3;

    return FadeTransition(
      opacity: _entranceFade,
      child: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                // ── Header ─────────────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20.r, 18.r, 20.r, 6.r),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Hey, $username 👋',
                                style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 14.sp,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            const CoinBalanceWidget(),
                            SizedBox(width: 8.w),
                            const WeeklyPointsPill(),
                          ],
                        ),
                        SizedBox(height: 10.h),
                        RichText(
                          text: TextSpan(
                            style: TextStyle(
                              fontFamily: AppTypography.fontFamily,
                              fontSize: 27.sp,
                              fontWeight: FontWeight.w900,
                              height: 1.12,
                              color: AppColors.textPrimary,
                            ),
                            children: const [
                              TextSpan(text: "Let's build\n"),
                              TextSpan(text: "today's lineup"),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Today strip ────────────────────────────────────────
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 98.h,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(20.r, 10.h, 8.r, 0),
                      scrollDirection: Axis.horizontal,
                      children: [
                        _TodayGauntletCard(onTap: _startDailyGauntlet),
                        SizedBox(width: 12.w),
                        _TodayPrizeCard(onTap: widget.onOpenRankings),
                        SizedBox(width: 8.w),
                      ],
                    ),
                  ),
                ),

                // ── Premium banner ─────────────────────────────────────
                SliverToBoxAdapter(
                  child: const _PremiumBanner(),
                ),

                // ── Admin payout entry ─────────────────────────────────
                const SliverToBoxAdapter(
                  child: AdminPayoutEntry(),
                ),

                // ── Lineup section header ──────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20.r, 26.r, 20.r, 4.r),
                    child: SectionHeader(
                      title: 'Build your lineup',
                      trailing: GestureDetector(
                        onTap: _surpriseMe,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 12.w, vertical: 7.h),
                          decoration: BoxDecoration(
                            color: AppColors.secondary.withOpacity(0.14),
                            borderRadius: BorderRadius.circular(20.r),
                            border: Border.all(
                                color: AppColors.secondary.withOpacity(0.4)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('🎲', style: TextStyle(fontSize: 13.sp)),
                              SizedBox(width: 5.w),
                              Text(
                                'Surprise me',
                                style: TextStyle(
                                    color: AppColors.secondary,
                                    fontSize: 12.sp,
                                    fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20.r, 4.r, 20.r, 0),
                    child: Text(
                      'Pick 2 or more anime to start a quiz',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 12.sp),
                    ),
                  ),
                ),

                // ── Filter chips ───────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0),
                    child: _FilterChips(
                      current: _filter,
                      totalCount: _animeTitles.length,
                      readyCount: readyCount,
                      cooldownCount: cooldownCount,
                      onChanged: (f) => setState(() => _filter = f),
                    ),
                  ),
                ),

                // ── Anime grid (3-col poster cards) ──────────────────────
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                      20.r, 12.r, 20.r, hasSelection ? 120.h : 32.h),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final title = visibleTitles[i];
                        return _AnimeCard(
                          title: title,
                          isSelected: _selected.contains(title),
                          lockTime: _locks[title],
                          isNew: _unlockedForever.contains(title),
                          lockTick: _lockTick,
                          onTap: () => _toggleSelection(title),
                          onSkipCooldown: () => _skipCooldown(title),
                          onUnlockEarly: () => _unlockEarly(title),
                        );
                      },
                      childCount: visibleTitles.length,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 10.w,
                      mainAxisSpacing: 10.h,
                      childAspectRatio: 0.62,
                    ),
                  ),
                ),
                if (visibleTitles.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
                      child: Text(
                        'Nothing here yet — try a different filter.',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 12.sp),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ── Lineup tray ──────────────────────────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              offset: hasSelection ? Offset.zero : const Offset(0, 1),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: hasSelection ? 1 : 0,
                child: _LineupTray(
                  selected: _selected.toList(),
                  difficulty: context.watch<SoloDifficultyProvider>().difficulty,
                  onStart: () => _startQuiz(),
                  onClearAll: () => setState(() => _selected.clear()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Gauntlet confirm dialog detail row ────────────────────────────────────
class _GauntletDialogRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _GauntletDialogRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 32.r,
          height: 32.r,
          decoration: BoxDecoration(
            color: AppColors.amber.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppColors.amber, size: 16.r),
        ),
        SizedBox(width: 10.w),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.sp,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Gauntlet WP tier chip ──────────────────────────────────────────────────
/// One rung of the Daily Gauntlet's per-question WP ladder. The fill darkens as
/// the tier climbs, so the escalation reads at a glance without a legend. Tiers
/// are the same values the submitDailyGauntlet CF applies.
class _WpChip extends StatelessWidget {
  final int tier;
  const _WpChip({required this.tier});

  @override
  Widget build(BuildContext context) {
    final lowest = kGauntletTiers.reduce((a, b) => a < b ? a : b);
    final highest = kGauntletTiers.reduce((a, b) => a > b ? a : b);
    final t = highest == lowest
        ? 1.0
        : (tier - lowest) / (highest - lowest).toDouble();

    return Container(
      height: 28.r,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.10 + 0.16 * t),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(
          color: AppColors.amber.withValues(alpha: 0.22 + 0.20 * t),
        ),
      ),
      child: Text(
        '$tier',
        style: TextStyle(
          color: AppColors.amber,
          fontSize: 12.sp,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

// ─── Today: Daily Gauntlet card ──────────────────────────────────────────────
class _TodayGauntletCard extends StatelessWidget {
  final VoidCallback onTap;
  const _TodayGauntletCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();

    return StreamBuilder<Map<String, dynamic>>(
      stream: FirestoreService.instance.gauntletProgressStream(),
      builder: (context, snap) {
        final data = snap.data ?? const {};
        final streak = (data['streak'] as int?) ?? 0;
        final usedToday = (data['usedToday'] as bool?) ?? false;
        final retryIndex = (data['retryIndex'] as int?) ?? 0;
        final isPremium = context.watch<UserDataProvider>().premiumActive;
        final isFreeAttempt = !usedToday;
        final retryCost = gauntletRetryCost(
          retryIndex: retryIndex,
          isPremium: isPremium,
          isFreeAttempt: isFreeAttempt,
        );
        final atCap = retryCost == null;

        int? nextDay;
        for (final day in kGauntletMilestones.keys) {
          if (streak < day) {
            nextDay = day;
            break;
          }
        }
        final milestoneLabel = nextDay == null
            ? 'All milestones claimed'
            : '${nextDay - streak}d to ${kGauntletMilestones[nextDay]}';

        String retryLabel;
        if (isFreeAttempt) {
          retryLabel = 'Free attempt';
        } else if (atCap) {
          retryLabel = 'No retries left';
        } else if (retryCost == 0) {
          retryLabel = 'Retry \u00b7 FREE';
        } else {
          retryLabel = 'Retry \u00b7 $retryCost AC';
        }

        return GestureDetector(
          onTap: onTap,
          child: Container(
            width: 196.w,
            height: 88.h,
            padding: EdgeInsets.all(12.r),
            decoration: BoxDecoration(
              gradient: usedToday
                  ? null
                  : LinearGradient(
                      colors: [
                        AppColors.amber.withOpacity(0.20),
                        AppColors.amber.withOpacity(0.05)
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              color: usedToday ? AppColors.surface : null,
              borderRadius: BorderRadius.circular(18.r),
              border: Border.all(
                color: usedToday
                    ? AppColors.divider
                    : AppColors.amber.withOpacity(0.45),
                width: usedToday ? 1 : 1.5,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$streak',
                      style: TextStyle(
                        color:
                            usedToday ? AppColors.textMuted : AppColors.amber,
                        fontSize: 22.sp,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                      ),
                    ),
                    Text(
                      streak == 1 ? 'day' : 'days',
                      style: TextStyle(
                        color: usedToday
                            ? AppColors.textMuted.withOpacity(0.6)
                            : AppColors.amber.withOpacity(0.7),
                        fontSize: 9.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'DAILY GAUNTLET',
                        style: TextStyle(
                          color:
                              usedToday ? AppColors.textMuted : AppColors.amber,
                          fontSize: 8.sp,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.7,
                        ),
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        retryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: usedToday
                              ? AppColors.textSecondary
                              : AppColors.textPrimary,
                          fontSize: 11.sp,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        milestoneLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 9.sp),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Fraction (0–1) of the way from the previous milestone to [nextDay].
/// Returns 1 once every milestone has been claimed.
double _milestoneProgress(int streak, int? nextDay) {
  if (nextDay == null) return 1;
  var previous = 0;
  for (final day in kGauntletMilestones.keys) {
    if (day < nextDay) previous = day;
  }
  final span = nextDay - previous;
  if (span <= 0) return 0;
  return ((streak - previous) / span).clamp(0.0, 1.0).toDouble();
}

// ─── Today: Prize Pool card ────────────────────────────────────────────────
class _TodayPrizeCard extends StatefulWidget {
  /// Opens the Rankings tab. The card advertises this week's pool, so making it
  /// the way to the board is the obvious affordance it never had.
  final VoidCallback onTap;

  const _TodayPrizeCard({required this.onTap});

  @override
  State<_TodayPrizeCard> createState() => _TodayPrizeCardState();
}

class _TodayPrizeCardState extends State<_TodayPrizeCard> {
  late final Stream<Map<String, dynamic>> _stream;

  double _guaranteedFloor = 0;

  @override
  void initState() {
    super.initState();
    _stream = FirestoreService.instance.prizePoolStream();
    // Same *rule* the leaderboard uses (PrizePoolService.projectPrizePool), so
    // the two can never compute a different figure. They can still be read at
    // different times: this card streams live while the leaderboard re-reads on
    // open / pull-to-refresh / a stale resume, so for a few minutes after a
    // sale the card can lead the board. The rule is shared; the cadence is not.
    _loadFloor();
  }

  Future<void> _loadFloor() async {
    final floor = await FirestoreService.instance.guaranteedFloor();
    if (!mounted) return;
    setState(() => _guaranteedFloor = floor);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: _stream,
      builder: (context, snap) {
        final pool = snap.data ?? const <String, dynamic>{};
        // Derived from entry revenue (or the admin's fixed figure), never from
        // `totalNaira` - that is legacy ad revenue the weekly reset ignores, so
        // showing it here quoted players a number they would never be paid.
        final projection = PrizePoolService.projectPrizePool(
          entryCodeRevenue: pool['entryCodeRevenue'] as num?,
          adminPoolNaira: pool['adminPoolNaira'] as num?,
          guaranteedFloor: _guaranteedFloor,
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 120.w,
            height: 88.h,
            padding: EdgeInsets.symmetric(
              horizontal: 12.w,
              vertical: 10.h,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(18.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.emoji_events_rounded,
                      size: 11.r,
                      color: AppColors.accent,
                    ),
                    SizedBox(width: 4.w),
                    Text(
                      'PRIZE POOL',
                      style: TextStyle(
                        color: AppColors.accent.withValues(alpha: 0.9),
                        fontSize: 7.5.sp,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 5.h),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    PrizePoolService.formatNaira(projection.amount),
                    maxLines: 1,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                SizedBox(height: 4.h),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── Premium Banner ─────────────────────────────────────────────────────────
class _PremiumBanner extends StatelessWidget {
  const _PremiumBanner();

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<UserDataProvider>().premiumActive;

    if (premium) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PremiumUpsellScreen()),
        ),
        child: Container(
          padding: EdgeInsets.all(16.r),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.accent.withOpacity(0.18),
                AppColors.secondary.withOpacity(0.10),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18.r),
            border: Border.all(color: AppColors.accent.withOpacity(0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 48.r,
                height: 48.r,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.20),
                  borderRadius: BorderRadius.circular(14.r),
                  border: Border.all(color: AppColors.accent.withOpacity(0.40)),
                ),
                child: Center(
                    child: Text('👑', style: TextStyle(fontSize: 24.sp))),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'GO PREMIUM',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 9.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                      ),
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      'Unlock more ways to compete',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                        height: 1.15,
                      ),
                    ),
                    SizedBox(height: 6.h),
                    Text(
                      '1.20× eligible WP · Extra Quick Match · Free Gauntlet retry',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: EdgeInsets.all(8.r),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12.r),
                  border: Border.all(color: AppColors.accent.withOpacity(0.3)),
                ),
                child: Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: AppColors.accent,
                  size: 16.sp,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Anime Card — 3:4 portrait poster, status-only label ──────────────────
// Image fills the card; a bottom gradient scrim carries a single status line
// ("Tap to add" / "Selected" / "On cooldown"). No title text — a picked card
// turns red (border + glow + check badge); everything else on the page stays
// neutral so red means "selected". UI-only — callbacks and lock/selection
// logic are unchanged.
class _AnimeCard extends StatefulWidget {
  final String title;
  final bool isSelected;
  final DateTime? lockTime;
  final VoidCallback onTap;
  final VoidCallback? onSkipCooldown;
  final VoidCallback? onUnlockEarly;
  final bool isNew;

  /// Ticks once per second while a cooldown is active. Only the countdown pill
  /// listens, so the rest of the grid is not rebuilt every second.
  final ValueListenable<int> lockTick;

  const _AnimeCard({
    required this.title,
    required this.isSelected,
    required this.onTap,
    required this.lockTick,
    this.lockTime,
    this.onSkipCooldown,
    this.onUnlockEarly,
    this.isNew = false,
  });

  @override
  State<_AnimeCard> createState() => _AnimeCardState();
}

class _AnimeCardState extends State<_AnimeCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 150),
        lowerBound: 0.96,
        upperBound: 1.0,
        value: 1.0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _isLocked =>
      widget.lockTime != null && widget.lockTime!.isAfter(DateTime.now());
  int get _secs =>
      _isLocked ? widget.lockTime!.difference(DateTime.now()).inSeconds : 0;

  String get _timerLabel =>
      _secs >= 60 ? '${_secs ~/ 60}m ${_secs % 60}s' : '${_secs}s';

  // ── Tile art (original franchise artwork) ─────────────────────────────
  // Poster path is derived from the title (assets/<title>.jpg, the exact
  // filenames in assets/), with the emoji+gradient pattern as a fallback only
  // when the image is missing. Emoji + colour per title are derived
  // deterministically.
  static String? _assetPathFor(String title) {
    final key = title.toLowerCase().trim();
    const available = {
      'attack on titan',
      'bleach',
      'death note',
      'demon slayer',
      'dragon ball z',
      'jujutsu kaisen',
      'my hero academia',
      'naruto',
      'one piece',
      'one punch man',
    };
    return available.contains(key) ? 'assets/$key.jpg' : null;
  }

  static const Map<String, String> _emojiMap = {
    'naruto': '🍜',
    'one piece': '🏴‍☠️',
    'dragon ball z': '💥',
    'attack on titan': '⚔️',
    'demon slayer': '🗡️',
    'my hero academia': '🦸',
    'death note': '📓',
    'fullmetal alchemist': '⚗️',
    'hunter x hunter': '🎯',
    'jujutsu kaisen': '🌀',
    'bleach': '🔱',
    'sword art online': '🗡',
    'fairy tail': '🧙',
    'black clover': '🍀',
    'one punch man': '👊',
    'tokyo ghoul': '👁️',
    'vinland saga': '🪓',
    'chainsaw man': '🔪',
  };

  static const List<List<Color>> _palettes = [
    [Color(0xFF6D5DFB), Color(0xFF4338CA)],
    [Color(0xFF38BDF8), Color(0xFF0369A1)],
    [Color(0xFFF59E0B), Color(0xFFB45309)],
    [Color(0xFF34D399), Color(0xFF047857)],
    [Color(0xFFF472B6), Color(0xFFBE185D)],
    [Color(0xFFA78BFA), Color(0xFF2563EB)],
    [Color(0xFFFB7185), Color(0xFF9F1239)],
    [Color(0xFF22D3EE), Color(0xFF155E75)],
  ];

  String get _emoji =>
      _emojiMap[widget.title.toLowerCase().trim()] ?? '✨';

  List<Color> get _palette {
    final index = widget.title.codeUnits.fold<int>(0, (sum, value) => sum + value) %
        _palettes.length;
    return _palettes[index];
  }

  /// Poster from assets/ when one exists for this title, otherwise the
  /// deterministic emoji + gradient tile.
  Widget _tileArt() {
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _palette,
        ),
      ),
      child: Center(
        child: Text(
          _emoji,
          style: TextStyle(fontSize: 52.sp),
        ),
      ),
    );

    final path = _assetPathFor(widget.title);
    if (path == null) return fallback;

    return Image.asset(
      path,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => fallback,
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusLabel = _isLocked
        ? 'On cooldown'
        : (widget.isSelected ? 'Selected' : 'Tap to add');

    return GestureDetector(
      onTapDown: (_) => _ctrl.reverse(),
      onTapUp: (_) {
        _ctrl.forward();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.forward(),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) =>
            Transform.scale(scale: _ctrl.value, child: child),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(
              color: widget.isSelected
                  ? AppColors.primary
                  : (_isLocked ? AppColors.locked : AppColors.divider),
              width: widget.isSelected ? 2 : 1,
            ),
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.25),
                      blurRadius: 16,
                      spreadRadius: 0,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15.r),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Tile art (original franchise artwork) ────────────────
                _tileArt(),
                // ── Bottom scrim for text contrast ───────────────────
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  top: null,
                  child: Container(
                    height: 110.h,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.0),
                          Colors.black.withOpacity(0.55),
                          Colors.black.withOpacity(0.85),
                        ],
                      ),
                    ),
                  ),
                ),
                // ── Status pill (top-left, cooldown/NEW only) ────────
                if (_isLocked)
                  Positioned(
                    top: 6.h,
                    left: 6.w,
                    // Only this pill reads the per-second ticker, so the
                    // countdown refreshes without rebuilding the grid.
                    child: ValueListenableBuilder<int>(
                      valueListenable: widget.lockTick,
                      builder: (_, __, ___) => _StatusPill(
                        label: _timerLabel,
                        background: Colors.black.withOpacity(0.65),
                        foreground: Colors.white,
                        icon: Icons.lock_rounded,
                      ),
                    ),
                  )
                else if (widget.isNew)
                  Positioned(
                    top: 6.h,
                    left: 6.w,
                    child: _StatusPill(
                      label: 'NEW',
                      background: AppColors.accent,
                      foreground: Colors.black,
                    ),
                  ),
                // ── Selected check (top-right) ───────────────────────
                if (widget.isSelected)
                  const Positioned(
                    top: 6,
                    right: 6,
                    child: _SelectedCheck(),
                  ),
                // ── Locked overlay ───────────────────────────────────
                if (_isLocked)
                  Container(color: Colors.black.withOpacity(0.55)),
                if (_isLocked)
                  Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6.w),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.lock_rounded,
                              color: Colors.white70, size: 22.r),
                          SizedBox(height: 6.h),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onSkipCooldown?.call(),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 8.w, vertical: 4.h),
                              decoration: BoxDecoration(
                                color: AppColors.secondary.withOpacity(0.9),
                                borderRadius: BorderRadius.circular(8.r),
                              ),
                              child: Text(
                                '⏩ $kCooldownSkipCost',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.sp,
                                    fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                          SizedBox(height: 4.h),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onUnlockEarly?.call(),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 8.w, vertical: 4.h),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withOpacity(0.9),
                                borderRadius: BorderRadius.circular(8.r),
                              ),
                              child: Text('🔓 $kEarlyUnlockCost',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.sp,
                                      fontWeight: FontWeight.w800)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // ── Status label (bottom-aligned overlay) ────────────
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(8.w, 0, 8.w, 8.h),
                    child: Text(
                      statusLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 10.5.sp,
                        fontWeight: FontWeight.w700,
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

// ─── Status pill (compact, top-left of poster card) ─────────────────────────
class _StatusPill extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  const _StatusPill({
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7.w, vertical: 3.h),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: foreground, size: 10.r),
            SizedBox(width: 3.w),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontSize: 9.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Selected check badge (top-right) ───────────────────────────────────────
class _SelectedCheck extends StatelessWidget {
  const _SelectedCheck();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22.r,
      height: 22.r,
      decoration: const BoxDecoration(
          color: AppColors.primary, shape: BoxShape.circle),
      child: Icon(Icons.check, color: Colors.white, size: 14.r),
    );
  }
}

// ─── Filter chips — client-side only, filters _visibleTitles ────────────────
class _FilterChips extends StatelessWidget {
  final _AnimeFilter current;
  final int totalCount;
  final int readyCount;
  final int cooldownCount;
  final ValueChanged<_AnimeFilter> onChanged;

  const _FilterChips({
    required this.current,
    required this.totalCount,
    required this.readyCount,
    required this.cooldownCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final chips = <({ _AnimeFilter value, String label })>[
      (value: _AnimeFilter.all, label: 'All ($totalCount)'),
      (value: _AnimeFilter.ready, label: 'Ready ($readyCount)'),
      (value: _AnimeFilter.cooldown, label: 'Cooldown ($cooldownCount)'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) SizedBox(width: 8.w),
            _FilterChip(
              label: chips[i].label,
              selected: current == chips[i].value,
              onTap: () => onChanged(chips[i].value),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceAlt : AppColors.surface,
          borderRadius: BorderRadius.circular(20.r),
          border: Border.all(
            color: selected ? AppColors.textMuted : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.textPrimary : AppColors.textMuted,
            fontSize: 12.sp,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

// ─── Lineup tray (compact: header + start button, no chips) ─────────────────
class _LineupTray extends StatelessWidget {
  final List<String> selected;
  final String difficulty;
  final VoidCallback onStart;
  final VoidCallback onClearAll;

  const _LineupTray({
    required this.selected,
    this.difficulty = 'easy',
    required this.onStart,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final ready = selected.length >= 2;
    final diffLabel = normalizeSoloDifficulty(difficulty);
    final diffName = diffLabel[0].toUpperCase() + diffLabel.substring(1);

    return Container(
      padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.r)),
        border: const Border(top: BorderSide(color: AppColors.divider)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: count badge + clear-all ───────────────────────
          Row(
            children: [
              Text(
                'Lineup',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12.r),
                  border: Border.all(color: AppColors.textMuted),
                ),
                child: Text(
                  '${selected.length}',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClearAll,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4.w, vertical: 4.h),
                  child: Text(
                    'Clear all',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10.h),
          GradientButton(
            label: ready
                ? 'Start $diffName Quiz  (${selected.length} picked)'
                : 'Pick ${2 - selected.length} more to begin',
            onTap: ready ? onStart : null,
            icon: ready ? Icons.play_arrow_rounded : null,
            height: 54.h,
          ),
        ],
      ),
    );
  }
}