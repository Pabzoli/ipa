import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/prize_pool_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/weekly_points_pill.dart';
import '../admin/admin_payout_service.dart';
import '../auth/auth_service.dart';
import '../friends/add_friend_page.dart';
import '../multiplayer/rivalry_page.dart';
import 'leaderboard_models.dart';
import 'widgets/friends_board_tab.dart';
import 'widgets/leaderboard_pool_card.dart';
import 'widgets/leaderboard_position.dart';
import 'widgets/leaderboard_rows.dart';
import 'widgets/leaderboard_states.dart';

/// The paid weekly leaderboard ("Rankings").
///
/// Reached two ways: as a tab inside the home shell's IndexedStack, and as a
/// pushed route from the Monday announcement and from a notification tap. The
/// header only offers a back affordance in the second case, so a tab never
/// shows a button that would do nothing.
///
/// DATA FRESHNESS (locked design, amended)
/// The Global board loads when the page is opened, re-reads on pull-to-refresh,
/// and re-reads on resume only once the data is older than
/// [kLeaderboardRefreshInterval]. There is NO timer and NO live subscription:
/// an idle screen performs **zero** Firestore reads. (It previously held an
/// open websocket, then a self-rearming six-hour timer; both spent reads and
/// battery delivering changes nobody acts on that fast.)
///
/// The Friends tab loads on demand the same way — tab open, tab re-visible,
/// resume, and pull-to-refresh — floored by a five-minute service cache. So a
/// player who never looks at Friends spends nothing on it, and a player who
/// does look gets current data.
///
/// Two things stay live WITHOUT a read: the signed-in player's own weekly
/// points (arrive live via [UserDataProvider]) and their own rank (recomputed
/// from the stored snapshot against those live points).
///
/// A fetch is also forced when the entry week changes, because it swaps the
/// cohort the board queries. Scoring more points deliberately does not trigger
/// a read.
class WeeklyLeaderboardPage extends StatefulWidget {
  final int initialTab;

  const WeeklyLeaderboardPage({super.key, this.initialTab = 0});

  @override
  State<WeeklyLeaderboardPage> createState() => _WeeklyLeaderboardPageState();
}

