// lib/features/multiplayer/multiplayer_hub_page.dart
//
// Battle tab — the "start something" launcher. One job: surface what needs your
// action right now, then hand you off to the ways to start a game (a named
// rival, a code duel, or a practice Quick Match). It owns no rivalry list and
// no discovery UI: those live on the Rivalries page, which this screen links
// to.
//
// Section order:
//   Header -> Your move -> Recent rivalry -> Start a duel -> Quick Match.
//
// READ COST: "Your move" is TWO one-shot challenge queries (creator side +
// opponent side). "Recent rivalry" is ONE recentRivals(limit 1) match query
// plus at most ONE rivalry-doc read for the series line. Nothing here attaches
// a Firestore listener; pull-to-refresh and returning from a pushed route
// re-run the reads. Quick Match state comes from UserDataProvider.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/constants/rival_economy.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/device_id_service.dart';
import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_empty_state.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/app_skeleton.dart';
import '../../core/widgets/rival_avatar.dart';
import '../../core/widgets/series_progress_bar.dart';
import '../../core/widgets/shared_widgets.dart';
import '../premium/premium_upsell_screen.dart';
import '../quiz/questions_page.dart';
import 'anime_select_page.dart';
import 'challenge_lobby_page.dart';
import 'join_challenge_page.dart';
import 'my_challenges_page.dart';
import 'rivalries_page.dart';
import 'rivalry_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
// MultiplayerHubPage — Battle tab
// ═══════════════════════════════════════════════════════════════════════════
class MultiplayerHubPage extends StatefulWidget {
  const MultiplayerHubPage({super.key});

  @override
  State<MultiplayerHubPage> createState() => _MultiplayerHubPageState();
}

class _MultiplayerHubPageState extends State<MultiplayerHubPage>
    with SingleTickerProviderStateMixin {
  /// Bumped after returning from a pushed route (or pull-to-refresh) so the
  /// one-shot sections re-run their reads.
  int _tick = 0;

  late final AnimationController _entrance;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    )..forward();
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  void _bump() {
    if (mounted) setState(() => _tick++);
  }

  Future<void> _push(Widget page) async {
    await Navigator.push(context, _slideRoute(page));
    _bump();
  }

  void _goQuickMatch() => _startMatchmaking();

  Future<void> _startMatchmaking() async {
    if (!mounted) return;
    final result = await showDialog<_MatchResult?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SearchingDialog(),
    );
    if (!mounted) return;
    if (result == null) return;
    if (result.noTokens) {
      _snack('No Quick Matches left today — watch an ad for one more, '
          'or come back tomorrow.');
      return;
    }
    if (result.tooManyActive) {
      _snack('You already have too many active challenges. Finish or leave one '
          'before starting a Quick Match.');
      return;
    }
    if (result.noMatch) {
      // Token NOT consumed in this case (server consumes it atomically with
      // the ghost reservation; see joinMatchmakingQueue). Confirmed in code.
      _snack('No ghost available right now — token not used. Try again soon.');
      return;
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => _MatchedDialog(result: result),
    );
    if (!mounted) return;
    Navigator.push(
      context,
      _slideRoute(
        QuestionsPage(
          mode: QuizMode.asyncChallenge,
          selectedTitles: [result.animeTitle],
          questionIds: result.questionIds,
          challengeId: result.challengeId,
          isCreator: result.isCreator,
          isQuickMatch: true,
          isGhost: result.isGhost,
          opponentName: result.opponentName,
        ),
      ),
    ).then((_) {
      if (mounted) _bump();
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ));
  }

  PageRoute _slideRoute(Widget page) => AppPageRoute(builder: (_) => page);

  @override
  Widget build(BuildContext context) {
    return _buildGated(context);
  }

  Widget _buildGated(BuildContext context) {
    final udp = context.watch<UserDataProvider>();

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.02),
              end: Offset.zero,
            ).animate(_fade),
            child: RefreshIndicator(
              color: AppColors.readable(AppColors.primary),
              backgroundColor: AppColors.surface,
              onRefresh: () async => _bump(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20.r, 18.r, 20.r, 40.r),
                children: [
                  _HubHeader(premiumActive: udp.premiumActive),
                  SizedBox(height: 16.h),
                  _MyChallengesEntry(
                    onTap: () => _push(const MyChallengesPage()),
                  ),
                  SizedBox(height: 22.h),
                  _YourMoveSection(
                    refreshTick: _tick,
                    onSeeAll: () => _push(const MyChallengesPage()),
                  ),
                  _RecentRivalrySection(
                    refreshTick: _tick,
                    onOpenRival: (uid, name) =>
                        _push(RivalryPage(rivalUid: uid, rivalUsername: name)),
                    onOpenRivalries: () => _push(const RivalriesPage()),
                  ),
                  SizedBox(height: 8.h),
                  Padding(
                    padding: EdgeInsets.only(left: 2.r, bottom: 12.r),
                    child: const SectionHeader(title: 'Start a duel'),
                  ),
                  _CreateJoinRow(
                    onCreate: () => _push(const AnimeSelectPage()),
                    onJoin: () => _push(const JoinChallengePage()),
                  ),
                  SizedBox(height: 22.h),
                  _QuickMatchSection(onQuickMatch: _goQuickMatch),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Header: title + premium chip + balances (display only) ───────────────────
class _HubHeader extends StatelessWidget {
  final bool premiumActive;

  const _HubHeader({required this.premiumActive});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text('Battle', style: AppTypography.heading1),
            ),
            SizedBox(width: 10.w),
            _BattlePremiumChip(premiumActive: premiumActive),
          ],
        ),
      ],
    );
  }
}

