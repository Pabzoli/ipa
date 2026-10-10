// lib/features/multiplayer/multiplayer_hub_page.dart
//
// Battle tab — rebuilt around the rivalry series (first to 3, staked ranked
// duels only; draws replay; spars never count).
//
// Section order (locked):
//   Header -> Your move -> Rivalries (live) -> Find a rival -> Quick Match
//   (practice) -> Payout Rules table.
//
// READ-COST NOTE (avoiding N+1 blowups): the Rivalries section issues ONE
// users/{uid}/matches query via recentRivals(limit 8) to discover rivals,
// then opens at most 5 live rivalry-doc streams + 5 one-shot rival-WP reads
// for bounty chips. History/H2H reuse the RivalSummary already in memory;
// no per-row matches query is issued here. RivalryPage owns the deeper
// per-rival history stream.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../../core/services/firestore_service.dart';
import '../../core/constants/rival_economy.dart';
import '../quiz/questions_page.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_page_route.dart';
import 'anime_select_page.dart';
import 'join_challenge_page.dart';
import 'my_challenges_page.dart';
import 'challenge_lobby_page.dart';
import 'rivalry_page.dart';
import 'rivalries_page.dart';
import '../leaderboard/weekly_leaderboard_page.dart';
import '../premium/premium_upsell_screen.dart';

abstract final class _C {
  static const surface = AppColors.surface;
  static const elevated = AppColors.surfaceAlt;
  static const crimson = AppColors.primary;
  static const crimsonBright = AppColors.crimsonBright;
  static const crimsonGlow = Color(0x1CE63946);
  static const crimsonBorder = Color(0x55E63946);
  static const sky = AppColors.secondary;
  static const text = AppColors.textPrimary;
  static const textSub = AppColors.textSecondary;
  static const textMuted = AppColors.textMuted;
  static const divider = AppColors.divider;
  static const border = Color(0xFF252538);
  static const rival = AppColors.rival;
}

// ═══════════════════════════════════════════════════════════════════════════
// MultiplayerHubPage — Battle tab
// ═══════════════════════════════════════════════════════════════════════════
class MultiplayerHubPage extends StatefulWidget {
  const MultiplayerHubPage({super.key});

  @override
  State<MultiplayerHubPage> createState() => _MultiplayerHubPageState();
}