class _WeeklyLeaderboardPageState extends State<WeeklyLeaderboardPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabCtrl;

  // ── Data ───────────────────────────────────────────────────────────────
  //
  // Held as reassignable futures. `FutureBuilder` restarts whenever the future
  // instance changes, so refreshing means assigning a new future — there is no
  // stream identity to manage and nothing to re-subscribe.
  Future<LeaderboardSnapshot> _snapshotFuture =
      Future.value(LeaderboardSnapshot.empty);

  /// True rank past the 100-row window, read at fetch time only.
  Future<WeeklyStanding> _standingFuture = Future.value(WeeklyStanding.none);

  /// Friends board (getFriendsBoard callable, 5-minute client cache inside the
  /// service). Loaded on demand — tab open, tab re-visible, resume, or
  /// pull-to-refresh — never on the Global six-hour cadence. Null until the
  /// first request, so the tab shows a spinner rather than an error card.
  Future<FriendsBoardData>? _friendsFuture;

  /// Whether a friends future has ever been assigned. Combined with the
  /// service cache freshness to decide when re-opening the tab actually reads.
  bool _friendsRequested = false;

  /// When the current snapshot was READ. Set only on success, so a failed
  /// fetch leaves the page "stale" and a later resume retries it.
  DateTime? _lastFetchAt;

  String? _userUniversity;
  bool _universityLoaded = false;

  /// The week the data is bound to.
  String _activeWeek = FirestoreService.currentWeekId();

  /// Last entry week seen from the provider, stashed in a field so async
  /// callbacks never touch an ancestor lookup after an await.
  String _providerWeek = '';

  /// Last selected tab index, so the tab controller's frequent notifications
  /// only trigger work when the tab actually changed.
  int _lastTabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeWeek = FirestoreService.currentWeekId();

    _tabCtrl = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab,
    );
    _lastTabIndex = widget.initialTab;
    _tabCtrl.addListener(_onTabChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadUserUniversity();
      _refresh();
      if (_tabCtrl.index == 1) _ensureFriends();
    });
  }

  /// Fires once per real tab change. Opening the Friends tab reads the board
  /// (subject to the cache floor below).
  void _onTabChanged() {
    final index = _tabCtrl.index;
    if (index == _lastTabIndex) return;
    _lastTabIndex = index;
    if (index == 1) _ensureFriends();
  }

  /// Loads the friends board on tab open, floored by the service's five-minute
  /// cache. While the cache is fresh the rendered future is left alone, so
  /// re-visiting the tab never flashes a spinner and never spends a callable.
  void _ensureFriends({bool force = false}) {
    if (!force &&
        _friendsRequested &&
        FirestoreService.instance.friendsBoardCacheFresh) {
      return;
    }
    if (!_canRebuild) return;
    _friendsRequested = true;
    setState(() {
      _friendsFuture =
          FirestoreService.instance.fetchFriendsBoard(force: force);
    });
  }

  /// Pull-to-refresh / "Try again" on the Friends tab: bypasses the cache and
  /// completes when the new data lands, so the gesture's spinner clears on the
  /// right frame.
  Future<void> _reloadFriends() async {
    if (!_canRebuild) return;
    _friendsRequested = true;
    final future = FirestoreService.instance.fetchFriendsBoard(force: true);
    setState(() => _friendsFuture = future);
    try {
      await future;
    } catch (_) {
      // Rendered by the FutureBuilder's error state.
    }
  }

  /// True when the data on screen is older than the refresh interval, or when
  /// the calendar week has rolled since it was fetched.
  bool get _isStale => isLeaderboardDataStale(
        lastFetchAt: _lastFetchAt,
        now: DateTime.now(),
        fetchedWeek: _activeWeek,
        currentWeek: FirestoreService.currentWeekId(),
      );

  /// Whether it is safe to call setState right now.
  ///
  /// `mounted` alone is NOT sufficient. Between `deactivate()` and `dispose()`
  /// a State still reports mounted while its element is no longer part of the
  /// live tree, and a `setState` in that window calls `markNeedsBuild` on an
  /// inactive element. That surfaces as
  /// "framework.dart: _elements.contains(element) is not true" rather than the
  /// familiar "setState() called after dispose()" — a much harder error to
  /// trace back to its cause.
  ///
  /// Requiring the route to be the current one also keeps a backgrounded tab
  /// (covered by a pushed route) from rebuilding under the user's feet when a
  /// resumed lifecycle callback fires.
  bool get _canRebuild {
    if (!mounted) return false;
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // watch (not read) so this re-runs when the provider finishes loading the
    // entry week after the first build.
    //
    // Deliberately calls no setState. A build always follows
    // didChangeDependencies in the same frame, so assigning the new futures
    // here is enough. The previous implementation funneled this hook through
    // _applyBoardStreams(notify: true), which called setState again mid-rebuild
    // after the refresh path had already invalidated its own stream keys —
    // two setStates in one pass plus a mutated dependency graph, which is the
    // shape that trips the element-consistency assertion pull-to-refresh was
    // throwing.
    final provider = context.watch<UserDataProvider>();
    _lastKnownProvider = provider;

    final week = provider.leaderboardEntryWeekId ?? '';
    final weekChanged = shouldRefetchOnProviderChange(
      previousEntryWeek: _providerWeek,
      nextEntryWeek: week,
    );
    _providerWeek = week;

    // Only an entry-week change re-reads: it swaps the cohort the board is
    // querying, so the stored snapshot describes a different set of players.
    // A points change deliberately does not — see
    // [shouldRefetchOnProviderChange].
    if (weekChanged) _assignData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // The board only refreshes on open, on pull-to-refresh, and here. A resume
    // after the data has aged past [kLeaderboardRefreshInterval] re-reads;
    // resuming sooner costs nothing rather than burning a query per app switch.
    if (state != AppLifecycleState.resumed) return;
    if (_isStale) _refresh();
    // The Friends tab is on-demand: a resume while it is open re-checks it
    // (still floored by the cache).
    if (_tabCtrl.index == 1) _ensureFriends();
  }

  /// Re-reads the Global board and completes when the new snapshot has landed.
  ///
  /// This backs both the error state's "Try again" and the Global tab's
  /// pull-to-refresh, so the gesture's spinner clears on the right frame.
  Future<void> refreshAndWait() async {
    _refresh();
    try {
      await _snapshotFuture;
    } catch (_) {
      // The failure is rendered by the FutureBuilder's error state; swallowing
      // it here keeps it from escaping as an unhandled async error.
    }
  }

  Future<void> _refreshAndWait() => refreshAndWait();

  /// Re-reads the Global board and rebinds the week if it rolled.
  ///
  /// The single entry point for every Global read: the initial load, a stale
  /// resume, pull-to-refresh, and the error state's retry. Exactly one
  /// assignment and one rebuild per call keeps the transitions predictable.
  void _refresh() {
    if (!_canRebuild) return;
    setState(_assignData);
  }

  /// Computes and stores the snapshot/standing/campus futures for this frame.
  ///
  /// Split out from [_refresh] so `didChangeDependencies` can update the data
  /// without a `setState` — a build is already on its way, and calling setState
  /// from that hook is a framework assertion.
  void _assignData() {
    final week = FirestoreService.currentWeekId();
    if (week != _activeWeek) _activeWeek = week;

    final provider = _lastKnownProvider;
    final eligible = provider?.isLeaderboardEligible ?? false;
    final entryWeek = provider?.leaderboardEntryWeekId ?? '';
    // Only a CURRENT-week entry names a cohort the player may read. A stale
    // entry week (paid last week, not this one) would otherwise query last
    // week's cohort and render it — every row unranked and zeroed — which is
    // not a board anyone should see. An empty week resolves to an empty board
    // and the pay-to-enter state instead.
    final cohortWeek = eligible ? entryWeek : '';
    final service = FirestoreService.instance;

    final snapshot = _fetchSnapshot(admin: isAdminUid(), entryWeek: cohortWeek);

    // Record when the data was read, so a resume can tell fresh from stale. On
    // failure it is deliberately left untouched, so the page stays "stale" and
    // the next resume (or pull-to-refresh) retries it.
    _snapshotFuture = snapshot.then((value) {
      _lastFetchAt = DateTime.now();
      return value;
    });

    _standingFuture = eligible && entryWeek.isNotEmpty
        ? service.weeklyStanding(entryWeekId: entryWeek, eligible: true)
        : Future.value(WeeklyStanding.none);
  }

  /// Reads the board, pool, floor and last finalised pool concurrently into
  /// one snapshot. The old 50-row campus board fetch is gone (replaced by
  /// the campus-chip COUNT above): it cost up to 50 doc reads per refresh
  /// for a tab nobody paid for.
  ///
  /// Only the BOARD is allowed to fail the snapshot. Pool, floor and
  /// last-week reads each degrade to a safe default, because a failure in any
  /// of them must not blank an otherwise-healthy Global tab.
  Future<LeaderboardSnapshot> _fetchSnapshot({
    required bool admin,
    required String entryWeek,
  }) async {
    final service = FirestoreService.instance;

    final results = await Future.wait<Object?>([
      // Board: propagates. This is the one failure worth surfacing, because
      // without it there is no leaderboard at all.
      admin
          ? service.fetchWeeklyLeaderboard()
          : service.fetchEligibleWeeklyLeaderboard(entryWeek),
      // Everything below degrades rather than failing the whole read.
      service
          .fetchPrizePool()
          .catchError((Object _) => const <String, dynamic>{}),
      service.guaranteedFloor().catchError((Object _) => 0.0),
      service.lastFinalisedPool().catchError((Object _) => null),
    ]);

    final board = results[0]! as List<BoardEntry>;

    return LeaderboardSnapshot(
      global: board,
      pool: results[1]! as Map<String, dynamic>,
      guaranteedFloor: (results[2]! as num).toDouble(),
      lastWeekPool: (results[3] as num?)?.toDouble(),
      fetchedAt: DateTime.now(),
    );
  }

  /// Cached provider handle, set in `didChangeDependencies`.
  ///
  /// Held as a field because async callbacks (a stale resume, the retry, the
  /// university load) can fire when there is no build in flight, where
  /// `context.read` would throw for a deactivated State.
  UserDataProvider? _lastKnownProvider;

  Future<void> _loadUserUniversity() async {
    try {
      final uni = await FirestoreService.instance.getCurrentUserUniversity();
      if (!mounted) return;
      setState(() {
        _userUniversity = uni ?? '';
        _universityLoaded = true;
      });
    } catch (_) {
      // Never leave the chip on an infinite spinner: a failed read
      // (offline / permission) still unblocks the UI.
      if (!mounted) return;
      setState(() {
        _userUniversity = _userUniversity ?? '';
        _universityLoaded = true;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabCtrl.removeListener(_onTabChanged);
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    // Ghost admin: sees every player, competes for nothing, needs no entry code.
    final isAdmin = isAdminUid();

    if (_tabCtrl.index == 1 && !_friendsRequested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureFriends();
      });
    }

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(canPop ? 8.r : 20.r, 10.r, 20.r, 0),
              child: Row(
                children: [
                  if (canPop)
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      color: AppColors.textPrimary,
                      iconSize: 20.r,
                      tooltip: 'Back',
                    ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            'Rankings',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 26.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                              height: 1.05,
                            ),
                          ),
                        ),
                        // The campus/university indicator lives here alongside
                        // the points pill (it used to sit on its own row under
                        // the tabs). It takes only the width it needs, and its
                        // label ellipsizes when the campus name is long.
                        // It is meaningless for the ghost admin.
                        if (!isAdmin)
                          Flexible(
                            child: _CampusChip(
                              university: _userUniversity ?? '',
                              universityLoaded: _universityLoaded,
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(width: 8.w),
                  WeeklyPointsPill(label: isAdmin ? 'ADMIN' : null),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
              child: _RankingTabs(controller: _tabCtrl),
            ),
            SizedBox(height: 8.h),
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  _GlobalLeaderboardTab(
                    snapshotFuture: _snapshotFuture,
                    standingFuture: _standingFuture,
                    onRetry: _refreshAndWait,
                  ),
                  FriendsBoardTab(
                    friendsFuture: _friendsFuture,
                    onReload: _reloadFriends,
                    onAddFriend: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AddFriendPage()),
                    ),
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

/// Campus chip: just the player's campus name ("UNILAG").
/// "Campus not set" when unset. No rank number and no "join board to rank"
/// suffix — the chip names the campus and nothing else.
///
/// Read-only: the chip used to open the campus picker sheet, but campus is now
/// changed in Settings only, so it is a display indicator with no tap action.
class _CampusChip extends StatelessWidget {
  final String university;
  final bool universityLoaded;

  const _CampusChip({
    required this.university,
    required this.universityLoaded,
  });

  @override
  Widget build(BuildContext context) {
    if (!universityLoaded) return const SizedBox.shrink();
    if (university.isEmpty) return const _ChipShell(label: 'Campus not set');
    return _ChipShell(label: university);
  }
}

class _ChipShell extends StatelessWidget {
  final String label;
  const _ChipShell({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.school_rounded, color: AppColors.secondary, size: 13.r),
          SizedBox(width: 6.w),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.secondary,
                fontSize: 11.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
          Tab(text: 'Friends'),
        ],
      ),
    );
  }
}

