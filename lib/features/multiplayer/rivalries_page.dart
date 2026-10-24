// lib/features/multiplayer/rivalries_page.dart
//
// Rivalries — the management screen. One job: show who your rivals are and
// where each series stands, then open a specific rivalry. Discovery lives here
// too (campus suggestions), so it is not duplicated on the Battle hub.
// Creating a code duel and joining by code live on the hub now.
//
// PAGING: one page is kRivalriesPageSize rivals. "Show more" reveals the next
// page — from memory when the scan already found more, otherwise by scanning a
// larger window of the match history (repeat matches collapse, so the window
// grows until it can fill the page). Rivalry docs are read ONLY for rivals that
// are newly shown. Pull-to-refresh resets to the first page. No listeners.
//
// READ COST: the first page is ONE recentRivalsWindow query (window =
// kRivalriesPageSize) plus at most ONE rivalry-doc read per newly shown rival
// (bounded by the page size). Campus discovery is ONE users-doc read for the
// viewer plus ONE campusRivals query (≤20). Nothing here attaches a listener.

import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/rival_economy.dart';
import '../../core/constants/rivalries_paging.dart';
import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/weekly_points_pill.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_empty_state.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/app_skeleton.dart';
import '../../core/widgets/rival_avatar.dart';
import '../../core/widgets/series_progress_bar.dart';
import '../../core/widgets/shared_widgets.dart';
import 'rivalry_page.dart';

/// A rival plus their series state, flattened to display fields so the row
/// widget stays dumb.
class _RivalRowData {
  final String uid;
  final String username;
  final int wins;
  final int draws;
  final int losses;
  final bool lastWasLoss;
  final bool hasSeries;
  final int seriesNo;
  final int myWins;
  final int opWins;
  final String status;

  const _RivalRowData({
    required this.uid,
    required this.username,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.lastWasLoss,
    required this.hasSeries,
    required this.seriesNo,
    required this.myWins,
    required this.opWins,
    required this.status,
  });

  bool get hasLiveSeries => hasSeries && status == 'active';
}

class RivalriesPage extends StatefulWidget {
  const RivalriesPage({super.key});

  @override
  State<RivalriesPage> createState() => _RivalriesPageState();
}

