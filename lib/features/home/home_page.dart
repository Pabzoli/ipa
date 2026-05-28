import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_balance_widget.dart';           // FIX: added
import '../../core/widgets/insufficient_coins_sheet.dart';     // FIX: added
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/prize_pool_service.dart';
import '../auth/auth_service.dart';
import '../quiz/questions_page.dart';
import '../player/pi_page.dart';
import '../../features/multiplayer/multiplayer_hub_page.dart';
import '../leaderboard/leaderboard_page.dart';
import '../leaderboard/weekly_leaderboard_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final List<String> _animeTitles = const [
    'attack on titan', 'demon slayer', 'jujutsu kaisen',
    'naruto', 'one piece', 'one punch man',
  ];

  final Set<String>           _selected        = {};
  final Map<String, DateTime> _locks           = {};
  Set<String>                 _unlockedForever = {}; // Bug 3: permanently unlocked animes
  late Timer                  _lockTimer;
  late AnimationController    _entranceCtrl;
  late Animation<double>      _entranceFade;
  late SharedPreferences      _prefs;
  late StreamSubscription<User?> _authSub;
  bool                        _prefsReady = false;

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
      // Bug 4 fix: keys are namespaced by UID so different accounts
      // on the same device never share cooldown state.
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
    // Bug 3 fix: load permanently unlocked animes from Firestore so
    // _startQuiz never re-locks them after a paid 200 AC unlock.
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
    if (!mounted) return;
    setState(() => _unlockedForever = {}); // clear previous user's data
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

  // Bug 4 fix: namespace prefs keys by UID so account switches
  // don't bleed cooldowns across users on the same device.
  String _prefKey(String title) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return uid.isEmpty ? title : '${uid}_$title';
  }

  // Bug 3 fix: fetch unlockedAnimes once on load and refresh after unlock.
  // _startQuiz checks this set and skips re-locking for permanent unlocks.
  Future<void> _loadUnlockedAnimes() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final doc  = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final list = (doc.data()?['unlockedAnimes'] as List?)
              ?.cast<String>() ??
          [];
      if (mounted) setState(() => _unlockedForever = list.toSet());
    } catch (e) {
      debugPrint('[HomePage] _loadUnlockedAnimes error (ignored): $e');
    }
  }

  void _toggleSelection(String title) {
    if (_locks.containsKey(title)) return;
    setState(() => _selected.contains(title)
        ? _selected.remove(title)
        : _selected.add(title));
  }

  void _startQuiz() {
    if (_selected.length < 2 || !_prefsReady) return;

    final titlesToPlay = _selected.toList();
    setState(() => _selected.clear());

    final counts   = [0, 0, 10 * 60, 7 * 60 + 30, 5 * 60, 2 * 60 + 30, 0];
    final lockSecs = counts[titlesToPlay.length.clamp(0, 6)];
    for (final t in titlesToPlay) {
      // Bug 3 fix: permanently unlocked animes never get re-locked.
      if (_unlockedForever.contains(t)) continue;
      if (lockSecs > 0) {
        _locks[t] = DateTime.now().add(Duration(seconds: lockSecs));
        _prefs.setString(_prefKey(t), _locks[t]!.toIso8601String()); // Bug 4 fix
      }
    }

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, a, __) => FadeTransition(
          opacity: a,
          child: QuestionsPage(selectedTitles: titlesToPlay),
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  // ── SPEND SURFACE 2: Cooldown Skip (25 AC) ──────────────────────────────────
  // FIX: new method wired to the locked card's skip button.

  Future<void> _skipCooldown(String title) async {
    const cost = 25;
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
          'Skip Cooldown?',
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Spend 25🪙 to unlock "${title.toUpperCase()}" immediately?',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              '⏩ Skip  −25🪙',
              style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await userData.updateAnimeCoins(-cost, 'spend_cooldown');
      if (!mounted) return;
      setState(() {
        _locks.remove(title);
        _prefs.remove(_prefKey(title)); // Bug 4 fix
      });
    } on InsufficientCoinsException {
  if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
} catch (e) {
  debugPrint('Unexpected error: $e');
  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Something went wrong — please try again.')),
  );
}
  }

  // ── SPEND SURFACE 4: Early Anime Unlock (200 AC) ────────────────────────────
  // FIX: new method wired to the locked card's unlock button.

  Future<void> _unlockEarly(String title) async {
    const cost = 200;
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
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Spend 200🪙 to permanently unlock "${title.toUpperCase()}"?\n\n'
          'This removes it from cooldown and adds it to your unlocked library.',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              '🔓 Unlock  −200🪙',
              style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await userData.updateAnimeCoins(-cost, 'spend_unlock');
      await FirestoreService.instance.unlockAnimeEarly(title);
      if (!mounted) return;
      setState(() {
        _locks.remove(title);
        _prefs.remove(_prefKey(title));    // Bug 4 fix
        _unlockedForever.add(title);       // Bug 3 fix: prevent re-locking on next quiz
      });
    } on InsufficientCoinsException {
  if (mounted) await showInsufficientCoinsSheet(context, needed: cost);
} catch (e) {
  debugPrint('Unexpected error: $e');
  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Something went wrong — please try again.')),
  );
}
  }

  @override
  Widget build(BuildContext context) {
    final userData = context.watch<UserDataProvider>();
    final username =
        AuthService.instance.currentUser?.displayName ?? 'Trainer';

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      drawer: _AppDrawer(username: username),
      body: FadeTransition(
        opacity: _entranceFade,
        child: CustomScrollView(slivers: [
          SliverAppBar(
            expandedHeight: 180,
            pinned: true,
            backgroundColor: AppColors.surfaceDim,
            leading: Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu_rounded,
                    color: AppColors.textPrimary),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
            actions: [
              // FIX: CoinBalanceWidget replaces the old ScoreBadge for animeCoins.
              // It is tappable, shows live balance with 🪙 pill styling, and
              // navigates to EarnCoinsScreen when P-04 is built.
              const CoinBalanceWidget(),
              const SizedBox(width: 8),
              ScoreBadge(
                  score: userData.score, icon: Icons.stars_rounded),
              const SizedBox(width: 16),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: AppDecorations.heroBg,
                padding: const EdgeInsets.fromLTRB(24, 80, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('Hey, $username 👋',
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 16)),
                    const SizedBox(height: 4),
                    const Text('Pick your anime',
                        style: TextStyle(
                            color:      AppColors.textPrimary,
                            fontSize:   28,
                            fontWeight: FontWeight.w900)),
                    const Text('Select 2 or more to start',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),

          // ── Prize pool banner ──────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: _PrizePoolBanner(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const WeeklyLeaderboardPage()),
                ),
              ),
            ),
          ),

          // ── Rivalry banner ─────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: _RivalryBanner(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const WeeklyLeaderboardPage(initialTab: 1),
                  ),
                ),
              ),
            ),
          ),

          // ── Anime grid ────────────────────────────────────────────────
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _AnimeCard(
                  title:            _animeTitles[i],
                  isSelected:       _selected.contains(_animeTitles[i]),
                  lockTime:         _locks[_animeTitles[i]],
                  onTap:            () => _toggleSelection(_animeTitles[i]),
                  // FIX: wire Surface 2 & 4 callbacks into every card
                  onSkipCooldown:   () => _skipCooldown(_animeTitles[i]),
                  onUnlockEarly:    () => _unlockEarly(_animeTitles[i]),
                ),
                childCount: _animeTitles.length,
              ),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:   2,
                crossAxisSpacing: 14,
                mainAxisSpacing:  14,
                childAspectRatio: 0.85,
              ),
            ),
          ),
        ]),
      ),
      floatingActionButtonLocation:
          FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _selected.length >= 2
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: GradientButton(
                label: 'Start Quiz  (${_selected.length} selected)',
                onTap: _startQuiz,
                icon:  Icons.play_arrow_rounded,
                height: 58,
              ),
            )
          : null,
    );
  }
}

