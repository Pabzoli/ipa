// lib/features/multiplayer/rivalry_page.dart
//
// One page per rival pairing: head-to-head record, best-of series state,
// upset-bounty context, and the two ways to play:
//
//   • Duel (staked) — counts for the series (first to 3, draws replay).
//   • Spar (free) — zero stakes, never counts for the series, 5 WP on a win
//     inside the daily spar budget. Bypasses to anime select → quiz.
//
// Spar/duel availability, budgets and cooldowns are enforced server-side; this
// page only previews them so the UI never over-promises. The cooldown is shown
// INSIDE the Duel button ("Ready in ~Nh") and Spar is always enabled, so the
// state is never a silent dead end. The word "rank" is never used here: series
// standing is not a rank.
//
// FRIENDSHIP: the relationship is visible on the face-off card ("FRIEND"
// badge), the actions are hidden behind the AppBar ⋯ (see friend_actions.dart).
// The body stays solely about the match, so the page ends on Spar.
//
// READ COST: the series block is a single rivalry-doc listener (rivalryStream).
// The H2H record, the rival user doc and the cooldown are one-shot reads on
// open (and re-run after a duel returns).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/constants/rival_economy.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/weekly_points_pill.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/app_skeleton.dart';
import '../../core/widgets/rival_avatar.dart';
import '../../core/widgets/series_progress_bar.dart';
import '../../core/widgets/shared_widgets.dart';
import '../friends/friend_actions.dart';
import 'anime_select_page.dart';
import 'spar_launcher.dart';

class RivalryPage extends StatefulWidget {
  final String rivalUid;
  final String rivalUsername;

  /// Set when the pairing came from the Friends board. The friend row itself
  /// carries no menu, so this page — where the player is already looking at
  /// that friend — owns the friendship actions. They sit behind the AppBar ⋯,
  /// with the relationship itself badged on the face-off card.
  final bool isFriend;

