// lib/features/multiplayer/rivalry_page.dart
//
// One page per rival pairing: head-to-head record, best-of series state,
// upset-bounty context, recent history, and the two ways to play:
//
//   • Spar (free) — zero stakes, never counts for the series, 5 WP on a win
//     inside the daily spar budget. Bypasses to anime select → quiz.
//   • Duel (staked) — counts for the series (first to 3, draws replay).
//
// Spar/duel availability, budgets and cooldowns are enforced server-side;
// this page only previews them (estimates) so the UI never over-promises.
// The word "rank" is never used here: series standing is not a rank.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/constants/rival_economy.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_page_route.dart';
import '../quiz/questions_page.dart';
import 'anime_select_page.dart';

class RivalryPage extends StatefulWidget {
  final String rivalUid;
  final String rivalUsername;

  const RivalryPage({
    super.key,
    required this.rivalUid,
    required this.rivalUsername,
  });

  @override
  State<RivalryPage> createState() => _RivalryPageState();
}

class _RivalryPageState extends State<RivalryPage> {
  bool _sparBusy = false;
  Map<String, int>? _h2h;
  Object? _h2hError;
  int? _rivalWP;
  bool _rivalWPFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        FirestoreService.instance.getHeadToHeadRecord(
          FirestoreService.instance.currentUid ?? '',
          widget.rivalUid,
        ),
        FirebaseFirestore.instance
            .collection('users')
            .doc(widget.rivalUid)
            .get(),
      ]);
      if (!mounted) return;
      setState(() {
        _h2h = results[0] as Map<String, int>;
        _h2hError = null;
        _rivalWPFailed = false;
        _rivalWP = ((results[1] as DocumentSnapshot<Map<String, dynamic>>)
                    .data()?['weeklyPoints'] as num?)
                ?.toInt();
      });
    } catch (e) {
      // Rival doc may be unreadable (different cohort week) — show the
      // bounty line as unavailable instead of hiding it, and surface the
      // H2H error instead of swallowing it.
      if (!mounted) return;
      setState(() {
        _rivalWPFailed = true;
        _h2hError = e;
      });
    }
  }

  Future<void> _startSpar(String animeTitle) async {
    if (_sparBusy) return;
    setState(() => _sparBusy = true);
    try {
      final res = await FirestoreService.instance.createSparChallenge(
        animeTitle: animeTitle,
        opponentUid: widget.rivalUid,
        opponentUsername: widget.rivalUsername,
      );
      final challengeId = res['challengeId']?.toString() ?? '';
      final rawIds = res['questionIds'];
      if (!mounted) return;
      if (challengeId.isEmpty || rawIds is! List) {
        throw Exception('challenge_creation_failed');
      }
      final questionIds =
          List<String>.unmodifiable(rawIds.map((e) => '$e'));
      Navigator.of(context).pushReplacement(
        AppPageRoute(
          builder: (_) => QuestionsPage(
            mode: QuizMode.asyncChallenge,
            selectedTitles: [animeTitle],
            questionIds: questionIds,
            challengeId: challengeId,
            isCreator: true,
            opponentName: widget.rivalUsername,
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final msg = e.message ?? '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          msg.contains('daily_spar_limit_reached')
              ? 'Daily spar limit reached — come back tomorrow for friendlies.'
              : msg.contains('not_friends')
                  ? 'Add them as a friend to spar.'
                  : 'Could not start the spar — please try again.',
        ),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not start the spar — please try again.'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _sparBusy = false);
    }
  }

  void _goSpar() {
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => AnimeSelectPage(
          opponentUid: widget.rivalUid,
          opponentUsername: widget.rivalUsername,
          onSelect: _startSpar,
        ),
      ),
    );
  }

  void _goDuel() {
    Navigator.of(context).push(
      AppPageRoute(
        builder: (_) => AnimeSelectPage(
          opponentUid: widget.rivalUid,
          opponentUsername: widget.rivalUsername,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final udp = context.watch<UserDataProvider>();
    final myWP = udp.weeklyPoints;
    final myUid = FirestoreService.instance.currentUid ?? '';

    final onCooldown = !udp.canChallengeRival(widget.rivalUid);
    final cooldownHrs = udp.getRivalCooldownHours(widget.rivalUid);

    final gap = (_rivalWP ?? 0) - myWP;
    final showBounty = _rivalWP != null && gap >= kBountyWpGap;

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
          'Rivalry',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── VS header ───────────────────────────────────────────
            _VsHeader(
              rivalUsername: widget.rivalUsername,
              h2h: _h2h,
              h2hError: _h2hError,
            ),
            SizedBox(height: 12.h),

            // ── Series banner (always shown, even at 0-0) ───────────
            StreamBuilder<Map<String, dynamic>?>(
              stream: FirestoreService.instance
                  .rivalryStream(widget.rivalUid),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const _SeriesBanner(
                    seriesNo: 1,
                    myWins: 0,
                    opWins: 0,
                    status: 'active',
                    iWon: false,
                    unavailable: true,
                    lastPrizeAt: null,
                  );
                }
                final data = snap.data;
                if (data == null) {
                  return const _SeriesBanner(
                    seriesNo: 1,
                    myWins: 0,
                    opWins: 0,
                    status: 'active',
                    iWon: false,
                    unavailable: false,
                    lastPrizeAt: null,
                  );
                }
                final isA = myUid == (data['aUid'] as String?);
                final myWins =
                    ((isA ? data['winsA'] : data['winsB']) as num?)?.toInt() ??
                        0;
                final opWins =
                    ((isA ? data['winsB'] : data['winsA']) as num?)?.toInt() ??
                        0;
                final status = (data['status'] as String?) ?? 'active';
                final iWonSeries =
                    (data['seriesWinnerUid'] as String?) == myUid &&
                        myUid.isNotEmpty;
                DateTime? lastPrizeAt;
                final rawPrize = data['lastSeriesPrizeAt'];
                if (rawPrize is Timestamp) lastPrizeAt = rawPrize.toDate();
                return _SeriesBanner(
                  seriesNo: ((data['seriesNo'] as num?)?.toInt()) ?? 1,
                  myWins: myWins,
                  opWins: opWins,
                  status: status,
                  iWon: iWonSeries,
                  unavailable: false,
                  lastPrizeAt: lastPrizeAt,
                );
              },
            ),
            SizedBox(height: 8.h),
            Text(
              "Draws replay and don't count toward the series.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11.sp,
                fontWeight: FontWeight.w600,
              ),
            ),

            // ── Bounty line (never silently hidden) ─────────────────
            if (_rivalWPFailed) ...[
              SizedBox(height: 12.h),
              const _BountyUnavailable(),
            ] else if (showBounty) ...[
              SizedBox(height: 12.h),
              _BountyLine(gap: gap),
            ],
            SizedBox(height: 16.h),

            // ── Spar / Duel — the only two actions ──────────────────
            Row(
              children: [
                Expanded(
                  child: _ModeButton(
                    emoji: '🤝',
                    title: 'Spar',
                    subtitle: 'Free · never counts',
                    accent: AppColors.correct,
                    busy: _sparBusy,
                    onTap: _sparBusy ? null : _goSpar,
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: _ModeButton(
                    emoji: '⚔️',
                    title: 'Duel',
                    subtitle: onCooldown
                        ? 'Series game in ~${cooldownHrs}h (estimate)'
                        : 'Counts for series',
                    accent: const Color(0xFFFF6B00),
                    onTap: _goDuel,
                  ),
                ),
              ],
            ),
            if (onCooldown) ...[
              SizedBox(height: 8.h),
              Text(
                'Series rematch cooldown (estimate) — sparring stays open. The server skips it inside an active series.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            SizedBox(height: 20.h),

            // ── History ─────────────────────────────────────────────
            Text(
              'HISTORY',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
            SizedBox(height: 8.h),
            _RivalryHistory(rivalUid: widget.rivalUid),
          ],
        ),
      ),
    );
  }
}

