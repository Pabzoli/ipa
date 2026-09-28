// lib/features/leaderboard/weekly_leaderboard_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/prize_pool_service.dart';
import '../admin/admin_payout_service.dart';
import '../prizes/payout_claim_page.dart';
import '../../core/providers/user_data_provider.dart';
import '../../features/auth/auth_service.dart';
import '../../features/multiplayer/anime_select_page.dart';

class WeeklyLeaderboardPage extends StatefulWidget {
  final int initialTab;
  const WeeklyLeaderboardPage({super.key, this.initialTab = 0});

  @override
  State<WeeklyLeaderboardPage> createState() => _WeeklyLeaderboardPageState();
}

class _WeeklyLeaderboardPageState extends State<WeeklyLeaderboardPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  Timer? _countdownTimer;
  Duration _timeLeft = PrizePoolService.timeUntilReset();

  // All reassignable (NOT late final): sources switch when the entry week
  // loads late, the account changes, the campus is picked in-tab, or the
  // weekly prize-pool doc rolls over on Monday.
  Stream<Map<String, dynamic>> _prizePoolStream =
      FirestoreService.instance.prizePoolStream();
  Stream<List<Map<String, dynamic>>> _weeklyLbStream =
      FirestoreService.instance.emptyBoardStream();
  Stream<List<Map<String, dynamic>>>? _campusLbStream;

  String? _userUniversity;
  bool _universityLoaded = false;

  // Keys guard stream creation so provider rebuilds (points ticking,
  // entry week loading late) don't resubscribe the boards needlessly.
  String? _boardKey;
  String? _campusKey;
  String? _poolKey;

  @override
  void initState() {
    super.initState();

    _tabCtrl = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab,
    );

    _poolKey = FirestoreService.currentWeekId();
    _ensureBoardStreams();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _timeLeft = PrizePoolService.timeUntilReset());
    });

    _loadUserUniversity();
  }

  // Last entry week observed in didChangeDependencies. Stashed in a field
  // so async callbacks (e.g. _loadUserUniversity after an await, when this
  // State may already be deactivated) never touch context/ancestors.
  String _lastProviderWeek = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // watch (not read) so this re-runs when UserDataProvider finishes
    // loading the entry week after first build.
    final userData = context.watch<UserDataProvider>();
    _lastProviderWeek = userData.leaderboardEntryWeekId ?? '';
    _applyBoardStreams(
      admin: isAdminUid(),
      week: _lastProviderWeek,
      uni: _userUniversity ?? '',
      notify: true,
    );
  }

  /// Picks the board streams the signed-in user may read under the `users`
  /// rule: the unfiltered board for the payout admin, the same-week cohort
  /// board for everyone else (empty stream for non-entrants — the page
  /// merges their own doc client-side for the "your position" card).
  void _ensureBoardStreams() {
    // initState path: watch is forbidden here, so seed defaults; the
    // didChangeDependencies path above converges once provider data lands.
    _applyBoardStreams(
      admin: isAdminUid(),
      week: '',
      uni: _userUniversity ?? '',
      notify: false,
    );
  }

  void _applyBoardStreams({
    required bool admin,
    required String week,
    required String uni,
    required bool notify,
  }) {
    var changed = false;

    // Prize-pool doc rolls over every Monday: track it independently so the
    // header never sticks to last week's pool.
    final poolKey = FirestoreService.currentWeekId();
    if (poolKey != _poolKey) {
      _poolKey = poolKey;
      _prizePoolStream = FirestoreService.instance.prizePoolStream();
      changed = true;
    }

    final boardKey = '${admin}_$week';
    if (boardKey != _boardKey) {
      _boardKey = boardKey;
      _weeklyLbStream = admin
          ? FirestoreService.instance.weeklyLeaderboardStream()
          : FirestoreService.instance
              .eligibleWeeklyLeaderboardStream(week);
      changed = true;
    }

    if (uni.isNotEmpty) {
      final campusKey = '${admin}_${uni}_$week';
      if (campusKey != _campusKey) {
        _campusKey = campusKey;
        _campusLbStream = FirestoreService.instance
            .weeklyCampusLeaderboardStream(uni,
                entryWeekId: admin ? '' : week, includeAll: admin);
        changed = true;
      }
    } else if (_campusLbStream != null) {
      _campusLbStream = null;
      _campusKey = null;
      changed = true;
    }

    if (changed && notify && mounted) setState(() {});
  }

  Future<void> _loadUserUniversity() async {
    // Capture the admin flag BEFORE the await (context-free). Everything
    // else comes from stashed fields: after an async gap this State may be
    // deactivated, and any ancestor lookup (context.read/watch) throws.
    final admin = isAdminUid();
    try {
      final uni = await FirestoreService.instance.getCurrentUserUniversity();
      if (!mounted) return;

      setState(() {
        _userUniversity = uni ?? '';
        _universityLoaded = true;
      });
      // Creates the campus stream with the cohort constraint applied.
      // notify: university load completes after first build, so the campus
      // tab needs an explicit rebuild to pick the stream up.
      _applyBoardStreams(
        admin: admin,
        week: _lastProviderWeek,
        uni: _userUniversity ?? '',
        notify: true,
      );
    } catch (_) {
      // Never leave the campus tab on an infinite spinner: a failed read
      // (offline / permission) still unblocks the UI, which then offers the
      // in-tab campus picker.
      if (!mounted) return;
      setState(() {
        _userUniversity = _userUniversity ?? '';
        _universityLoaded = true;
      });
    }
  }

  /// Called by the in-tab campus picker after a successful save.
  void _onUniversitySaved(String uni) {
    _userUniversity = uni;
    _universityLoaded = true;
    _applyBoardStreams(
      admin: isAdminUid(),
      week: _lastProviderWeek,
      uni: uni,
      notify: true,
    );
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
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Header ─────────────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 4.r),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      'Rankings',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 26.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                        height: 1.05,
                      ),
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: 10.r, vertical: 5.r),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20.r),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt_rounded,
                            color: AppColors.accent, size: 12.r),
                        SizedBox(width: 4.w),
                        Text(
                          '$myWeeklyPts pts',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 11.sp,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Tabs ───────────────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
              child: _RankingTabs(controller: _tabCtrl),
            ),

            SizedBox(height: 4.h),

            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  _GlobalTab(
                    prizePoolStream: _prizePoolStream,
                    weeklyLbStream: _weeklyLbStream,
                    timeLeft: _timeLeft,
                    myWeeklyPts: myWeeklyPts,
                  ),
                  _CampusTab(
                    campusLbStream: _campusLbStream,
                    university: _userUniversity,
                    universityLoaded: _universityLoaded,
                    onUniversitySaved: _onUniversitySaved,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tab Bar ────────────────────────────────────────────────────────────────
class _RankingTabs extends StatelessWidget {
  final TabController controller;
  const _RankingTabs({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: EdgeInsets.all(3.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: TabBar(
        controller: controller,
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: EdgeInsets.zero,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: AppColors.textMuted,
        labelStyle: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w800),
        unselectedLabelStyle:
            TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700),
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicator: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(11.r),
        ),
        tabs: const [
          Tab(text: 'Global'),
          Tab(text: 'My Campus'),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLOBAL TAB
// ═══════════════════════════════════════════════════════════════════════════
class _GlobalTab extends StatefulWidget {
  final Stream<Map<String, dynamic>> prizePoolStream;
  final Stream<List<Map<String, dynamic>>> weeklyLbStream;
  final Duration timeLeft;
  final int myWeeklyPts;

  const _GlobalTab({
    required this.prizePoolStream,
    required this.weeklyLbStream,
    required this.timeLeft,
    required this.myWeeklyPts,
  });

  @override
  State<_GlobalTab> createState() => _GlobalTabState();
}

class _GlobalTabState extends State<_GlobalTab>
    with AutomaticKeepAliveClientMixin {
  // Plain reassignable future (NOT late): refreshed when the entry week
  // loads. Reassigning a late variable throws LateInitializationError.
  Future<int> _totalPlayersFuture = Future.value(0);
  String? _playersWeek;

  // Keeps the board subscriptions alive across Global ↔ Campus switches.
  // Without it, TabBarView disposes this subtree on switch; the recreated
  // StreamBuilder re-listens to the shared broadcast streams, which replay
  // nothing — leaving Global empty and Campus spinning until the next
  // Firestore push.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Seed default; didChangeDependencies converges once the entry week
    // loads (watch is forbidden in initState).
    _playersWeek = '';
    _totalPlayersFuture =
        FirestoreService.instance.getWeeklyPlayerCount(entryWeekId: '');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // watch (not read) so the count refreshes when the entry week lands.
    final week =
        context.watch<UserDataProvider>().leaderboardEntryWeekId ?? '';
    if (week == _playersWeek) return;
    _playersWeek = week;
    _totalPlayersFuture =
        FirestoreService.instance.getWeeklyPlayerCount(entryWeekId: week);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<int>(
      future: _totalPlayersFuture,
      builder: (context, totalSnap) {
        final totalPlayers = totalSnap.data ?? 0;

        return StreamBuilder<Map<String, dynamic>>(
          stream: widget.prizePoolStream,
          builder: (context, poolSnap) {
            final pool = poolSnap.data ?? <String, dynamic>{};
            final totalNaira = (pool['totalNaira'] as num?)?.toDouble() ?? 0;
            final prizes = PrizePoolService.calculatePrizes(totalNaira);

            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: widget.weeklyLbStream,
              builder: (context, lbSnap) {
                if (lbSnap.connectionState == ConnectionState.waiting &&
                    poolSnap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  );
                }

                final entries = lbSnap.data ?? <Map<String, dynamic>>[];
                final currentWeekId = FirestoreService.currentWeekId();
                final isCurrentEligible =
                    context.watch<UserDataProvider>().isLeaderboardEligible;
                bool entryEligible(Map<String, dynamic> e) =>
                    e['leaderboardEntryWeekId'] == currentWeekId;

                final top3 = entries
                    .where((e) =>
                        (e['rank'] as int?) != null &&
                        (e['rank'] as int) <= 3)
                    .toList();
                final rest = entries
                    .where((e) =>
                        (e['rank'] as int?) == null ||
                        (e['rank'] as int) > 3)
                    .toList();

                Map<String, dynamic>? myEntry;
                Map<String, dynamic>? rivalEntry;
                int myRank = -1;

                for (final e in entries) {
                  if (e['isCurrentUser'] == true) {
                    myEntry = e;
                    myRank = e['rank'] as int? ?? -1;
                    break;
                  }
                }

                // Cohort boards omit non-entrants by rule: fall back to local
                // data so the user still sees their points plus the entry
                // CTA (handled by _YourPosition's !isEligible branch).
                final Map<String, dynamic> myCard = myEntry ??
                    {
                      'rank': null,
                      'uid':
                          AuthService.instance.currentUser?.uid ?? '',
                      'username': AuthService.instance.currentUser
                              ?.displayName ??
                          'You',
                      'weeklyPoints': widget.myWeeklyPts,
                      'isCurrentUser': true,
                      'leaderboardEntryWeekId': null,
                    };

                if (myRank > 1) {
                  for (final e in entries) {
                    if ((e['rank'] as int?) == myRank - 1) {
                      rivalEntry = e;
                      break;
                    }
                  }
                }

                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding:
                            EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
                        child: _PoolSummary(
                          totalNaira: totalNaira,
                          prizes: prizes,
                          timeLeft: widget.timeLeft,
                        ),
                      ),
                    ),
                    // Winner payout state (Phase 3): shows ONLY cycles where
                    // the signed-in user is in leaderboardCycles.ranked[].
                    // "Paid" is shown only when ranked[].paid == true.
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding:
                            EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: _MyPrizesBanner(),
                      ),
                    ),
                    // Skip the "your position" card when the board is empty
                    // and the user hasn't entered: _BoardEmptyState already
                    // renders the same pay-to-enter CTA, so showing both
                    // produced two "Buy leaderboard entry · ₦500" buttons.
                    if (entries.isNotEmpty || isCurrentEligible)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding:
                              EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
                          child: _YourPosition(
                            entry: myCard,
                            totalPlayers: totalPlayers,
                            isEligible: isCurrentEligible,
                            onBuyPressed: () => _showPurchaseSheet(context),
                          ),
                        ),
                      ),
                    if (top3.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding:
                              EdgeInsets.fromLTRB(20.r, 22.r, 20.r, 0.r),
                          child: const _SectionHeader(
                            icon: Icons.emoji_events_rounded,
                            title: 'Top players',
                            color: Color(0xFFFFD700),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding:
                              EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
                          child: _TopThree(
                            entries: top3,
                            prizes: prizes,
                            rivalEntry: rivalEntry,
                            isEligible: entryEligible,
                            onRivalTap: (entry) =>
                                _showRivalSheet(context, entry),
                          ),
                        ),
                      ),
                    ],
                    if (rest.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding:
                              EdgeInsets.fromLTRB(20.r, 22.r, 20.r, 12.r),
                          child: const _SectionHeader(
                            icon: Icons.format_list_numbered_rounded,
                            title: 'Leaderboard',
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 32.r),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (_, i) {
                              final e = rest[i];
                              final isRival = rivalEntry != null &&
                                  e['uid'] == rivalEntry!['uid'];
                              return Padding(
                                padding: EdgeInsets.only(
                                    bottom: i == rest.length - 1 ? 0 : 8.r),
                                child: _RankRow(
                                  entry: e,
                                  prize: prizes[e['rank']],
                                  isRival: isRival,
                                  isEligible: entryEligible(e),
                                  onTap: isRival
                                      ? () => _showRivalSheet(context, e)
                                      : null,
                                ),
                              );
                            },
                            childCount: rest.length,
                          ),
                        ),
                      ),
                    ],
                    if (entries.isEmpty)
                      SliverFillRemaining(
                        child: _BoardEmptyState(
                          isEligible: isCurrentEligible,
                          isAdmin: isAdminUid(),
                          onBuyPressed: () =>
                              _showPurchaseSheet(context),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

// ─── Section header (icon + title) ─────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 26.r,
          height: 26.r,
          decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(8.r),
          ),
          child: Icon(icon, color: color, size: 15.r),
        ),
        SizedBox(width: 9.w),
        Text(
          title,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}