// ─── My challenges entry ───────────────────────────────────────────────────────
// Persistent hub affordance: the "Your move" card only appears when something
// needs THIS player's action, so a creator waiting on an opponent otherwise
// had no route to their own active/pending/completed list from the hub.
class _MyChallengesEntry extends StatelessWidget {
  final VoidCallback onTap;

  const _MyChallengesEntry({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 12.r),
      child: Row(
        children: [
          Container(
            width: 38.r,
            height: 38.r,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Icon(Icons.assignment_outlined,
                color: AppColors.readable(AppColors.primary), size: 20.r),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'My challenges',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.5.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded,
              color: AppColors.textMuted, size: 20.r),
        ],
      ),
    );
  }
}

// ─── Match result data class ──────────────────────────────────────────────────
List<String> _stringListOf(Object? raw) {
  if (raw is! List) return const [];
  return List<String>.unmodifiable(raw.map((e) => '$e'));
}

class _MatchResult {
  final bool noMatch;
  final bool noTokens;
  final bool tooManyActive;
  final List<String> questionIds;
  final String challengeId;
  final bool isGhost;
  final bool isCreator;
  final String opponentName;
  final String animeTitle;

  const _MatchResult.noMatch()
      : noMatch = true,
        noTokens = false,
        tooManyActive = false,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '';

  const _MatchResult.noTokens()
      : noMatch = false,
        noTokens = true,
        tooManyActive = false,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '';

  const _MatchResult.tooManyActive()
      : noMatch = false,
        noTokens = false,
        tooManyActive = true,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '';

  const _MatchResult({
    required this.questionIds,
    required this.challengeId,
    required this.isGhost,
    required this.isCreator,
    required this.opponentName,
    required this.animeTitle,
  })  : noMatch = false,
        noTokens = false,
        tooManyActive = false;
}

// ─── Searching dialog (safe, explicit no-ghost copy) ────────────────────────
class _SearchingDialog extends StatefulWidget {
  const _SearchingDialog();

  @override
  State<_SearchingDialog> createState() => _SearchingDialogState();
}

