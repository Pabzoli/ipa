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
import '../../core/widgets/app_page_route.dart';
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
import '../quiz/quiz_controller.dart' show kBlitzQuestionCount;
import '../../core/constants/blitz_economy.dart';
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
    const _HomeTab(),
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
            color: AppColors.surfaceDim.withValues(alpha: 0.92),
            border: Border(top: BorderSide(color: AppColors.divider)),
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
                      padding:
                          EdgeInsets.symmetric(horizontal: 14.w, vertical: 5.h),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.primary.withValues(alpha: 0.14)
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
  const _HomeTab();

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> with TickerProviderStateMixin {
  /// Server-rotated shelf (app_config/featured_rotation). Same 9 for every
  /// user; rotates every 6/12/18/24/48h server-side. Null until first event.
  /// The full catalogue doc is server-only (denied to clients in
  /// firestore.rules), so the shelf renders as-is — never filtered against
  /// or expanded to a catalogue client-side.
  List<String>? _featuredTitles;

  final Set<String> _selected = {};
  final Map<String, DateTime> _locks = {};
  Set<String> _unlockedForever = {};
  _AnimeFilter _filter = _AnimeFilter.all;
  late Timer _lockTimer;
  late AnimationController _entranceCtrl;
  late Animation<double> _entranceFade;
  late StreamSubscription<User?> _authSub;
  StreamSubscription<Map<String, DateTime>>? _cooldownSub;
  StreamSubscription<Map<String, dynamic>>? _featuredSub;

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

    _featuredSub = FirestoreService.instance.featuredRotationStream().listen(
      (featured) {
        if (!mounted) return;
        setState(() {
          final titles = (featured['titles'] as List<String>);
          _featuredTitles = titles.isNotEmpty ? titles : null;
        });
      },
      onError: (Object e) =>
          debugPrint('[HomeTab] featured rotation error (fallback used): $e'),
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
    _featuredSub?.cancel();
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

  /// The 9 the user is allowed to see: the server rotation as-is, bundled
  /// head while offline. Membership is decided server-side (the rotation
  /// scheduler draws from the catalogue via the Admin SDK); the catalogue
  /// doc itself is unreadable by clients. The grid, the filter counts,
  /// surprise-me and selection all read this.
  List<String> get _shelfTitles {
    if (_featuredTitles != null && _featuredTitles!.isNotEmpty) {
      return List<String>.from(_featuredTitles!);
    }
    return kAnimeCatalog.take(9).toList();
  }

  List<String> get _unlockedTitles => _shelfTitles
      .where(
          (t) => !_locks.containsKey(t) || _locks[t]!.isBefore(DateTime.now()))
      .toList();

  bool _isTitleLocked(String title) {
    final t = _locks[title];
    return t != null && t.isAfter(DateTime.now());
  }

  List<String> get _visibleTitles {
    // The shelf is the whole app as far as the user knows: the
    // server-rotated 9. Selection/locks are untouched by rotation. Unknown
    // featured entries (catalogue lag) are dropped.
    final shelf = _shelfTitles;
    switch (_filter) {
      case _AnimeFilter.ready:
        return shelf.where((t) => !_isTitleLocked(t)).toList();
      case _AnimeFilter.cooldown:
        return shelf.where(_isTitleLocked).toList();
      case _AnimeFilter.all:
        return shelf;
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
  /// True from the tap on Start until the `startSoloCooldowns` call resolves.
  ///
  /// The cooldown call is a network round-trip, so on a slow connection the
  /// Start button stays live for seconds. Without this flag every extra tap
  /// ran its own launch and pushed its own quiz page — leaving the player with
  /// two live solo sessions at once (each one submitting its own score).
  bool _startingSolo = false;

  Future<void> _startQuiz({
    bool isGauntlet = false,
    List<String>? titles,
    String? gauntletTicketId,
    String? gauntletRunId,
  }) async {
    if (isGauntlet) {
      if (gauntletRunId == null || gauntletRunId.isEmpty) {
        // Never fail silently — the user just confirmed + may have paid.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                const Text("Couldn't load Gauntlet Blitz — please try again."),
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
              mode: QuizMode.gauntlet,
              isGauntlet: true,
              gauntletTicketId: gauntletTicketId,
              gauntletRunId: gauntletRunId,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
      return;
    }

    final titlesToPlay = titles ?? _selected.toList();
    if (titlesToPlay.length < 2) return;

    // One launch at a time — see [_startingSolo]. A gauntlet entry in flight
    // counts too: its confirm/charge sequence must not race a solo push.
    if (_startingSolo || _gauntletBusy) return;
    setState(() => _startingSolo = true);

    // Capture the difficulty from the shared settings now — the tray clears
    // _selected but must not reset the difficulty choice.
    final difficultyToPlay = normalizeSoloDifficulty(
      context.read<SoloDifficultyProvider>().difficulty,
    );

    // The server records the cooldown (and refuses titles still locked), so
    // the lock can't be skipped by clearing app data. It also mints the run's
    // session id, which the submission must present. Nothing navigates unless
    // the lock was recorded.
    final SoloRunStart start;
    try {
      start = await FirestoreService.instance.startSoloCooldowns(titlesToPlay);
    } catch (e) {
      debugPrint('[HomeTab] startSoloCooldowns error: $e');
      if (mounted) {
        if (e is FirebaseFunctionsException &&
            e.code == 'failed-precondition' &&
            e.message == 'run_in_progress') {
          // The quiz page is gone but the server lock is still held (quit
          // raced the background cancel, app killed, etc.). Show a live
          // countdown and a way out instead of a dead end. Solo runs are
          // free to abandon.
          _showStuckRunRecovery(
            fallback: 'Finish your current run before starting another.',
            feeWarning: false,
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_cooldownStartErrorMessage(e))),
          );
        }
      }
      return;
    } finally {
      // No tap can slip in between this and the push below: the success path
      // navigates synchronously after the await resolves.
      if (mounted && _startingSolo) setState(() => _startingSolo = false);
    }
    if (!mounted) return;

    setState(() {
      _selected.clear();
      start.expiresAt.forEach(
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
            soloSessionId: start.sessionId,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  /// Recovery for a run whose quiz page is gone but whose server lock is still
  /// held (quit raced the background cancel, the app was killed, etc.). Asks
  /// the server what is actually holding the lock and shows a live countdown
  /// ("Your solo run ends in ~4 min") with a Clear action — never a generic
  /// dead end. Abandoning a solo run is free; a paid Gauntlet retry forfeits
  /// its entry fee, so that path ([feeWarning]) confirms first.
  Future<void> _showStuckRunRecovery({
    required String fallback,
    required bool feeWarning,
  }) async {
    String message = fallback;
    bool hasStuckRun = true;
    try {
      final status = await FirestoreService.instance.getActiveRunStatus();
      if (status['active'] != true) {
        // The server already released it (expired/settled self-heal) — just
        // say so; the next start will go through.
        message = 'Your old run was already cleared — try starting again.';
        hasStuckRun = false;
      } else {
        final kind = _friendlyRunKind(status['kind'] as String?);
        final secs = (status['secondsLeft'] as num?)?.toInt();
        message = secs == null
            ? 'Your $kind is still in progress. Clear it now to start fresh?'
            : 'Your $kind ends in ${_formatCountdown(secs)}. '
                'Clear it now to start fresh?';
      }
    } catch (e) {
      debugPrint('[HomeTab] getActiveRunStatus failed, generic message: $e');
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: hasStuckRun
            ? SnackBarAction(
                label: 'Clear run',
                onPressed: () => _clearStuckRun(feeWarning: feeWarning),
              )
            : null,
      ),
    );
  }

  /// Server run kinds (`solo`, `gauntlet`, `challenge`, `quickmatch`) in
  /// player-facing words.
  String _friendlyRunKind(String? kind) {
    return switch (kind) {
      'gauntlet' => 'Blitz run',
      'challenge' => 'challenge run',
      'quickmatch' => 'Quick Match run',
      _ => 'solo run',
    };
  }

  /// 90 → '~2 min'; anything under a minute says so instead of '~0 min'.
  String _formatCountdown(int secondsLeft) {
    if (secondsLeft < 60) return 'less than a minute';
    final mins = (secondsLeft / 60).ceil();
    return '~$mins min';
  }

  Future<void> _clearStuckRun({required bool feeWarning}) async {
    if (feeWarning && mounted) {
      final confirmed = await showAppDialog<bool>(
        context,
        barrierDismissible: true,
        builder: (ctx) => AppDialog(
          icon: Icons.warning_amber_rounded,
          title: 'Clear current run?',
          content:
              'This abandons your unfinished run so you can start a new one.\n\n'
              'A paid entry fee is non-refundable.',
          actions: [
            AppButton(
              label: 'Keep run',
              variant: AppButtonVariant.text,
              onPressed: () => Navigator.pop(ctx, false),
            ),
            AppButton(
              label: 'Clear run',
              variant: AppButtonVariant.text,
              color: AppColors.errorText,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || !mounted) return;
    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final activeRunId =
          (snap.data()?['activeRunId'] as String?)?.trim() ?? '';
      if (!mounted) return;
      if (activeRunId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No stuck run found — try starting again.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      await FirestoreService.instance.cancelRun(activeRunId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stuck run cleared — start again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      debugPrint('[HomeTab] clearStuckRun failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text("Couldn't clear the run — check connection, try again."),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _cooldownStartErrorMessage(Object e) {
    if (e is FirebaseFunctionsException) {
      if (e.code == 'failed-precondition' && e.message == 'cooldown_active') {
        return 'Some anime are still on cooldown — pick again.';
      }
      if (e.code == 'failed-precondition' && e.message == 'run_in_progress') {
        return 'Finish your current run before starting another.';
      }
      if (e.code == 'failed-precondition' &&
          (e.message ?? '').startsWith('App update required')) {
        return e.message!;
      }
    }
    return 'Something went wrong — please try again.';
  }

  // ── Gauntlet Blitz entry point ────────────────────────────────────────────
  // Flow: preview (live stream, no charge) → confirm dialog → loading →
  // enterDailyGauntlet (authoritative deduction + ticket + 30Q run) →
  // quiz page. Charging happens ONLY after the user confirms AND content
  // is available, so a content failure never burns coins.
  bool _gauntletBusy = false;

  Future<void> _startDailyGauntlet() async {
    // A solo launch still in flight will push its own quiz page in a moment;
    // entering the Gauntlet on top of it would stack two sessions (and charge
    // for the Gauntlet entry at the same time).
    if (_gauntletBusy || _startingSolo) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please sign in to play Gauntlet Blitz.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Claim the entry before the first await. The preview read below can take
    // up to 6 s on a slow connection while nothing covers the screen, and a
    // second tap used to run a whole second entry: two confirm dialogs, two
    // `enterDailyGauntlet` charges (each minting its own ticket) and two
    // stacked quiz pages. The finally releases the gate on every exit path.
    _gauntletBusy = true;
    try {
      await _enterDailyGauntlet();
    } finally {
      _gauntletBusy = false;
    }
  }

  /// Preview → confirm → fetch → authoritative entry. Split out of
  /// [_startDailyGauntlet] so its re-entrancy gate wraps the whole sequence.
  Future<void> _enterDailyGauntlet() async {
    // ── 1. Preview (no charge, same source as the home card) ──────────
    // Capture premium BEFORE any async gap.
    final isPremiumCached = context.read<UserDataProvider>().premiumActive;
    bool isFreeAttempt = true;
    int? retryCost = 0;
    try {
      final progress = await FirestoreService.instance
          .gauntletProgressStream()
          .first
          .timeout(const Duration(seconds: 6));
      final usedToday = (progress['usedToday'] as bool?) ?? false;
      final retryIndex = (progress['retryIndex'] as int?) ?? 0;
      isFreeAttempt = !usedToday;
      retryCost = blitzRetryCost(
        retryIndex: retryIndex,
        isPremium: isPremiumCached,
        isFreeAttempt: isFreeAttempt,
      );
    } catch (e) {
      // Offline / slow stream — fall back to a free preview so the dialog
      // still opens; the server remains authoritative at enter time.
      debugPrint('[HomeTab] gauntlet preview fallback (free): $e');
      isFreeAttempt = true;
      retryCost = 0;
    }

    if (!mounted) return;

    // At cap — no retries left today.
    if (!isFreeAttempt && retryCost == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No Blitz retries left today — come back tomorrow.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // ── 2. Confirm (redesigned to match the app) ───────────────────────
    final confirmed = await _showGauntletConfirmDialog(
      isFreeAttempt: isFreeAttempt,
      retryCost: retryCost ?? 0,
    );
    if (confirmed != true || !mounted) return;

    // ── 3. Load + enter with visible feedback ──────────────────────────
    _showGauntletLoading();
    try {
      // The server picks the 30 questions and mints the run BEFORE charging,
      // so a content failure still never burns coins. It returns the runId;
      // the quiz page resolves the sanitized questions from it.
      final entryResult = await FirestoreService.instance.enterDailyGauntlet();
      final String? ticketId = entryResult['ticketId'] as String?;
      final String? runId = entryResult['runId'] as String?;

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close loading
      _startQuiz(
        isGauntlet: true,
        gauntletTicketId: ticketId,
        gauntletRunId: runId,
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
        final raw = e.message ?? '';
        if (raw.startsWith('App update required')) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(raw),
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppColors.wrong,
            ),
          );
          return;
        }
        if (raw == 'run_in_progress') {
          _showStuckRunRecovery(
            fallback: 'Finish your current run before starting Blitz.',
            // A paid retry forfeits its entry fee when cleared.
            feeWarning: !isFreeAttempt,
          );
          return;
        }
        final message = switch (raw) {
          'not_enough_questions' =>
            'Not enough questions for Blitz yet — try another anime.',
          'max_retries_exceeded' =>
            'No Blitz retries left today — come back tomorrow.',
          'gauntlet_free_entry_limit' =>
            'Free Blitz entries used up for today — come back tomorrow.',
          _ => "Couldn't start Gauntlet Blitz — please try again.",
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
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
            content: const Text('Gauntlet Blitz is updating on the server — '
                'please try again in a minute.'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.wrong,
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              const Text("Couldn't start Gauntlet Blitz — please try again."),
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
    }
  }

  /// Friendly message for content failures (thrown BEFORE any charge).
  String _gauntletLoadErrorMessage(Object e) {
    final msg = e.toString();
    if (msg.contains('Not enough questions')) {
      return 'Not enough questions yet — try a normal quiz first.';
    }
    return "Couldn't load Gauntlet Blitz — please try again.";
  }

  /// Non-dismissible loading indicator shown while fetching + entering.
  void _showGauntletLoading() {
    showAppDialog<void>(
      context,
      barrierDismissible: false,
      builder: (_) => AppDialog(
        icon: Icons.hourglass_top_rounded,
        iconColor: AppColors.readable(AppColors.amber),
        title: 'Preparing Blitz…',
        content: 'Fetching questions and reserving your entry.',
      ),
    );
  }

  /// Confirm dialog for Gauntlet Blitz.
  ///
  /// Built on [AppDialog] for the app's dialog shell: a clock hero with the
  /// entry cost as a pill, the AC payout grid read from [kBlitzAcTiers]
  /// (never a hardcoded copy of the server curve) with the break-even tier
  /// highlighted, one verdict line connecting cost to payout, and one rules
  /// note. Nothing is charged until this resolves true.
  Future<bool?> _showGauntletConfirmDialog({
    required bool isFreeAttempt,
    required int retryCost,
  }) {
    const amber = AppColors.amber;
    final isFreeEntry = isFreeAttempt || retryCost == 0;

    // Lowest payout covering this run's entry fee. Null for free entries
    // (everything is profit) and for deep retries no tier can cover.
    BlitzAcTier? breakEven;
    if (!isFreeEntry) {
      for (final tier in kBlitzAcTiers) {
        if (tier.ac >= retryCost) {
          breakEven = tier;
          break;
        }
      }
    }
    final covered = breakEven;

    final confirmLabel = isFreeAttempt
        ? 'Start · Free'
        : (retryCost == 0 ? 'Retry · FREE' : 'Retry · $retryCost AC');

    return showAppDialog<bool>(
      context,
      builder: (ctx) => AppDialog(
        icon: Icons.bolt_rounded,
        iconColor: amber,
        title: 'Gauntlet Blitz',
        contentWidget: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Hero: clock + entry ─────────────────────────────────
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
              child: Row(
                children: [
                  Container(
                    width: 52.r,
                    height: 52.r,
                    decoration: BoxDecoration(
                      color: amber.withValues(alpha: isFreeEntry ? 0.16 : 0.07),
                      borderRadius: BorderRadius.circular(14.r),
                      border: Border.all(
                        color:
                            amber.withValues(alpha: isFreeEntry ? 0.34 : 0.16),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.timer_rounded,
                          color: isFreeEntry ? amber : AppColors.textMuted,
                          size: 15.r,
                        ),
                        Text(
                          '90s',
                          style: AppTypography.titleLarge.copyWith(
                            color: isFreeEntry ? amber : AppColors.textMuted,
                            fontWeight: FontWeight.w900,
                            height: 1.0,
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
                          'Answer as many as you can',
                          style: AppTypography.titleMedium.copyWith(
                            fontWeight: FontWeight.w900,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 6.h),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8.r,
                            vertical: 4.r,
                          ),
                          decoration: BoxDecoration(
                            color: isFreeEntry
                                ? amber.withValues(alpha: 0.16)
                                : AppColors.surface,
                            borderRadius: BorderRadius.circular(AppRadii.full),
                            border: Border.all(
                              color: isFreeEntry
                                  ? amber.withValues(alpha: 0.4)
                                  : AppColors.divider,
                            ),
                          ),
                          child: Text(
                            isFreeEntry ? 'FREE ENTRY' : '$retryCost AC ENTRY',
                            style: AppTypography.labelSmall.copyWith(
                              color:
                                  isFreeEntry ? amber : AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: AppSpacing.lg),

            // ── Payout grid (read from kBlitzAcTiers) ───────────────
            Text('PAYOUT', style: AppTypography.labelSmall),
            SizedBox(height: 8.h),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var row = 0; row < 2; row++)
                  Padding(
                    padding: EdgeInsets.only(bottom: row == 0 ? 6.h : 0),
                    child: Row(
                      children: [
                        for (var col = 0; col < 3; col++)
                          Expanded(
                            child: Padding(
                              padding:
                                  EdgeInsets.only(right: col < 2 ? 6.w : 0),
                              child: _BlitzPayoutChip(
                                tier: kBlitzAcTiers[row * 3 + col],
                                breakEven:
                                    covered == kBlitzAcTiers[row * 3 + col],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            SizedBox(height: 8.h),
            Text(
              isFreeEntry
                  ? 'Every run pays — '
                      '${kBlitzAcTiers.last.minCorrect}+ correct takes '
                      'the full $kBlitzMaxAc AC.'
                  : covered != null
                      ? '${covered.minCorrect}+ correct covers '
                          'your $retryCost AC entry.'
                      : 'Top payout is $kBlitzMaxAc AC — below this entry. '
                          'Play for WP.',
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall.copyWith(
                color: isFreeEntry || covered != null
                    ? AppColors.readable(amber)
                    : AppColors.textMuted,
                fontWeight: FontWeight.w700,
              ),
            ),

            SizedBox(height: AppSpacing.lg),

            // ── One-line rules ──────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.block_rounded,
                  size: 13.r,
                  color: AppColors.textMuted,
                ),
                SizedBox(width: 6.w),
                Flexible(
                  child: Text(
                    isFreeEntry
                        ? 'No hints or pauses · up to $kBlitzQuestionCount questions'
                        : 'No hints or pauses · quitting forfeits the entry',
                    textAlign: TextAlign.center,
                    style: AppTypography.bodySmall,
                  ),
                ),
              ],
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
        title: Text(
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
                  color: AppColors.readable(AppColors.accent),
                  fontWeight: FontWeight.w700),
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
    } on FirebaseFunctionsException catch (e) {
      debugPrint('[HomeTab] _skipCooldown CF error: ${e.code} ${e.message}');
      if (e.code == 'failed-precondition' &&
          (e.message ?? '') == 'cooldown_not_active') {
        // The lock already lapsed between tap and spend — nothing was
        // charged, so just drop the stale lock locally instead of erroring.
        if (mounted) {
          setState(() => _locks.remove(title));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('That cooldown already expired — pick again.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      if (e.code == 'unauthenticated' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your session expired — sign in again, then retry.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Something went wrong — please try again.')),
        );
      }
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
        title: Text(
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
              style: TextStyle(
                  color: AppColors.readable(AppColors.accent),
                  fontWeight: FontWeight.w700),
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
    // Client-side filter counts over the visible shelf (never the full
    // catalogue — its size stays unknown to the user).
    final now = DateTime.now();
    final shelfTitles = _shelfTitles;
    final cooldownCount = shelfTitles.where((t) {
      final lock = _locks[t];
      return lock != null && lock.isAfter(now);
    }).length;
    final readyCount = shelfTitles.length - cooldownCount;
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
                        const _TodayPrizeCard(),
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
                            color: AppColors.secondary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(20.r),
                            border: Border.all(
                                color:
                                    AppColors.secondary.withValues(alpha: 0.4)),
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
                      totalCount: shelfTitles.length,
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
                  difficulty:
                      context.watch<SoloDifficultyProvider>().difficulty,
                  starting: _startingSolo,
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

// ─── Blitz payout chip ───────────────────────────────────────────────────────
/// One AC payout tier. The break-even tier (lowest payout covering this
/// run's entry fee) renders highlighted so the gamble reads at a glance.
class _BlitzPayoutChip extends StatelessWidget {
  final BlitzAcTier tier;
  final bool breakEven;

  const _BlitzPayoutChip({required this.tier, required this.breakEven});

  @override
  Widget build(BuildContext context) {
    const amber = AppColors.amber;
    return Container(
      padding: EdgeInsets.symmetric(vertical: 8.r, horizontal: 4.r),
      decoration: BoxDecoration(
        color: breakEven
            ? amber.withValues(alpha: 0.20)
            : AppColors.surfaceAlt.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(
          color: breakEven
              ? amber.withValues(alpha: 0.6)
              : AppColors.divider.withValues(alpha: 0.7),
          width: breakEven ? 1.5 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${tier.minCorrect}+',
            style: AppTypography.labelMedium.copyWith(
              color:
                  breakEven ? AppColors.readable(amber) : AppColors.textMuted,
            ),
          ),
          SizedBox(height: 2.h),
          Text(
            '+${tier.ac}',
            style: AppTypography.labelLarge.copyWith(
              color:
                  breakEven ? AppColors.readable(amber) : AppColors.textPrimary,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Today: Gauntlet Blitz card ──────────────────────────────────────────────
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
        final usedToday = (data['usedToday'] as bool?) ?? false;
        final retryIndex = (data['retryIndex'] as int?) ?? 0;
        final isPremium = context.watch<UserDataProvider>().premiumActive;
        final isFreeAttempt = !usedToday;
        final retryCost = blitzRetryCost(
          retryIndex: retryIndex,
          isPremium: isPremium,
          isFreeAttempt: isFreeAttempt,
        );
        final atCap = retryCost == null;

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
                        AppColors.amber.withValues(alpha: 0.20),
                        AppColors.amber.withValues(alpha: 0.05)
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              color: usedToday ? AppColors.surface : null,
              borderRadius: BorderRadius.circular(18.r),
              border: Border.all(
                color: usedToday
                    ? AppColors.divider
                    : AppColors.amber.withValues(alpha: 0.45),
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
                      '90s',
                      style: TextStyle(
                        color: usedToday
                            ? AppColors.textMuted
                            : AppColors.readable(AppColors.amber),
                        fontSize: 22.sp,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                      ),
                    ),
                    Text(
                      'blitz',
                      style: TextStyle(
                        color: usedToday
                            ? AppColors.textMuted.withValues(alpha: 0.6)
                            : AppColors.readable(AppColors.amber)
                                .withValues(alpha: 0.8),
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
                        'GAUNTLET BLITZ',
                        style: TextStyle(
                          color: usedToday
                              ? AppColors.textMuted
                              : AppColors.readable(AppColors.amber),
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
                        'Up to $kBlitzMaxAc AC · no streak',
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

// ─── Today: Prize Pool card (display-only, not tappable) ────────────────────
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
    // Same *rule* the leaderboard uses (PrizePoolService.projectPrizePool), so
    // the two can never compute a different figure. They can still be read at
    // different times: this card streams live while the leaderboard re-reads on
    // open / pull-to-refresh / a stale resume, so for a few minutes after a
    // sale the card can lead the board. The rule is shared; the cadence is not.
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
        );

        return Container(
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
                    color: AppColors.readable(AppColors.accent),
                  ),
                  SizedBox(width: 4.w),
                  Text(
                    'PRIZE POOL',
                    style: TextStyle(
                      color: AppColors.readable(AppColors.accent)
                          .withValues(alpha: 0.9),
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
          AppPageRoute(builder: (_) => const PremiumUpsellScreen()),
        ),
        child: Container(
          padding: EdgeInsets.all(16.r),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.accent.withValues(alpha: 0.18),
                AppColors.secondary.withValues(alpha: 0.10),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18.r),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Container(
                width: 48.r,
                height: 48.r,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(14.r),
                  border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.40)),
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
                      '1.20× eligible WP · Extra Quick Match · Free Blitz retry',
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
                  color: AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12.r),
                  border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.3)),
                ),
                child: Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: AppColors.readable(AppColors.accent),
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
  // Exact poster filenames per title (dark, light). Mixed extensions because
  // some dark posters were supplied as PNG — keep this map in sync with the
  // assets list in pubspec.yaml. Unknown titles fall back to emoji+gradient.
  static const Map<String, List<String>> _posterFiles = {
    'attack on titan': [
      'assets/attack on titan.jpg',
      'assets/attack on titan1.jpg'
    ],
    'berserk': ['assets/berserk.jpg', 'assets/berserk1.jpg'],
    'black clover': ['assets/black clover.jpg', 'assets/black clover1.jpg'],
    'bleach': ['assets/bleach.jpg', 'assets/bleach1.jpg'],
    'blue lock': ['assets/blue lock.jpg', 'assets/blue lock1.jpg'],
    'chainsaw man': ['assets/chainsaw man.jpg', 'assets/chainsaw man1.jpg'],
    'classroom of the elite': [
      'assets/classroom of the elite.jpg',
      'assets/classroom of the elite1.jpg'
    ],
    'death note': ['assets/death note.jpg', 'assets/death note1.jpg'],
    'demon slayer': ['assets/demon slayer.jpg', 'assets/demon slayer1.jpg'],
    'dragon ball z': ['assets/dragon ball z.jpg', 'assets/dragon ball z1.jpg'],
    'dr stone': ['assets/dr stone.jpg', 'assets/dr stone1.jpg'],
    'fairy tail': ['assets/fairy tail.jpg', 'assets/fairy tail1.jpg'],
    'fire force': ['assets/fire force.jpg', 'assets/fire force1.jpg'],
    "hell's paradise": [
      "assets/hell's paradise.jpg",
      "assets/hell's paradise1.jpg"
    ],
    'hunter x hunter': [
      'assets/hunter x hunter.jpg',
      'assets/hunter x hunter1.jpg'
    ],
    "jojo's bizarre adventure": [
      "assets/jojo's bizarre adventure.jpg",
      "assets/jojo's bizarre adventure1.jpg"
    ],
    'jujutsu kaisen': [
      'assets/jujutsu kaisen.jpg',
      'assets/jujutsu kaisen1.jpg'
    ],
    "kuroko's basketball": [
      "assets/kuroko's basketball.jpg",
      "assets/kuroko's basketball1.jpg"
    ],
    'mushoku tensei': [
      'assets/mushoku tensei.jpg',
      'assets/mushoku tensei1.jpg'
    ],
    'my hero academia': [
      'assets/my hero academia.jpg',
      'assets/my hero academia1.jpg'
    ],
    'naruto': ['assets/naruto.jpg', 'assets/naruto1.jpg'],
    'one piece': ['assets/one piece.jpg', 'assets/one piece1.jpg'],
    'one punch man': ['assets/one punch man.jpg', 'assets/one punch man1.jpg'],
    're zero': ['assets/re zero.jpg', 'assets/re zero1.jpg'],
    'solo leveling': ['assets/solo leveling.jpg', 'assets/solo leveling1.jpg'],
    'sword art online': [
      'assets/sword art online.jpg',
      'assets/sword art online1.jpg'
    ],
    'that time i got reincarnated as a slime': [
      'assets/that time i got reincarnated as a slime.jpg',
      'assets/that time i got reincarnated as a slime1.jpg'
    ],
    'tokyo ghoul': ['assets/tokyo ghoul.jpg', 'assets/tokyo ghoul1.jpg'],
    'tokyo revengers': [
      'assets/tokyo revengers.jpg',
      'assets/tokyo revengers1.jpg'
    ],
    'tower of god': ['assets/tower of god.jpg', 'assets/tower of god1.jpg'],
    'vinland saga': ['assets/vinland saga.jpg', 'assets/vinland saga1.jpg'],
    'wind breaker': ['assets/wind breaker.jpg', 'assets/wind breaker1.jpg'],
  };

  static String? _assetPathFor(String title) {
    final pair = _posterFiles[title.toLowerCase().trim()];
    if (pair == null) return null;
    return AppColors.isDark ? pair[0] : pair[1];
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
    "jojo's bizarre adventure": '🕺',
    'blue lock': '⚽',
    'solo leveling': '🗡️',
    "kuroko's basketball": '🏀',
    'mushoku tensei': '🔮',
    'that time i got reincarnated as a slime': '💧',
    'fire force': '🔥',
    'classroom of the elite': '🎓',
    'dr stone': '🪨',
    "hell's paradise": '⛩️',
    're zero': '🔁',
    'tower of god': '🗼',
    'tokyo revengers': '🏍️',
    'wind breaker': '🌪️',
    'berserk': '🌑',
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

  String get _emoji => _emojiMap[widget.title.toLowerCase().trim()] ?? '✨';

  List<Color> get _palette {
    final index =
        widget.title.codeUnits.fold<int>(0, (total, value) => total + value) %
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
                      color: AppColors.primary.withValues(alpha: 0.25),
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
                        background: Colors.black.withValues(alpha: 0.65),
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
                  Container(color: Colors.black.withValues(alpha: 0.55)),
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
                                color:
                                    AppColors.secondary.withValues(alpha: 0.9),
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
                                color: AppColors.accent.withValues(alpha: 0.9),
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
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 10.5.sp,
                        fontWeight: FontWeight.w700,
                        shadows: const [
                          Shadow(
                            color: Colors.black54,
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
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
      decoration:
          const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
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
    final chips = <({_AnimeFilter value, String label})>[
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

  /// True while the start request is in flight — the button shows a spinner and
  /// ignores taps so lag can't stack a second quiz session.
  final bool starting;
  final VoidCallback onStart;
  final VoidCallback onClearAll;

  const _LineupTray({
    required this.selected,
    this.difficulty = 'easy',
    this.starting = false,
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
        border: Border(top: BorderSide(color: AppColors.divider)),
        boxShadow: [
          BoxShadow(
            // Dark keeps the original 35% lift; light needs the soft token.
            color: AppColors.isDark
                ? Colors.black.withValues(alpha: 0.35)
                : AppColors.shadow,
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
            isLoading: starting,
            icon: ready ? Icons.play_arrow_rounded : null,
            height: 54.h,
          ),
        ],
      ),
    );
  }
}