// ─── Prize Pool Card ────────────────────────────────────────────────────────
class _PoolSummary extends StatelessWidget {
  final double totalNaira;
  final Map<int, double> prizes;
  final Duration timeLeft;

  const _PoolSummary({
    required this.totalNaira,
    required this.prizes,
    required this.timeLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row: label + countdown ─────────────────────────────
          Row(
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 8.r, vertical: 3.r),
                decoration: BoxDecoration(
                  color: AppColors.secondary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6.r),
                ),
                child: Text(
                  'THIS WEEK',
                  style: TextStyle(
                    color: AppColors.secondary,
                    fontSize: 9.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 9.r, vertical: 4.r),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20.r),
                  border: Border.all(
                    color: AppColors.accent.withOpacity(0.28),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule_rounded,
                        color: AppColors.accent, size: 11.r),
                    SizedBox(width: 4.w),
                    Text(
                      PrizePoolService.formatCountdown(timeLeft),
                      style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12.h),

          // ── Big prize amount ──────────────────────────────────────────
          Text(
            'WEEKLY PRIZE POOL',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            totalNaira > 0 ? PrizePoolService.formatNaira(totalNaira) : '₦—',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 34.sp,
              fontWeight: FontWeight.w900,
              height: 1.0,
              letterSpacing: -1.0,
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            'Top 5 players share the pool.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.sp,
            ),
          ),
          SizedBox(height: 2.h),
          Text(
            'Week of ${FirestoreService.currentWeekId()}',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 16.h),