class _SearchingDialogState extends State<_SearchingDialog>
    with SingleTickerProviderStateMixin {
  bool _leaving = false;
  bool _done = false;
  late AnimationController _spinCtrl;
  late Animation<double> _spinAnim;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _spinAnim = Tween<double>(begin: 0, end: 1).animate(_spinCtrl);
    _callMatchmaking();
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    super.dispose();
  }

  Future<void> _callMatchmaking() async {
    if (!mounted || _leaving) return;
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('joinMatchmakingQueue');
      final result = await callable.call<Map<Object?, Object?>>({
        'deviceId': await DeviceIdService.instance.value(),
        ...AppUpdateService.instance.clientBuildStamp,
      });
      if (!mounted || _leaving || _done) return;
      _done = true;
      final data = Map<String, dynamic>.from(result.data);
      final matched = data['matched'] == true;
      final isGhost = data['isGhost'] == true;
      final animeTitle = data['animeTitle']?.toString() ?? '';
      final questionIds = _stringListOf(data['questionIds']);
      if (matched) {
        Navigator.of(context).pop(_MatchResult(
          questionIds: questionIds,
          challengeId: data['challengeId']?.toString() ?? '',
          isGhost: false,
          isCreator: data['isCreator'] == true,
          opponentName: data['opponentUsername']?.toString() ?? 'Opponent',
          animeTitle: animeTitle,
        ));
        return;
      }
      if (isGhost) {
        Navigator.of(context).pop(_MatchResult(
          questionIds: questionIds,
          challengeId: data['challengeId']?.toString() ?? '',
          isGhost: true,
          isCreator: true,
          opponentName:
              data['ghostUsername']?.toString() ?? 'Recorded Opponent',
          animeTitle: animeTitle,
        ));
        return;
      }
      Navigator.of(context).pop(const _MatchResult.noMatch());
    } on FirebaseFunctionsException catch (e) {
      if (!mounted || _leaving || _done) return;
      _done = true;
      if (e.message == 'no_qm_tokens') {
        Navigator.of(context).pop(const _MatchResult.noTokens());
        return;
      }
      if (e.message == 'too_many_active_challenges') {
        Navigator.of(context).pop(const _MatchResult.tooManyActive());
        return;
      }
      Navigator.of(context).pop(const _MatchResult.noMatch());
    } catch (_) {
      if (!mounted || _leaving || _done) return;
      _done = true;
      Navigator.of(context).pop(const _MatchResult.noMatch());
    }
  }

  Future<void> _handleCancel() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('leaveMatchmakingQueue')
          .call(AppUpdateService.instance.clientBuildStamp);
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleCancel();
      },
      child: Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: BorderSide(
              color: AppColors.primary.withValues(alpha: 0.30), width: 1.5),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(28.r, 34.r, 28.r, 26.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RotationTransition(
                turns: _spinAnim,
                child: Container(
                  width: 88.w,
                  height: 88.h,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary.withValues(alpha: 0.11),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.33),
                        width: 1.5),
                  ),
                  child: Center(
                      child: Text('⚡', style: TextStyle(fontSize: 32.sp))),
                ),
              ),
              SizedBox(height: 22.h),
              Text(
                'Finding a practice ghost…',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 6.h),
              Text(
                'No token is used until a ghost is found.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12.sp),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 24.h),
              GestureDetector(
                onTap: _leaving ? null : _handleCancel,
                child: AnimatedOpacity(
                  opacity: _leaving ? 0.35 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    padding:
                        EdgeInsets.symmetric(horizontal: 32.r, vertical: 13.r),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                          color: AppColors.divider.withValues(alpha: 0.7)),
                    ),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w600),
                    ),
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

// ─── Your move: actionable challenges only ────────────────────────────────────
class _YourMoveSection extends StatefulWidget {
  /// Bumped by the Hub after a route returns / pull-to-refresh.
  final int refreshTick;
  final VoidCallback onSeeAll;

  const _YourMoveSection({
    required this.refreshTick,
    required this.onSeeAll,
  });

  @override
  State<_YourMoveSection> createState() => _YourMoveSectionState();
}

