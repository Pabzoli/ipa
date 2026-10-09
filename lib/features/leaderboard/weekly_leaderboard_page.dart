import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/prize_pool_service.dart';
import '../../core/theme/app_theme.dart';
import '../admin/admin_payout_service.dart';
import '../auth/auth_service.dart';
import 'leaderboard_models.dart';
import 'widgets/leaderboard_campus.dart';
import 'widgets/leaderboard_pool_card.dart';
import 'widgets/leaderboard_position.dart';
import 'widgets/leaderboard_prizes.dart';
import 'widgets/leaderboard_rows.dart';
import 'widgets/leaderboard_sheets.dart';
import 'widgets/leaderboard_states.dart';

/// The paid weekly leaderboard ("Rankings").
///
/// Reached two ways: as a tab inside the home shell's IndexedStack, and as a
/// pushed route from the Monday announcement and from a notification tap. The
/// header only offers a back affordance in the second case, so a tab never
/// shows a button that would do nothing.
///
/// DATA FRESHNESS
/// The board is polled every [kLeaderboardRefreshInterval] (six hours, four
/// times a day) rather than subscribed. Live snapshots held an open Firestore
/// websocket per board for the whole time the page was mounted, streaming every
/// cohort member's `weeklyPoints` write — for a weekly ranking, updates nobody
/// reads that fast.
///
/// Two things refresh ahead of that cadence, because staleness there is
/// actually harmful rather than merely stale:
///   * the signed-in player's own weekly points, which arrive live via
///     [UserDataProvider] and trigger an immediate re-read;
///   * a resume, if the cache has aged past the refresh interval;
///   * an explicit retry, only after the board fetch failed.
///
/// Nothing else triggers a read. In particular, scoring more points does NOT:
/// the player's own points and rank are derived from the stored snapshot, so
/// the screen stays correct for them without a network call.
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

  /// The single scheduled refresh. One-shot: armed only after a successful
  /// fetch, fired once, then re-armed by that fetch's own completion. There is
  /// no repeating timer, so an idle leaderboard performs no work at all.
  Timer? _refreshTimer;

  /// Bumped to re-run the winner-cycle query, which is not part of the
  /// snapshot.
  int _prizesNonce = 0;

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadUserUniversity();
      _refresh();
    });
  }

  /// True when the data on screen is older than the refresh interval, or when
  /// the calendar week has rolled since it was fetched.
  bool get _isStale => isLeaderboardDataStale(
        lastFetchAt: _lastFetchAt,
        now: DateTime.now(),
        fetchedWeek: _activeWeek,
        currentWeek: FirestoreService.currentWeekId(),
      );

  /// Arms the one-shot refresh for the next due moment — a week boundary if
  /// one is nearer than the full interval.
  void _scheduleNextRefresh(DateTime fetchedAt) {
    _refreshTimer?.cancel();
    final now = DateTime.now();
    final due = nextRefreshAt(fetchedAt: fetchedAt, now: now);
    _refreshTimer = Timer(due.difference(now), _onScheduledRefresh);
  }

  void _onScheduledRefresh() {
    _refreshTimer = null;
    _refresh();
  }

  /// Backoff for an automatic retry after a failed read.
  ///
  /// At most two extra reads, then the page stays on the error state and waits
  /// for the player to act. One minute catches the common case — a transient
  /// blip or a tunnel — and five catches a device that just came back online;
  /// beyond that, retrying silently would burn battery to render a screen
  /// nobody is necessarily looking at.
  static const List<Duration> _failureBackoff = <Duration>[
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  /// Retries consumed by the current failure sequence. Reset on any success and
  /// on an explicit user retry.
  int _retriesUsed = 0;

  /// Arms the next automatic attempt after a failed read, or does nothing once
  /// the backoff budget is spent.
  void _scheduleRetry() {
    if (!mounted) return;
    if (_retriesUsed >= _failureBackoff.length) return;
    final delay = _failureBackoff[_retriesUsed];
    _retriesUsed++;
    _refreshTimer?.cancel();
    _refreshTimer = Timer(delay, _onScheduledRefresh);
  }

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
  /// A timer is the realistic way to land in that window, since it can fire
  /// while a rebuild is in flight. Requiring the route to be the current one
  /// closes it: a deactivated page is never current.
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
    // A backgrounded app cannot run its timer, so returning after longer than
    // one interval must re-read. Resuming sooner leaves the scheduled refresh
    // alone rather than costing a query per app switch.
    if (state == AppLifecycleState.resumed && _isStale) _refresh();
  }

  /// Re-reads everything, arms the next scheduled refresh, and completes when
  /// the new snapshot has landed.
  ///
  /// This is the player-facing Retry, so it restores the automatic-retry budget:
  /// someone who tapped "Try again" has earned a fresh pair of backoffs rather
  /// than inheriting an exhausted one.
  Future<void> refreshAndWait() async {
    _retriesUsed = 0;
    _refresh();
    try {
      await _snapshotFuture;
    } catch (_) {
      // The failure is rendered by the FutureBuilder's error state; swallowing
      // it here keeps it from escaping as an unhandled async error.
    }
  }

  Future<void> _refreshAndWait() => refreshAndWait();

  /// Re-reads everything the page shows, and rebinds the week if it rolled.
  ///
  /// The single entry point for every read: the initial fetch, the scheduled
  /// boundary, a stale resume, and the error state's retry. Exactly one
  /// assignment and one rebuild per call keeps the transitions predictable.
  void _refresh() {
    if (!_canRebuild) return;
    setState(_assignData);
  }

  /// Computes and stores the next snapshot/standing futures, then arms the
  /// follow-up refresh once the read succeeds.
  ///
  /// Split out from [_refresh] so `didChangeDependencies` can update the data
  /// without a `setState` — a build is already on its way, and calling setState
  /// from that hook is a framework assertion.
  void _assignData() {
    final week = FirestoreService.currentWeekId();
    if (week != _activeWeek) _activeWeek = week;

    final provider = _lastKnownProvider;
    final entryWeek = provider?.leaderboardEntryWeekId ?? '';
    final university = _userUniversity ?? '';
    final service = FirestoreService.instance;

    _prizesNonce++;

    final snapshot = _fetchSnapshot(
      admin: isAdminUid(),
      entryWeek: entryWeek,
      university: university,
    );

    // Arm the next refresh only once this one actually lands. A failure instead
    // arms the short backoff, so a blip self-heals without the player touching
    // anything; `_lastFetchAt` is left untouched either way on failure, so the
    // page stays "stale" and a resume can also pick it up.
    _snapshotFuture = snapshot.then(
      (value) {
        _retriesUsed = 0;
        final fetchedAt = DateTime.now();
        _lastFetchAt = fetchedAt;
        if (mounted) _scheduleNextRefresh(fetchedAt);
        return value;
      },
      onError: (Object error, StackTrace stack) {
        _scheduleRetry();
        // Rethrown so the FutureBuilder still renders the error state rather
        // than hanging on the spinner.
        Error.throwWithStackTrace(error, stack);
      },
    );

    _standingFuture = (provider?.isLeaderboardEligible ?? false) &&
            entryWeek.isNotEmpty
        ? service.weeklyStanding(entryWeekId: entryWeek, eligible: true)
        : Future.value(WeeklyStanding.none);
  }

  /// Reads the board, pool, floor, last finalised pool and campus board
  /// concurrently into one snapshot.
  ///
  /// Only the BOARD is allowed to fail the snapshot. Campus, pool, floor and
  /// last-week reads each degrade to a safe default, because a failure in any of
  /// them must not blank an otherwise-healthy Global tab.
  Future<LeaderboardSnapshot> _fetchSnapshot({
    required bool admin,
    required String entryWeek,
    required String university,
  }) async {
    final service = FirestoreService.instance;

    final results = await Future.wait<Object?>([
      // Board: propagates. This is the one failure worth surfacing, because
      // without it there is no leaderboard at all.
      admin
          ? service.fetchWeeklyLeaderboard()
          : service.fetchEligibleWeeklyLeaderboard(entryWeek),
      // Everything below degrades rather than failing the whole read.
      service.fetchPrizePool().catchError((Object _) => const <String, dynamic>{}),
      service.guaranteedFloor().catchError((Object _) => 0.0),
      service.lastFinalisedPool().catchError((Object _) => null),
      (university.isEmpty
              ? Future.value(const <BoardEntry>[])
              : service.fetchCampusLeaderboard(
                  university,
                  entryWeekId: admin ? '' : entryWeek,
                  includeAll: admin,
                ))
          .catchError((Object _) => const <BoardEntry>[]),
    ]);

    final board = results[0]! as List<BoardEntry>;

    return LeaderboardSnapshot(
      global: board,
      campus: results[4]! as List<BoardEntry>,
      pool: results[1]! as Map<String, dynamic>,
      guaranteedFloor: (results[2]! as num).toDouble(),
      lastWeekPool: (results[3]! as num?)?.toDouble(),
      fetchedAt: DateTime.now(),
    );
  }

  /// Cached provider handle, set in `didChangeDependencies`.
  ///
  /// Held as a field because the scheduled refresh can fire when there is no
  /// build in flight, where `context.read` would throw for a deactivated State.
  UserDataProvider? _lastKnownProvider;

  Future<void> _loadUserUniversity() async {
    try {
      final uni = await FirestoreService.instance.getCurrentUserUniversity();
      if (!mounted) return;
      setState(() {
        _userUniversity = uni ?? '';
        _universityLoaded = true;
      });
      // The campus board depends on the university, so re-read now.
      _refresh();
    } catch (_) {
      // Never leave the campus tab on an infinite spinner: a failed read
      // (offline / permission) still unblocks the UI, which then offers the
      // in-tab picker.
      if (!mounted) return;
      setState(() {
        _userUniversity = _userUniversity ?? '';
        _universityLoaded = true;
      });
    }
  }

  void _onUniversitySaved(String uni) {
    setState(() {
      _userUniversity = uni;
      _universityLoaded = true;
    });
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabCtrl.dispose();
    // The only scheduled work this page owns. Cancelled here so a discarded
    // page can never fire a read; while merely deactivated (pushed under
    // another route) the timer is allowed to run, and its setState is blocked
    // by _canRebuild.
    _refreshTimer?.cancel();
    _refreshTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = _lastKnownProvider;
    final canPop = ModalRoute.of(context)?.canPop ?? false;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding:
                  EdgeInsets.fromLTRB(canPop ? 8.r : 20.r, 10.r, 20.r, 0),
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
                          '${provider?.weeklyPoints ?? 0} pts',
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

            Padding(
              padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
              child: _RankingTabs(controller: _tabCtrl),
            ),

            SizedBox(height: 4.h),

            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
_GlobalLeaderboardTab(
                    snapshotFuture: _snapshotFuture,
                    standingFuture: _standingFuture,
                    prizesNonce: _prizesNonce,
                    onRetry: _refreshAndWait,
                  ),
                  CampusLeaderboardTab(
                    snapshotFuture: _snapshotFuture,
                    university: _userUniversity,
                    universityLoaded: _universityLoaded,
                    onUniversitySaved: _onUniversitySaved,
                    onRetry: _refreshAndWait,
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

// ============================================================================
// GLOBAL TAB
// ============================================================================

class _GlobalLeaderboardTab extends StatelessWidget {
  final Future<LeaderboardSnapshot> snapshotFuture;
  final Future<WeeklyStanding> standingFuture;

  /// Incremented on refresh so the winner-cycle query re-runs too.
  final int prizesNonce;

  final Future<void> Function() onRetry;

  const _GlobalLeaderboardTab({
    required this.snapshotFuture,
    required this.standingFuture,
    required this.prizesNonce,
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

    final rivalUid = myRank > 1
        ? _firstWhere(split.rest, (e) => e.rank == myRank - 1)?.uid
        : null;

    final cta = LeaderboardEntryCta();

    // No pull-to-refresh: refreshes are scheduled, and a gesture would
    // silently override the "four times a day" cadence. Recovery from a failure
    // is the error state's Retry button instead.
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
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

          // -- Winner payout state ---------------------------------------
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
              child: MyPrizesBanner(refreshSignal: prizesNonce),
            ),
          ),

          // -- Your standing ---------------------------------------------
          // Omitted only when the board is genuinely empty AND the player has
          // not entered: the empty state below already renders the same CTA,
          // and two identical buttons read as a bug.
          if (!showStandaloneEmpty || eligible)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 0.r),
                child: YourPositionCard(
                  standing: standing,
                  myWeeklyPoints: provider.weeklyPoints,
                  displayName:
                      myRow?.username ?? _fallbackName(),
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
                isAdmin: isAdminUid(),
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
                    onRivalTap: (entry) => showRivalSheet(context, entry),
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
                    trailing: '${slots.whereType<RowSlot>().length} shown',
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(20.r, 0.r, 20.r, 24.r),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => _slot(context, slots[i], prizes, myRank, rivalUid),
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
            onTap: entry.uid == rivalUid
                ? () => showRivalSheet(context, entry)
                : null,
          ),
        );
      case GroupSlot(:final label):
        return RankGroupHeader(label: label);
      case GapSlot(:final hiddenAbove, :final hiddenBelow):
        return RowGap(hiddenAbove: hiddenAbove, hiddenBelow: hiddenBelow);
    }
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
    final above = _firstWhere(entries, (e) => myRank > 0 && e.rank == myRank - 1);
    final below = _firstWhere(entries, (e) => myRank > 0 && e.rank == myRank + 1);

    return WeeklyStanding(
      rank: myRank,
      totalPlayers: resolved.totalPlayers > 0
          ? resolved.totalPlayers
          : entries.where((e) => e.isRanked).length,
      myPoints: myRow?.weeklyPoints ?? myPoints,
      pointsToNextRank: above?.weeklyPoints,
      nextRankUsername: above?.username,
      belowRankUsername: below?.username,
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