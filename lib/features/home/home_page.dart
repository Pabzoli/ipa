import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_balance_widget.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/prize_pool_service.dart';
import '../admin/admin_payout_dashboard.dart';
import '../auth/auth_service.dart';
import '../quiz/questions_page.dart';
import '../quiz/quiz_controller.dart' show kGauntletQuestionCount;
import '../../core/constants/gauntlet_economy.dart';
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

  static const List<Widget> _pages = <Widget>[
    _HomeTab(),
    MultiplayerHubPage(),
    WeeklyLeaderboardPage(),
    PInform(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: IndexedStack(index: _tab, children: _pages),
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
            top: 10,
            bottom: MediaQuery.of(context).padding.bottom + 8,
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 5),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.primary.withOpacity(0.14)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(item.icon,
                          size: 22,
                          color:
                              active ? AppColors.primary : AppColors.textMuted),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 10,
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
  const _HomeTab();

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> with TickerProviderStateMixin {
  final List<String> _animeTitles = const [
    'attack on titan',
    'demon slayer',
    'jujutsu kaisen',
    'naruto',
    'one piece',
    'one punch man',
    'bleach',
    'dragon ball z',
    'my hero academia',
    'death note',
  ];

  final Set<String> _selected = {};
  final Map<String, DateTime> _locks = {};
  Set<String> _unlockedForever = {};
  _AnimeFilter _filter = _AnimeFilter.all;
  late Timer _lockTimer;
  late AnimationController _entranceCtrl;
  late Animation<double> _entranceFade;
  late SharedPreferences _prefs;
  late StreamSubscription<User?> _authSub;
  bool _prefsReady = false;

  // ── Weekly rank badge cache ─────────────────────────────────────────────
  // The header rebuilds every second (lock countdown), so the rank future
  // must be cached — recreating it on every build re-queries Firestore and
  // flickers the badge between '#N' and '—'. Keyed on week · eligibility ·
  // points; _lastKnownRank keeps the old value on screen while a refresh
  // is in flight.
  Future<int>? _rankFuture;
  String _rankKey = '';
  int _lastKnownRank = 0;

  Future<int> _rankFutureFor(UserDataProvider userData) {
    final key = '${userData.leaderboardEntryWeekId ?? ""}'
        '_${userData.isLeaderboardEligible}'
        '_${userData.weeklyPoints}';
    if (key != _rankKey || _rankFuture == null) {
      _rankKey = key;
      _rankFuture = FirestoreService.instance.getCurrentUserWeeklyRank(
        entryWeekId: userData.leaderboardEntryWeekId,
        eligible: userData.isLeaderboardEligible,
      ).then((r) {
        _lastKnownRank = r;
        return r;
      });
    }
    return _rankFuture!;
  }

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..forward();
    _entranceFade =
        CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOut);

    _lockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(
            () => _locks.removeWhere((_, t) => t.isBefore(DateTime.now())));
      }
    });

    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      _prefs = p;
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      for (final title in _animeTitles) {
        final raw = p.getString(uid.isEmpty ? title : '${uid}_$title');
        if (raw != null) {
          final t = DateTime.parse(raw);
          if (t.isAfter(DateTime.now())) _locks[title] = t;
        }
      }
      setState(() => _prefsReady = true);
    });

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      setState(() => _unlockedForever = {});
      if (user != null) _loadUnlockedAnimes();
    });
  }

  @override
  void dispose() {
    _lockTimer.cancel();
    _entranceCtrl.dispose();
    _authSub.cancel();
    super.dispose();
  }

  String _prefKey(String title) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return uid.isEmpty ? title : '${uid}_$title';
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
  void _startQuiz({
    bool isDailyChallenge = false,
    bool isGauntlet = false,
    List<String>? titles,
    List<String>? questionIds,
    String? gauntletTicketId,
  }) {
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
    if (titlesToPlay.length < 2 || !_prefsReady) return;

    setState(() => _selected.clear());

    // Cooldown by lineup size: picking more titles locks each for less time.
    // Index = number of titles played (clamped 0..10 for the 10-title grid).
    final counts = [
      0, // 0 titles (unreachable — guarded above)
      0, // 1 title (unreachable — min 2 required)
      10 * 60, // 2 titles
      7 * 60, // 3 titles
      5 * 60, // 4 titles
      4 * 60, // 5 titles
      3 * 60, // 6 titles
      2 * 60, // 7 titles
      1 * 60, // 8 titles
      0, // 9 titles
      0, // 10 titles
    ];
    final lockSecs = counts[titlesToPlay.length.clamp(0, 10)];
    for (final t in titlesToPlay) {
      if (_unlockedForever.contains(t)) continue;
      if (lockSecs > 0) {
        _locks[t] = DateTime.now().add(Duration(seconds: lockSecs));
        _prefs.setString(_prefKey(t), _locks[t]!.toIso8601String());
      }
    }

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, a, __) => FadeTransition(
          opacity: a,
          child: QuestionsPage(
            selectedTitles: titlesToPlay,
            isDailyChallenge: isDailyChallenge,
            onRetryLockCleared: () {
              if (mounted) {
                setState(() {
                  for (final t in titlesToPlay) {
                    _locks.remove(t);
                  }
                });
              }
            },
          ),
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  // ── Daily Gauntlet entry point ──────────────────────────────────────────
  // Flow: preview (live stream, no charge) → confirm dialog → loading →
  // fetch question IDs (free, validated) → enterDailyGauntlet (authoritative
  // deduction + ticket) → quiz page. Charging happens ONLY after the user
  // confirms AND content is available, so a content failure never burns coins.
  bool _gauntletBusy = false;

  static const Map<int, String> _gauntletMilestones = {
    3: '40🪙',
    7: '100🪙 + 50 WP',
    14: '200🪙 + 🖼️',
    30: '500🪙 + Premium',
  };

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
    // NOTE: no _prefsReady gate — the Gauntlet doesn't use cooldown locks.

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

  /// Redesigned confirm dialog: amber status banner (mirrors the home card),
  /// three detail rows, then full-width Start + Not-now buttons.
  /// Uses contentWidget (not actions) for a stable, app-consistent layout.
  Future<bool?> _showGauntletConfirmDialog({
    required int streak,
    required bool isFreeAttempt,
    required int retryCost,
  }) {
    const amber = AppColors.amber;
    final isFreeEntry = isFreeAttempt || retryCost == 0;

    int? nextDay;
    for (final day in _gauntletMilestones.keys) {
      if (streak < day) {
        nextDay = day;
        break;
      }
    }
    final milestoneLabel = nextDay == null
        ? 'All milestones claimed'
        : '${nextDay - streak}d to ${_gauntletMilestones[nextDay]}';

    final entryPillLabel = isFreeAttempt
        ? 'FREE ENTRY'
        : (retryCost == 0 ? 'RETRY · FREE' : 'RETRY · $retryCost AC');
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
            // ── Status banner (mirrors _TodayGauntletCard) ──────────
            Container(
              padding: const EdgeInsets.all(14),
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
              child: Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$streak',
                        style: TextStyle(
                          color: isFreeEntry ? amber : AppColors.textMuted,
                          fontSize: 26.sp,
                          fontWeight: FontWeight.w900,
                          height: 1.0,
                        ),
                      ),
                      Text(
                        streak == 1 ? 'day' : 'days',
                        style: TextStyle(
                          color: isFreeEntry
                              ? amber.withValues(alpha: 0.7)
                              : AppColors.textMuted.withValues(alpha: 0.6),
                          fontSize: 10.sp,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'STREAK',
                          style: TextStyle(
                            color: isFreeEntry ? amber : AppColors.textMuted,
                            fontSize: 9.sp,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.7,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          milestoneLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: isFreeEntry
                                ? amber.withValues(alpha: 0.16)
                                : AppColors.surface,
                            borderRadius:
                                BorderRadius.circular(AppRadii.full),
                            border: Border.all(
                              color: isFreeEntry
                                  ? amber.withValues(alpha: 0.5)
                                  : AppColors.divider,
                            ),
                          ),
                          child: Text(
                            entryPillLabel,
                            style: TextStyle(
                              color: isFreeEntry
                                  ? amber
                                  : AppColors.textSecondary,
                              fontSize: 11.sp,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            // ── Detail rows ─────────────────────────────────────────
            _GauntletDialogRow(
              icon: Icons.quiz_rounded,
              text: '7 mixed-anime questions',
            ),
            const SizedBox(height: AppSpacing.sm),
            const _GauntletDialogRow(
              icon: Icons.bolt_rounded,
              text: 'Escalating WP · 15/15/15/20/20/25/25',
            ),
            const SizedBox(height: AppSpacing.sm),
            _GauntletDialogRow(
              icon: Icons.monetization_on_rounded,
              text: isFreeAttempt
                  ? 'Free attempt — no coins needed'
                  : (retryCost == 0
                      ? 'Retry is FREE (Premium)'
                      : 'Entry: $retryCost AC · non-refundable if you quit'),
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
    const cost = 100;

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
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
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
      await userData.spendCoins(cost, 'spend_cooldown');
      if (!mounted) return;
      setState(() {
        _locks.remove(title);
        _prefs.remove(_prefKey(title));
      });
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

  // ── SPEND SURFACE 4: Early Anime Unlock (500 AC) ────────────────────────
  Future<void> _unlockEarly(String title) async {
    if (_spendBusy) return;
    const cost = 500;
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
          'Spend 500🪙 to permanently unlock "${title.toUpperCase()}"?\n\n'
          'This removes it from cooldown and adds it to your unlocked library.',
          style: const TextStyle(
              color: AppColors.textSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              '🔓 Unlock  −500🪙',
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
      final result = await FirestoreService.instance.unlockAnimeEarly(title);

      if (!mounted) return;

      setState(() {
        _locks.remove(title);
        _prefs.remove(_prefKey(title));
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
    final userData = context.watch<UserDataProvider>();
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
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Hey, $username 👋',
                                style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            const CoinBalanceWidget(),
                            const SizedBox(width: 8),
                            FutureBuilder<int>(
                              future: _rankFutureFor(userData),
                              builder: (context, snapshot) {
                                final rank = snapshot.data ?? _lastKnownRank;
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                        color: AppColors.divider),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.leaderboard_rounded,
                                          color: AppColors.textSecondary,
                                          size: 16),
                                      const SizedBox(width: 4),
                                      Text(
                                        rank > 0 ? '#$rank' : '—',
                                        style: const TextStyle(
                                          color: AppColors.textPrimary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        RichText(
                          text: TextSpan(
                            style: const TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 27,
                              fontWeight: FontWeight.w900,
                              height: 1.12,
                              color: AppColors.textPrimary,
                            ),
                            children: [
                              const TextSpan(text: "Let's build\n"),
                              const TextSpan(text: "today's lineup"),
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
                    height: 98,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
                      scrollDirection: Axis.horizontal,
                      children: [
                        _TodayGauntletCard(onTap: _startDailyGauntlet),
                        const SizedBox(width: 12),
                        const _TodayPrizeCard(),
                        const SizedBox(width: 8),
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
                    padding: const EdgeInsets.fromLTRB(20, 26, 20, 4),
                    child: SectionHeader(
                      title: 'Build your lineup',
                      trailing: GestureDetector(
                        onTap: _prefsReady ? _surpriseMe : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: AppColors.secondary.withOpacity(0.14),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: AppColors.secondary.withOpacity(0.4)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('🎲', style: TextStyle(fontSize: 13)),
                              SizedBox(width: 5),
                              Text(
                                'Surprise me',
                                style: TextStyle(
                                    color: AppColors.secondary,
                                    fontSize: 12,
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
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: Text(
                      'Pick 2 or more anime to start a quiz',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                  ),
                ),

                // ── Filter chips ───────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
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
                  padding:
                      EdgeInsets.fromLTRB(20, 12, 20, hasSelection ? 120 : 32),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final title = visibleTitles[i];
                        return _AnimeCard(
                          title: title,
                          isSelected: _selected.contains(title),
                          lockTime: _locks[title],
                          isNew: _unlockedForever.contains(title),
                          onTap: () => _toggleSelection(title),
                          onSkipCooldown: () => _skipCooldown(title),
                          onUnlockEarly: () => _unlockEarly(title),
                        );
                      },
                      childCount: visibleTitles.length,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 0.62,
                    ),
                  ),
                ),
                if (visibleTitles.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20, 8, 20, 32),
                      child: Text(
                        'Nothing here yet — try a different filter.',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 12),
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
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: AppColors.amber.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppColors.amber, size: 16),
        ),
        const SizedBox(width: 10),
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

// ─── Today: Daily Gauntlet card ──────────────────────────────────────────────
class _TodayGauntletCard extends StatelessWidget {
  final VoidCallback onTap;
  const _TodayGauntletCard({required this.onTap});

  static const _amber = Color(0xFFF59E0B);

  static const Map<int, String> _milestones = {
    3: '40🪙',
    7: '100🪙 + 50 WP',
    14: '200🪙 + 🖼️',
    30: '500🪙 + Premium',
  };

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
        for (final day in _milestones.keys) {
          if (streak < day) {
            nextDay = day;
            break;
          }
        }
        final milestoneLabel = nextDay == null
            ? 'All milestones claimed'
            : '${nextDay - streak}d to ${_milestones[nextDay]}';

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
            width: 196,
            height: 88,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: usedToday
                  ? null
                  : LinearGradient(
                      colors: [
                        _amber.withOpacity(0.20),
                        _amber.withOpacity(0.05)
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              color: usedToday ? AppColors.surface : null,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: usedToday ? AppColors.divider : _amber.withOpacity(0.45),
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
                        color: usedToday ? AppColors.textMuted : _amber,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                      ),
                    ),
                    Text(
                      streak == 1 ? 'day' : 'days',
                      style: TextStyle(
                        color: usedToday
                            ? AppColors.textMuted.withOpacity(0.6)
                            : _amber.withOpacity(0.7),
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'DAILY GAUNTLET',
                        style: TextStyle(
                          color: usedToday ? AppColors.textMuted : _amber,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.7,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        retryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: usedToday
                              ? AppColors.textSecondary
                              : AppColors.textPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        milestoneLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 9),
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

// ─── Today: Prize Pool card ────────────────────────────────────────────────
class _TodayPrizeCard extends StatefulWidget {
  const _TodayPrizeCard();

  @override
  State<_TodayPrizeCard> createState() => _TodayPrizeCardState();
}

class _TodayPrizeCardState extends State<_TodayPrizeCard> {
  late final Stream<Map<String, dynamic>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = FirestoreService.instance.prizePoolStream();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: _stream,
      builder: (context, snap) {
        final pool = snap.data ?? {};
        final totalNaira = (pool['totalNaira'] as num?)?.toDouble() ?? 0.0;
        final timeLeft = PrizePoolService.timeUntilReset();

        return Container(
          width: 120,
          height: 88,
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    '🏆',
                    style: TextStyle(fontSize: 11),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'PRIZE POOL',
                    style: TextStyle(
                      color: AppColors.accent.withOpacity(0.9),
                      fontSize: 7.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                PrizePoolService.formatNaira(totalNaira),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.schedule_rounded,
                    size: 10,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(
                      PrizePoolService.formatCountdown(timeLeft),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
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
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PremiumUpsellScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.accent.withOpacity(0.18),
                AppColors.secondary.withOpacity(0.10),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.accent.withOpacity(0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.20),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.accent.withOpacity(0.40)),
                ),
                child: Center(
                    child: Text('👑', style: TextStyle(fontSize: 24.sp))),
              ),
              const SizedBox(width: 12),
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
                    const SizedBox(height: 4),
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
                    const SizedBox(height: 6),
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
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
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

  const _AnimeCard({
    required this.title,
    required this.isSelected,
    required this.onTap,
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

  // ── Safe tile art (no copyrighted anime imagery) ──────────────────────
  // Mirrors the gradient+emoji tile pattern from anime_select_page.dart so
  // the home grid no longer depends on unlicensed franchise artwork. The
  // emoji + colour per title are derived deterministically.
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
            borderRadius: BorderRadius.circular(16),
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
            borderRadius: BorderRadius.circular(15),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Tile art (gradient + emoji — no copyrighted artwork) ──
                DecoratedBox(
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
                      style: const TextStyle(fontSize: 52),
                    ),
                  ),
                ),
                // ── Bottom scrim for text contrast ───────────────────
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  top: null,
                  child: Container(
                    height: 110,
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
                    top: 6,
                    left: 6,
                    child: _StatusPill(
                      label: _timerLabel,
                      background: Colors.black.withOpacity(0.65),
                      foreground: Colors.white,
                      icon: Icons.lock_rounded,
                    ),
                  )
                else if (widget.isNew)
                  Positioned(
                    top: 6,
                    left: 6,
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
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_rounded,
                              color: Colors.white70, size: 22),
                          const SizedBox(height: 6),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onSkipCooldown?.call(),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.secondary.withOpacity(0.9),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '⏩ 100',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.onUnlockEarly?.call(),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withOpacity(0.9),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text('🔓 500',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
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
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: foreground, size: 10),
            const SizedBox(width: 3),
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
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
          color: AppColors.primary, shape: BoxShape.circle),
      child: const Icon(Icons.check, color: Colors.white, size: 14),
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
            if (i > 0) const SizedBox(width: 8),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceAlt : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.textMuted : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.textPrimary : AppColors.textMuted,
            fontSize: 12,
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
  final VoidCallback onStart;
  final VoidCallback onClearAll;

  const _LineupTray({
    required this.selected,
    required this.onStart,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final ready = selected.length >= 2;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
              const Text(
                'Lineup',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.textMuted),
                ),
                child: Text(
                  '${selected.length}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClearAll,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text(
                    'Clear all',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GradientButton(
            label: ready
                ? 'Start Quiz  (${selected.length} picked)'
                : 'Pick ${2 - selected.length} more to begin',
            onTap: ready ? onStart : null,
            icon: ready ? Icons.play_arrow_rounded : null,
            height: 54,
          ),
        ],
      ),
    );
  }
}