class _MultiplayerHubPageState extends State<MultiplayerHubPage> {
  void _goCreate() =>
      Navigator.push(context, _slideRoute(const AnimeSelectPage()));
  void _goJoin() =>
      Navigator.push(context, _slideRoute(const JoinChallengePage()));
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
    );
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
    final udp = context.watch<UserDataProvider>();
    final animeCoins = udp.animeCoins;
    final weeklyPoints = udp.weeklyPoints;
    final premiumActive = udp.premiumActive;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // ── Header: balances ──────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 18.r, 20.r, 0.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Battle',
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 27.sp,
                                  fontWeight: FontWeight.w900,
                                  height: 1.1,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 12.w),
                        _BattlePremiumChip(premiumActive: premiumActive),
                        SizedBox(width: 8.w),
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 12.r, vertical: 6.r),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(20.r),
                            border: Border.all(
                                color:
                                    AppColors.accent.withValues(alpha: 0.38)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('🪙', style: TextStyle(fontSize: 14.sp)),
                              SizedBox(width: 5.w),
                              Text(
                                '$animeCoins',
                                style: TextStyle(
                                  color: AppColors.accent,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.sp,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 8.w),
                        GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    const WeeklyLeaderboardPage()),
                          ),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: 12.r, vertical: 6.r),
                            decoration: BoxDecoration(
                              color: _C.sky.withValues(alpha: 0.13),
                              borderRadius: BorderRadius.circular(20.r),
                              border: Border.all(
                                  color: _C.sky.withValues(alpha: 0.38)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('⭐', style: TextStyle(fontSize: 14.sp)),
                                SizedBox(width: 5.w),
                                Text(
                                  '$weeklyPoints',
                                  style: TextStyle(
                                    color: _C.sky,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14.sp,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // ── Your move: actionable challenges only ─────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 20.r, 20.r, 0.r),
                child: const _YourMoveSection(),
              ),
            ),

            // ── Rivalries (live series cards) ─────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 16.r, 20.r, 0.r),
                child: _RivalriesSection(
                  onCreate: _goCreate,
                  onJoin: _goJoin,
                ),
              ),
            ),

            // ── Find a rival: single row ──────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
                child: _FindRivalRow(
                  onCreate: _goCreate,
                  onJoin: _goJoin,
                ),
              ),
            ),

            // ── Quick Match (practice vs ghost) ───────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
                child: QuickMatchCard(onStartMatchmaking: _goQuickMatch),
              ),
            ),

            // ── Payout Rules table ────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 40.r),
                child: const _RewardsTable(),
              ),
            ),
          ],
        ),
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
  final int ghostScore;

  const _MatchResult.noMatch()
      : noMatch = true,
        noTokens = false,
        tooManyActive = false,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '',
        ghostScore = 0;

  const _MatchResult.noTokens()
      : noMatch = false,
        noTokens = true,
        tooManyActive = false,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '',
        ghostScore = 0;

  const _MatchResult.tooManyActive()
      : noMatch = false,
        noTokens = false,
        tooManyActive = true,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '',
        ghostScore = 0;

  const _MatchResult({
    required this.questionIds,
    required this.challengeId,
    required this.isGhost,
    required this.isCreator,
    required this.opponentName,
    required this.animeTitle,
    this.ghostScore = 0,
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
      final result = await callable.call<Map<Object?, Object?>>({});
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
          opponentName: data['ghostUsername']?.toString() ?? 'Recorded Opponent',
          animeTitle: animeTitle,
          ghostScore: (data['ghostScore'] as num?)?.toInt() ?? 0,
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
          .call();
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
        backgroundColor: _C.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24.r),
          side:
              BorderSide(color: _C.crimson.withValues(alpha: 0.30), width: 1.5),
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
                    color: _C.crimsonGlow,
                    border: Border.all(color: _C.crimsonBorder, width: 1.5),
                  ),
                  child: Center(
                      child: Text('⚡', style: TextStyle(fontSize: 32.sp))),
                ),
              ),
              SizedBox(height: 22.h),
              Text(
                'Finding a practice ghost…',
                style: TextStyle(
                  color: _C.text,
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 6.h),
              Text(
                'No token is used until a ghost is found.',
                style: TextStyle(color: _C.textMuted, fontSize: 12.sp),
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
                      color: _C.elevated,
                      borderRadius: BorderRadius.circular(12.r),
                      border:
                          Border.all(color: _C.border.withValues(alpha: 0.7)),
                    ),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                          color: _C.textSub,
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
  const _YourMoveSection();

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

  StreamSubscription<QuerySnapshot>? _creatorSub;
  StreamSubscription<QuerySnapshot>? _opponentSub;
  List<QueryDocumentSnapshot> _creatorDocs = [];
  List<QueryDocumentSnapshot> _opponentDocs = [];
  bool _loading = true;
  Object? _streamError;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _setupStreams();
  }

  void _setupStreams() {
    final uid = _uid;
    if (uid == null) {
      setState(() => _loading = false);
      return;
    }
    final db = FirebaseFirestore.instance;
    _creatorSub = db
        .collection('challenges')
        .where('creatorUid', isEqualTo: uid)
        .where('status', whereIn: _activeStatuses)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _creatorDocs = snap.docs;
        _loading = false;
      });
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        _streamError = e;
        _loading = false;
      });
    });
    _opponentSub = db
        .collection('challenges')
        .where('opponentUid', isEqualTo: uid)
        .where('status', whereIn: _activeStatuses)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _opponentDocs = snap.docs;
        _loading = false;
      });
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        _streamError = e;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _creatorSub?.cancel();
    _opponentSub?.cancel();
    super.dispose();
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

  String _detailLine(Map<String, dynamic> data, String uid) {
    final creatorUid = data['creatorUid'] as String? ?? '';
    final isCreator = creatorUid == uid;
    final creatorScore = (data['creatorScore'] as num?)?.toInt();
    final opponentScore = (data['opponentScore'] as num?)?.toInt();
    final otherScore = isCreator ? opponentScore : creatorScore;
    final otherName = isCreator
        ? (data['opponentUsername'] as String? ?? 'Opponent')
        : (data['creatorUsername'] as String? ?? 'Opponent');
    if (otherScore != null) return '$otherName scored $otherScore/10 — beat it';
    return 'Waiting for $otherName';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_streamError != null) {
      return Container(
        padding: EdgeInsets.all(14.r),
        decoration: BoxDecoration(
          color: _C.surface,
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(color: _C.border.withValues(alpha: 0.5)),
        ),
        child: Text(
          'Could not load your move: $_streamError',
          style: TextStyle(color: _C.textMuted, fontSize: 12.sp),
        ),
      );
    }
    final uid = _uid ?? '';
    final seen = <String>{};
    final actionable = <QueryDocumentSnapshot>[];
    for (final doc in [..._creatorDocs, ..._opponentDocs]) {
      if (!seen.add(doc.id)) continue;
      final data = doc.data() as Map<String, dynamic>;
      if (_actionLabel(data, uid) != null) actionable.add(doc);
    }
    if (actionable.isEmpty) return const SizedBox.shrink();
    final visible =
        actionable.length > 3 ? actionable.sublist(0, 3) : actionable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 2.r, bottom: 12.r),
          child: Row(
            children: [
              Text(
                'Your move',
                style: TextStyle(
                  color: _C.text,
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 2.r),
                decoration: BoxDecoration(
                  color: _C.crimsonGlow,
                  borderRadius: BorderRadius.circular(10.r),
                  border: Border.all(color: _C.crimsonBorder),
                ),
                child: Text(
                  '${actionable.length}',
                  style: TextStyle(
                    color: _C.crimsonBright,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final doc in visible)
          Padding(
            padding: EdgeInsets.only(bottom: 10.r),
            child: _YourMoveCard(
              doc: doc,
              actionLabel: _actionLabel(
                  doc.data() as Map<String, dynamic>, uid)!,
              detail: _detailLine(doc.data() as Map<String, dynamic>, uid),
            ),
          ),
        if (actionable.length > 3)
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MyChallengesPage()),
            ),
            child: const Text('See all'),
          ),
        SizedBox(height: 8.h),
      ],
    );
  }
}

