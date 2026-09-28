// lib/features/multiplayer/multiplayer_hub_page.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../quiz/questions_page.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_page_route.dart';
import 'anime_select_page.dart';
import 'join_challenge_page.dart';
import 'my_challenges_page.dart';
import 'challenge_lobby_page.dart';
import '../premium/premium_upsell_screen.dart';

// ─── Design tokens (mapped to AppColors) ──────────────────────────────────────
abstract final class _C {
  static const surface = AppColors.surface;
  static const elevated = AppColors.surfaceAlt;

  static const crimson = AppColors.primary;
  static const crimsonBright = AppColors.crimsonBright;
  static const crimsonGlow = Color(0x1CE63946);
  static const crimsonBorder = Color(0x55E63946);

  static const sky = AppColors.secondary;

  static const green = AppColors.correct;
  static const greenDim = Color(0x1638EF7D);

  static const text = AppColors.textPrimary;
  static const textSub = AppColors.textSecondary;
  static const textMuted = AppColors.textMuted;
  static const divider = AppColors.divider;
  static const border = Color(0xFF252538);
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

    if (result.qmWindowClosed) {
      _snack('Quick Match is only available during scheduled windows. '
          'Check the timer below.');
      return;
    }
    if (result.noTokens) {
      _snack('No tokens left — watch an ad for one more.');
      return;
    }
    if (result.tooManyActive) {
      _snack('You already have 5 active challenges. Finish or leave one '
          'before starting a Quick Match.');
      return;
    }
    if (result.noMatch) {
      _snack(
          'No ghost sessions available right now. Try again in a few minutes.');
      return;
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
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
            // ── Flat page header ──────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 18.r, 20.r, 0.r),
                child: Row(
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
                          SizedBox(height: 3.h),
                          Text(
                            'Challenge a rival · Quick match · Async battles',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13.sp,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 12.w),
                    _BattlePremiumChip(premiumActive: premiumActive),
                    SizedBox(width: 8.w),
                    // Coin balance
                    Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(20.r),
                        border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.38)),
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
                    // WP balance
                    Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
                      decoration: BoxDecoration(
                        color: _C.sky.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(20.r),
                        border:
                            Border.all(color: _C.sky.withValues(alpha: 0.38)),
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
                  ],
                ),
              ),
            ),

            // ── Arena banner ──────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 20.r, 20.r, 0.r),
                child: const _ArenaBanner(),
              ),
            ),

            // ── How it works ──────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
                child: const _HowItWorksStrip(),
              ),
            ),

            // ── Active challenges ─────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 20.r, 20.r, 0.r),
                child: const _ActiveChallengesSection(),
              ),
            ),

            // ── Create / Join ─────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 16.r, 20.r, 0.r),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _ActionCard(
                          emoji: '⚔️',
                          title: 'Create\nChallenge',
                          subtitle:
                              'Pick anime, set stake,\nplay first. Share code.',
                          accent: _C.crimson,
                          onTap: _goCreate,
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Expanded(
                        child: _ActionCard(
                          emoji: '🎯',
                          title: 'Join\nChallenge',
                          subtitle: 'Got a 6-char code?\nEnter it and battle.',
                          accent: _C.sky,
                          onTap: _goJoin,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Quick Match window ────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0.r),
                child: QMWindowWidget(onStartMatchmaking: _goQuickMatch),
              ),
            ),

            // ── Rules ─────────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 40.r),
                child: const _RulesCard(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Match result data class ──────────────────────────────────────────────────
/// Defensive list builder for `questionIds` returned by the matchmaking CF.
/// Remote data is untrusted — a legacy ghost session may store ids as ints,
/// which used to crash `List<String>.from(...)` with a type-cast error.
List<String> _stringListOf(Object? raw) {
  if (raw is! List) return const [];
  return List<String>.unmodifiable(raw.map((e) => '$e'));
}

class _MatchResult {
  final bool noMatch;
  final bool qmWindowClosed;
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
        qmWindowClosed = false,
        noTokens = false,
        tooManyActive = false,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '';

  const _MatchResult.qmWindowClosed()
      : noMatch = false,
        qmWindowClosed = true,
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
        qmWindowClosed = false,
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
        qmWindowClosed = false,
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
        qmWindowClosed = false,
        noTokens = false,
        tooManyActive = false;
}

// ─── Searching dialog ─────────────────────────────────────────────────────────
class _SearchingDialog extends StatefulWidget {
  const _SearchingDialog();

  @override
  State<_SearchingDialog> createState() => _SearchingDialogState();
}

class _SearchingDialogState extends State<_SearchingDialog>
    with SingleTickerProviderStateMixin {
  bool _leaving = false;
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

      if (!mounted || _leaving) return;

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

      // No ghosts available
      Navigator.of(context).pop(const _MatchResult.noMatch());
    } on FirebaseFunctionsException catch (e) {
      if (!mounted || _leaving) return;
      if (e.message == 'outside_qm_window') {
        Navigator.of(context).pop(const _MatchResult.qmWindowClosed());
        return;
      }
      if (e.message == 'no_qm_tokens') {
        Navigator.of(context).pop(const _MatchResult.noTokens());
        return;
      }
      if (e.message == 'too_many_active_challenges') {
        Navigator.of(context).pop(const _MatchResult.tooManyActive());
        return;
      }
      Navigator.of(context).pop(const _MatchResult.noMatch());
    } catch (e, st) {
      debugPrint('[GhostMatch][joinMatchmakingQueue] ERROR: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted || _leaving) return;
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
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 4.r),
                decoration: BoxDecoration(
                  color: _C.crimsonGlow,
                  borderRadius: BorderRadius.circular(20.r),
                  border: Border.all(color: _C.crimsonBorder, width: 1),
                ),
                child: Text(
                  'FINDING GHOST',
                  style: TextStyle(
                    color: _C.crimsonBright,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.5,
                  ),
                ),
              ),
              SizedBox(height: 10.h),
              Text(
                'Match against a recorded player',
                style: TextStyle(
                  color: _C.text,
                  fontSize: 18.sp,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
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

// ─── Concentric pulse badge ────────────────────────────────────────────────
class _ConcentricPulseBadge extends StatefulWidget {
  @override
  State<_ConcentricPulseBadge> createState() => _ConcentricPulseBadgeState();
}

class _ConcentricPulseBadgeState extends State<_ConcentricPulseBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _ring1, _ring2, _ring3;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat();
    _ring1 = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _ctrl, curve: const Interval(0.0, 1.0, curve: Curves.easeOut)));
    _ring2 = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.18, 1.0, curve: Curves.easeOut)));
    _ring3 = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.36, 1.0, curve: Curves.easeOut)));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => SizedBox(
        width: 88.w,
        height: 88.h,
        child: Stack(alignment: Alignment.center, children: [
          Opacity(
            opacity: (1.0 - _ring3.value).clamp(0.0, 1.0),
            child: Container(
              width: 44 + 44 * _ring3.value,
              height: 44 + 44 * _ring3.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: _C.crimson.withValues(alpha: 0.18), width: 1),
              ),
            ),
          ),
          Opacity(
            opacity: (1.0 - _ring2.value).clamp(0.0, 1.0),
            child: Container(
              width: 44 + 30 * _ring2.value,
              height: 44 + 30 * _ring2.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: _C.crimson.withValues(alpha: 0.28), width: 1),
              ),
            ),
          ),
          Opacity(
            opacity: (1.0 - _ring1.value).clamp(0.0, 1.0),
            child: Container(
              width: 44 + 16 * _ring1.value,
              height: 44 + 16 * _ring1.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: _C.crimson.withValues(alpha: 0.40), width: 1),
              ),
            ),
          ),
          Container(
            width: 52.w,
            height: 52.h,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _C.crimsonGlow,
              border: Border.all(
                  color: _C.crimson.withValues(alpha: 0.45), width: 1.5),
            ),
            child: Center(child: Text('⚡', style: TextStyle(fontSize: 24.sp))),
          ),
        ]),
      ),
    );
  }
}