// ─── Anime Card ───────────────────────────────────────────────────────────────

class _AnimeCard extends StatefulWidget {
  final String       title;
  final bool         isSelected;
  final DateTime?    lockTime;
  final VoidCallback onTap;
  // FIX: two new optional spend-surface callbacks
  final VoidCallback? onSkipCooldown;
  final VoidCallback? onUnlockEarly;

  const _AnimeCard({
    required this.title,
    required this.isSelected,
    required this.onTap,
    this.lockTime,
    this.onSkipCooldown,   // FIX
    this.onUnlockEarly,    // FIX
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
        lowerBound: 0.95,
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
  int get _secs => _isLocked
      ? widget.lockTime!.difference(DateTime.now()).inSeconds
      : 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:  (_) => _ctrl.reverse(),
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
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: widget.isSelected
                  ? AppColors.primary
                  : _isLocked
                      ? AppColors.locked
                      : AppColors.divider,
              width: widget.isSelected ? 2.5 : 1,
            ),
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                        color:      AppColors.primary.withOpacity(0.35),
                        blurRadius: 20)
                  ]
                : [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(19),
            child: Stack(fit: StackFit.expand, children: [
              Image.asset(
                'assets/${widget.title}.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: AppColors.surface,
                  child: const Icon(Icons.image_not_supported,
                      color: AppColors.textMuted, size: 40),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.75),
                    ],
                    begin: Alignment.topCenter,
                    end:   Alignment.bottomCenter,
                  ),
                ),
              ),
              Positioned(
                left: 10, right: 10, bottom: 10,
                child: Text(
                  widget.title.toUpperCase(),
                  style: const TextStyle(
                      color:         Colors.white,
                      fontSize:      11,
                      fontWeight:    FontWeight.w800,
                      letterSpacing: 1),
                  maxLines:  2,
                  textAlign: TextAlign.center,
                ),
              ),
              if (widget.isSelected)
                Positioned(
                  top: 10, right: 10,
                  child: Container(
                    width:  28,
                    height: 28,
                    decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle),
                    child: const Icon(Icons.check,
                        color: Colors.white, size: 18),
                  ),
                ),

              // ── Locked overlay with spend-surface buttons ──────────────────
              // FIX: added "⏩ Skip wait" and "🔓 Unlock Early" action buttons.
              // Each button is wrapped in its own GestureDetector to absorb
              // the tap so it does NOT bubble up to the card's onTap.
              if (_isLocked) ...[
                Container(color: Colors.black.withOpacity(0.65)),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_rounded,
                          color: Colors.white70, size: 30),
                      const SizedBox(height: 4),
                      Text(
                        _secs >= 60
                            ? '${_secs ~/ 60}m ${_secs % 60}s'
                            : '${_secs}s',
                        style: const TextStyle(
                            color:      Colors.white70,
                            fontSize:   12,
                            fontWeight: FontWeight.w700),
                      ),

                      // ── Surface 2: Cooldown Skip (25 AC) ──────────────────
                      const SizedBox(height: 8),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          // Absorb tap — do not propagate to card's onTap.
                          widget.onSkipCooldown?.call();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.secondary.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '⏩ Skip  25🪙',
                            style: TextStyle(
                              color:      Colors.white,
                              fontSize:   11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),

                      // ── Surface 4: Early Unlock (200 AC) ──────────────────
                      const SizedBox(height: 5),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          widget.onUnlockEarly?.call();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '🔓 Unlock  200🪙',
                            style: TextStyle(
                              color:      Colors.white,
                              fontSize:   11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  final String username;
  const _AppDrawer({required this.username});

  @override
  Widget build(BuildContext context) {
    final userData = context.watch<UserDataProvider>();
    return Drawer(
      width: 260,
      backgroundColor: AppColors.surface,
      child: SafeArea(
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: AppDecorations.heroBg,
            child: Row(children: [
              Container(
                width:  52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.primary, Color(0xFFFF6B6B)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.person_rounded,
                    color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(username,
                        style: const TextStyle(
                            color:      AppColors.textPrimary,
                            fontSize:   18,
                            fontWeight: FontWeight.w800),
                        overflow: TextOverflow.ellipsis),
                    Row(children: [
                      const Icon(Icons.stars_rounded,
                          color: AppColors.accent, size: 14),
                      const SizedBox(width: 4),
                      Text('${userData.score} pts',
                          style: const TextStyle(
                              color: AppColors.accent, fontSize: 13)),
                    ]),
                  ],
                ),
              ),
            ]),
          ),

          const SizedBox(height: 12),

          _Tile(
            icon:  Icons.person_outline_rounded,
            label: 'My Profile',
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PInform()));
            },
          ),

          _Tile(
            icon:  Icons.sports_esports_rounded,
            label: 'Battle Arena',
            color: AppColors.primary,
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const MultiplayerHubPage(),
                ),
              );
            },
          ),

          _Tile(
            icon:  Icons.leaderboard_rounded,
            label: 'Leaderboard',
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const LeaderboardPage()));
            },
          ),
          _Tile(
            icon:  Icons.emoji_events_rounded,
            label: 'Weekly Prizes',
            color: AppColors.accent,
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(
                      builder: (_) => const WeeklyLeaderboardPage()));
            },
          ),

          const Spacer(),
          const Divider(color: AppColors.divider),
          _Tile(
            icon:  Icons.logout_rounded,
            label: 'Sign Out',
            color: AppColors.wrong,
            onTap: () async {
              Navigator.pop(context);
              await AuthService.instance.signOut();
            },
          ),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  final Color?       color;
  const _Tile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });
  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textPrimary;
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title:   Text(label,
          style: TextStyle(
              color: c, fontSize: 15, fontWeight: FontWeight.w600)),
      onTap:   onTap,
      shape:   RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }
}