class _YourMoveCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final String actionLabel;
  final String detail;
  const _YourMoveCard(
      {required this.doc, required this.actionLabel, required this.detail});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final animeTitle = data['animeTitle'] as String? ?? 'Unknown Anime';
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isCreator = (data['creatorUid'] as String? ?? '') == uid;
    final opponentName = isCreator
        ? (data['opponentUsername'] as String? ?? 'Opponent')
        : (data['creatorUsername'] as String? ?? 'Opponent');
    final stakeAmount = (data['stakeAmount'] as num?)?.toInt() ?? 0;
    final wpStake = (data['wpStake'] as num?)?.toInt() ?? 0;
    final questionIds = _stringListOf(data['questionIds']);

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(
            color: _C.crimson.withValues(alpha: 0.45), width: 1.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(animeTitle,
                    style: TextStyle(
                        color: _C.text,
                        fontSize: 13.sp,
                        fontWeight: FontWeight.w700)),
                SizedBox(height: 3.h),
                Text('vs $opponentName',
                    style: TextStyle(color: _C.textMuted, fontSize: 11.sp)),
                SizedBox(height: 4.h),
                Text(actionLabel,
                    style: TextStyle(
                        color: _C.crimsonBright,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w800)),
                SizedBox(height: 2.h),
                Text(detail,
                    style: TextStyle(color: _C.textMuted, fontSize: 11.sp)),
                if (stakeAmount > 0 || wpStake > 0) ...[
                  SizedBox(height: 4.h),
                  Text('🪙 $stakeAmount AC · ⭐ $wpStake WP',
                      style: TextStyle(color: _C.textMuted, fontSize: 10.sp)),
                ],
              ],
            ),
          ),
          SizedBox(width: 10.w),
          if (questionIds.isNotEmpty)
            AppButton(
              label: 'Play',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ChallengeLobbyPage(challengeId: doc.id),
                ),
              ),
              variant: AppButtonVariant.primary,
              size: AppButtonSize.small,
              width: 90.w,
              height: 38.h,
            ),
        ],
      ),
    );
  }
}