// ─── VS header ───────────────────────────────────────────────────────────────
class _VsHeader extends StatelessWidget {
  final String rivalUsername;
  final Map<String, int>? h2h;
  final Object? h2hError;

  const _VsHeader(
      {required this.rivalUsername, required this.h2h, this.h2hError});

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
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _FighterTag(label: 'YOU', name: 'You'),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.r),
                child: Text(
                  'VS',
                  style: TextStyle(
                    color: const Color(0xFFFF6B00).withValues(alpha: 0.85),
                    fontSize: 18.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
              ),
              _FighterTag(label: 'RIVAL', name: rivalUsername),
            ],
          ),
          SizedBox(height: 14.h),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 8.r),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: h2h == null
                ? Text(
                    h2hError != null
                        ? 'Could not load record: $h2hError'
                        : 'Loading record…',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : Text(
                    '${h2h!['wins'] ?? 0}W · ${h2h!['draws'] ?? 0}D · ${h2h!['losses'] ?? 0}L all-time incl. sparring + code duels',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FighterTag extends StatelessWidget {
  final String label;
  final String name;

  const _FighterTag({required this.label, required this.name});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 4.r),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(6.r),
            border: Border.all(color: AppColors.divider),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ),
        SizedBox(height: 6.h),
        SizedBox(
          width: 100.w,
          child: Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Series banner (always visible) ───────────────────────────────────────────
class _SeriesBanner extends StatelessWidget {
  final int seriesNo;
  final int myWins;
  final int opWins;
  final String status;
  final bool iWon;
  final bool unavailable;
  final DateTime? lastPrizeAt;

  const _SeriesBanner({
    required this.seriesNo,
    required this.myWins,
    required this.opWins,
    required this.status,
    required this.iWon,
    required this.unavailable,
    required this.lastPrizeAt,
  });

  static const _purple = Color(0xFF8B5CF6);

  @override
  Widget build(BuildContext context) {
    final isNew = myWins == 0 && opWins == 0;
    final lead = isNew
        ? 'First to $kSeriesWinsRequired wins the series'
        : myWins == opWins
            ? 'Tied $myWins–$opWins'
            : (myWins > opWins
                ? 'You lead $myWins–$opWins'
                : 'They lead $opWins–$myWins');

    String title;
    String sub;
    if (unavailable) {
      title = 'SERIES $seriesNo · SCORE UNAVAILABLE';
      sub = 'Showing record only — check connection and reopen.';
    } else if (status == 'expired') {
      title = 'SERIES $seriesNo EXPIRED · NEXT GAME OPENS SERIES ${seriesNo + 1}';
      sub = 'Stale series never pay a prize. Win series games to take the next one.';
    } else if (status == 'decided') {
      title = iWon
          ? 'SERIES $seriesNo WON · +$kSeriesAcPrize AC'
          : 'SERIES $seriesNo DECIDED';
      sub = iWon
          ? 'Next series game opens series ${seriesNo + 1}.'
          : 'Next series game opens series ${seriesNo + 1}. Decided series pay +$kSeriesAcPrize AC at most once per 7 days.';
    } else if (isNew) {
      title = 'SERIES $seriesNo · FIRST TO $kSeriesWinsRequired';
      sub = 'Staked duels only — sparring never counts.';
    } else {
      title = 'SERIES $seriesNo · FIRST TO $kSeriesWinsRequired';
      sub = '$lead — win series games to take it.';
    }

    String? prizeNote;
    if (!unavailable && lastPrizeAt != null) {
      final remaining = kSeriesPrizeCooldown - DateTime.now().difference(lastPrizeAt!);
      if (remaining > Duration.zero) {
        final days = (remaining.inHours / 24).ceil().clamp(1, 7);
        prizeNote =
            'Series prize on cooldown — available again in $days day${days == 1 ? '' : 's'}.';
      }
    }

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _purple.withValues(alpha: 0.16),
            _purple.withValues(alpha: 0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: _purple.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Text('🏆', style: TextStyle(fontSize: 24.sp)),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _purple,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  sub,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (prizeNote != null) ...[
                  SizedBox(height: 3.h),
                  Text(
                    prizeNote,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Bounty lines ─────────────────────────────────────────────────────────────
class _BountyLine extends StatelessWidget {
  final int gap;

  const _BountyLine({required this.gap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          Text('🎯', style: TextStyle(fontSize: 16.sp)),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              'You trail by $gap WP — a series win takes a +$kBountyWpBonus bounty.',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BountyUnavailable extends StatelessWidget {
  const _BountyUnavailable();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Text('🎯', style: TextStyle(fontSize: 16.sp)),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              'Bounty unavailable — could not read rival points.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Mode buttons (Spar / Duel) ──────────────────────────────────────────────
class _ModeButton extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Color accent;
  final bool busy;
  final VoidCallback? onTap;

  const _ModeButton({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.accent,
    this.busy = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 16.r),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18.r),
          border: Border.all(color: accent.withValues(alpha: 0.5), width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox(
                width: 26.w,
                height: 26.h,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: accent,
                ),
              )
            else
              Text(emoji, style: TextStyle(fontSize: 28.sp)),
            SizedBox(height: 8.h),
            Text(
              title,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 3.h),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontSize: 11.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── History vs this rival ───────────────────────────────────────────────────
// CAUSE (confirmed in code): history needs the composite index
// (matches: opponentUid ASC + timestamp DESC) now declared in
// firestore.indexes.json. The all-time record uses getHeadToHeadRecord with
// NO orderBy, so it worked while history failed with failed-precondition —
// and the old builder swallowed the error (snap.hasError unchecked) and
// rendered "No battles yet". Errors are now surfaced.
class _RivalryHistory extends StatelessWidget {
  final String rivalUid;

  const _RivalryHistory({required this.rivalUid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(FirestoreService.instance.currentUid)
          .collection('matches')
          .where('opponentUid', isEqualTo: rivalUid)
          .orderBy('timestamp', descending: true)
          .limit(8)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          );
        }
        if (snap.hasError) {
          return Container(
            padding: EdgeInsets.all(16.r),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text(
              'Could not load history: ${snap.error}. If this says a missing index, deploy firestore.indexes.json.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Container(
            padding: EdgeInsets.all(16.r),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text(
              'No battles yet — spar or duel to open the history.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        return Column(
          children: [
            for (final doc in docs) _HistoryRow(data: doc.data()),
          ],
        );
      },
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final Map<String, dynamic> data;

  const _HistoryRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final outcome = data['outcome'] as String?;
    final mine = (data['playerScore'] as num?)?.toInt() ?? 0;
    final theirs = (data['opponentScore'] as num?)?.toInt() ?? 0;
    final type = (data['challengeType'] as String?) ?? '';
    final isSpar = type == 'spar';
    final isSeriesGame = type == 'rival';
    final stake = (data['stakeAmount'] as num?)?.toInt() ?? 0;
    final seriesNo = (data['seriesNo'] as num?)?.toInt() ?? 0;
    final color = outcome == 'win'
        ? AppColors.correct
        : (outcome == 'draw' ? AppColors.secondary : AppColors.wrong);
    final tag = isSpar
        ? 'SPAR · never counts'
        : isSeriesGame
            ? (stake > 0 ? '$stake AC · series${seriesNo > 0 ? ' $seriesNo' : ''}' : 'SERIES')
            : (stake > 0 ? '$stake AC' : 'DUEL');

    return Container(
      margin: EdgeInsets.only(bottom: 8.h),
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 11.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 8.w,
            height: 8.h,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          SizedBox(width: 10.w),
          Text(
            '$mine–$theirs',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(width: 10.w),
          Text(
            outcome == 'win'
                ? 'Won'
                : (outcome == 'draw' ? 'Drew' : 'Lost'),
            style: TextStyle(
              color: color,
              fontSize: 12.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(20.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text(
              tag,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