class _PrizePoolBanner extends StatefulWidget {
  final VoidCallback onTap;
  const _PrizePoolBanner({required this.onTap});

  @override
  State<_PrizePoolBanner> createState() => _PrizePoolBannerState();
}

class _PrizePoolBannerState extends State<_PrizePoolBanner> {
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
        final pool       = snap.data ?? {};
        final totalNaira = (pool['totalNaira'] as num?)?.toDouble() ?? 0.0;
        final timeLeft   = PrizePoolService.timeUntilReset();

        return GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.primary.withOpacity(0.18),
                  AppColors.accent.withOpacity(0.12),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: AppColors.primary.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                const Text('🏆', style: TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'THIS WEEK\'S PRIZE POOL',
                        style: TextStyle(
                          color:         AppColors.textMuted,
                          fontSize:      10,
                          fontWeight:    FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        PrizePoolService.formatNaira(totalNaira),
                        style: const TextStyle(
                          color:      AppColors.textPrimary,
                          fontSize:   22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      'Resets in',
                      style: TextStyle(
                          color:    AppColors.textMuted,
                          fontSize: 10),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      PrizePoolService.formatCountdown(timeLeft),
                      style: const TextStyle(
                          color:      AppColors.accent,
                          fontSize:   11,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Top 5 win →',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RivalryBanner extends StatefulWidget {
  final VoidCallback onTap;
  const _RivalryBanner({required this.onTap});

  @override
  State<_RivalryBanner> createState() => _RivalryBannerState();
}

class _RivalryBannerState extends State<_RivalryBanner> {
  List<UniversityTotal>? _top;
  bool                   _loaded = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final top = await FirestoreService.instance.getTopUniversities();
      if (!mounted) return;
      setState(() {
        _top    = top;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return _RivalryBannerShell(
        onTap: widget.onTap,
        child: const _RivalrySkeleton(),
      );
    }

    final top = _top ?? [];

    if (top.length < 2) {
      return _RivalryBannerShell(
        onTap: widget.onTap,
        child: Row(
          children: [
            Container(
              width:  36,
              height: 36,
              decoration: const BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.school_outlined,
                  color: AppColors.textMuted, size: 18),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Campus battles heat up as more students join',
                style: TextStyle(
                  color:    AppColors.textMuted,
                  fontSize: 12,
                  height:   1.3,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textMuted, size: 18),
          ],
        ),
      );
    }

    final leader     = top[0];
    final challenger = top[1];

    return _RivalryBannerShell(
      onTap: widget.onTap,
      child: Row(
        children: [
          Container(
            width:  36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF).withOpacity(0.18),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.school_rounded,
                color: Color(0xFF6C63FF), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'CAMPUS WARS',
                  style: TextStyle(
                    color:         AppColors.textMuted,
                    fontSize:      9,
                    fontWeight:    FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 13, height: 1.2),
                    children: [
                      TextSpan(
                        text: leader.university,
                        style: const TextStyle(
                          color:      AppColors.textPrimary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const TextSpan(
                        text: ' leads ',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                      TextSpan(
                        text: challenger.university,
                        style: const TextStyle(
                          color:      AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(
                        text:
                            '  ·  ${_fmt(leader.total)} – ${_fmt(challenger.total)}',
                        style: const TextStyle(
                          color:      AppColors.textMuted,
                          fontSize:   11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right_rounded,
              color: AppColors.textMuted, size: 18),
        ],
      ),
    );
  }

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000)    return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

class _RivalryBannerShell extends StatelessWidget {
  final VoidCallback onTap;
  final Widget       child;
  const _RivalryBannerShell(
      {required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF6C63FF).withOpacity(0.12),
              const Color(0xFF3ECFCF).withOpacity(0.08),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: const Color(0xFF6C63FF).withOpacity(0.28)),
        ),
        child: child,
      ),
    );
  }
}

class _RivalrySkeleton extends StatelessWidget {
  const _RivalrySkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width:  36,
          height: 36,
          decoration: const BoxDecoration(
            color: AppColors.surface,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                  width: 70, height: 8,
                  decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(4))),
              const SizedBox(height: 6),
              Container(
                  width: double.infinity, height: 10,
                  decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(4))),
            ],
          ),
        ),
      ],
    );
  }
}