// ─── Rivalries: live series cards ─────────────────────────────────────────────
class _RivalriesSection extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onJoin;
  const _RivalriesSection({required this.onCreate, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 10.r),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: _C.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Rivalries',
            style: TextStyle(
              color: _C.text,
              fontSize: 16.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          SizedBox(height: 4.h),
          FutureBuilder<List<RivalSummary>>(
            future: FirestoreService.instance.recentRivals(limit: 8),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return Padding(
                  padding: EdgeInsets.symmetric(vertical: 14.h),
                  child: const Center(
                    child: CircularProgressIndicator(color: _C.rival),
                  ),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: EdgeInsets.symmetric(vertical: 10.h),
                  child: Text(
                    'Could not load rivalries: ${snap.error}. Pull to retry by reopening Battle.',
                    style: TextStyle(color: _C.textMuted, fontSize: 12.sp),
                  ),
                );
              }
              final rivals = (snap.data ?? []).take(5).toList();
              if (rivals.isEmpty) {
                return Padding(
                  padding: EdgeInsets.fromLTRB(4.r, 10.r, 4.r, 8.r),
                  child: Text(
                    'No rivalries yet.\n\nHow it works: you play first, share the code, best score wins. '
                    'Staked duels count toward a first-to-$kSeriesWinsRequired series; draws replay and never count. '
                    'Tap Find a rival below to start one.',
                    style: TextStyle(
                      color: _C.textMuted,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w600,
                      height: 1.5,
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  SizedBox(height: 8.h),
                  for (final r in rivals)
                    _RivalryLiveCard(summary: r),
                  SizedBox(height: 2.h),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const RivalriesPage()),
                      ),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8.r, vertical: 4.r),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'View rivalries →',
                        style: TextStyle(
                          color: _C.sky,
                          fontSize: 12.sp,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RivalryLiveCard extends StatelessWidget {
  final RivalSummary summary;
  const _RivalryLiveCard({required this.summary});

  String _tag({
    required int myWins,
    required int opWins,
    required bool lastWasLoss,
    required bool hasSeries,
  }) {
    if (!hasSeries) return 'New series';
    if (myWins == kSeriesWinsRequired - 1) return 'Match point';
    if (myWins == 0 && opWins == kSeriesWinsRequired - 1) return 'Down 0–2';
    if (lastWasLoss) return 'Revenge';
    return 'Series live';
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirestoreService.instance.currentUid ?? '';
    return StreamBuilder<Map<String, dynamic>?>(
      stream: FirestoreService.instance.rivalryStream(summary.uid),
      builder: (context, seriesSnap) {
        if (seriesSnap.hasError) {
          return _rivalryCardShell(
            context: context,
            seriesLine: 'You 0–0 ${summary.username}',
            seriesNoLine: 'Series —',
            tag: 'New series',
            seriesData: null,
            seriesError: true,
          );
        }
        final data = seriesSnap.data;
        int myWins = 0;
        int opWins = 0;
        int seriesNo = 1;
        String status = 'active';
        DateTime? lastPrizeAt;
        bool hasSeries = false;
        if (data != null) {
          final isA = myUid == (data['aUid'] as String?);
          myWins = ((isA ? data['winsA'] : data['winsB']) as num?)?.toInt() ?? 0;
          opWins = ((isA ? data['winsB'] : data['winsA']) as num?)?.toInt() ?? 0;
          seriesNo = ((data['seriesNo'] as num?)?.toInt()) ?? 1;
          status = (data['status'] as String?) ?? 'active';
          final rawPrize = data['lastSeriesPrizeAt'];
          if (rawPrize is Timestamp) lastPrizeAt = rawPrize.toDate();
          hasSeries = (myWins + opWins) > 0 || status != 'active';
          if (status == 'decided' || status == 'expired') hasSeries = true;
        }
        final tag = status == 'expired'
            ? 'New series'
            : status == 'decided'
                ? 'New series'
                : _tag(
                    myWins: myWins,
                    opWins: opWins,
                    lastWasLoss: summary.lastWasLoss,
                    hasSeries: hasSeries,
                  );
        return _rivalryCardShell(
          context: context,
          seriesLine: 'You $myWins–$opWins ${summary.username}',
          seriesNoLine: 'Series $seriesNo'
              '${status == 'expired' ? ' · last one expired' : status == 'decided' ? ' · decided' : ''}',
          tag: tag,
          seriesData: data,
          seriesError: false,
          lastPrizeAt: lastPrizeAt,
          status: status,
        );
      },
    );
  }

  Widget _rivalryCardShell({
    required BuildContext context,
    required String seriesLine,
    required String seriesNoLine,
    required String tag,
    required Map<String, dynamic>? seriesData,
    required bool seriesError,
    DateTime? lastPrizeAt,
    String status = 'active',
  }) {
    final myUid = FirestoreService.instance.currentUid ?? '';
    String? prizeLine;
    if (lastPrizeAt != null) {
      final elapsed = DateTime.now().difference(lastPrizeAt);
      final remaining = kSeriesPrizeCooldown - elapsed;
      if (remaining > Duration.zero) {
        final days = (remaining.inHours / 24).ceil().clamp(1, 7);
        prizeLine = 'Prize available again in $days day${days == 1 ? '' : 's'}';
      }
    }
    prizeLine ??= 'Win series: +$kSeriesAcPrize AC';

    return Container(
      margin: EdgeInsets.only(bottom: 10.h),
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: _C.elevated,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: _C.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(seriesLine,
                    style: TextStyle(
                        color: _C.text,
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w900)),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
                decoration: BoxDecoration(
                  color: _C.rival.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text(tag,
                    style: TextStyle(
                        color: _C.rival,
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          SizedBox(height: 2.h),
          Text(seriesNoLine,
              style: TextStyle(color: _C.textMuted, fontSize: 11.sp)),
          SizedBox(height: 4.h),
          Text(
            '${summary.wins}W · ${summary.draws}D · ${summary.losses}L all-time incl. sparring',
            style: TextStyle(color: _C.textMuted, fontSize: 11.sp),
          ),
          SizedBox(height: 6.h),
          Wrap(
            spacing: 6.w,
            runSpacing: 6.h,
            children: [
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
                decoration: BoxDecoration(
                  color: AppColors.coinGold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                      color: AppColors.coinGold.withValues(alpha: 0.4)),
                ),
                child: Text('🏆 $prizeLine',
                    style: TextStyle(
                        color: AppColors.coinGold,
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w700)),
              ),
              _BountyChip(
                rivalUid: summary.uid,
                myUid: myUid,
                status: status,
              ),
            ],
          ),
          if (seriesError) ...[
            SizedBox(height: 4.h),
            Text('Series score unavailable — showing record only.',
                style: TextStyle(color: _C.textMuted, fontSize: 10.sp)),
          ],
          SizedBox(height: 8.h),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Play next game',
                  onPressed: () => Navigator.of(context).push(
                    AppPageRoute(
                      builder: (_) => RivalryPage(
                        rivalUid: summary.uid,
                        rivalUsername: summary.username,
                      ),
                    ),
                  ),
                  variant: AppButtonVariant.primary,
                  size: AppButtonSize.small,
                  width: double.infinity,
                  height: 38.h,
                ),
              ),
              SizedBox(width: 8.w),
              Expanded(
                child: AppButton(
                  label: 'Spar',
                  onPressed: () => Navigator.of(context).push(
                    AppPageRoute(
                      builder: (_) => AnimeSelectPage(
                        opponentUid: summary.uid,
                        opponentUsername: summary.username,
                        onSelect: (title) =>
                            _startSpar(context, title, summary),
                      ),
                    ),
                  ),
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.small,
                  width: double.infinity,
                  height: 38.h,
                ),
              ),
            ],
          ),
          FutureBuilder<String?>(
            future: _cooldownEstimate(summary.uid),
            builder: (context, snap) {
              final t = snap.data;
              if (t == null || t.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: EdgeInsets.only(top: 6.h),
                child: Text('Cooldown estimate: $t',
                    style: TextStyle(
                        color: _C.textMuted,
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w600)),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _startSpar(
      BuildContext context, String title, RivalSummary r) async {
    try {
      final res = await FirestoreService.instance.createSparChallenge(
        animeTitle: title,
        opponentUid: r.uid,
        opponentUsername: r.username,
      );
      final challengeId = res['challengeId']?.toString() ?? '';
      final rawIds = res['questionIds'];
      if (!context.mounted) return;
      if (challengeId.isEmpty || rawIds is! List) throw Exception('failed');
      final questionIds =
          List<String>.unmodifiable(rawIds.map((e) => '$e'));
      Navigator.of(context).pushReplacement(
        AppPageRoute(
          builder: (_) => QuestionsPage(
            mode: QuizMode.asyncChallenge,
            selectedTitles: [title],
            questionIds: questionIds,
            challengeId: challengeId,
            isCreator: true,
            opponentName: r.username,
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!context.mounted) return;
      final msg = e.message ?? '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          msg.contains('not_friends')
              ? 'Add them as a friend to spar.'
              : msg.contains('daily_spar_limit_reached')
                  ? 'Daily spar limit reached — come back tomorrow.'
                  : 'Could not start the spar — please try again.',
        ),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not start the spar — please try again.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  /// Estimate only — the server enforces 12h/6h inside its transaction and
  /// skips it inside an active series. Never shown as authoritative.
  Future<String?> _cooldownEstimate(String rivalUid) async {
    try {
      final me = FirebaseFirestore.instance
          .collection('users')
          .doc(FirestoreService.instance.currentUid);
      final snap = await me.get();
      final data = snap.data() ?? {};
      final map =
          (data['rivalCooldowns'] as Map<String, dynamic>?) ?? const {};
      final raw = map[rivalUid];
      DateTime? at;
      if (raw is Timestamp) at = raw.toDate();
      if (at == null) {
        // Legacy single-pair fallback.
        final udpUid = data['lastRivalUid'] as String?;
        final udpAt = data['lastRivalChallenge'];
        if (udpUid == rivalUid && udpAt is Timestamp) at = udpAt.toDate();
      }
      if (at == null) return null;
      // Series-aware skip: if an active series has games, server skips.
      try {
        final meUid = FirestoreService.instance.currentUid ?? '';
        final pair = [meUid, rivalUid]..sort();
        final rSnap = await FirebaseFirestore.instance
            .collection('rivalries')
            .doc('${pair[0]}_${pair[1]}')
            .get();
        final r = rSnap.data() ?? {};
        final w =
            (((r['winsA'] as num?)?.toInt()) ?? 0) +
                (((r['winsB'] as num?)?.toInt()) ?? 0);
        if ((r['status'] as String?) == 'active' && w > 0) {
          return 'none inside this active series (estimate)';
        }
      } catch (_) {}
      final elapsed = DateTime.now().difference(at).inHours;
      final isPremium = await _isPremium();
      final cd = isPremium
          ? kRivalCooldownPremiumHours
          : kRivalCooldownFreeHours;
      final left = cd - elapsed;
      if (left <= 0) return null;
      return '~$left h left (estimate)';
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isPremium() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(FirestoreService.instance.currentUid)
          .get();
      return (snap.data()?['premiumActive'] as bool?) ?? false;
    } catch (_) {
      return false;
    }
  }
}

class _BountyChip extends StatelessWidget {
  final String rivalUid;
  final String myUid;
  final String status;
  const _BountyChip(
      {required this.rivalUid, required this.myUid, required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == 'expired' || status == 'decided') {
      return const SizedBox.shrink();
    }
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance
          .collection('users')
          .doc(rivalUid)
          .get(),
      builder: (context, rivalSnap) {
        if (rivalSnap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        if (rivalSnap.hasError) {
          return _chip('🎯 Bounty unavailable', AppColors.textMuted);
        }
        final rivalData = rivalSnap.data?.data();
        if (rivalData == null) {
          // Permission-denied and missing both land here via error path on
          // most SDKs; surface as unavailable, never silently hide.
          return _chip('🎯 Bounty unavailable', AppColors.textMuted);
        }
        final rivalWp = ((rivalData['weeklyPoints'] as num?)?.toInt()) ?? 0;
        final myWp =
            Provider.of<UserDataProvider>(context, listen: false).weeklyPoints;
        final gap = rivalWp - myWp;
        if (gap >= kBountyWpGap) {
          return _chip('🎯 Bounty +$kBountyWpBonus WP if you win',
              const Color(0xFFF59E0B));
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 10.sp, fontWeight: FontWeight.w700)),
    );
  }
}

// ─── Find a rival: single row ─────────────────────────────────────────────────
class _FindRivalRow extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onJoin;
  const _FindRivalRow({required this.onCreate, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: _C.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Find a rival',
              style: TextStyle(
                  color: _C.text,
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w800)),
          SizedBox(height: 4.h),
          Text('Recent foes · campus · code — one tap to start.',
              style: TextStyle(color: _C.textMuted, fontSize: 12.sp)),
          SizedBox(height: 10.h),
          Row(
            children: [
              Expanded(
                  child: _FindTile(
                      emoji: '🕘',
                      label: 'Rivalries',
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const RivalriesPage())))),
              SizedBox(width: 8.w),
              Expanded(
                  child: _FindTile(
                      emoji: '🎓',
                      label: 'Campus',
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const RivalriesPage())))),
              SizedBox(width: 8.w),
              Expanded(
                  child: _FindTile(
                      emoji: '🎯',
                      label: 'Code',
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const JoinChallengePage())))),
            ],
          ),
          SizedBox(height: 8.h),
          GestureDetector(
            onTap: onCreate,
            child: Text('or create a code challenge →',
                style: TextStyle(
                    color: _C.sky,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _FindTile extends StatelessWidget {
  final String emoji;
  final String label;
  final VoidCallback onTap;
  const _FindTile(
      {required this.emoji, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12.r),
        decoration: BoxDecoration(
          color: _C.rival.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(color: _C.rival.withValues(alpha: 0.4)),
        ),
        child: Column(
          children: [
            Text(emoji, style: TextStyle(fontSize: 20.sp)),
            SizedBox(height: 4.h),
            Text(label,
                style: TextStyle(
                    color: _C.text,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

// ─── Quick Match card (practice vs ghost) ─────────────────────────────────────
class QuickMatchCard extends StatefulWidget {
  final VoidCallback onStartMatchmaking;
  const QuickMatchCard({super.key, required this.onStartMatchmaking});

  @override
  State<QuickMatchCard> createState() => _QuickMatchCardState();
}

class _QuickMatchCardState extends State<QuickMatchCard> {
  bool _watchingAd = false;

  Future<void> _handleWatchAd(BuildContext context) async {
    if (_watchingAd) return;
    setState(() => _watchingAd = true);
    final shown = await AdService.instance.showQMTokenAd(
      context: context,
      onTokenGranted: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('🎟 +1 token granted!'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      },
    );
    if (!shown && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
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

    return Container(
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(
          color: _C.crimson.withValues(alpha: 0.40),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16.r, 18.r, 16.r, 14.r),
            child: Row(
              children: [
                Container(
                  width: 44.w,
                  height: 44.h,
                  decoration: BoxDecoration(
                    color: _C.crimsonGlow,
                    borderRadius: BorderRadius.circular(13.r),
                    border: Border.all(color: _C.crimsonBorder),
                  ),
                  child: Center(
                      child: Text('⚡', style: TextStyle(fontSize: 20.sp))),
                ),
                SizedBox(width: 14.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Quick Match',
                          style: TextStyle(
                              color: _C.text,
                              fontSize: 16.sp,
                              fontWeight: FontWeight.w800)),
                      SizedBox(height: 3.h),
                      Text(
                        'Practice vs ghost · $qmTokens of $dailyMax left · No series, flat rewards',
                        style:
                            TextStyle(color: _C.textMuted, fontSize: 12.sp),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1.h, thickness: 1, color: _C.divider),
          Padding(
            padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 8.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TokenBar(tokens: qmTokens, max: dailyMax),
                SizedBox(height: 14.h),
                AppButton(
                  label: 'Play Ghost Match',
                  icon: Icon(Icons.bolt_rounded, size: 20.r),
                  onPressed:
                      qmTokens > 0 ? widget.onStartMatchmaking : null,
                  variant: AppButtonVariant.gradient,
                  gradientColors: const [
                    AppColors.primary,
                    Color(0xFFFF4D5E),
                  ],
                  size: AppButtonSize.large,
                  height: 52.h,
                  width: double.infinity,
                ),
                if (qmTokens == 0 && !qmAdTokenUsed) ...[
                  SizedBox(height: 10.h),
                  _AdButton(
                    loading: _watchingAd,
                    onTap: _watchingAd ? null : () => _handleWatchAd(context),
                  ),
                ],
                SizedBox(height: 8.h),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TokenBar extends StatelessWidget {
  final int tokens;
  final int max;
  const _TokenBar({required this.tokens, required this.max});

  @override
  Widget build(BuildContext context) {
    final segs = max.clamp(1, 8);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 13.r),
      decoration: BoxDecoration(
        color: _C.crimsonGlow,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: _C.crimsonBorder),
      ),
      child: Row(
        children: [
          Text('🎟', style: TextStyle(fontSize: 15.sp)),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$tokens of $max left today',
                  style: TextStyle(
                      color: _C.crimsonBright,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6.h),
                Row(
                  children: List.generate(segs, (i) {
                    final filled = i < tokens;
                    return Expanded(
                      child: Padding(
                        padding:
                            EdgeInsets.only(right: i < segs - 1 ? 4.r : 0.r),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: 4.h,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2.r),
                            color: filled
                                ? _C.crimson
                                : _C.crimson.withValues(alpha: 0.18),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdButton extends StatelessWidget {
  final bool loading;
  final VoidCallback? onTap;
  const _AdButton({required this.loading, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Ink(
      decoration: BoxDecoration(
        color: _C.elevated,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: _C.border.withValues(alpha: 0.6)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Container(
          height: 42.h,
          padding: EdgeInsets.symmetric(horizontal: 12.r),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading)
                SizedBox(
                  width: 14.w,
                  height: 14.h,
                  child: const CircularProgressIndicator(
                      strokeWidth: 2, color: _C.textMuted),
                )
              else
                Text('📺', style: TextStyle(fontSize: 14.sp)),
              SizedBox(width: 8.w),
              Text(
                loading ? 'Loading ad…' : 'Watch ad for extra token',
                style: TextStyle(
                    color: _C.textMuted,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
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
      backgroundColor: _C.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24.r),
        side: BorderSide(color: _C.crimson.withValues(alpha: 0.40), width: 1.5),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24.r, 30.r, 24.r, 24.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('GHOST FOUND!',
                style: TextStyle(
                    color: _C.crimsonBright,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.5)),
            SizedBox(height: 12.h),
            Text(result.opponentName,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _C.text,
                    fontSize: 24.sp,
                    fontWeight: FontWeight.w900)),
            SizedBox(height: 8.h),
            Text(result.animeTitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: _C.textMuted, fontSize: 15.sp)),
            if (result.isGhost && result.ghostScore > 0) ...[
              SizedBox(height: 14.h),
              Text('They scored ${result.ghostScore}/10 — beat it to win',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _C.crimsonBright,
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
                style: TextStyle(color: _C.textMuted, fontSize: 11.sp)),
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

  static const _gold = Color(0xFFFFB300);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PremiumUpsellScreen()),
      ),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: premiumActive ? 0.13 : 0.10),
          borderRadius: BorderRadius.circular(20.r),
          border: Border.all(color: _gold.withValues(alpha: 0.38)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('👑', style: TextStyle(fontSize: 12.sp)),
            SizedBox(width: 4.w),
            Text(
              premiumActive ? 'PREMIUM' : 'GET',
              style: TextStyle(
                color: _gold,
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

// ─── Payout Rules table (from rival_economy.dart = server constants) ──────────
class _RewardsTable extends StatefulWidget {
  const _RewardsTable();

  @override
  State<_RewardsTable> createState() => _RewardsTableState();
}

class _RewardsTableState extends State<_RewardsTable> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: _C.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 12.r),
              child: Row(
                children: [
                  Text('⚖️', style: TextStyle(fontSize: 15.sp)),
                  SizedBox(width: 10.w),
                  Text('Payout Rules',
                      style: TextStyle(
                          color: _C.text,
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Icon(
                    _isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: _C.textMuted,
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _isExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(
                          height: 1.h, thickness: 1, color: _C.divider),
                      _modeBlock(
                        title: '⚔️ DUEL — staked, counts for series',
                        rows: [
                          'AC: win 1.9× (stake + 90%), draw 0.95× (5% fee), loss 0×',
                          'WP stake: win 1.9×, draw 0.9× (10% fee), loss 0×',
                          'Flat WP: +$kDuelFlatWinWp win / +$kDuelFlatDrawWp draw / +0 loss',
                          'Bounty: +$kBountyWpBonus WP when you trail by $kBountyWpGap+ WP',
                          'Series: first to $kSeriesWinsRequired wins +$kSeriesAcPrize AC (paid at most once per 7 days)',
                          'Draws replay and never count toward the series',
                        ],
                      ),
                      _modeBlock(
                        title: '🤝 SPAR — free practice, never counts',
                        rows: [
                          'Stake: none. Flat WP: +$kSparWinWp on a win inside the daily budget ($kSparDailyFree/day, $kSparDailyPremium premium), else +0',
                          'Never touches series score, win stats, or achievements',
                        ],
                      ),
                      _modeBlock(
                        title: '⚡ GHOST — practice vs recording',
                        rows: [
                          'No series. AC +$kGhostAcWin/+$kGhostAcDraw/+$kGhostAcLose · WP +$kGhostWpWin/+$kGhostWpDraw/+$kGhostWpLose',
                          'Skill-matched to your recent ghost average; your own recordings excluded',
                        ],
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(16.r, 8.r, 16.r, 14.r),
                        child: Text(
                          'Caps & cooldown: premium ×$kPremiumWpMultiplier WP · daily soft cap $kWpDailySoftCap WP then 20% · weekly cap $kWpWeeklyCap WP · '
                          'same-rival cooldown $kRivalCooldownFreeHours h (free) / $kRivalCooldownPremiumHours h (premium), skipped inside an active series · '
                          'WP stake min $kWpMinStake step $kWpStakeStep · AC stake min $kAcMinStake step $kAcStakeStep · '
                          'unplayed duels expire (12 h invite / 24 h match) and one-sided silence forfeits 0 after 15 min.',
                          style: TextStyle(
                              color: _C.textMuted, fontSize: 11.sp, height: 1.5),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _modeBlock({required String title, required List<String> rows}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16.r, 10.r, 16.r, 4.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: _C.text,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w800)),
          SizedBox(height: 6.h),
          for (final r in rows)
            Padding(
              padding: EdgeInsets.only(bottom: 3.h),
              child: Text('· $r',
                  style: TextStyle(
                      color: _C.textSub, fontSize: 12.sp, height: 1.4)),
            ),
        ],
      ),
    );
  }
}
