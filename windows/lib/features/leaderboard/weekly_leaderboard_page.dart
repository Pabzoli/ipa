import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/prize_pool_service.dart';
import '../../core/providers/user_data_provider.dart';
import '../../features/multiplayer/anime_select_page.dart';
import '../../features/multiplayer/stake_screen.dart';

// ─── Page ─────────────────────────────────────────────────────────────────────
class WeeklyLeaderboardPage extends StatefulWidget {
  /// 0 = Global tab (default), 1 = My Campus tab.
  /// Pass [initialTab: 1] from the rivalry banner to land directly on campus.
  final int initialTab;

  const WeeklyLeaderboardPage({super.key, this.initialTab = 0});

  @override
  State<WeeklyLeaderboardPage> createState() =>
      _WeeklyLeaderboardPageState();
}

class _WeeklyLeaderboardPageState extends State<WeeklyLeaderboardPage>
    with SingleTickerProviderStateMixin {
  // ── Controllers ────────────────────────────────────────────────────────────
  late final TabController _tabCtrl;
  Timer?   _countdownTimer;
  Duration _timeLeft = PrizePoolService.timeUntilReset();

  // ── Streams — created once, never in build() ───────────────────────────────
  late final Stream<Map<String, dynamic>>       _prizePoolStream;
  late final Stream<List<Map<String, dynamic>>> _weeklyLbStream;
  Stream<List<Map<String, dynamic>>>?           _campusLbStream;

  // ── University state ────────────────────────────────────────────────────────
  /// null = still loading | empty string = user skipped prompt | value = set
  String? _userUniversity;
  bool    _universityLoaded = false;

  @override
  void initState() {
    super.initState();

    _tabCtrl = TabController(
      length:       2,
      vsync:        this,
      initialIndex: widget.initialTab,
    );

    _prizePoolStream = FirestoreService.instance.prizePoolStream();
    _weeklyLbStream  = FirestoreService.instance.weeklyLeaderboardStream();

    // Countdown rebuilds the chip every second — only this widget, not
    // the two expensive StreamBuilders inside the tabs.
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _timeLeft = PrizePoolService.timeUntilReset());
    });

    _loadUserUniversity();
  }

  Future<void> _loadUserUniversity() async {
    final uni = await FirestoreService.instance.getCurrentUserUniversity();
    if (!mounted) return;
    setState(() {
      _userUniversity   = uni ?? '';   // null → empty string (not set)
      _universityLoaded = true;
      if (uni != null && uni.isNotEmpty) {
        _campusLbStream =
            FirestoreService.instance.weeklyCampusLeaderboardStream(uni);
      }
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myWeeklyPts = context.watch<UserDataProvider>().weeklyPoints;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: Container(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            children: [
              // ── App bar ──────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: AppColors.textPrimary),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Text(
                      'Weekly Prize',
                      style: TextStyle(
                          color:      AppColors.textPrimary,
                          fontSize:   22,
                          fontWeight: FontWeight.w800),
                    ),
                    const Spacer(),
                    // Countdown chip
                    _CountdownChip(timeLeft: _timeLeft),
                  ],
                ),
              ),

              // ── Tab bar ──────────────────────────────────────────────────
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _LeaderboardTabBar(controller: _tabCtrl),
              ),

              // ── Tab views ────────────────────────────────────────────────
              Expanded(
                child: TabBarView(
                  controller: _tabCtrl,
                  children: [
                    // ── Tab 0: Global ──────────────────────────────────────
                    _GlobalTab(
                      prizePoolStream: _prizePoolStream,
                      weeklyLbStream:  _weeklyLbStream,
                      timeLeft:        _timeLeft,
                      myWeeklyPts:     myWeeklyPts,
                    ),

                    // ── Tab 1: My Campus ───────────────────────────────────
                    _CampusTab(
                      campusLbStream:   _campusLbStream,
                      university:       _userUniversity,
                      universityLoaded: _universityLoaded,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Tab Bar ──────────────────────────────────────────────────────────────────
class _LeaderboardTabBar extends StatelessWidget {
  final TabController controller;
  const _LeaderboardTabBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height:      44,
      decoration: BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: AppColors.divider),
      ),
      child: TabBar(
        controller:         controller,
        indicator: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.primary.withOpacity(0.85),
              AppColors.secondary.withOpacity(0.85),
            ],
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        indicatorSize:      TabBarIndicatorSize.tab,
        indicatorPadding:   const EdgeInsets.all(3),
        dividerColor:       Colors.transparent,
        labelColor:         Colors.white,
        unselectedLabelColor: AppColors.textMuted,
        labelStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600),
        tabs: const [
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.public_rounded, size: 14),
                SizedBox(width: 6),
                Text('Global'),
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.school_rounded, size: 14),
                SizedBox(width: 6),
                Text('My Campus'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Countdown Chip ───────────────────────────────────────────────────────────
class _CountdownChip extends StatelessWidget {
  final Duration timeLeft;
  const _CountdownChip({required this.timeLeft});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined,
              color: AppColors.accent, size: 13),
          const SizedBox(width: 4),
          Text(
            PrizePoolService.formatCountdown(timeLeft),
            style: const TextStyle(
                color:      AppColors.accent,
                fontSize:   11,
                fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

// ─── Global Tab ───────────────────────────────────────────────────────────────
class _GlobalTab extends StatefulWidget {
  final Stream<Map<String, dynamic>>       prizePoolStream;
  final Stream<List<Map<String, dynamic>>> weeklyLbStream;
  final Duration                           timeLeft;
  final int                                myWeeklyPts;

  const _GlobalTab({
    required this.prizePoolStream,
    required this.weeklyLbStream,
    required this.timeLeft,
    required this.myWeeklyPts,
  });

  @override
  State<_GlobalTab> createState() => _GlobalTabState();
}

class _GlobalTabState extends State<_GlobalTab> {
  // Fetched once when the tab first builds; refreshes with the stream rebuilds
  // only after the 5-minute cache expires (handled inside FirestoreService).
  late Future<int> _totalPlayersFuture;

  @override
  void initState() {
    super.initState();
    _totalPlayersFuture =
        FirestoreService.instance.getWeeklyPlayerCount();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: _totalPlayersFuture,
      builder: (context, totalSnap) {
        final totalPlayers = totalSnap.data ?? 0;
        return _buildContent(context, totalPlayers);
      },
    );
  }

  Widget _buildContent(BuildContext context, int totalPlayers) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: widget.prizePoolStream,
      builder: (context, poolSnap) {
        final pool       = poolSnap.data ?? {};
        final totalNaira = (pool['totalNaira'] as num?)?.toDouble() ?? 0.0;
        final prizes     = PrizePoolService.calculatePrizes(totalNaira);

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: widget.weeklyLbStream,
          builder: (context, lbSnap) {
            if (lbSnap.connectionState == ConnectionState.waiting &&
                poolSnap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              );
            }

            final entries = lbSnap.data ?? [];

            // Find user's rank for the near-miss nudge
            int myRank = -1;
            for (final e in entries) {
              if (e['isCurrentUser'] == true) {
                myRank = e['rank'] as int;
                break;
              }
            }

            // ── Rival detection ─────────────────────────────────────────────
            // The rival is the entry ranked exactly one position above the
            // current user.  No rival if:
            //   • user has 0 weekly pts (not on the board yet)
            //   • user is already rank 1
            Map<String, dynamic>? rivalEntry;
            if (widget.myWeeklyPts > 0 && myRank > 1) {
              for (final e in entries) {
                if ((e['rank'] as int?) == myRank - 1) {
                  rivalEntry = e;
                  break;
                }
              }
            }

            return CustomScrollView(
              slivers: [
                // Prize pool hero
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: _PrizePoolHero(
                      totalNaira: totalNaira,
                      timeLeft:   widget.timeLeft,
                    ),
                  ),
                ),

                // Prize breakdown
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: _PrizeBreakdown(prizes: prizes),
                  ),
                ),

                // Near-miss nudge
                if (myRank > 0 && myRank <= 8 && entries.length > myRank)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: _NearMissCard(
                        myRank:     myRank,
                        myPts:      widget.myWeeklyPts,
                        entries:    entries,
                        totalNaira: totalNaira,
                      ),
                    ),
                  ),

                // Section header
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
                    child: SectionHeader(title: 'This Week\'s Rankings'),
                  ),
                ),

                // Empty state
                if (entries.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: Text(
                        'No players yet this week.\nBe the first!',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 15),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),

                // Leaderboard rows
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final e       = entries[i];
                        final isRival = rivalEntry != null &&
                            e['uid'] == rivalEntry!['uid'];
                        return _WeeklyRow(
                          entry:        e,
                          prize:        prizes[e['rank']],
                          totalNaira:   totalNaira,
                          isRival:      isRival,
                          totalPlayers: totalPlayers,
                          onTap: isRival
                              ? () => _showRivalSheet(context, e)
                              : null,
                        );
                      },
                      childCount: entries.length,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ─── Campus Tab ───────────────────────────────────────────────────────────────