  const RivalryPage({
    super.key,
    required this.rivalUid,
    required this.rivalUsername,
    this.isFriend = false,
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

  /// Whole hours before a staked rematch is allowed, from the shared client
  /// mirror of the server rule (0 = allowed). Drives the Duel button label.
  int _cooldownHours = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // read (not watch) — premium only chooses the cooldown length, and this
    // runs while the widget is still initialising.
    final premium = context.read<UserDataProvider>().premiumActive;
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
        FirestoreService.instance.rivalDuelCooldownHours(
          widget.rivalUid,
          premium: premium,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _h2h = results[0] as Map<String, int>;
        _h2hError = null;
        _rivalWPFailed = false;
        _rivalWP = ((results[1] as DocumentSnapshot<Map<String, dynamic>>)
                .data()?['weeklyPoints'] as num?)
            ?.toInt();
        _cooldownHours = results[2] as int;
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
      await startFreeSpar(
        context,
        opponentUid: widget.rivalUid,
        opponentUsername: widget.rivalUsername,
        animeTitle: animeTitle,
      );
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
    // Refresh on return: a duel may have moved the series, the H2H record and
    // the rematch cooldown while this page sat underneath the quiz.
    Navigator.of(context)
        .push(
      AppPageRoute(
        builder: (_) => AnimeSelectPage(
          opponentUid: widget.rivalUid,
          opponentUsername: widget.rivalUsername,
        ),
      ),
    )
        .then((_) {
      if (mounted) _load();
    });
  }

  /// The friend menu: Remove / Block, confirmed in the sheet. Both end the
  /// friendship, so a confirmed action leaves the page and the board (behind
  /// us) reloads from the pop result.
  Future<void> _manageFriend() async {
    final result = await showFriendManageSheet(
      context,
      uid: widget.rivalUid,
      name: widget.rivalUsername,
    );
    if (!mounted || result == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == FriendManageResult.removed
              ? 'You are no longer friends.'
              : 'Blocked. They can\'t contact you or send requests.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final myWP = context.watch<UserDataProvider>().weeklyPoints;
    final myUid = FirestoreService.instance.currentUid ?? '';

    final onCooldown = _cooldownHours > 0;

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
        actions: [
          const WeeklyPointsPill(),
          // Actions hidden, state visible: the relationship is badged on the
          // face-off card, while Remove / Block live behind this ⋯ so they are
          // never a stray tap between Duel and Spar.
          if (widget.isFriend)
            Padding(
              padding: EdgeInsets.only(right: 8.r),
              child: IconButton(
                tooltip: 'Manage friend',
                onPressed: _manageFriend,
                icon: Icon(
                  Icons.more_horiz_rounded,
                  color: AppColors.textPrimary,
                  size: 24.r,
                ),
              ),
            )
          else
            SizedBox(width: 12.r),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Face-off: who, and the all-time head-to-head ────────
            _FaceOffCard(
              rivalUsername: widget.rivalUsername,
              isFriend: widget.isFriend,
              h2h: _h2h,
              h2hError: _h2hError,
            ),
            SizedBox(height: 16.h),

            // ── Series banner (always shown, even at 0-0) ───────────
            StreamBuilder<Map<String, dynamic>?>(
              stream: FirestoreService.instance.rivalryStream(widget.rivalUid),
              builder: (context, snap) {
                if (snap.hasError) {
                  return const _SeriesPanel(
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
                  return const _SeriesPanel(
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
                return _SeriesPanel(
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

            // ── Bounty line (never silently hidden) ─────────────────
            if (_rivalWPFailed) ...[
              SizedBox(height: 12.h),
              const _BountyUnavailable(),
            ] else if (showBounty) ...[
              SizedBox(height: 12.h),
              _BountyLine(gap: gap),
            ],
            SizedBox(height: 24.h),

            // ── The two actions, one clear job each ─────────────────
            Padding(
              padding: EdgeInsets.only(left: 2.r, bottom: 12.r),
              child: const SectionHeader(title: 'Next match'),
            ),
            AppButton(
              label: onCooldown
                  ? '⚔️  Duel · ready in ~${_cooldownHours}h'
                  : '⚔️  Duel · counts for the series',
              onPressed: _goDuel,
              variant: AppButtonVariant.primary,
              size: AppButtonSize.medium,
              color: AppColors.primary,
              height: 52.h,
            ),
            SizedBox(height: 10.h),
            AppButton(
              label: _sparBusy
                  ? 'Starting spar…'
                  : '🤝  Spar · free, never counts',
              onPressed: _sparBusy ? null : _goSpar,
              variant: AppButtonVariant.outline,
              size: AppButtonSize.medium,
              color: AppColors.secondary,
              loading: _sparBusy,
              height: 52.h,
            ),
            SizedBox(height: 8.h),
            if (onCooldown)
              Text(
                'Staked rematch cooldown — sparring stays open. The server '
                'skips it inside an active series.',
                textAlign: TextAlign.center,
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

// ─── Face-off card: identity + all-time head-to-head ─────────────────────────
class _FaceOffCard extends StatelessWidget {
  final String rivalUsername;
  final bool isFriend;
  final Map<String, int>? h2h;
  final Object? h2hError;

  const _FaceOffCard({
    required this.rivalUsername,
    required this.isFriend,
    required this.h2h,
    this.h2hError,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: AppCardTier.elevated,
      padding: EdgeInsets.fromLTRB(16.r, 18.r, 16.r, 16.r),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: _Fighter(
                  label: 'YOU',
                  name: 'You',
                  color: AppColors.primary,
                ),
              ),
              const _VsMedallion(),
              Expanded(
                child: _Fighter(
                  // The relationship is the one piece of friendship state
                  // worth showing: the actions themselves stay in the AppBar ⋯.
                  label: isFriend ? 'FRIEND' : 'RIVAL',
                  name: rivalUsername,
                  color: AppColors.accent,
                  badgeColor: isFriend ? AppColors.correct : null,
                ),
              ),
            ],
          ),
          SizedBox(height: 18.h),
          Container(height: 1, color: AppColors.divider),
          SizedBox(height: 16.h),
          _HeadToHead(h2h: h2h, h2hError: h2hError),
        ],
      ),
    );
  }
}

/// The glowing "VS" coin between the two players.
class _VsMedallion extends StatelessWidget {
  const _VsMedallion();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 8.w, right: 8.w, top: 8.h),
      child: Container(
        width: 46.r,
        height: 46.r,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.primary,
              AppColors.primary.withValues(alpha: 0.55),
            ],
          ),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          'VS',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// One side of the face-off: avatar, role chip, name.
class _Fighter extends StatelessWidget {
  final String label;
  final String name;
  final Color color;

  /// Chip colour when it should differ from the identity colour (a friend is
  /// still the accent-coloured rival, but the chip reads as a positive state).
  final Color? badgeColor;

  const _Fighter({
    required this.label,
    required this.name,
    required this.color,
    this.badgeColor,
  });

  @override
  Widget build(BuildContext context) {
    final badge = badgeColor ?? color;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RivalAvatar(name: name, size: 62.r, color: color),
        SizedBox(height: 10.h),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 3.r),
          decoration: BoxDecoration(
            color: badge.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadii.full),
            border: Border.all(color: badge.withValues(alpha: 0.35)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: badge,
              fontSize: 9.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
              height: 1,
            ),
          ),
        ),
        SizedBox(height: 7.h),
        Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14.sp,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}

/// The all-time W / D / L head-to-head, or the load error.
class _HeadToHead extends StatelessWidget {
  final Map<String, int>? h2h;
  final Object? h2hError;

  const _HeadToHead({required this.h2h, this.h2hError});

  @override
  Widget build(BuildContext context) {
    if (h2h == null) {
      if (h2hError != null) {
        return Text(
          'All-time record unavailable — reopen to retry.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11.5.sp,
            fontWeight: FontWeight.w700,
          ),
        );
      }
      return const _RecordSkeleton();
    }

    final wins = h2h!['wins'] ?? 0;
    final draws = h2h!['draws'] ?? 0;
    final losses = h2h!['losses'] ?? 0;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatBlock(
                value: wins,
                label: 'WINS',
                color: AppColors.correct,
              ),
            ),
            const _StatDivider(),
            Expanded(
              child: _StatBlock(
                value: draws,
                label: 'DRAWS',
                color: AppColors.draw,
              ),
            ),
            const _StatDivider(),
            Expanded(
              child: _StatBlock(
                value: losses,
                label: 'LOSSES',
                color: AppColors.lose,
              ),
            ),
          ],
        ),
        SizedBox(height: 12.h),
        Text(
          'All-time · sparring and code duels included',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.sp,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _StatBlock extends StatelessWidget {
  final int value;
  final String label;
  final Color color;

  const _StatBlock({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value',
          style: TextStyle(
            color: color,
            fontSize: 24.sp,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
        SizedBox(height: 5.h),
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
    return Container(width: 1, height: 34.h, color: AppColors.divider);
  }
}

class _RecordSkeleton extends StatelessWidget {
  const _RecordSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) SizedBox(width: 12.w),
          Expanded(
            child: AppSkeleton(height: 40.h, radius: AppRadii.md),
          ),
        ],
      ],
    );
  }
}

// ─── Series panel (always visible) ───────────────────────────────────────────
class _SeriesPanel extends StatelessWidget {
  final int seriesNo;
  final int myWins;
  final int opWins;
  final String status;
  final bool iWon;
  final bool unavailable;
  final DateTime? lastPrizeAt;