// ============================================================================
// GLOBAL TAB
// ============================================================================

class _GlobalLeaderboardTab extends StatelessWidget {
  final Future<LeaderboardSnapshot> snapshotFuture;
  final Future<WeeklyStanding> standingFuture;

  final Future<void> Function() onRetry;

  const _GlobalLeaderboardTab({
    required this.snapshotFuture,
    required this.standingFuture,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<WeeklyStanding>(
      future: standingFuture,
      builder: (context, standingSnap) {
        final standing = standingSnap.data ?? WeeklyStanding.none;
        return FutureBuilder<LeaderboardSnapshot>(
          future: snapshotFuture,
          builder: (context, snap) {
            if (snap.hasError) {
              // The single Retry in the app: it exists only here, and only
              // because the BOARD read is the one failure worth surfacing.
              return BoardErrorState(
                error: snap.error,
                onRetry: () => onRetry(),
              );
            }
            if (!snap.hasData) return const BoardSpinner();
            return _body(context, snap.data!, standing);
          },
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    LeaderboardSnapshot snapshot,
    WeeklyStanding resolved,
  ) {
    final provider = context.watch<UserDataProvider>();
    final eligible = provider.isLeaderboardEligible;
    final myPoints = provider.weeklyPoints;
    final entries = snapshot.global;
    // Ghost admin: sees all players, holds no rank, buys nothing.
    final isAdmin = isAdminUid();

    // Between Sunday's reset and the week rollover the CF has already
    // snapshotted and zeroed every score while the week id still names the
    // closed cycle. Showing that board — or a zeroed pool — would be actively
    // misleading, so the hour renders as "closing" instead.
    if (PrizePoolService.isFinalising) {
      return const WeekClosingState();
    }

    final projection = PrizePoolService.projectPrizePool(
      entryCodeRevenue: snapshot.pool['entryCodeRevenue'] as num?,
      adminPoolNaira: snapshot.pool['adminPoolNaira'] as num?,
      guaranteedFloor: snapshot.guaranteedFloor,
    );
    final prizes = PrizePoolService.calculatePrizes(projection.amount);

    final split = splitBoard(entries);
    final slots = buildBoardSlots(split.rest);

    // Rank derived from the STORED snapshot against LIVE points, so scoring
    // moves the player's rank with no network access. Falls back to the rank
    // captured at fetch time once the player falls below the 100-row window.
    final myRank = eligible
        ? resolveDisplayRank(
            entries: entries,
            myPoints: myPoints,
            capturedRank: resolved.rank,
          )
        : 0;
    final myRow = _firstWhere(entries, (e) => e.isCurrentUser);
    final standing = _buildStanding(
      entries: entries,
      myRow: myRow,
      myRank: myRank,
      myPoints: myPoints,
      resolved: resolved,
    );

    // A board that has not loaded yet is NOT an empty board.
    final showStandaloneEmpty = entries.isEmpty;

    // The player one place above, looked up across the WHOLE board — not just
    // the rows below the podium. Searching only `split.rest` meant a player
    // ranked 2–4 (whose target sits on the podium) never got a rival badge or
    // a PASS ME marker, i.e. exactly where the money is.
    final rivalUid = myRank > 1
        ? _firstWhere(entries, (e) => e.rank == myRank - 1)?.uid
        : null;

    final cta = LeaderboardEntryCta();

    // Pull-to-refresh is the Global tab's manual re-read; otherwise the board
    // refreshes on open and on a stale resume. A failure is recoverable here
    // too, so the error state's Retry is a convenience, not the only path.
    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: onRetry,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // -- Admin ghost banner ----------------------------------------
          if (isAdmin)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
                child: Container(
                  padding:
                      EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
                  decoration: BoxDecoration(
                    color: AppColors.secondary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    border: Border.all(
                      color: AppColors.secondary.withValues(alpha: 0.32),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.visibility_rounded,
                          color: AppColors.secondary, size: 15.r),
                      SizedBox(width: 8.w),
                      Expanded(
                        child: Text(
                          'Admin view · your account is not competing.',
                          style: TextStyle(
                            color: AppColors.secondary,
                            fontSize: 11.5.sp,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // -- Prize pool -----------------------------------------------
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
              child: PrizePoolCard(
                projection: projection,
                lastWeekPool: snapshot.lastWeekPool,
                weekId: FirestoreService.currentWeekId(),
                poolOpen: snapshot.poolOpen,
                isBoardEmpty: entries.isEmpty,
              ),
            ),
          ),

          // -- Your standing ---------------------------------------------
          // Omitted only when the board is genuinely empty AND the player has
          // not entered: the empty state below already renders the same CTA,
          // and two identical buttons read as a bug. Never shown to the ghost
          // admin — it has no standing and must never see a "pay to enter" CTA.
          if (!isAdmin && (!showStandaloneEmpty || eligible))
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
                child: YourPositionCard(
                  standing: standing,
                  myWeeklyPoints: provider.weeklyPoints,
                  displayName: myRow?.username ?? _fallbackName(),
                  isEligible: eligible,
                  entryCta: cta,
                ),
              ),
            ),

          // -- Genuinely empty --------------------------------------------
          if (showStandaloneEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: BoardEmptyState(
                isEligible: eligible,
                isAdmin: isAdmin,
                cta: cta,
              ),
            )

          // -- The board itself ------------------------------------------
          else ...[
            if (split.podium.length >= 2) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.r, 22.r, 20.r, 12.r),
                  child: const LeaderboardSectionHeader(
                    icon: Icons.emoji_events_rounded,
                    title: 'Top players',
                    color: LeaderboardPalette.gold,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 0.r),
                  child: LeaderboardPodium(
                    entries: split.podium,
                    prizes: prizes,
                    rivalUids: rivalUid == null ? const {} : {rivalUid},
                    onRivalTap: (entry) => _openPlayerPage(context, entry),
                  ),
                ),
              ),
            ],
            if (slots.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.r, 22.r, 20.r, 4.r),
                  child: LeaderboardSectionHeader(
                    icon: Icons.format_list_numbered_rounded,
                    title: 'Leaderboard',
                    color: AppColors.primary,
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 24.r),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) =>
                        _slot(context, slots[i], prizes, myRank, rivalUid),
                    childCount: slots.length,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 32.r),
                  child: BoardFooter(
                    shown: entries.length,
                    totalPlayers: standing.totalPlayers,
                    fetchedAt: snapshot.fetchedAt,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _slot(
    BuildContext context,
    BoardSlot slot,
    Map<int, double> prizes,
    int myRank,
    String? rivalUid,
  ) {
    switch (slot) {
      case RowSlot(:final entry):
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: RankRow(
            key: ValueKey(entry.uid),
            entry: entry,
            prize: entry.isRanked ? prizes[entry.rank] : null,
            isMe: entry.isCurrentUser,
            isRival: entry.uid == rivalUid,
            isNextRank: myRank > 0 && entry.rank == myRank - 1,
            isBelowRank: myRank > 0 && entry.rank == myRank + 1,
            // Every player other than you opens their page from here. The
            // signed-in player's own row is not a target.
            onTap: entry.isCurrentUser
                ? null
                : () => _openPlayerPage(context, entry),
          ),
        );
      case GroupSlot(:final label):
        return RankGroupHeader(label: label);
      case GapSlot(:final hiddenAbove, :final hiddenBelow):
        return RowGap(hiddenAbove: hiddenAbove, hiddenBelow: hiddenBelow);
    }
  }

  /// Opens the tapped player's page — the face-off card, the head-to-head
  /// record, the series and the two ways to play (duel and spar).
  ///
  /// All data there is read for [entry] on open; nothing about the row is
  /// passed through but the identity, so the page never renders a stale copy of
  /// the board's points.
  void _openPlayerPage(BuildContext context, BoardEntry entry) {
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => RivalryPage(
          rivalUid: entry.uid,
          rivalUsername: entry.username,
        ),
      ),
    );
  }

  /// Builds the standing card's data around the live-points [myRank].
  ///
  /// The neighbour rows come from the stored snapshot (free, and consistent
  /// with the list). [resolved] contributes only the true cohort size, which the
  /// capped snapshot cannot know.
  ///
  /// Past the 100-row window the player is absent from the snapshot entirely, so
  /// there is no neighbour to name and the overtake target simply goes
  /// unstated rather than being invented.
  WeeklyStanding _buildStanding({
    required List<BoardEntry> entries,
    required BoardEntry? myRow,
    required int myRank,
    required int myPoints,
    required WeeklyStanding resolved,
  }) {
    // Keep the delta and its target on ONE points scale. `myRank` is derived
    // from the player's LIVE points, so the overtake target must be picked by
    // live points too — looking it up by the stored snapshot's rank mixed two
    // vintages and could name a row that is no longer directly above.
    BoardEntry? above;
    for (final e in entries) {
      if (e.isCurrentUser || !e.isRanked) continue;
      if (e.weeklyPoints > myPoints &&
          (above == null || e.weeklyPoints < above.weeklyPoints)) {
        above = e;
      }
    }

    return WeeklyStanding(
      rank: myRank,
      // 0 == unknown (the ghost admin has no standing). The footer renders that
      // as "top N shown" rather than claiming the capped board is complete.
      totalPlayers: resolved.totalPlayers,
      myPoints: myPoints,
      pointsToNextRank: above?.weeklyPoints,
      nextRankUsername: above?.username,
    );
  }

  static T? _firstWhere<T>(Iterable<T> items, bool Function(T) test) {
    for (final item in items) {
      if (test(item)) return item;
    }
    return null;
  }

  static String _fallbackName() {
    final name = AuthService.instance.currentUser?.displayName;
    return (name == null || name.isEmpty) ? 'You' : name;
  }
}