// ─── QM Window widget ────────────────────────────────────────────────────────
class QMWindowWidget extends StatefulWidget {
  final VoidCallback onStartMatchmaking;
  const QMWindowWidget({super.key, required this.onStartMatchmaking});

  @override
  State<QMWindowWidget> createState() => _QMWindowWidgetState();
}

class _QMWindowWidgetState extends State<QMWindowWidget> {
  static const List<String> _testQmBypassUids = [
    '79OGBOEHSFhn2gONP0XPijZXugP2',
  ];

  bool get _isQmTestBypassUser =>
      _testQmBypassUids.contains(FirebaseAuth.instance.currentUser?.uid);

  Timer? _countdownTimer;
  Duration _timeToNext = Duration.zero;
  bool _watchingAd = false;

  @override
  void initState() {
    super.initState();
    _updateCountdown();
    _countdownTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _updateCountdown();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _updateCountdown() {
    final next = QMWindowSchedule.nextWindowStart();
    setState(() {
      _timeToNext = next.difference(DateTime.now().toUtc());
      if (_timeToNext.isNegative) _timeToNext = Duration.zero;
    });
  }

  String _formatCountdown(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  String _buildCountdownLabel() {
    final next = QMWindowSchedule.nextWindowStart();
    final diff = next.difference(DateTime.now().toUtc());
    final clamped = diff.isNegative ? Duration.zero : diff;
    final nextWindow = QMWindowSchedule.windows.firstWhere(
      (w) => w.startUTC == next.hour,
      orElse: () => QMWindowSchedule.windows.first,
    );
    return 'Next: ${nextWindow.name} in ${_formatCountdown(clamped)}';
  }

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
    final activeWindow = QMWindowSchedule.currentWindow();
    final isWindowOpen = activeWindow != null || _isQmTestBypassUser;
    final premiumActive = udp.premiumActive;

    return Container(
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(
          color: isWindowOpen
              ? _C.crimson.withValues(alpha: 0.40)
              : _C.border.withValues(alpha: 0.5),
          width: isWindowOpen ? 1.5 : 1,
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
                    color: isWindowOpen ? _C.crimsonGlow : _C.elevated,
                    borderRadius: BorderRadius.circular(13.r),
                    border: Border.all(
                      color: isWindowOpen
                          ? _C.crimsonBorder
                          : _C.border.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Center(
                      child: Text('⚡', style: TextStyle(fontSize: 20.sp))),
                ),
                SizedBox(width: 14.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Quick Match',
                            style: TextStyle(
                              color: _C.text,
                              fontSize: 16.sp,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          SizedBox(width: 8.w),
                          _LiveChip(isLive: isWindowOpen),
                        ],
                      ),
                      SizedBox(height: 3.h),
                      Text(
                        isWindowOpen
                            ? '${activeWindow?.name ?? 'Test'} window is open'
                            : 'Opens 3× daily — windows gated',
                        style: TextStyle(color: _C.textMuted, fontSize: 12.sp),
                      ),
                      SizedBox(height: 4.h),
                      _QMPremiumLine(
                        premiumActive: premiumActive,
                        tokens: qmTokens,
                        isWindowOpen: isWindowOpen,
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
                if (isWindowOpen)
                  _TokenBar(tokens: qmTokens)
                else
                  _CountdownChip(label: _buildCountdownLabel()),
                SizedBox(height: 14.h),
                _QMButton(
                  enabled: isWindowOpen && qmTokens > 0,
                  onTap: widget.onStartMatchmaking,
                ),
                if (isWindowOpen && qmTokens == 0 && !qmAdTokenUsed) ...[
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

// ─── Live chip ────────────────────────────────────────────────────────────────
class _LiveChip extends StatefulWidget {
  final bool isLive;
  const _LiveChip({required this.isLive});

  @override
  State<_LiveChip> createState() => _LiveChipState();
}

class _LiveChipState extends State<_LiveChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _blink;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _blink = Tween<double>(begin: 0.35, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blink,
      builder: (_, __) => Container(
        padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 3.r),
        decoration: BoxDecoration(
          color: widget.isLive ? _C.greenDim : _C.elevated,
          borderRadius: BorderRadius.circular(20.r),
          border: Border.all(
            color: widget.isLive
                ? _C.green.withValues(alpha: 0.45)
                : _C.border.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isLive)
              Padding(
                padding: EdgeInsets.only(right: 4.r),
                child: Container(
                  width: 5.w,
                  height: 5.h,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _C.green.withValues(alpha: _blink.value),
                  ),
                ),
              ),
            Text(
              widget.isLive ? 'LIVE' : '○ CLOSED',
              style: TextStyle(
                color: widget.isLive ? _C.green : _C.textMuted,
                fontSize: 9.sp,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Token bar ────────────────────────────────────────────────────────────────
class _TokenBar extends StatelessWidget {
  final int tokens;
  const _TokenBar({required this.tokens});

  @override
  Widget build(BuildContext context) {
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
                  '$tokens ${tokens == 1 ? "token" : "tokens"} remaining',
                  style: TextStyle(
                      color: _C.crimsonBright,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6.h),
                Row(
                  children: List.generate(3, (i) {
                    final filled = i < tokens;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i < 2 ? 4.r : 0.r),
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

// ─── Countdown chip ───────────────────────────────────────────────────────────
class _CountdownChip extends StatelessWidget {
  final String label;
  const _CountdownChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 13.r),
      decoration: BoxDecoration(
        color: _C.elevated,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: _C.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.timer_outlined, color: _C.textMuted, size: 15.r),
          SizedBox(width: 8.w),
          Text(label,
              style: TextStyle(
                  color: _C.textSub,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ─── Find a Match button ──────────────────────────────────────────────────────
class _QMButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback? onTap;
  const _QMButton({required this.enabled, this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: 'Play Ghost Match',
      icon: Icon(Icons.bolt_rounded, size: 20.r),
      onPressed: enabled ? onTap : null,
      variant: AppButtonVariant.gradient,
      gradientColors: const [
        AppColors.primary,
        Color(0xFFFF4D5E),
      ],
      size: AppButtonSize.large,
      height: 52.h,
      width: double.infinity,
    );
  }
}

// ─── Watch-ad button ──────────────────────────────────────────────────────────
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

// ─── Arena banner ──────────────────────────────────────────────────────────────
class _ArenaBanner extends StatelessWidget {
  const _ArenaBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(20.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 64.w,
            height: 64.h,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(18.r),
              border:
                  Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
            ),
            child: Center(child: Text('⚔️', style: TextStyle(fontSize: 28.sp))),
          ),
          SizedBox(width: 18.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 2.r),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6.r),
                  ),
                  child: Text(
                    'ASYNC MULTIPLAYER',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 8.sp,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                SizedBox(height: 8.h),
                Text(
                  'Challenge\nyour rival',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 24.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.8,
                    height: 1.08,
                  ),
                ),
                SizedBox(height: 6.h),
                Text(
                  'Play now · They play when ready\nWinner takes all',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.sp,
                    height: 1.45,
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

// ─── How-it-works strip ───────────────────────────────────────────────────────
class _HowItWorksStrip extends StatelessWidget {
  const _HowItWorksStrip();

  static const _steps = [
    (num: '1', emoji: '🎮', label: 'You play\nfirst', color: _C.crimson),
    (num: '2', emoji: '📤', label: 'Share\nyour code', color: _C.sky),
    (num: '3', emoji: '🏆', label: 'Best score\nwins', color: _C.green),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 16.r),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: _C.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          for (int i = 0; i < _steps.length; i++) ...[
            if (i > 0)
              Expanded(child: Container(height: 1.h, color: _C.divider)),
            _StepBadge(
              number: _steps[i].num,
              emoji: _steps[i].emoji,
              label: _steps[i].label,
              accent: _steps[i].color,
            ),
          ],
        ],
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  final String number;
  final String emoji;
  final String label;
  final Color accent;

  const _StepBadge({
    required this.number,
    required this.emoji,
    required this.label,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 48.w,
              height: 48.h,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14.r),
                border: Border.all(color: accent.withValues(alpha: 0.28)),
              ),
              child:
                  Center(child: Text(emoji, style: TextStyle(fontSize: 22.sp))),
            ),
            Positioned(
              top: -5.h,
              right: -5.w,
              child: Container(
                width: 18.w,
                height: 18.h,
                decoration:
                    BoxDecoration(color: accent, shape: BoxShape.circle),
                child: Center(
                  child: Text(number,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9.sp,
                        fontWeight: FontWeight.w900,
                      )),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: 8.h),
        Text(
          label,
          style: TextStyle(
            color: _C.textMuted,
            fontSize: 10.sp,
            height: 1.35,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ─── Action card ──────────────────────────────────────────────────────────────
class _ActionCard extends StatefulWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;

  const _ActionCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
  });

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleCtrl;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 100));
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.96)
        .animate(CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: Ink(
        decoration: BoxDecoration(
          color: _C.surface,
          borderRadius: BorderRadius.circular(AppRadii.xl),
          border: Border.all(color: widget.accent.withValues(alpha: 0.28)),
        ),
        child: InkWell(
          onTapDown: (_) => _scaleCtrl.forward(),
          onTap: () {
            _scaleCtrl.reverse();
            widget.onTap();
          },
          onTapCancel: () => _scaleCtrl.reverse(),
          borderRadius: BorderRadius.circular(AppRadii.xl),
          child: Container(
            padding: EdgeInsets.all(16.r),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44.w,
                  height: 44.h,
                  decoration: BoxDecoration(
                    color: widget.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(13.r),
                    border: Border.all(
                        color: widget.accent.withValues(alpha: 0.25)),
                  ),
                  child: Center(
                      child: Text(widget.emoji,
                          style: TextStyle(fontSize: 22.sp))),
                ),
                SizedBox(height: 14.h),
                Text(
                  widget.title,
                  style: TextStyle(
                    color: widget.accent,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.3,
                    height: 1.15,
                  ),
                ),
                SizedBox(height: 5.h),
                Text(
                  widget.subtitle,
                  style: TextStyle(
                      color: _C.textMuted, fontSize: 11.sp, height: 1.45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Rules card ──────────────────────────────────────────────────────────────
class _RulesCard extends StatefulWidget {
  const _RulesCard();

  @override
  State<_RulesCard> createState() => _RulesCardState();
}

class _RulesCardState extends State<_RulesCard> {
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
          // ── Tappable Header ──
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 12.r),
              child: Row(
                children: [
                  Container(
                    width: 32.w,
                    height: 32.h,
                    decoration: BoxDecoration(
                      color: _C.elevated,
                      borderRadius: BorderRadius.circular(9.r),
                      border:
                          Border.all(color: _C.border.withValues(alpha: 0.5)),
                    ),
                    child: Center(
                        child: Text('⚖️', style: TextStyle(fontSize: 15.sp))),
                  ),
                  SizedBox(width: 10.w),
                  Text(
                    'Payout Rules',
                    style: TextStyle(
                      color: _C.text,
                      fontSize: 15.sp,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
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

          // ── Foldable Content ──
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _isExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(height: 1.h, thickness: 1, color: _C.divider),

                      // ── AC stakes ─────────────────────────
                      Padding(
                        padding: EdgeInsets.fromLTRB(12.r, 12.r, 12.r, 4.r),
                        child: Row(
                          children: [
                            Text('🪙', style: TextStyle(fontSize: 12.sp)),
                            SizedBox(width: 6.w),
                            Text(
                              'AC STAKES',
                              style: TextStyle(
                                color: _C.textMuted,
                                fontSize: 10.sp,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 9.r, vertical: 3.r),
                              decoration: BoxDecoration(
                                color: _C.elevated,
                                borderRadius: BorderRadius.circular(20.r),
                                border: Border.all(
                                    color: _C.border.withValues(alpha: 0.5)),
                              ),
                              child: Text(
                                '10% win fee · 5% draw fee',
                                style: TextStyle(
                                    color: _C.textMuted,
                                    fontSize: 10.sp,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),

                      Padding(
                        padding: EdgeInsets.fromLTRB(12.r, 8.r, 12.r, 6.r),
                        child: Column(
                          children: [
                            _RuleRow(
                              emoji: '🏆',
                              label: 'WIN',
                              labelColor: AppColors.win,
                              accentColor: AppColors.win,
                              detail: "Your stake back + 90% of opponent's",
                              highlight: '1.9×',
                              highlightColor: AppColors.win,
                            ),
                            SizedBox(height: 8.h),
                            _RuleRow(
                              emoji: '🤝',
                              label: 'DRAW',
                              labelColor: AppColors.draw,
                              accentColor: AppColors.draw,
                              detail: 'Stake refunded minus a 5% fee',
                              highlight: '0.95×',
                              highlightColor: AppColors.draw,
                            ),
                            SizedBox(height: 8.h),
                            _RuleRow(
                              emoji: '💀',
                              label: 'LOSE',
                              labelColor: AppColors.lose,
                              accentColor: AppColors.lose,
                              detail:
                                  'Your full stake is forfeited to the house',
                              highlight: '0×',
                              highlightColor: AppColors.lose,
                            ),
                          ],
                        ),
                      ),

                      Divider(
                          height: 1.h,
                          thickness: 1,
                          indent: 12.w,
                          endIndent: 12.w,
                          color: _C.divider.withValues(alpha: 0.5)),

                      // ── WP stakes ─────────────────────────
                      Padding(
                        padding: EdgeInsets.fromLTRB(12.r, 12.r, 12.r, 4.r),
                        child: Row(
                          children: [
                            Text('⭐', style: TextStyle(fontSize: 12.sp)),
                            SizedBox(width: 6.w),
                            Text(
                              'WP STAKES · RIVAL CHALLENGES',
                              style: TextStyle(
                                color: _C.textMuted,
                                fontSize: 10.sp,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 9.r, vertical: 3.r),
                              decoration: BoxDecoration(
                                color: _C.elevated,
                                borderRadius: BorderRadius.circular(20.r),
                                border: Border.all(
                                    color: _C.border.withValues(alpha: 0.5)),
                              ),
                              child: Text(
                                '10% fee',
                                style: TextStyle(
                                    color: _C.textMuted,
                                    fontSize: 10.sp,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),

                      Padding(
                        padding: EdgeInsets.fromLTRB(12.r, 8.r, 12.r, 6.r),
                        child: Column(
                          children: [
                            _RuleRow(
                              emoji: '🏆',
                              label: 'WIN',
                              labelColor: AppColors.win,
                              accentColor: AppColors.win,
                              detail: "Your WP back + 90% of opponent's",
                              highlight: '1.9×',
                              highlightColor: AppColors.win,
                            ),
                            SizedBox(height: 8.h),
                            _RuleRow(
                              emoji: '🤝',
                              label: 'DRAW',
                              labelColor: AppColors.draw,
                              accentColor: AppColors.draw,
                              detail: 'WP refunded minus a 10% fee',
                              highlight: '0.9×',
                              highlightColor: AppColors.draw,
                            ),
                            SizedBox(height: 8.h),
                            _RuleRow(
                              emoji: '💀',
                              label: 'LOSE',
                              labelColor: AppColors.lose,
                              accentColor: AppColors.lose,
                              detail: '90% of your WP to opponent, 10% fee',
                              highlight: '0×',
                              highlightColor: AppColors.lose,
                            ),
                          ],
                        ),
                      ),

                      Padding(
                        padding: EdgeInsets.fromLTRB(16.r, 6.r, 16.r, 14.r),
                        child: Row(
                          children: [
                            Icon(Icons.timer_outlined,
                                color: _C.textMuted, size: 12.r),
                            SizedBox(width: 6.w),
                            Text(
                              'Unclaimed challenges expire after 24 hours',
                              style: TextStyle(
                                  color: _C.textMuted, fontSize: 11.sp),
                            ),
                          ],
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
}

class _RuleRow extends StatelessWidget {
  final String emoji;
  final String label;
  final Color labelColor;
  final Color accentColor;
  final String detail;
  final String highlight;
  final Color highlightColor;

  const _RuleRow({
    required this.emoji,
    required this.label,
    required this.labelColor,
    required this.accentColor,
    required this.detail,
    required this.highlight,
    required this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 11.r),
      decoration: BoxDecoration(
        color: labelColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(11.r),
        border: Border.all(color: labelColor.withValues(alpha: 0.15), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 3.w,
            height: 26.h,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(2.r),
            ),
          ),
          SizedBox(width: 10.w),
          Text(emoji, style: TextStyle(fontSize: 16.sp)),
          SizedBox(width: 8.w),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
            decoration: BoxDecoration(
              color: labelColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(5.r),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: labelColor,
                fontSize: 9.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8,
              ),
            ),
          ),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              detail,
              style: TextStyle(color: _C.textSub, fontSize: 12.sp, height: 1.3),
            ),
          ),
          SizedBox(width: 8.w),
          Text(
            highlight,
            style: TextStyle(
              color: highlightColor,
              fontSize: 14.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Active Challenges Section
// ═══════════════════════════════════════════════════════════════════════════
class _ActiveChallengesSection extends StatefulWidget {
  const _ActiveChallengesSection();

  @override
  State<_ActiveChallengesSection> createState() =>
      _ActiveChallengesSectionState();
}

class _ActiveChallengesSectionState extends State<_ActiveChallengesSection> {
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
    });
  }

  @override
  void dispose() {
    _creatorSub?.cancel();
    _opponentSub?.cancel();
    super.dispose();
  }

  List<QueryDocumentSnapshot> get _merged {
    final seen = <String>{};
    final result = <QueryDocumentSnapshot>[];
    for (final doc in [..._creatorDocs, ..._opponentDocs]) {
      if (seen.add(doc.id)) result.add(doc);
    }
    return result;
  }

  void _navigateToMyChallenges() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) => const MyChallengesPage(),
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final challenges = _merged;
    if (challenges.isEmpty) return const SizedBox.shrink();

    final visible =
        challenges.length > 3 ? challenges.sublist(0, 3) : challenges;
    final showSeeAll = challenges.length > 3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 2.r, bottom: 12.r),
          child: Row(
            children: [
              Text(
                'Active Challenges',
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
                  '${challenges.length}',
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
            child: _ActiveChallengeCard(doc: doc),
          ),
        if (showSeeAll) ...[
          SizedBox(height: 4.h),
          TextButton(
            onPressed: _navigateToMyChallenges,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('See All'),
                SizedBox(width: 4.w),
                Icon(Icons.arrow_forward_rounded, size: 14.r),
              ],
            ),
          ),
        ],
        SizedBox(height: 8.h),
      ],
    );
  }
}

// ─── Single active challenge card ─────────────────────────────────────────────
class _ActiveChallengeCard extends StatefulWidget {
  final QueryDocumentSnapshot doc;
  const _ActiveChallengeCard({required this.doc});

  @override
  State<_ActiveChallengeCard> createState() => _ActiveChallengeCardState();
}

class _ActiveChallengeCardState extends State<_ActiveChallengeCard> {
  bool _declining = false;

  QueryDocumentSnapshot get doc => widget.doc;

  Future<void> _declineChallenge(
      BuildContext context, String challengeId) async {
    if (_declining) return;
    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => AppDialog(
        title: 'Decline challenge?',
        contentWidget: Text(
          'The other player\'s stake will be refunded to them. This can\'t be undone.',
          style: TextStyle(color: _C.textMuted, fontSize: 13.sp),
        ),
        actions: [
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.text,
            color: _C.textMuted,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            label: 'Decline',
            variant: AppButtonVariant.text,
            color: _C.crimsonBright,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _declining = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('declineChallenge')
          .call({'challengeId': challengeId});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Challenge declined'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Failed to decline: ${e.toString().replaceFirst('Exception: ', '')}'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      if (mounted) setState(() => _declining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    final animeTitle = data['animeTitle'] as String? ?? 'Unknown Anime';
    final status = data['status'] as String? ?? '';
    final isQuickMatch = data['isQuickMatch'] as bool? ?? false;
    final creatorUid = data['creatorUid'] as String? ?? '';
    final creatorUsername = data['creatorUsername'] as String? ?? 'You';
    final opponentUsername = data['opponentUsername'] as String? ?? '—';
    final stakeAmount = data['stakeAmount'] as int? ?? 0;
    final wpStake = data['wpStake'] as int? ?? 0;
    final questionIds = _stringListOf(data['questionIds']);
    final challengeId = doc.id;
    final isCreator = creatorUid == uid;
    final hasOpponent = data['opponentUid'] != null;

    final creatorScore = data['creatorScore'];
    final opponentScore = data['opponentScore'];

    String statusLabel;
    bool needsAction = false;

    if (isQuickMatch) {
      final hasPlayed =
          isCreator ? creatorScore != null : opponentScore != null;
      if (hasPlayed) {
        statusLabel = 'Waiting for opponent…';
      } else {
        statusLabel = 'Quick Match — play now!';
        needsAction = true;
      }
    } else {
      switch (status) {
        case 'waiting':
          if (isCreator) {
            statusLabel = hasOpponent
                ? 'Waiting for opponent to accept'
                : 'Waiting — share code';
          } else {
            statusLabel = 'Pending — accept to play';
            needsAction = true;
          }
          break;
        case 'opponent_joined':
          if (isCreator) {
            statusLabel = creatorScore != null
                ? 'You played — waiting for opponent'
                : 'Opponent joined — play now!';
            needsAction = creatorScore == null;
          } else {
            statusLabel = opponentScore != null
                ? 'You played — waiting for creator'
                : 'Creator played — your turn!';
            needsAction = opponentScore == null;
          }
          break;
        case 'creator_submitted':
          statusLabel = isCreator
              ? 'Waiting for opponent to play'
              : 'Creator played — your turn!';
          if (!isCreator) needsAction = true;
          break;
        case 'opponent_submitted':
          statusLabel = isCreator
              ? 'Opponent played — your turn!'
              : 'Waiting for creator to play';
          if (isCreator) needsAction = true;
          break;
        default:
          statusLabel = status;
      }
    }

    final opponentName = isCreator ? opponentUsername : creatorUsername;
    final accentColor = isQuickMatch ? _C.crimson : _C.sky;

    final showCopyCode =
        isCreator && status == 'waiting' && !hasOpponent && !isQuickMatch;

    final canDecline =
        !isQuickMatch && status == 'waiting' && !isCreator && hasOpponent;

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(
          color: needsAction
              ? _C.crimson.withValues(alpha: 0.45)
              : _C.border.withValues(alpha: 0.50),
          width: needsAction ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44.w,
            height: 44.h,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: accentColor.withValues(alpha: 0.30)),
            ),
            child: Center(
                child: Text(isQuickMatch ? '⚡' : '⚔️',
                    style: TextStyle(fontSize: 18.sp))),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  animeTitle,
                  style: TextStyle(
                      color: _C.text,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 3.h),
                Text('vs $opponentName',
                    style: TextStyle(color: _C.textMuted, fontSize: 11.sp)),
                SizedBox(height: 4.h),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 2.r),
                  decoration: BoxDecoration(
                    color: needsAction
                        ? _C.crimson.withValues(alpha: 0.14)
                        : _C.elevated,
                    borderRadius: BorderRadius.circular(5.r),
                    border: Border.all(
                      color: needsAction
                          ? _C.crimson.withValues(alpha: 0.35)
                          : _C.border.withValues(alpha: 0.4),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: needsAction ? _C.crimsonBright : _C.textMuted,
                      fontSize: 10.sp,
                      fontWeight:
                          needsAction ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (!isQuickMatch && stakeAmount > 0) ...[
                  SizedBox(height: 4.h),
                  Row(
                    children: [
                      Text('🪙 $stakeAmount AC',
                          style:
                              TextStyle(color: _C.textMuted, fontSize: 10.sp)),
                      if (wpStake > 0) ...[
                        SizedBox(width: 8.w),
                        Text('⭐ $wpStake WP',
                            style: TextStyle(
                                color: _C.textMuted, fontSize: 10.sp)),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: 10.w),
          if (showCopyCode)
            SizedBox(
              width: 90.w,
              child: _CopyCodeButton(code: challengeId),
            )
          else if (needsAction && questionIds.isNotEmpty)
            SizedBox(
              width: 90.w,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PlayNowButton(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChallengeLobbyPage(
                          challengeId: challengeId,
                        ),
                      ),
                    ),
                  ),
                  if (canDecline) ...[
                    SizedBox(height: 6.h),
                    _DeclineButton(
                      loading: _declining,
                      onTap: () => _declineChallenge(context, challengeId),
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

// ─── Decline button ──────────────────────────────────────────────────────────
class _DeclineButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;
  const _DeclineButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Ink(
      decoration: BoxDecoration(
        color: _C.crimson.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9.r),
        border: Border.all(
          color: _C.crimson.withValues(alpha: 0.4),
        ),
      ),
      child: InkWell(
        onTap: loading ? null : onTap,
        borderRadius: BorderRadius.circular(9.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
          child: Center(
            child: loading
                ? SizedBox(
                    width: 11.w,
                    height: 11.h,
                    child: const CircularProgressIndicator(
                        strokeWidth: 1.6, color: _C.textMuted),
                  )
                : Text(
                    'Decline',
                    style: TextStyle(
                        color: _C.crimson,
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w700),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Copy code button ────────────────────────────────────────────────────────
class _CopyCodeButton extends StatelessWidget {
  final String code;
  const _CopyCodeButton({required this.code});

  @override
  Widget build(BuildContext context) {
    return Ink(
      decoration: BoxDecoration(
        color: _C.elevated,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: _C.border.withValues(alpha: 0.65)),
      ),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: code));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Challenge code copied!'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ));
        },
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                code,
                style: TextStyle(
                  color: _C.text,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.5,
                ),
              ),
              SizedBox(height: 3.h),
              Text('tap to copy',
                  style: TextStyle(color: _C.textMuted, fontSize: 9.sp)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Play Now button ─────────────────────────────────────────────────────────
class _PlayNowButton extends StatelessWidget {
  final VoidCallback onTap;
  const _PlayNowButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: 'Accept',
      onPressed: onTap,
      variant: AppButtonVariant.primary,
      size: AppButtonSize.small,
      width: double.infinity,
      height: 38.h,
    );
  }
}

// ─── Matched dialog ─────────────────────────────────────────────────────────
class _MatchedDialog extends StatefulWidget {
  final _MatchResult result;
  const _MatchedDialog({required this.result});

  @override
  State<_MatchedDialog> createState() => _MatchedDialogState();
}

class _MatchedDialogState extends State<_MatchedDialog> {
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    _autoDismissTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    super.dispose();
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
            Container(
              width: 72.w,
              height: 72.h,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _C.crimsonGlow,
                border: Border.all(
                    color: _C.crimson.withValues(alpha: 0.5), width: 1.5),
              ),
              child: Center(
                child: Text('⚡', style: TextStyle(fontSize: 30.sp)),
              ),
            ),
            SizedBox(height: 16.h),
            Text(
              'GHOST FOUND!',
              style: TextStyle(
                color: _C.crimsonBright,
                fontSize: 12.sp,
                fontWeight: FontWeight.w800,
                letterSpacing: 2.5,
              ),
            ),
            SizedBox(height: 12.h),
            Text(
              result.opponentName,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _C.text,
                fontSize: 24.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            SizedBox(height: 8.h),
            Text(
              result.animeTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _C.textMuted,
                fontSize: 15.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 20.h),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _PlayerTag(
                  label: 'YOU',
                  name: 'You',
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.r),
                  child: Text(
                    'VS',
                    style: TextStyle(
                      color: _C.crimson.withValues(alpha: 0.8),
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                _PlayerTag(
                  label: result.isGhost ? 'GHOST' : 'RIVAL',
                  name: result.opponentName,
                ),
              ],
            ),
            SizedBox(height: 24.h),
            Text(
              'Starting battle...',
              style: TextStyle(color: _C.textMuted, fontSize: 12.sp),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerTag extends StatelessWidget {
  final String label;
  final String name;
  const _PlayerTag({required this.label, required this.name});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 4.r),
          decoration: BoxDecoration(
            color: _C.elevated,
            borderRadius: BorderRadius.circular(6.r),
            border: Border.all(color: _C.border.withValues(alpha: 0.5)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: _C.textMuted,
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
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _C.text,
              fontSize: 14.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Battle header premium chip ───────────────────────────────────────────────
// Free users get a tappable gold "GO PREMIUM" pill; premium users get a calm
// gold crown pill affirming their status. Both lead to PremiumUpsellScreen.
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

// ─── Quick Match premium line ─────────────────────────────────────────────────
// One-line, zero-height-cost hint under the QM status:
//   - premium: quiet gold affirmation of extra QM access
//   - free:    grey nudge naming what Premium adds
class _QMPremiumLine extends StatelessWidget {
  final bool premiumActive;
  final int tokens;
  final bool isWindowOpen;

  const _QMPremiumLine({
    required this.premiumActive,
    required this.tokens,
    required this.isWindowOpen,
  });

  @override
  Widget build(BuildContext context) {
    final String label;
    if (premiumActive) {
      if (!isWindowOpen) {
        label = '★ Premium · watch for your next window';
      } else if (tokens > 0) {
        label = '★ Premium · extra QM access active';
      } else {
        label = '★ Premium · watch an ad below for one more token';
      }
    } else {
      label = '★ Premium adds extra Quick Match access';
    }

    return Text(
      label,
      style: TextStyle(
        color: premiumActive ? Color(0xFFFFB300) : _C.textMuted,
        fontSize: 10.sp,
        fontWeight: premiumActive ? FontWeight.w800 : FontWeight.w600,
      ),
    );
  }
}