  const _SeriesPanel({
    required this.seriesNo,
    required this.myWins,
    required this.opWins,
    required this.status,
    required this.iWon,
    required this.unavailable,
    required this.lastPrizeAt,
  });

  @override
  Widget build(BuildContext context) {
    final decided = status == 'decided' || status == 'expired';
    final accent = unavailable
        ? AppColors.textMuted
        : (decided ? AppColors.gold : AppColors.primary);

    final String tag;
    if (unavailable) {
      tag = 'UNAVAILABLE';
    } else if (status == 'expired') {
      tag = 'EXPIRED';
    } else if (status == 'decided') {
      tag = iWon ? 'WON' : 'DECIDED';
    } else {
      tag = 'LIVE';
    }

    final String caption;
    if (unavailable) {
      caption = 'Series score could not be read — showing what we have.';
    } else if (status == 'expired') {
      caption =
          'Next staked duel opens series ${seriesNo + 1}. Stale series never pay a prize.';
    } else if (status == 'decided') {
      caption = iWon
          ? 'You took it — next staked duel opens series ${seriesNo + 1}.'
          : 'They took it — next staked duel opens series ${seriesNo + 1}.';
    } else {
      caption = '';
    }

    String? prizeNote;
    if (!unavailable && lastPrizeAt != null) {
      final remaining =
          kSeriesPrizeCooldown - DateTime.now().difference(lastPrizeAt!);
      if (remaining > Duration.zero) {
        final days = (remaining.inHours / 24).ceil().clamp(1, 7);
        prizeNote =
            'Series prize on cooldown — back in $days day${days == 1 ? '' : 's'}.';
      }
    }

    return AppCard(
      padding: EdgeInsets.all(16.r),
      borderColor: accent.withValues(alpha: 0.40),
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
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Text('🏆', style: TextStyle(fontSize: 18.sp)),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'SERIES $seriesNo',
                      style: TextStyle(
                        color: accent,
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                        height: 1.1,
                      ),
                    ),
                    SizedBox(height: 3.h),
                    Text(
                      unavailable
                          ? 'Score unavailable'
                          : 'First to $kSeriesWinsRequired wins takes it',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10.5.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border: Border.all(color: accent.withValues(alpha: 0.35)),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    color: accent,
                    fontSize: 9.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 16.h),
          SeriesProgressBar(
            myWins: myWins,
            opWins: opWins,
            unavailable: unavailable,
          ),
          SizedBox(height: 14.h),
          if (caption.isNotEmpty)
            Text(
              caption,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          if (prizeNote != null) ...[
            SizedBox(height: 6.h),
            Text(
              prizeNote,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
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
        color: AppColors.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.45)),
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
        borderRadius: BorderRadius.circular(AppRadii.md),
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

// The foldable match-history section used to live here. It was removed to keep
// this page focused on the head-to-head record, the series and the two ways to
// play; the all-time W/D/L line in the face-off card already summarises form.