class _RivalriesPageState extends State<RivalriesPage>
    with SingleTickerProviderStateMixin {
  /// Rivalry docs already read this load, so a "Show more" never re-reads the
  /// first page's docs. Cleared on pull-to-refresh.
  final Map<String, Map<String, dynamic>> _series = {};
  final Set<String> _seriesFetched = {};

  /// Every rival the last scan discovered, and how many are rendered.
  List<RivalSummary> _rivals = const [];
  List<_RivalRowData> _rows = const [];
  int _revealed = 0;

  /// Matches scanned by the last scan, and whether the history ran out.
  int _window = kRivalriesPageSize;
  bool _exhausted = false;

  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  String _myUid = '';

  /// One shared scroll controller so the empty state can offer "find a rival"
  /// and actually scroll the discovery section into view.
  final ScrollController _scroll = ScrollController();
  final GlobalKey _discoverKey = GlobalKey();

  late final AnimationController _entrance;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _myUid = FirestoreService.instance.currentUid ?? '';
    _load(reset: true);
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..forward();
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _entrance.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// True while any rival could still be revealed: either one is already
  /// scanned but not shown, or the history may hold further matches.
  bool get _hasMore => _revealed < _rivals.length || !_exhausted;

  /// Loads one page. [reset] returns to the first page (open / pull-to-refresh);
  /// otherwise it reveals the next page.
  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _error = null;
        _rivals = const [];
        _rows = const [];
        _revealed = 0;
        _window = kRivalriesPageSize;
        _exhausted = false;
        _series.clear();
        _seriesFetched.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }

    try {
      final target = _revealed + kRivalriesPageSize;

      List<RivalSummary> rivals = _rivals;
      var exhausted = _exhausted;
      var window = _window;

      // Scan only while the already-scanned rivals fall short of the page.
      // Extra rivals already scanned are revealed from memory with no query,
      // and a paging load never re-scans the window it already has.
      if (rivals.length < target && !exhausted) {
        var firstScan = rivals.isEmpty;
        while (true) {
          window =
              firstScan ? window : min(window * 2, kRivalriesMaxWindow);
          firstScan = false;
          final page = await FirestoreService.instance
              .recentRivalsWindow(window: window);
          rivals = page.rivals;
          exhausted = !page.hasMore;
          if (exhausted ||
              rivals.length >= target ||
              window >= kRivalriesMaxWindow) {
            break;
          }
        }
        _window = window;
        // At the cap we stop offering more even if the history may run on:
        // the read cost has to have a floor.
        _exhausted = exhausted || window >= kRivalriesMaxWindow;
      }

      final shown = rivals.length < target ? rivals.length : target;

      // Rivalry docs ONLY for rivals that will be shown, and only once each.
      final newUids = rivals
          .take(shown)
          .map((r) => r.uid)
          .where((u) => !_seriesFetched.contains(u))
          .toList();
      if (newUids.isNotEmpty) {
        _seriesFetched.addAll(newUids);
        _series.addAll(
          await FirestoreService.instance.rivalryStates(newUids),
        );
      }

      final myUid = _myUid;
      final rows = [
        for (final r in rivals.take(shown)) _rowData(r, myUid),
      ];

      if (!mounted) return;
      setState(() {
        _rivals = rivals;
        _revealed = shown;
        _rows = rows;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  _RivalRowData _rowData(RivalSummary r, String myUid) {
    final s = _seriesFor(_series[r.uid], myUid);
    return _RivalRowData(
      uid: r.uid,
      username: r.username,
      wins: r.wins,
      draws: r.draws,
      losses: r.losses,
      lastWasLoss: r.lastWasLoss,
      hasSeries: s.hasSeries,
      seriesNo: s.seriesNo,
      myWins: s.myWins,
      opWins: s.opWins,
      status: s.status,
    );
  }

  void _openRivalry(String uid, String username) {
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => RivalryPage(rivalUid: uid, rivalUsername: username),
      ),
    );
  }

  void _scrollToDiscovery() {
    final keyContext = _discoverKey.currentContext;
    if (keyContext == null) return;
    Scrollable.ensureVisible(
      keyContext,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  static const _ParsedSeries _noSeries = _ParsedSeries(
    hasSeries: false,
    seriesNo: 1,
    myWins: 0,
    opWins: 0,
    status: 'active',
  );

  /// Parses one rivalry doc into the flattened series state, or [_noSeries]
  /// when the pair has never played a ranked duel.
  static _ParsedSeries _seriesFor(Map<String, dynamic>? s, String myUid) {
    if (s == null) return _noSeries;
    final isA = myUid == (s['aUid'] as String?);
    return _ParsedSeries(
      hasSeries: true,
      seriesNo: ((s['seriesNo'] as num?)?.toInt()) ?? 1,
      myWins: ((isA ? s['winsA'] : s['winsB']) as num?)?.toInt() ?? 0,
      opWins: ((isA ? s['winsB'] : s['winsA']) as num?)?.toInt() ?? 0,
      status: (s['status'] as String?) ?? 'active',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Rivalries',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 12.r),
            child: const WeeklyPointsPill(),
          ),
        ],
      ),
      body: FadeTransition(
        opacity: _fade,
        child: RefreshIndicator(
          color: AppColors.primary,
          backgroundColor: AppColors.surface,
          onRefresh: () => _load(reset: true),
          child: ListView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
            children: [
              _SummaryCard(
                loading: _loading,
                error: _error,
                rows: _rows,
                onRetry: () => _load(reset: true),
              ),
              SizedBox(height: 20.h),
              Padding(
                padding: EdgeInsets.only(left: 2.r, bottom: 12.r),
                child: SectionHeader(
                  title: 'Your rivals',
                  trailing: _rows.isEmpty
                      ? null
                      : _CountPill(label: '${_rows.length}'),
                ),
              ),
              _rivalList(),
              SizedBox(height: 26.h),
              Padding(
                key: _discoverKey,
                padding: EdgeInsets.only(left: 2.r, bottom: 12.r),
                child: const SectionHeader(title: 'Find a rival'),
              ),
              const _Subtitle('Campus players on this week’s board.'),
              SizedBox(height: 12.h),
              _CampusSuggestions(onOpen: _openRivalry),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rivalList() {
    if (_loading) {
      return const _RowsSkeleton(rows: 4);
    }
    if (_error != null) {
      return AppCard(
        padding: EdgeInsets.zero,
        child: AppEmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Couldn’t load rivalries',
          color: AppColors.wrong,
          action: AppButton(
            label: 'Retry',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _load(reset: true),
            variant: AppButtonVariant.outline,
            size: AppButtonSize.small,
          ),
        ),
      );
    }
    if (_rows.isEmpty) {
      return AppCard(
        onTap: _scrollToDiscovery,
        padding: EdgeInsets.zero,
        child: AppEmptyState(
          icon: Icons.sports_kabaddi_rounded,
          title: 'No rivals yet',
          message: 'Duel someone and they land here.',
          color: AppColors.primary,
          action: AppButton(
            label: 'Find a rival',
            icon: const Icon(Icons.person_search_rounded),
            onPressed: _scrollToDiscovery,
            variant: AppButtonVariant.primary,
            size: AppButtonSize.small,
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final r in _rows)
          _RivalRow(
            data: r,
            onTap: () => _openRivalry(r.uid, r.username),
          ),
        if (_hasMore) ...[
          SizedBox(height: 6.h),
          AppButton(
            label: _loadingMore ? 'Loading…' : 'Show more rivals',
            onPressed: _loadingMore ? null : () => _load(reset: false),
            variant: AppButtonVariant.outline,
            size: AppButtonSize.small,
            loading: _loadingMore,
            width: double.infinity,
          ),
        ],
      ],
    );
  }
}

// ─── Hero summary: the rivalry ledger at a glance ─────────────────────────────

/// One elevated card answering "how is my rivalry life going": how many rivals
/// the loaded list holds, how many series are live, and the combined W–L
/// across them. Derived ONLY from the rows already read, so it never invents
/// numbers the scan hasn't fetched.
class _SummaryCard extends StatelessWidget {
  final bool loading;
  final Object? error;
  final List<_RivalRowData> rows;
  final VoidCallback onRetry;

  const _SummaryCard({
    required this.loading,
    required this.error,
    required this.rows,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return const _SummarySkeleton();

    final live = rows.where((r) => r.hasLiveSeries).length;
    final wins = rows.fold(0, (a, r) => a + r.wins);
    final losses = rows.fold(0, (a, r) => a + r.losses);
    final draws = rows.fold(0, (a, r) => a + r.draws);

    final leading = rows.isEmpty
        ? (error != null ? 'UNAVAILABLE' : 'NO RIVALS YET')
        : (live > 0 ? 'LIVE' : 'READY');

    return AppCard(
      tier: AppCardTier.elevated,
      gradient: const LinearGradient(
        colors: AppColors.cardGradient,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 14.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 38.r,
                height: 38.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Text('⚔️', style: TextStyle(fontSize: 17.sp)),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Text(
                  'Rivalry report',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              _Tag(label: leading, color: AppColors.primary),
            ],
          ),
          SizedBox(height: 16.h),
          Row(
            children: [
              Expanded(
                child: _SummaryStat(
                  value: '${rows.length}',
                  label: 'RIVALS',
                  color: AppColors.textPrimary,
                ),
              ),
              const _StatDivider(),
              Expanded(
                child: _SummaryStat(
                  value: '$live',
                  label: 'SERIES LIVE',
                  color: AppColors.primary,
                ),
              ),
              const _StatDivider(),
              Expanded(
                child: _SummaryStat(
                  value: '$wins–$losses',
                  label: draws > 0 ? 'W–L · ${draws}D' : 'W–L',
                  color: wins >= losses
                      ? AppColors.correct
                      : AppColors.lose,
                ),
              ),
            ],
          ),
          SizedBox(height: 14.h),
          Text(
            rows.isEmpty
                ? 'Duel someone and they land here as a rematchable rival.'
                : 'First to $kSeriesWinsRequired staked duels takes a series. '
                    'Draws replay — sparring never counts.',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _SummaryStat({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 22.sp,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
        SizedBox(height: 6.h),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 9.sp,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            height: 1,
          ),
        ),
      ],
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 36.h, color: AppColors.divider);
  }
}

class _SummarySkeleton extends StatelessWidget {
  const _SummarySkeleton();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: AppCardTier.elevated,
      padding: EdgeInsets.all(16.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppSkeleton(width: 38.r, height: 38.r, radius: AppRadii.md),
              SizedBox(width: 10.w),
              Expanded(child: AppSkeleton(width: 120.w, height: 14.h)),
            ],
          ),
          SizedBox(height: 18.h),
          Row(
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) SizedBox(width: 12.w),
                Expanded(child: AppSkeleton(height: 42.h)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Small count pill trailing a section header.
class _CountPill extends StatelessWidget {
  final String label;

  const _CountPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 3.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(color: AppColors.divider),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.textMuted,
          fontSize: 10.sp,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

// ─── Rows ─────────────────────────────────────────────────────────────────────

/// Parsed series state for one rival, flattened for the row.
class _ParsedSeries {
  final bool hasSeries;
  final int seriesNo;
  final int myWins;
  final int opWins;
  final String status;

  const _ParsedSeries({
    required this.hasSeries,
    required this.seriesNo,
    required this.myWins,
    required this.opWins,
    required this.status,
  });
}

/// The one muted helper line under a section header.
class _Subtitle extends StatelessWidget {
  final String text;
  const _Subtitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 2.r, right: 2.r),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.textMuted,
          fontSize: 12.sp,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
  }
}

/// One rival, tappable end to end. Shows only what decides the next move: who
/// they are, the live series score, and whether they beat you last (REVENGE).
/// The full W/D/L record and series detail live on the rivalry page.
class _RivalRow extends StatelessWidget {
  final _RivalRowData data;
  final VoidCallback onTap;

  const _RivalRow({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 10.h),
      child: AppCard(
        onTap: onTap,
        padding: EdgeInsets.all(12.r),
        child: Row(
          children: [
            RivalAvatar(
              name: data.username,
              size: 46.r,
              color: AppColors.primary,
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
                          data.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (data.lastWasLoss) ...[
                        SizedBox(width: 8.w),
                        const _Tag(label: 'REVENGE', color: AppColors.primary),
                      ],
                    ],
                  ),
                  SizedBox(height: 8.h),
                  if (data.hasSeries)
                    SeriesProgressBar(
                      myWins: data.myWins,
                      opWins: data.opWins,
                      compact: true,
                    )
                  else
                    Text(
                      'No series yet',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(width: 8.w),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textMuted,
              size: 22.r,
            ),
          ],
        ),
      ),
    );
  }
}

/// Small uppercase pill used for status / context tags.
class _Tag extends StatelessWidget {
  final String label;
  final Color color;

  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 2.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

// ─── Discovery: campus carousel ──────────────────────────────────────────────

/// Campus suggestions: same-university, same-week players, ordered by WP.
/// Tapping a card opens the per-rival detail page (Spar/Duel live there).
class _CampusSuggestions extends StatelessWidget {
  final void Function(String uid, String username) onOpen;

  const _CampusSuggestions({required this.onOpen});

  Future<List<RivalCandidate>?> _load() async {
    final me = FirestoreService.instance.currentUid;
    if (me == null) return [];
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(me)
        .get();
    final data = doc.data() ?? {};
    final uni = (data['university'] as String?) ?? '';
    final week = (data['leaderboardEntryWeekId'] as String?) ?? '';
    if (uni.isEmpty || week.isEmpty) return null;
    return FirestoreService.instance.campusRivals(
      university: uni,
      weekId: week,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<RivalCandidate>?>(
      future: _load(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _CampusSkeleton();
        }
        final rows = snap.data;
        if (rows == null) {
          return const _HintCard(
            icon: Icons.school_rounded,
            text:
                'Set your university and join the weekly board to see campus rivals.',
          );
        }
        final shown = rows.take(8).toList();
        if (shown.isEmpty) {
          return const _HintCard(
            icon: Icons.person_search_rounded,
            text: 'No campus rivals on the board this week — yet.',
          );
        }
        return SizedBox(
          height: 172.h,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.only(bottom: 2.r),
            itemCount: shown.length,
            separatorBuilder: (context, i) => SizedBox(width: 10.w),
            itemBuilder: (context, i) => _CampusCard(
              name: shown[i].username,
              weeklyPoints: shown[i].weeklyPoints,
              onTap: () => onOpen(shown[i].uid, shown[i].username),
            ),
          ),
        );
      },
    );
  }
}

/// One discoverable campus player as a vertical candidate card. Same tap
/// target as a rival row (opens the matchup page), so the read and the
/// gesture stay consistent.
class _CampusCard extends StatelessWidget {
  final String name;
  final int weeklyPoints;
  final VoidCallback onTap;

  const _CampusCard({
    required this.name,
    required this.weeklyPoints,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.all(14.r),
      child: SizedBox(
        width: 140.w,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RivalAvatar(
                  name: name,
                  size: 42.r,
                  color: AppColors.primary,
                ),
              ],
            ),
            const Spacer(),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.2,
              ),
            ),
            SizedBox(height: 3.h),
            Text(
              '$weeklyPoints WP this week',
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
    );
  }
}

/// Loading placeholder that mirrors a row of campus cards.
class _CampusSkeleton extends StatelessWidget {
  const _CampusSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 172.h,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 3,
        separatorBuilder: (_, __) => SizedBox(width: 10.w),
        itemBuilder: (context, i) => AppCard(
          padding: EdgeInsets.all(14.r),
          child: SizedBox(
            width: 140.w,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppSkeleton(width: 42.r, height: 42.r, radius: 21.r),
                    const Spacer(),
                    AppSkeleton(width: 42.w, height: 12.h, radius: 4.r),
                  ],
                ),
                const Spacer(),
                AppSkeleton(width: 100.w, height: 13.h),
                SizedBox(height: 8.h),
                AppSkeleton(width: 78.w, height: 10.h),
                SizedBox(height: 12.h),
                AppSkeleton(width: 92.w, height: 10.h),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A short, actionable note rendered as a surface card (no dead-end spinner).
class _HintCard extends StatelessWidget {
  final IconData icon;
  final String text;

  const _HintCard({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 14.r),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textMuted, size: 18.r),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading placeholder that mirrors a list of rival rows.
class _RowsSkeleton extends StatelessWidget {
  final int rows;

  const _RowsSkeleton({this.rows = 4});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: EdgeInsets.only(bottom: 10.h),
            child: AppCard(
              padding: EdgeInsets.all(12.r),
              child: Row(
                children: [
                  AppSkeleton(
                    width: 50.r,
                    height: 50.r,
                    radius: 25.r,
                  ),
                  SizedBox(width: 12.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            AppSkeleton(width: 110.w, height: 13.h),
                            SizedBox(width: 8.w),
                            AppSkeleton(width: 44.w, height: 12.h, radius: 4.r),
                          ],
                        ),
                        SizedBox(height: 9.h),
                        AppSkeleton(width: 200.w, height: 10.h),
                        SizedBox(height: 9.h),
                        AppSkeleton(width: 150.w, height: 9.h),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