class _YourMoveSectionState extends State<_YourMoveSection> {
  static const _activeStatuses = [
    'waiting',
    'opponent_joined',
    'creator_submitted',
    'opponent_submitted',
  ];

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _actionable = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_YourMoveSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) _load();
  }

  /// Two one-shot queries (creator side + opponent side), merged client-side.
  /// No listeners: the section re-reads when the Hub bumps its tick.
  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final db = FirebaseFirestore.instance;
      final snaps = await Future.wait([
        db
            .collection('challenges')
            .where('creatorUid', isEqualTo: uid)
            .where('status', whereIn: _activeStatuses)
            .get(),
        db
            .collection('challenges')
            .where('opponentUid', isEqualTo: uid)
            .where('status', whereIn: _activeStatuses)
            .get(),
      ]);
      final seen = <String>{};
      final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (final snap in snaps) {
        for (final doc in snap.docs) {
          if (!seen.add(doc.id)) continue;
          if (_actionLabel(doc.data(), uid) != null) docs.add(doc);
        }
      }
      if (!mounted) return;
      setState(() {
        _actionable = docs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _actionable = const [];
        _loading = false;
      });
    }
  }

  /// Only challenges needing THIS player's action. Returns null when the row
  /// should be hidden (waiting on the other side).
  String? _actionLabel(Map<String, dynamic> data, String uid) {
    final status = data['status'] as String? ?? '';
    final isQuick = data['isQuickMatch'] as bool? ?? false;
    final creatorUid = data['creatorUid'] as String? ?? '';
    final isCreator = creatorUid == uid;
    final creatorScore = data['creatorScore'];
    final opponentScore = data['opponentScore'];
    if (isQuick) {
      final mine = isCreator ? creatorScore : opponentScore;
      if (mine != null) return null; // waiting for ghost/real opponent
      return 'Your turn';
    }
    switch (status) {
      case 'waiting':
        return isCreator ? null : 'Your turn';
      case 'opponent_joined':
        if (isCreator) {
          return creatorScore == null ? 'Your turn' : null;
        } else {
          return opponentScore == null ? 'Your turn' : null;
        }
      case 'creator_submitted':
        return isCreator ? null : 'Your turn';
      case 'opponent_submitted':
        return isCreator ? 'Your turn' : null;
      default:
        return null;
    }
  }

  Future<void> _play() async {
    if (_actionable.isEmpty) return;
    await Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => ChallengeLobbyPage(challengeId: _actionable.first.id),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing waiting (or still loading / failed): render nothing at all.
    if (_loading || _actionable.isEmpty) return const SizedBox.shrink();

    final data = _actionable.first.data();
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isCreator = (data['creatorUid'] as String? ?? '') == uid;
    final opponent = isCreator
        ? (data['opponentUsername'] as String? ?? 'Opponent')
        : (data['creatorUsername'] as String? ?? 'Opponent');
    final animeTitle = data['animeTitle'] as String? ?? 'Challenge';
    final count = _actionable.length;

    return Padding(
      padding: EdgeInsets.only(bottom: 20.h),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            padding: EdgeInsets.all(14.r),
            borderColor: AppColors.primary.withValues(alpha: 0.45),
            child: Row(
              children: [
                Container(
                  width: 40.r,
                  height: 40.r,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  child: Icon(Icons.play_arrow_rounded,
                      color: AppColors.readable(AppColors.primary), size: 22.r),
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
                              'Your move',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 15.sp,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          if (count > 1) ...[
                            SizedBox(width: 8.w),
                            Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 8.r, vertical: 2.r),
                              decoration: BoxDecoration(
                                color:
                                    AppColors.primary.withValues(alpha: 0.11),
                                borderRadius:
                                    BorderRadius.circular(AppRadii.sm),
                                border: Border.all(
                                    color: AppColors.readable(AppColors.primary)
                                        .withValues(alpha: 0.33)),
                              ),
                              child: Text(
                                '$count',
                                style: TextStyle(
                                  color: AppColors.readable(
                                      AppColors.crimsonBright),
                                  fontSize: 11.sp,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      SizedBox(height: 4.h),
                      Text(
                        '$animeTitle · vs $opponent',
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
                SizedBox(width: 10.w),
                AppButton(
                  label: 'Play',
                  onPressed: _play,
                  variant: AppButtonVariant.primary,
                  size: AppButtonSize.small,
                  width: 88.w,
                  height: 40.h,
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: widget.onSeeAll,
              style: TextButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'See all',
                style: TextStyle(
                  color: AppColors.readable(AppColors.primary),
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Recent rivalry: the single most recent series ───────────────────────────
class _RecentRivalry {
  final RivalSummary rival;
  final bool hasSeries;
  final int seriesNo;
  final int myWins;
  final int opWins;
  final String status;

  const _RecentRivalry({
    required this.rival,
    required this.hasSeries,
    required this.seriesNo,
    required this.myWins,
    required this.opWins,
    required this.status,
  });

  String get seriesLine {
    if (!hasSeries) return 'No series yet — duel to start one';
    final lead = myWins == opWins
        ? 'tied'
        : (myWins > opWins ? 'you lead' : 'they lead');
    final suffix = status == 'decided'
        ? ' · decided'
        : status == 'expired'
            ? ' · expired'
            : '';
    return 'Series $seriesNo · $lead$suffix';
  }
}

class _RecentRivalrySection extends StatefulWidget {
  /// Bumped by the Hub after a route returns / pull-to-refresh.
  final int refreshTick;
  final void Function(String uid, String username) onOpenRival;
  final VoidCallback onOpenRivalries;

  const _RecentRivalrySection({
    required this.refreshTick,
    required this.onOpenRival,
    required this.onOpenRivalries,
  });

  @override
  State<_RecentRivalrySection> createState() => _RecentRivalrySectionState();
}

class _RecentRivalrySectionState extends State<_RecentRivalrySection> {
  late Future<_RecentRivalry?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(_RecentRivalrySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) {
      // Block body on purpose: an arrow body would return the assigned Future,
      // which setState() rejects.
      setState(() {
        _future = _load();
      });
    }
  }

  /// ONE recentRivals(limit 1) match query, then at most ONE rivalry-doc read
  /// for the series state. Returns null when the player has no named rival yet.
  Future<_RecentRivalry?> _load() async {
    final rivals = await FirestoreService.instance.recentRivals(limit: 1);
    if (rivals.isEmpty) return null;
    final rival = rivals.first;

    Map<String, dynamic>? state;
    try {
      final states = await FirestoreService.instance.rivalryStates([rival.uid]);
      state = states[rival.uid];
    } catch (_) {
      // Unreadable series falls back to the "no series yet" copy.
    }

    if (state == null) {
      return _RecentRivalry(
        rival: rival,
        hasSeries: false,
        seriesNo: 1,
        myWins: 0,
        opWins: 0,
        status: 'active',
      );
    }

    final myUid = FirestoreService.instance.currentUid ?? '';
    final isA = myUid == (state['aUid'] as String?);
    return _RecentRivalry(
      rival: rival,
      hasSeries: true,
      seriesNo: ((state['seriesNo'] as num?)?.toInt()) ?? 1,
      myWins: ((isA ? state['winsA'] : state['winsB']) as num?)?.toInt() ?? 0,
      opWins: ((isA ? state['winsB'] : state['winsA']) as num?)?.toInt() ?? 0,
      status: (state['status'] as String?) ?? 'active',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 2.r, bottom: 12.r),
          child: const SectionHeader(title: 'Recent rivalry'),
        ),
        FutureBuilder<_RecentRivalry?>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const _RecentRivalrySkeleton();
            }
            final data = snap.data;
            if (data == null) {
              return AppCard(
                padding: EdgeInsets.zero,
                child: AppEmptyState(
                  icon: Icons.sports_kabaddi_rounded,
                  title: 'No rivalries yet',
                  color: AppColors.readable(AppColors.rival),
                  action: AppButton(
                    label: 'Find a rival',
                    icon: const Icon(Icons.person_search_rounded),
                    onPressed: widget.onOpenRivalries,
                    variant: AppButtonVariant.primary,
                    size: AppButtonSize.small,
                  ),
                ),
              );
            }
            return _recentCard(data);
          },
        ),
      ],
    );
  }

  Widget _recentCard(_RecentRivalry data) {
    final rival = data.rival;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          onTap: () => widget.onOpenRival(rival.uid, rival.username),
          padding: EdgeInsets.all(14.r),
          child: Row(
            children: [
              RivalAvatar(
                name: rival.username,
                size: 48.r,
                color: AppColors.readable(AppColors.rival),
                highlight: true,
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      rival.username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      data.seriesLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (data.hasSeries) ...[
                      SizedBox(height: 8.h),
                      SeriesProgressBar(
                        myWins: data.myWins,
                        opWins: data.opWins,
                        compact: true,
                      ),
                    ],
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
        SizedBox(height: 2.h),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.onOpenRivalries,
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'View more',
                  style: TextStyle(
                    color: AppColors.readable(AppColors.primary),
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(width: 4.w),
                Icon(Icons.arrow_forward_rounded,
                    color: AppColors.readable(AppColors.primary), size: 14.r),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RecentRivalrySkeleton extends StatelessWidget {
  const _RecentRivalrySkeleton();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.all(14.r),
      child: Row(
        children: [
          AppSkeleton(width: 48.r, height: 48.r, radius: 24.r),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppSkeleton(width: 130.w, height: 14.h),
                SizedBox(height: 8.h),
                AppSkeleton(width: 170.w, height: 11.h),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Create and Join: the two ways in, side by side ───────────────────────────
class _CreateJoinRow extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  const _CreateJoinRow({required this.onCreate, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AppButton(
            label: 'Create',
            icon: const Icon(Icons.add_rounded),
            onPressed: onCreate,
            variant: AppButtonVariant.primary,
            size: AppButtonSize.medium,
            height: 52.h,
          ),
        ),
        SizedBox(width: 12.w),
        Expanded(
          child: AppButton(
            label: 'Join',
            icon: const Icon(Icons.vpn_key_rounded),
            onPressed: onJoin,
            variant: AppButtonVariant.outline,
            size: AppButtonSize.medium,
            height: 52.h,
          ),
        ),
      ],
    );
  }
}

// ─── Quick Match: the last block on the page ──────────────────────────────────
class _QuickMatchSection extends StatefulWidget {
  final VoidCallback onQuickMatch;

  const _QuickMatchSection({required this.onQuickMatch});

  @override
  State<_QuickMatchSection> createState() => _QuickMatchSectionState();
}

class _QuickMatchSectionState extends State<_QuickMatchSection> {
  bool _watchingAd = false;

  Future<void> _handleWatchAd() async {
    if (_watchingAd) return;
    // Captured before the await: the messenger survives the ad flow, so no
    // BuildContext is touched across an async gap.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _watchingAd = true);
    final shown = await AdService.instance.showQMTokenAd(
      context: context,
      onTokenGranted: () {
        messenger.showSnackBar(const SnackBar(
          content: Text('🎟 +1 token granted!'),
          behavior: SnackBarBehavior.floating,
        ));
      },
    );
    if (!shown) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Ad not ready yet — try again in a moment.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
    if (mounted) setState(() => _watchingAd = false);
  }

  @override
  Widget build(BuildContext context) {
    final udp = context.watch<UserDataProvider>();
    final qmTokens = udp.qmTokens;
    final qmAdTokenUsed = udp.qmAdTokenUsed;
    final premiumActive = udp.premiumActive;
    final dailyMax = premiumActive ? kQmDailyPremium : kQmDailyFree;
    final outOfTokens = qmTokens == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          onTap: widget.onQuickMatch,
          padding: EdgeInsets.all(14.r),
          borderColor: AppColors.primary.withValues(alpha: 0.35),
          child: Row(
            children: [
              Container(
                width: 44.r,
                height: 44.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Icon(Icons.bolt_rounded,
                    color: AppColors.readable(AppColors.primary), size: 24.r),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Quick Match',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      'Practice vs a ghost recording · no series',
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
              SizedBox(width: 10.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.full),
                  border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.30)),
                ),
                child: Text(
                  '$qmTokens/$dailyMax',
                  style: TextStyle(
                    color: AppColors.readable(AppColors.primary),
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (outOfTokens && !qmAdTokenUsed) ...[
          SizedBox(height: 10.h),
          AppButton(
            label: _watchingAd
                ? 'Loading ad…'
                : '📺  Watch ad for a Quick Match token',
            onPressed: _watchingAd ? null : _handleWatchAd,
            variant: AppButtonVariant.outline,
            size: AppButtonSize.small,
            color: AppColors.readable(AppColors.accent),
            width: double.infinity,
          ),
        ] else if (outOfTokens && qmAdTokenUsed) ...[
          SizedBox(height: 8.h),
          Text(
            'Tokens reset tomorrow.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Matched dialog (safe auto-dismiss) ───────────────────────────────────────
class _MatchedDialog extends StatefulWidget {
  final _MatchResult result;
  const _MatchedDialog({required this.result});

  @override
  State<_MatchedDialog> createState() => _MatchedDialogState();
}

class _MatchedDialogState extends State<_MatchedDialog> {
  Timer? _autoDismissTimer;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    // Safe: guarded by mounted + cancelled on dispose; tap continues now.
    _autoDismissTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _gone) return;
      _gone = true;
      Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    super.dispose();
  }

  void _continueNow() {
    if (_gone) return;
    _gone = true;
    _autoDismissTimer?.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.xl),
        side: BorderSide(
            color: AppColors.primary.withValues(alpha: 0.40), width: 1.5),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24.r, 30.r, 24.r, 24.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('GHOST FOUND!',
                style: TextStyle(
                    color: AppColors.readable(AppColors.crimsonBright),
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.5)),
            SizedBox(height: 12.h),
            Text(result.opponentName,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 24.sp,
                    fontWeight: FontWeight.w900)),
            SizedBox(height: 8.h),
            Text(result.animeTitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 15.sp)),
            if (result.isGhost) ...[
              SizedBox(height: 14.h),
              Text('Beat their score to win',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.readable(AppColors.crimsonBright),
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w700)),
            ],
            SizedBox(height: 20.h),
            AppButton(
              label: 'Start battle',
              onPressed: _continueNow,
              variant: AppButtonVariant.primary,
              size: AppButtonSize.small,
              width: double.infinity,
              height: 42.h,
            ),
            SizedBox(height: 8.h),
            Text('Continuing automatically…',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11.sp)),
          ],
        ),
      ),
    );
  }
}

// ─── Battle header premium chip ───────────────────────────────────────────────
class _BattlePremiumChip extends StatelessWidget {
  final bool premiumActive;
  const _BattlePremiumChip({required this.premiumActive});

  @override
  Widget build(BuildContext context) {
    const gold = AppColors.gold;
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        AppPageRoute(builder: (_) => const PremiumUpsellScreen()),
      ),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: gold.withValues(alpha: premiumActive ? 0.13 : 0.10),
          borderRadius: BorderRadius.circular(AppRadii.full),
          border: Border.all(color: gold.withValues(alpha: 0.38)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('👑', style: TextStyle(fontSize: 12.sp)),
            SizedBox(width: 4.w),
            Text(
              premiumActive ? 'PREMIUM' : 'GET',
              style: TextStyle(
                color: AppColors.readable(gold),
                fontWeight: FontWeight.w800,
                fontSize: 11.sp,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