          // ── Divider ───────────────────────────────────────────────────
          Container(
            height: 1,
            color: AppColors.divider,
          ),
          SizedBox(height: 14.h),

          // ── Rank distribution row ────────────────────────────────────
          Row(
            children: List.generate(5, (i) {
              final rank = i + 1;
              final amount = prizes[rank] ?? 0;
              return Expanded(
                child: _PrizeSlot(
                  rank: rank,
                  amount: amount,
                  fallbackPercent:
                      ['40%', '25%', '15%', '10%', '10%'][i],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _PrizeSlot extends StatelessWidget {
  final int rank;
  final double amount;
  final String fallbackPercent;

  const _PrizeSlot({
    required this.rank,
    required this.amount,
    required this.fallbackPercent,
  });

  Color _rankColor() {
    switch (rank) {
      case 1:
        return const Color(0xFFFFD700);
      case 2:
        return const Color(0xFFC0C0C0);
      case 3:
        return const Color(0xFFCD7F32);
      default:
        return AppColors.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _rankColor();
    return Column(
      children: [
        Container(
          width: 24.r,
          height: 24.r,
          decoration: BoxDecoration(
            color: color.withOpacity(rank <= 3 ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(7.r),
          ),
          alignment: Alignment.center,
          child: Text(
            '$rank',
            style: TextStyle(
              color: color,
              fontSize: 11.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        SizedBox(height: 5.h),
        Text(
          amount > 0
              ? PrizePoolService.formatCompact(amount)
              : fallbackPercent,
          style: TextStyle(
            color: rank <= 3 ? color : AppColors.textSecondary,
            fontSize: 10.sp,
            fontWeight: FontWeight.w900,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

// ─── Your Position Card ─────────────────────────────────────────────────────
class _YourPosition extends StatelessWidget {
  final Map<String, dynamic> entry;
  final int totalPlayers;
  final bool isEligible;
  final VoidCallback onBuyPressed;

  const _YourPosition({
    required this.entry,
    required this.totalPlayers,
    required this.isEligible,
    required this.onBuyPressed,
  });

  @override
  Widget build(BuildContext context) {
    final rank = entry['rank'] as int? ?? 0;
    final pts = entry['weeklyPoints'] as int? ?? 0;
    final name = entry['username'] as String? ?? 'You';

    String suffix = '';
    if (totalPlayers > 1 && rank > 0) {
      final topPercent =
          ((rank / totalPlayers) * 100).ceil().clamp(1, 99);
      suffix = 'Top $topPercent%';
    }

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.primary.withOpacity(0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Rank badge
              Container(
                width: 44.r,
                height: 44.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(12.r),
                ),
                child: Text(
                  rank > 0 ? '#$rank' : '#—',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 16.sp,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
              SizedBox(width: 12.w),

              // Name · pts · suffix
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.2,
                              height: 1.15,
                            ),
                          ),
                        ),
                        SizedBox(width: 6.w),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 6.r, vertical: 2.r),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.14),
                            borderRadius: BorderRadius.circular(5.r),
                          ),
                          child: Text(
                            'YOU',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 8.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      suffix.isEmpty
                          ? '$pts pts this week'
                          : '$pts pts · $suffix',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),

              Icon(Icons.insights_rounded,
                  color: AppColors.primary, size: 20.r),
            ],
          ),
          if (!isEligible) ...[
            SizedBox(height: 12.h),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: 10.r, vertical: 8.r),
              decoration: BoxDecoration(
                color: AppColors.secondary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(
                  color: AppColors.secondary.withOpacity(0.24),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: AppColors.secondary, size: 14.r),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(
                      "You're not eligible for prizes this week",
                      style: TextStyle(
                        color: AppColors.secondary,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 10.h),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: ElevatedButton(
                onPressed: onBuyPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11.r),
                  ),
                ),
                child: Text(
                  'Buy leaderboard entry · ₦500',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Top Three (left-to-right, equal height) ─────────────────────────────
class _TopThree extends StatelessWidget {
  final List<Map<String, dynamic>> entries;
  final Map<int, double> prizes;
  final Map<String, dynamic>? rivalEntry;
  final bool Function(Map<String, dynamic>) isEligible;
  final ValueChanged<Map<String, dynamic>> onRivalTap;

  const _TopThree({
    required this.entries,
    required this.prizes,
    required this.isEligible,
    required this.onRivalTap,
    this.rivalEntry,
  });

  @override
  Widget build(BuildContext context) {
    // Order strictly by rank: #1, #2, #3 left-to-right.
    final sorted = [...entries]..sort((a, b) =>
        ((a['rank'] as int?) ?? 99).compareTo((b['rank'] as int?) ?? 99));

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < sorted.length; i++) ...[
            if (i > 0) SizedBox(width: 8.w),
            Expanded(
              child: _PodiumCard(
                entry: sorted[i],
                prize: prizes[sorted[i]['rank']],
                isRival: rivalEntry?['uid'] == sorted[i]['uid'],
                isEligible: isEligible(sorted[i]),
                onTap: rivalEntry?['uid'] == sorted[i]['uid']
                    ? () => onRivalTap(sorted[i])
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PodiumCard extends StatelessWidget {
  final Map<String, dynamic> entry;
  final double? prize;
  final bool isRival;
  final bool isEligible;
  final VoidCallback? onTap;

  const _PodiumCard({
    required this.entry,
    required this.prize,
    required this.isRival,
    required this.isEligible,
    this.onTap,
  });

  Color _rankColor() {
    switch (entry['rank'] as int? ?? 0) {
      case 1:
        return const Color(0xFFFFD700);
      case 2:
        return const Color(0xFFC0C0C0);
      default:
        return const Color(0xFFCD7F32);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rank = entry['rank'] as int? ?? 0;
    final name = entry['username'] as String? ?? '?';
    final pts = entry['weeklyPoints'] as int? ?? 0;
    final isMe = entry['isCurrentUser'] == true;
    final rankColor = _rankColor();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 14.r),
        decoration: BoxDecoration(
          color: isMe
              ? AppColors.primary.withOpacity(0.08)
              : rankColor.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(
            color: isMe
                ? AppColors.primary.withOpacity(0.35)
                : rankColor.withOpacity(0.35),
          ),
        ),
        child: Opacity(
          opacity: isEligible ? 1 : 0.5,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Rank badge
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 7.r, vertical: 2.r),
                decoration: BoxDecoration(
                  color: rankColor.withOpacity(0.20),
                  borderRadius: BorderRadius.circular(20.r),
                ),
                child: Text(
                  '#$rank',
                  style: TextStyle(
                    color: rankColor,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              SizedBox(height: 10.h),

              // Avatar
              Container(
                width: 48.r,
                height: 48.r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: rankColor.withOpacity(0.14),
                  border: Border.all(
                    color: rankColor.withOpacity(0.45),
                    width: 1.5,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(
                    color: rankColor,
                    fontSize: 20.sp,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
              SizedBox(height: 8.h),

              // Name
              Text(
                isMe ? 'You' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isMe ? AppColors.primary : AppColors.textPrimary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.1,
                ),
              ),
              SizedBox(height: 3.h),

              // Points
              Text(
                '$pts pts',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),

              // Prize / status
              if (isEligible && prize != null && prize! > 0) ...[
                SizedBox(height: 8.h),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: 8.r, vertical: 3.r),
                  decoration: BoxDecoration(
                    color: rankColor.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(20.r),
                  ),
                  child: Text(
                    PrizePoolService.formatCompact(prize!),
                    style: TextStyle(
                      color: rankColor,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
              if (!isEligible) ...[
                SizedBox(height: 6.h),
                Text(
                  'NO ENTRY',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 8.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
              if (isRival) ...[
                SizedBox(height: 6.h),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: 6.r, vertical: 2.r),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B00).withOpacity(0.14),
                    borderRadius: BorderRadius.circular(6.r),
                  ),
                  child: Text(
                    'RIVAL',
                    style: TextStyle(
                      color: const Color(0xFFFF6B00),
                      fontSize: 8.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Rank Row ───────────────────────────────────────────────────────────────
class _RankRow extends StatelessWidget {
  final Map<String, dynamic> entry;
  final double? prize;
  final bool isRival;
  final bool isEligible;
  final VoidCallback? onTap;

  const _RankRow({
    required this.entry,
    required this.prize,
    this.isRival = false,
    this.isEligible = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rank = entry['rank'] as int? ?? 0;
    final name = entry['username'] as String? ?? 'Unknown';
    final pts = entry['weeklyPoints'] as int? ?? 0;
    final isMe = entry['isCurrentUser'] == true;

    const rivalColor = Color(0xFFFF6B00);

    final accentColor = isRival
        ? rivalColor
        : isMe
            ? AppColors.primary
            : AppColors.textPrimary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
        decoration: BoxDecoration(
          color: isRival
              ? rivalColor.withOpacity(0.06)
              : isMe
                  ? AppColors.primary.withOpacity(0.06)
                  : AppColors.surface,
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(
            color: isRival
                ? rivalColor.withOpacity(0.28)
                : isMe
                    ? AppColors.primary.withOpacity(0.28)
                    : AppColors.divider,
          ),
        ),
        child: Opacity(
          opacity: isEligible ? 1 : 0.55,
          child: Row(
            children: [
              // Rank badge
              Container(
                width: 34.r,
                height: 34.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Text(
                  rank > 0 ? '$rank' : '—',
                  style: TextStyle(
                    color: accentColor,
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
              SizedBox(width: 11.w),

              // Name + points
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: accentColor,
                              fontSize: 13.sp,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.1,
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (isMe) ...[
                          SizedBox(width: 5.w),
                          Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: 5.r, vertical: 1.r),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(4.r),
                            ),
                            child: Text(
                              'YOU',
                              style: TextStyle(
                                color: AppColors.primary,
                                fontSize: 7.sp,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                        if (isRival) ...[
                          SizedBox(width: 5.w),
                          Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: 5.r, vertical: 1.r),
                            decoration: BoxDecoration(
                              color: rivalColor.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(4.r),
                            ),
                            child: Text(
                              'RIVAL',
                              style: TextStyle(
                                color: rivalColor,
                                fontSize: 7.sp,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      '$pts weekly pts',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),

              // Prize / status
              if (!isEligible)
                Text(
                  'No entry',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else if (prize != null && prize! > 0)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: 8.r, vertical: 4.r),
                  decoration: BoxDecoration(
                    color: AppColors.correct.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(
                    PrizePoolService.formatCompact(prize!),
                    style: TextStyle(
                      color: AppColors.correct,
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Board empty state ──────────────────────────────────────────────────────
// An empty cohort board means different things: for the admin (or the lone
// entrant) nobody has entered yet; for a non-entrant it means they haven't
// paid — so show the pay-to-enter CTA, never "no one has entered".
class _BoardEmptyState extends StatelessWidget {
  final bool isEligible;
  final bool isAdmin;
  final VoidCallback onBuyPressed;

  const _BoardEmptyState({
    required this.isEligible,
    required this.isAdmin,
    required this.onBuyPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (isEligible || isAdmin) return const _EmptyRankings();

    // Scrollable: on small screens the icon + copy + CTA exceed the
    // remaining viewport (seen as a 39px RenderFlex overflow in logs).
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: 32.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80.r,
              height: 80.r,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.divider),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.lock_outline_rounded,
                  color: AppColors.accent, size: 36.r),
            ),
            SizedBox(height: 16.h),
            Text(
              'Pay to enter the leaderboard',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6.h),
            Text(
              'Only paid players appear here. Buy your entry to compete for this week\u2019s prize pool.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.sp,
                height: 1.4,
              ),
            ),
            SizedBox(height: 16.h),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: ElevatedButton(
                onPressed: onBuyPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11.r),
                  ),
                ),
                child: Text(
                  'Buy leaderboard entry · ₦500',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
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

// ─── Empty rankings ─────────────────────────────────────────────────────────
class _EmptyRankings extends StatelessWidget {
  const _EmptyRankings();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80.r,
              height: 80.r,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.divider),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.emoji_events_outlined,
                  color: AppColors.textMuted, size: 36.r),
            ),
            SizedBox(height: 16.h),
            Text(
              'No players yet',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6.h),
            Text(
              'Be the first on the leaderboard this week.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.sp,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CAMPUS TAB
// ═══════════════════════════════════════════════════════════════════════════
class _CampusTab extends StatefulWidget {
  final Stream<List<Map<String, dynamic>>>? campusLbStream;
  final String? university;
  final bool universityLoaded;
  final ValueChanged<String> onUniversitySaved;

  const _CampusTab({
    required this.campusLbStream,
    required this.university,
    required this.universityLoaded,
    required this.onUniversitySaved,
  });

  @override
  State<_CampusTab> createState() => _CampusTabState();
}

class _CampusTabState extends State<_CampusTab>
    with AutomaticKeepAliveClientMixin {
  String? _picked;
  bool _saving = false;

  // Keeps this tab's State (and its stream subscription) alive when the
  // user switches Global ↔ Campus. Without it, TabBarView disposes the
  // off-screen tab; on return the StreamBuilder resubscribes and the board
  // sits empty/loading until the next Firestore push.
  @override
  bool get wantKeepAlive => true;

  Future<void> _save() async {
    final picked = _picked;
    if (picked == null || _saving) return;
    setState(() => _saving = true);
    try {
      await FirestoreService.instance.updateUniversity(picked);
      if (!mounted) return;
      setState(() => _saving = false);
      widget.onUniversitySaved(picked);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save campus — please try again.'),
          backgroundColor: AppColors.wrong,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (!widget.universityLoaded) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    final university = widget.university;
    if (university == null || university.isEmpty) {
      return _CampusPicker(
        picked: _picked,
        saving: _saving,
        onChanged: (v) => setState(() => _picked = v),
        onSave: _save,
      );
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: widget.campusLbStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        if (snap.hasError) {
          return _CampusIndexError(error: snap.error.toString());
        }

        final entries = snap.data ?? <Map<String, dynamic>>[];

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
                child: _CampusHeader(university: university),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 20.r, 20.r, 12.r),
                child: const _SectionHeader(
                  icon: Icons.school_rounded,
                  title: 'Campus leaderboard',
                  color: AppColors.secondary,
                ),
              ),
            ),
            if (entries.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32.r),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 80.r,
                          height: 80.r,
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.divider),
                          ),
                          alignment: Alignment.center,
                          child: Icon(Icons.school_outlined,
                              color: AppColors.textMuted, size: 36.r),
                        ),
                        SizedBox(height: 16.h),
                        Text(
                          'No players from your campus yet',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15.sp,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 6.h),
                        Text(
                          'Play and be the first!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12.sp,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 32.r),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => Padding(
                      padding: EdgeInsets.only(
                          bottom: i == entries.length - 1 ? 0 : 8.r),
                      child: _RankRow(
                        entry: entries[i],
                        prize: null,
                      ),
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

class _CampusHeader extends StatelessWidget {
  final String university;
  const _CampusHeader({required this.university});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 44.w,
            height: 44.h,
            decoration: BoxDecoration(
              color: AppColors.secondary.withOpacity(0.14),
              borderRadius: BorderRadius.circular(12.r),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.school_rounded,
                color: AppColors.secondary, size: 22.r),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'YOUR CAMPUS',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 9.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.9,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  university,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Campus picker (shown instead of a board until a campus is chosen) ──────
class _CampusPicker extends StatelessWidget {
  final String? picked;
  final bool saving;
  final ValueChanged<String?> onChanged;
  final VoidCallback onSave;

  const _CampusPicker({
    required this.picked,
    required this.saving,
    required this.onChanged,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: 32.r, vertical: 24.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.center,
              child: Container(
                width: 80.r,
                height: 80.r,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.divider),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.school_rounded,
                    color: AppColors.secondary, size: 36.r),
              ),
            ),
            SizedBox(height: 16.h),
            Text(
              'Pick your campus',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6.h),
            Text(
              'Choose your university to see how your school ranks against '
              'rivals across Nigeria.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.sp,
                height: 1.45,
              ),
            ),
            SizedBox(height: 20.h),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 14.r),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(color: AppColors.divider),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: picked,
                  isExpanded: true,
                  dropdownColor: AppColors.surface,
                  icon: Icon(Icons.expand_more_rounded,
                      color: AppColors.textMuted, size: 20.r),
                  hint: Text(
                    'Select your university',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 14.sp),
                  ),
                  style:
                      TextStyle(color: AppColors.textPrimary, fontSize: 14.sp),
                  items: kNigerianUniversities
                      .map((u) => DropdownMenuItem(
                            value: u,
                            child: Text(u,
                                style: const TextStyle(
                                    color: AppColors.textPrimary)),
                          ))
                      .toList(),
                  onChanged: saving ? null : onChanged,
                ),
              ),
            ),
            SizedBox(height: 14.h),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: ElevatedButton(
                onPressed: (picked == null || saving) ? null : onSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11.r),
                  ),
                ),
                child: saving
                    ? SizedBox(
                        width: 18.w,
                        height: 18.h,
                        child: const CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        'Save campus',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
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

class _CampusIndexError extends StatelessWidget {
  final String error;
  const _CampusIndexError({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72.r,
              height: 72.r,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.divider),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.build_outlined,
                  color: AppColors.accent, size: 30.r),
            ),
            SizedBox(height: 16.h),
            Text(
              'Campus ranking unavailable',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6.h),
            Text(
              'A Firestore composite index is required for this leaderboard.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.sp,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHEETS
// ═══════════════════════════════════════════════════════════════════════════
void _showRivalSheet(BuildContext context, Map<String, dynamic> rival) {
  final currentUid = FirestoreService.instance.currentUid;
  if (currentUid == null) return;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RivalSheet(
      rival: rival,
      currentUid: currentUid,
    ),
  );
}

void _showPurchaseSheet(BuildContext context) {
  // Leaderboard entry is sold on the website shop only (Play Billing policy:
  // no external-payment path may be reachable from the Play-distributed
  // Android app). On non-web platforms the purchase sheet is never opened.
  if (!kIsWeb) return;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _LeaderboardPurchaseSheet(),
  );
}

// ─── Purchase Sheet ─────────────────────────────────────────────────────────
class _LeaderboardPurchaseSheet extends StatefulWidget {
  const _LeaderboardPurchaseSheet();

  @override
  State<_LeaderboardPurchaseSheet> createState() =>
      _LeaderboardPurchaseSheetState();
}

class _LeaderboardPurchaseSheetState extends State<_LeaderboardPurchaseSheet> {
  bool _opening = false;
  bool _autoDismissed = false;
  static const _paymentEndpoint =
      'https://us-central1-anime-quiz-1ab1b.cloudfunctions.net/requestPaymentLink';

  Future<void> _buy() async {
    if (_opening) return;
    // Defensive: the sheet is only ever shown on web (see _showPurchaseSheet),
    // but never call the payment endpoint from a non-web build regardless.
    if (!kIsWeb) {
      if (mounted) _snack('Purchases are only available on our website.');
      return;
    }
    final email = AuthService.instance.currentUser?.email;
    if (email == null || email.isEmpty) {
      _snack('Sign in to purchase a leaderboard entry.');
      return;
    }

    setState(() => _opening = true);
    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse(_paymentEndpoint));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'productId': 'AQ_LB_WEEK', 'email': email}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      final decoded = jsonDecode(body);
      if (response.statusCode != 200 ||
          decoded is! Map<String, dynamic> ||
          decoded['success'] != true) {
        if (mounted) _snack('Payment setup failed. Please try again.');
        return;
      }

      final link = decoded['link'] as String?;
      if (link == null || link.isEmpty) {
        if (mounted) _snack('Payment setup failed. Please try again.');
        return;
      }

      final uri = Uri.parse(link);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          _snack(
              'After paying, redeem the code you receive under '
              'Profile → Redeem Code.');
        }
      } else {
        if (mounted) _snack('Could not open the payment page.');
      }
    } catch (e) {
      debugPrint('[LeaderboardPurchase] error: $e');
      if (mounted) _snack('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontFamily: 'Nunito'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    if (context.watch<UserDataProvider>().isLeaderboardEligible &&
        !_autoDismissed &&
        !_opening) {
      _autoDismissed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              '🏆 Entry active — good luck!',
              style: TextStyle(fontFamily: 'Nunito'),
            ),
          ),
        );
      });
    }
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24.r)),
        ),
        padding: EdgeInsets.fromLTRB(24.r, 16.r, 24.r, 28.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Grab handle
            Center(
              child: Container(
                width: 44.w,
                height: 4.h,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2.r),
                ),
              ),
            ),
            SizedBox(height: 20.h),

            // Header icon + title
            Row(
              children: [
                Container(
                  width: 44.r,
                  height: 44.r,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD700).withOpacity(0.16),
                    borderRadius: BorderRadius.circular(12.r),
                  ),
                  child: Icon(Icons.emoji_events_rounded,
                      color: const Color(0xFFFFD700), size: 22.r),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Compete for prizes',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18.sp,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.3,
                          height: 1.1,
                        ),
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        '₦500 · one week',
                        style: TextStyle(
                          color: AppColors.secondary,
                          fontSize: 12.sp,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 18.h),

            // Body copy
            Text(
              'A leaderboard entry activates your already-earned points for '
              'this week\'s paid rank & prize pool (top ranks split 70% of '
              'this week\'s entry revenue). One entry covers this week only.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13.sp,
                height: 1.5,
              ),
            ),
            SizedBox(height: 14.h),

            // Info callout
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12.r),
              decoration: BoxDecoration(
                color: AppColors.secondary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: AppColors.secondary.withOpacity(0.24),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: AppColors.secondary, size: 16.r),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: Text(
                      'Pay securely via Flutterwave. After payment you\'ll '
                      'receive a one-time code on the success page — redeem '
                      'it under Profile → Redeem Code to activate your entry.',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12.sp,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 20.h),

            // Continue button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _opening ? null : _buy,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.r),
                  ),
                ),
                child: _opening
                    ? SizedBox(
                        width: 20.w,
                        height: 20.h,
                        child: const CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        'Continue to payment',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
              ),
            ),
            SizedBox(height: 6.h),

            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  "I'll redeem my code later",
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontFamily: 'Nunito',
                    fontSize: 13.sp,
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

// ─── Rival Sheet ────────────────────────────────────────────────────────────
class _RivalSheet extends StatefulWidget {
  final Map<String, dynamic> rival;
  final String currentUid;

  const _RivalSheet({
    required this.rival,
    required this.currentUid,
  });

  @override
  State<_RivalSheet> createState() => _RivalSheetState();
}

class _RivalSheetState extends State<_RivalSheet> {
  static const _rivalColour = Color(0xFFFF6B00);

  Map<String, int>? _h2h;
  bool _loadingH2H = true;

  @override
  void initState() {
    super.initState();
    _loadH2H();
  }

  Future<void> _loadH2H() async {
    final uid2 = widget.rival['uid'] as String?;
    if (uid2 == null) {
      if (mounted) setState(() => _loadingH2H = false);
      return;
    }

    try {
      final result = await FirestoreService.instance
          .getHeadToHeadRecord(widget.currentUid, uid2);
      if (!mounted) return;
      setState(() {
        _h2h = result;
        _loadingH2H = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingH2H = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final udp = context.watch<UserDataProvider>();
    final rivalUid = widget.rival['uid'] as String? ?? '';
    final username = widget.rival['username'] as String? ?? 'Anonymous';
    final university = widget.rival['university'] as String? ?? '';
    final pts = widget.rival['weeklyPoints'] as int? ?? 0;

    final canChallenge = udp.canChallengeRival(rivalUid);
    String? cooldownText;

    if (!canChallenge &&
        udp.lastRivalUid == rivalUid &&
        udp.lastRivalChallenge != null) {
      final diff = DateTime.now().difference(udp.lastRivalChallenge!);
      final cooldownHours = udp.premiumActive ? 6 : 12;
      final remainingMinutes =
          (cooldownHours * 60 - diff.inMinutes).clamp(0, cooldownHours * 60);
      final hours = remainingMinutes ~/ 60;
      final minutes = remainingMinutes % 60;
      cooldownText = hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
    }

    return Container(
      padding: EdgeInsets.fromLTRB(
        22.r,
        16.r,
        22.r,
        24.r + MediaQuery.of(context).viewInsets.bottom,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.r)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grab handle
          Container(
            width: 44.w,
            height: 4.h,
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2.r),
            ),
          ),
          SizedBox(height: 20.h),

          // ── Header: avatar + name + status badge ─────────────────────
          Row(
            children: [
              Container(
                width: 54.w,
                height: 54.h,
                decoration: BoxDecoration(
                  color: _rivalColour.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(16.r),
                ),
                alignment: Alignment.center,
                child: Text(
                  username.isNotEmpty ? username[0].toUpperCase() : '?',
                  style: TextStyle(
                    color: _rivalColour,
                    fontSize: 24.sp,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 17.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.2,
                              height: 1.15,
                            ),
                          ),
                        ),
                        SizedBox(width: 6.w),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 6.r, vertical: 2.r),
                          decoration: BoxDecoration(
                            color: _rivalColour.withOpacity(0.14),
                            borderRadius: BorderRadius.circular(5.r),
                          ),
                          child: Text(
                            'RIVAL',
                            style: TextStyle(
                              color: _rivalColour,
                              fontSize: 8.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      university.isNotEmpty
                          ? '$university · $pts pts'
                          : '$pts pts',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 18.h),

          // ── Head-to-head stat block ──────────────────────────────────
          Container(
            padding: EdgeInsets.symmetric(vertical: 14.r),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt.withOpacity(0.55),
              borderRadius: BorderRadius.circular(14.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _H2HStat(
                  label: 'Wins',
                  value: _h2h?['wins'] ?? 0,
                  color: AppColors.correct,
                  loading: _loadingH2H,
                ),
                Container(
                  width: 1,
                  height: 32,
                  color: AppColors.divider,
                ),
                _H2HStat(
                  label: 'Draws',
                  value: _h2h?['draws'] ?? 0,
                  color: AppColors.secondary,
                  loading: _loadingH2H,
                ),
                Container(
                  width: 1,
                  height: 32,
                  color: AppColors.divider,
                ),
                _H2HStat(
                  label: 'Losses',
                  value: _h2h?['losses'] ?? 0,
                  color: AppColors.wrong,
                  loading: _loadingH2H,
                ),
              ],
            ),
          ),
          SizedBox(height: 16.h),

          // ── Action button ────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: cooldownText == null
                    ? AppColors.primary
                    : AppColors.surfaceAlt,
                foregroundColor: cooldownText == null
                    ? Colors.white
                    : AppColors.textMuted,
                elevation: 0,
                padding: EdgeInsets.symmetric(vertical: 14.r),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13.r),
                ),
              ),
              onPressed: cooldownText != null
                  ? null
                  : () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => AnimeSelectPage(
                            opponentUid: rivalUid,
                            opponentUsername: username,
                          ),
                        ),
                      );
                    },
              child: Text(
                cooldownText == null
                    ? 'Challenge rival'
                    : 'Cooldown · $cooldownText',
                style: TextStyle(
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _H2HStat extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final bool loading;

  const _H2HStat({
    required this.label,
    required this.value,
    required this.color,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (loading)
          SizedBox(
            width: 18.w,
            height: 18.h,
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.textMuted,
            ),
          )
        else
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: 22.sp,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
        SizedBox(height: 4.h),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.sp,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MY PRIZES BANNER (Phase 3 — winner payout state)
// ═══════════════════════════════════════════════════════════════════════════
// Minimal winner-state section: lists ONLY leaderboard cycles where the
// signed-in user is in `ranked[]` (server snapshot), each with its
// server-derived state. "Paid" appears only when `ranked[].paid == true`.
// Tapping a row pushes PayoutClaimPage for that week — no prize maths here.
class _MyPrizesBanner extends StatelessWidget {
  const _MyPrizesBanner();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<WinnerClaimSummary>>(
      future: FirestoreService.instance.getMyWinnerCycles(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        final cycles = snap.data ?? const <WinnerClaimSummary>[];
        if (cycles.isEmpty) return const SizedBox.shrink();

        return Container(
          padding: EdgeInsets.all(14.r),
          decoration: BoxDecoration(
            color: const Color(0xFFFFD700).withOpacity(0.06),
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(
              color: const Color(0xFFFFD700).withOpacity(0.30),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.emoji_events_rounded,
                      color: const Color(0xFFFFD700), size: 16.r),
                  SizedBox(width: 8.w),
                  Text(
                    'My prizes',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 10.h),
              for (int i = 0; i < cycles.length.clamp(0, 3); i++) ...[
                if (i > 0) SizedBox(height: 8.h),
                _PrizeRow(summary: cycles[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _PrizeRow extends StatelessWidget {
  final WinnerClaimSummary summary;

  const _PrizeRow({required this.summary});

  String get _label {
    if (summary.paid) return 'Paid';
    switch (summary.claimStatus) {
      case 'approved':
        return 'Transfer submitted';
      case 'pending':
        return 'Awaiting approval';
      case 'expired':
        return summary.canClaim ? 'Expired · reclaim' : 'Expired';
      default:
        return 'Claim available';
    }
  }

  Color get _color {
    if (summary.paid) return AppColors.correct;
    switch (summary.claimStatus) {
      case 'approved':
        return AppColors.secondary;
      case 'pending':
        return AppColors.accent;
      case 'expired':
        return AppColors.textMuted;
      default:
        return const Color(0xFFFFD700);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PayoutClaimPage(weekId: summary.weekId),
        ),
      ),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Week of ${summary.weekId} · Rank #${summary.rank}',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    _label,
                    style: TextStyle(
                      color: _color,
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded,
                color: AppColors.textMuted, size: 13.r),
          ],
        ),
      ),
    );
  }
}