class _CampusTab extends StatelessWidget {
  final Stream<List<Map<String, dynamic>>>? campusLbStream;
  final String?                             university;
  final bool                                universityLoaded;

  const _CampusTab({
    required this.campusLbStream,
    required this.university,
    required this.universityLoaded,
  });

  @override
  Widget build(BuildContext context) {
    // Still fetching university from Firestore
    if (!universityLoaded) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    // User skipped the prompt or university is empty
    if (university == null || university!.isEmpty) {
      return _NoCampusState();
    }

    // University is set — show the campus leaderboard
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: campusLbStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        // Firestore index missing → FAILED_PRECONDITION error.
        // The stream emits cached data for ~1s then errors once the server
        // responds. This surfaces the issue instead of silently showing "no players".
        if (snap.hasError) {
          return _CampusIndexError(error: snap.error.toString());
        }

        final entries = snap.data ?? [];

        return CustomScrollView(
          slivers: [
            // Campus header card
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: _CampusHeaderCard(university: university!),
              ),
            ),

            // Section header
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                child: SectionHeader(
                  title: '$university — Top Players',
                ),
              ),
            ),

            // Empty state
            if (entries.isEmpty)
              const SliverFillRemaining(
                child: Center(
                  child: Text(
                    'No players from your campus yet.\nPlay and be the first!',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 15),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // Campus leaderboard rows — reuses the same _WeeklyRow widget,
            // just without prize data (campus has no prize pool).
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _WeeklyRow(
                    entry:      entries[i],
                    prize:      null,     // no prize on campus tab
                    totalNaira: 0.0,
                  ),
                  childCount: entries.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Campus Header Card ───────────────────────────────────────────────────────
class _CampusHeaderCard extends StatelessWidget {
  final String university;
  const _CampusHeaderCard({required this.university});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF6C63FF).withOpacity(0.18),
            const Color(0xFF3ECFCF).withOpacity(0.12),
          ],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: const Color(0xFF6C63FF).withOpacity(0.35)),
        boxShadow: [
          BoxShadow(
            color:      const Color(0xFF6C63FF).withOpacity(0.15),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width:  48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF).withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.school_rounded,
                color: Color(0xFF6C63FF), size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  university,
                  style: const TextStyle(
                    color:      AppColors.textPrimary,
                    fontSize:   18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Campus rankings reset weekly with the global board.',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── No Campus State ─────────────────────────────────────────────────────────
class _NoCampusState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width:  72,
              height: 72,
              decoration: BoxDecoration(
                color:        AppColors.surface,
                shape:        BoxShape.circle,
                border: Border.all(color: AppColors.divider),
              ),
              child: const Icon(Icons.school_outlined,
                  color: AppColors.textMuted, size: 34),
            ),
            const SizedBox(height: 20),
            const Text(
              'No university set',
              style: TextStyle(
                color:      AppColors.textPrimary,
                fontSize:   20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Set your university in your profile to see how your '
              'campus stacks up against others.',
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: 14, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Campus Index Error ───────────────────────────────────────────────────────
/// Shown when the Firestore composite index for the campus leaderboard query
/// doesn't exist yet. The error message from Firestore contains a direct URL
/// to create the index — this widget surfaces it.
class _CampusIndexError extends StatelessWidget {
  final String error;
  const _CampusIndexError({required this.error});

  @override
  Widget build(BuildContext context) {
    // Firestore embeds a console URL in the error message — extract it so the
    // developer can tap straight to the index creation screen.
    final urlMatch =
        RegExp(r'https://console\.firebase\.google\.com\S+').firstMatch(error);
    final url = urlMatch?.group(0);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width:  64,
              height: 64,
              decoration: BoxDecoration(
                color:  AppColors.accent.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.build_outlined,
                  color: AppColors.accent, size: 30),
            ),
            const SizedBox(height: 20),
            const Text(
              'Index Required',
              style: TextStyle(
                color:      AppColors.textPrimary,
                fontSize:   18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'The campus leaderboard needs a Firestore composite index before '
              'it can load. This is a one-time setup.',
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: 13, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            // Index fields reference card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color:        AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border:       Border.all(color: AppColors.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Firestore → Indexes → Composite → Add index',
                    style: TextStyle(
                      color:      AppColors.textMuted,
                      fontSize:   11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _IndexField(field: 'university',   order: 'Ascending'),
                  const SizedBox(height: 6),
                  _IndexField(field: 'weeklyPoints', order: 'Descending'),
                ],
              ),
            ),
            if (url != null) ...[
              const SizedBox(height: 14),
              const Text(
                'Or tap the link in your IDE console to create it automatically.',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IndexField extends StatelessWidget {
  final String field;
  final String order;
  const _IndexField({required this.field, required this.order});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.arrow_right_rounded,
            color: AppColors.textMuted, size: 16),
        const SizedBox(width: 4),
        Text(
          field,
          style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color:        AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            order,
            style: const TextStyle(
                color: AppColors.textMuted, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

// ─── Prize Pool Hero ──────────────────────────────────────────────────────────
class _PrizePoolHero extends StatelessWidget {
  final double   totalNaira;
  final Duration timeLeft;
  const _PrizePoolHero(
      {required this.totalNaira, required this.timeLeft});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withOpacity(0.2),
            AppColors.accent.withOpacity(0.15),
          ],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.primary.withOpacity(0.4)),
        boxShadow: [
          BoxShadow(
            color:      AppColors.primary.withOpacity(0.2),
            blurRadius: 24,
          ),
        ],
      ),
      child: Column(
        children: [
          const Text(
            'THIS WEEK\'S PRIZE POOL',
            style: TextStyle(
              color:         AppColors.textMuted,
              fontSize:      11,
              fontWeight:    FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            totalNaira == 0
                ? '₦—'
                : PrizePoolService.formatNaira(totalNaira),
            style: const TextStyle(
              color:      AppColors.textPrimary,
              fontSize:   52,
              fontWeight: FontWeight.w900,
              height:     1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            totalNaira == 0
                ? 'Grows with every ad watched by anyone'
                : 'Every ad watched adds to this pool 🔥',
            style: const TextStyle(
              color:    AppColors.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color:        Colors.black.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.people_alt_rounded,
                    color: AppColors.textSecondary, size: 15),
                const SizedBox(width: 6),
                const Text(
                  'Top 5 players share this',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(width: 12),
                const Icon(Icons.timer_outlined,
                    color: AppColors.accent, size: 15),
                const SizedBox(width: 4),
                Text(
                  PrizePoolService.formatCountdown(timeLeft),
                  style: const TextStyle(
                      color:      AppColors.accent,
                      fontSize:   12,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Prize Breakdown ──────────────────────────────────────────────────────────
class _PrizeBreakdown extends StatelessWidget {
  final Map<int, double> prizes;
  const _PrizeBreakdown({required this.prizes});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Prize Breakdown'),
        const SizedBox(height: 10),
        Row(
          children: List.generate(5, (i) {
            final rank   = i + 1;
            final amount = prizes[rank] ?? 0.0;
            final pcts   = ['40%', '25%', '15%', '10%', '10%'];
            return Expanded(
              child: Container(
                margin: EdgeInsets.only(right: i < 4 ? 6 : 0),
                padding: const EdgeInsets.symmetric(
                    vertical: 12, horizontal: 4),
                decoration: BoxDecoration(
                  color:        _rankColor(rank).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                  border:       Border.all(
                      color: _rankColor(rank).withOpacity(0.3)),
                ),
                child: Column(
                  children: [
                    Text(
                      PrizePoolService.rankEmoji(rank),
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      amount > 0
                          ? PrizePoolService.formatCompact(amount)
                          : pcts[i],
                      style: TextStyle(
                        color:      _rankColor(rank),
                        fontSize:   11,
                        fontWeight: FontWeight.w800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Color _rankColor(int rank) {
    switch (rank) {
      case 1:  return const Color(0xFFFFD700);
      case 2:  return const Color(0xFFC0C0C0);
      case 3:  return const Color(0xFFCD7F32);
      default: return AppColors.secondary;
    }
  }
}

// ─── Near Miss Card ───────────────────────────────────────────────────────────
class _NearMissCard extends StatelessWidget {
  final int                        myRank;
  final int                        myPts;
  final List<Map<String, dynamic>> entries;
  final double                     totalNaira;

  const _NearMissCard({
    required this.myRank,
    required this.myPts,
    required this.entries,
    required this.totalNaira,
  });

  @override
  Widget build(BuildContext context) {
    if (myRank <= 5) {
      final prize = PrizePoolService.prizeForRank(myRank, totalNaira);
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        AppColors.correct.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(
              color: AppColors.correct.withOpacity(0.3)),
        ),
        child: Row(children: [
          const Text('🏆', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              prize > 0
                  ? 'You\'re in the prize zone! Keep playing to hold '
                    'rank #$myRank and win '
                    '${PrizePoolService.formatNaira(prize)} this week.'
                  : 'You\'re in the prize zone at rank #$myRank! '
                    'Hold your position.',
              style: const TextStyle(
                  color: AppColors.correct, fontSize: 13, height: 1.4),
            ),
          ),
        ]),
      );
    }

    const targetRank  = 5;
    final targetEntry = entries.firstWhere(
      (e) => e['rank'] == targetRank,
      orElse: () => {},
    );
    if (targetEntry.isEmpty) return const SizedBox.shrink();

    final targetPts = (targetEntry['weeklyPoints'] as int?) ?? 0;
    final gap       = targetPts - myPts;
    if (gap <= 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        AppColors.accent.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accent.withOpacity(0.3)),
      ),
      child: Row(children: [
        const Text('⚡', style: TextStyle(fontSize: 20)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'You\'re $gap pts away from winning real money '
            'this week. Play now.',
            style: const TextStyle(
                color: AppColors.accent, fontSize: 13, height: 1.4),
          ),
        ),
      ]),
    );
  }
}

// ─── Rival bottom-sheet launcher ─────────────────────────────────────────────
void _showRivalSheet(BuildContext context, Map<String, dynamic> rival) {
  showModalBottomSheet<void>(
    context:          context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder:          (_) => _RivalSheet(rival: rival),
  );
}

// ─── Weekly Row ───────────────────────────────────────────────────────────────
class _WeeklyRow extends StatelessWidget {
  final Map<String, dynamic> entry;
  final double?              prize;
  final double               totalNaira;
  final bool                 isRival;
  final VoidCallback?        onTap;
  /// Total number of players with weeklyPoints > 0 this week.
  /// 0 means not yet loaded — percentile chip is hidden.
  final int                  totalPlayers;

  const _WeeklyRow({
    required this.entry,
    required this.prize,
    required this.totalNaira,
    this.isRival      = false,
    this.onTap,
    this.totalPlayers = 0,
  });

  static const _rivalColour = Color(0xFFFF6B00);

  @override
  Widget build(BuildContext context) {
    final rank   = entry['rank']          as int?    ?? 0;
    final name   = entry['username']      as String? ?? 'Unknown';
    final pts    = entry['weeklyPoints']  as int?    ?? 0;
    final isMe   = entry['isCurrentUser'] == true;
    final inZone = rank <= 5 && totalNaira > 0;

    final container = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isRival
            ? _rivalColour.withOpacity(0.08)
            : isMe
                ? AppColors.primary.withOpacity(0.08)
                : inZone
                    ? AppColors.correct.withOpacity(0.04)
                    : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isRival
              ? _rivalColour.withOpacity(0.45)
              : isMe
                  ? AppColors.primary.withOpacity(0.4)
                  : inZone
                      ? AppColors.correct.withOpacity(0.2)
                      : AppColors.divider,
          width: (isRival || isMe) ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        // Rank
        SizedBox(
          width: 36,
          child: Text(
            rank <= 3
                ? PrizePoolService.rankEmoji(rank)
                : '#$rank',
            style: TextStyle(
              color: isRival
                  ? _rivalColour
                  : isMe
                      ? AppColors.primary
                      : AppColors.textMuted,
              fontSize:   rank <= 3 ? 18 : 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),

        // Avatar
        Container(
          width:  36,
          height: 36,
          decoration: BoxDecoration(
            color: isRival
                ? _rivalColour.withOpacity(0.18)
                : isMe
                    ? AppColors.primary.withOpacity(0.2)
                    : AppColors.surfaceAlt,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              name.isNotEmpty
                  ? name.substring(0, 1).toUpperCase()
                  : '?',
              style: TextStyle(
                color: isRival
                    ? _rivalColour
                    : isMe
                        ? AppColors.primary
                        : AppColors.textSecondary,
                fontWeight: FontWeight.w800,
                fontSize:   15,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),

        // Name + pts
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isRival) ...[
                    const Text('🔥',
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      isMe ? '$name (You)' : name,
                      style: TextStyle(
                        color: isRival
                            ? _rivalColour
                            : isMe
                                ? AppColors.primary
                                : AppColors.textPrimary,
                        fontSize:   14,
                        fontWeight: (isRival || isMe)
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Text(
                '$pts weekly pts',
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 11),
              ),
            ],
          ),
        ),

        // Rival badge
        if (isRival)
          Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(
                horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color:        _rivalColour.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _rivalColour.withOpacity(0.45)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('🔥', style: TextStyle(fontSize: 9)),
                SizedBox(width: 3),
                Text(
                  'RIVAL',
                  style: TextStyle(
                    color:         _rivalColour,
                    fontSize:      9,
                    fontWeight:    FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),

        // Prize badge (global tab only — when pool > 0 and rank ≤ 5)
        if (inZone && prize != null && prize! > 0)
          Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.correct.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppColors.correct.withOpacity(0.35)),
            ),
            child: Text(
              PrizePoolService.formatCompact(prize!),
              style: const TextStyle(
                color:      AppColors.correct,
                fontSize:   12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
      ]),
    );

    // ── Percentile chip (current user only, weeklyPoints > 0) ─────────────────
    // Shown as a small badge directly below the highlighted "You" row.
    // Only computed when totalPlayers > 0 (data loaded) and pts > 0
    // (user has competed this week).
    Widget? percentileChip;
    if (isMe && pts > 0 && totalPlayers > 0) {
      // percentile = floor position in the top-X% band.
      // rank 1/300 → top 1%; rank 30/300 → top 10%; rank 300/300 → top 99%.
      final rawPct  = (rank / totalPlayers * 100).ceil();
      final topPct  = (100 - rawPct).clamp(1, 99);
      percentileChip = _PercentileChip(topPercent: topPct);
    }

    // Rival row is tappable; all others are plain containers.
    Widget rowWidget;
    if (onTap != null) {
      rowWidget = Material(
        color:        Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap:        onTap,
          borderRadius: BorderRadius.circular(14),
          splashColor:  _rivalColour.withOpacity(0.12),
          child: container,
        ),
      );
    } else {
      rowWidget = container;
    }

    if (percentileChip != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          rowWidget,
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: percentileChip,
          ),
        ],
      );
    }
    return rowWidget;
  }
}
// ─── Percentile Chip (Stage 19) ───────────────────────────────────────────────
/// Small badge shown below the current user's highlighted row.
/// Displays "You are in the top X% this week." clamped to [1, 99] so we
/// never show "Top 0%" (impossible) or "Top 100%" (hasn't competed).
class _PercentileChip extends StatelessWidget {
  final int topPercent;
  const _PercentileChip({required this.topPercent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        AppColors.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(
            color: AppColors.primary.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bar_chart_rounded,
              color: AppColors.primary, size: 13),
          const SizedBox(width: 5),
          Text(
            'You are in the top $topPercent% this week',
            style: const TextStyle(
              color:      AppColors.primary,
              fontSize:   11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Rival Bottom Sheet ───────────────────────────────────────────────────────
/// Modal bottom sheet shown when the user taps the Rival's row.
/// Displays the rival's profile at a glance and offers a direct
/// "Challenge Rival" shortcut that pre-fills opponentUid / opponentUsername
/// on [AnimeSelectPage] so the challenge is automatically directed at them.
class _RivalSheet extends StatelessWidget {
  final Map<String, dynamic> rival;
  const _RivalSheet({required this.rival});

  static const _rivalColour = Color(0xFFFF6B00);

  @override
  Widget build(BuildContext context) {
    final username   = (rival['username']     as String?) ?? 'Anonymous';
    final university = (rival['university']   as String?) ?? '';
    final pts        = (rival['weeklyPoints'] as int?)    ?? 0;
    final uid        = (rival['uid']          as String?) ?? '';

    return Container(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24,
          32 + MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ────────────────────────────────────────────────
          Container(
            width:  40,
            height: 4,
            decoration: BoxDecoration(
              color:        AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // ── Flame avatar ───────────────────────────────────────────────
          Container(
            width:  72,
            height: 72,
            decoration: BoxDecoration(
              color:  _rivalColour.withOpacity(0.12),
              shape:  BoxShape.circle,
              border: Border.all(
                  color: _rivalColour.withOpacity(0.4), width: 2),
            ),
            child: const Center(
              child: Text('🔥', style: TextStyle(fontSize: 34)),
            ),
          ),
          const SizedBox(height: 12),

          // ── RIVAL badge ────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color:        _rivalColour.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _rivalColour.withOpacity(0.45)),
            ),
            child: const Text(
              'YOUR RIVAL',
              style: TextStyle(
                color:         _rivalColour,
                fontSize:      11,
                fontWeight:    FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Username ───────────────────────────────────────────────────
          Text(
            username,
            style: const TextStyle(
              color:      AppColors.textPrimary,
              fontSize:   22,
              fontWeight: FontWeight.w900,
            ),
            textAlign: TextAlign.center,
          ),

          // ── University (if set) ────────────────────────────────────────
          if (university.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              university,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 14),
            ),
          ],
          const SizedBox(height: 6),

          // ── Weekly points ──────────────────────────────────────────────
          Text(
            '$pts weekly pts',
            style: const TextStyle(
                color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 28),

          // ── Challenge button ───────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding:         const EdgeInsets.symmetric(vertical: 16),
                elevation:       0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () {
                Navigator.pop(context); // close the sheet first
                // AnimeSelectPage has no opponent params — it uses an
                // onSelect callback instead.  When the user picks an anime
                // the callback fires (page has already popped itself), so
                // we push StakeScreen from the caller's context with the
                // opponent pre-filled.  The FadeTransition mirrors the
                // transition AnimeSelectPage itself uses for StakeScreen.
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AnimeSelectPage(
                      onSelect: (animeTitle) => Navigator.push(
                        context,
                        PageRouteBuilder<void>(
                          pageBuilder: (_, a, __) => FadeTransition(
                            opacity: a,
                            child: StakeScreen(
                              animeTitle:       animeTitle,
                              opponentUid:      uid,
                              opponentUsername: username,
                            ),
                          ),
                          transitionDuration:
                              const Duration(milliseconds: 300),
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: const Text(
                '⚔️  Challenge Rival',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}