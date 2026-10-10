// lib/features/multiplayer/challenge_lobby_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/app_update_service.dart';
import '../../core/providers/user_data_provider.dart';
import '../quiz/quiz_controller.dart' show QuizMode;
import '../quiz/questions_page.dart';
import 'challenge_model.dart';
import 'challenge_result_page.dart';

// ─── Challenge Lobby ──────────────────────────────────────────────────────────
//
// Scope of this page is now strictly PRE-completion: waiting for an opponent,
// accepting, declining, and playing. The moment the challenge settles it
// hands off to ChallengeResultPage and gets out of the way — there is no
// "View Full Results" button, because a settled challenge should never be
// sitting on a lobby screen waiting for someone to tap through.
//
// That replaces the previous arrangement, which had two exit doors: a manual
// button that pushed ChallengeResultPage, and a post-quiz creator state that
// suppressed the lobby's own waiting UI. Both are gone.
class ChallengeLobbyPage extends StatefulWidget {
  final String challengeId;

  const ChallengeLobbyPage({
    super.key,
    required this.challengeId,
  });

  @override
  State<ChallengeLobbyPage> createState() => _ChallengeLobbyPageState();
}

class _ChallengeLobbyPageState extends State<ChallengeLobbyPage> {
  String? _uid;

  static void launchQuiz(BuildContext context, ChallengeModel challenge) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isCreator = uid == challenge.creatorUid;
    final isQuickMatch = challenge.isQuickMatch == true;
    final opponentName = isCreator
        ? challenge.opponentUsername ?? 'Opponent'
        : challenge.creatorUsername;

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) => FadeTransition(
          opacity: a,
          child: QuestionsPage(
            mode: QuizMode.asyncChallenge,
            questionIds: challenge.questionIds,
            challengeId: challenge.challengeId,
            isCreator: isCreator,
            isQuickMatch: isQuickMatch,
            isGhost: false,
            opponentName: opponentName,
          ),
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;
  }

  void _shareChallenge(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.challengeId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Challenge code copied! Share it with a friend.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ChallengeModel?>(
      stream: FirestoreService.instance.challengeStream(widget.challengeId),
      builder: (context, snap) {
        final challenge = snap.data;

        // ── Hand off to the result page the instant the challenge settles ──
        // Declines and expiries are terminal too, and the result page has
        // explicit copy for each, so it is the right destination for them
        // as well rather than a lobby that can offer no action at all.
        if (challenge != null && _isTerminal(challenge)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            Navigator.pushReplacement(
              context,
              AppPageRoute(
                builder: (_) => ChallengeResultPage(
                  challengeId: widget.challengeId,
                ),
              ),
            );
          });
        }

        final isCreator = challenge != null && challenge.creatorUid == _uid;
        final canShareCode = challenge != null &&
            isCreator &&
            !challenge.isQuickMatch &&
            challenge.kind != ChallengeKind.rival;

        // Show AC/WP balance in app bar for opponent accepting a rival challenge
        final isOpponent = challenge != null && challenge.opponentUid == _uid;
        final isWaiting = challenge?.status == ChallengeStatus.waiting;
        final showBalance =
            isOpponent && challenge.kind == ChallengeKind.rival && isWaiting;

        Widget body;
        if (snap.connectionState == ConnectionState.waiting) {
          body = const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        } else if (challenge == null) {
          body = const _NotFoundView();
        } else {
          body = _LobbyContent(
            challenge: challenge,
            currentUid: _uid ?? '',
          );
        }

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
              'Challenge Lobby',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
              ),
            ),
            actions: [
              if (canShareCode)
                IconButton(
                  icon: const Icon(Icons.share_rounded,
                      color: AppColors.textMuted),
                  onPressed: () => _shareChallenge(context),
                ),
              if (showBalance)
                Padding(
                  padding: EdgeInsets.only(right: 8.r), // added margin
                  child: Consumer<UserDataProvider>(
                    builder: (context, userData, child) {
                      return Row(
                        children: [
                          _BalancePill(
                            emoji: '🪙',
                            amount: userData.animeCoins,
                            color: AppColors.accent,
                          ),
                          SizedBox(width: 6.w),
                          _BalancePill(
                            emoji: '⭐',
                            amount: userData.weeklyPoints,
                            color: AppColors.secondary,
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
          body: body,
        );
      },
    );
  }

  /// A challenge the lobby has no further business with. Everything here is
  /// written by the backend as a final value: `completed` by
  /// _resolveChallengeCore / submitQuickMatchResult, `declined` by
  /// declineChallenge, `expired` / `expired_refunded` by
  /// expiredChallengeRefund.
  static bool _isTerminal(ChallengeModel c) =>
      c.isCompleted ||
      c.isDeclined ||
      c.status == ChallengeStatus.expired ||
      c.status == ChallengeStatus.expiredRefunded;
}

// ─── Balance Pill (matches multiplayer hub style) ──────────────────────
class _BalancePill extends StatelessWidget {
  final String emoji;
  final int amount;
  final Color color;

  const _BalancePill({
    required this.emoji,
    required this.amount,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 5.r),
      decoration: BoxDecoration(
        color: color.withOpacity(0.13),
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: color.withOpacity(0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: TextStyle(fontSize: 14.sp)),
          SizedBox(width: 4.w),
          Text(
            '$amount',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 14.sp,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Lobby Content ────────────────────────────────────────────────────────────
class _LobbyContent extends StatefulWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const _LobbyContent({
    required this.challenge,
    required this.currentUid,
  });

  @override
  State<_LobbyContent> createState() => _LobbyContentState();
}

class _LobbyContentState extends State<_LobbyContent> {
  bool _isAccepting = false;
  bool _isRejecting = false;

  // ─── Force Resolve state ───────────────────────────────────────────────
  bool _isResolving = false;

  ChallengeModel get c => widget.challenge;
  String get uid => widget.currentUid;

  bool get isCreator => uid == c.creatorUid;
  bool get isOpponent => uid == c.opponentUid;
  bool get isParticipant => isCreator || isOpponent;
  bool get isCompleted => c.isCompleted;
  bool get isDraw => c.isDraw;
  bool get isGhost => c.opponentUid == 'ghost';

  // ── Status helpers ──────────────────────────────────────────────────────────
  String get _statusText {
    if (isCompleted) {
      if (isDraw) return 'Draw 🤝';
      final winner = c.winnerUid(currentUid: uid);
      return winner == uid ? 'You Won 🏆' : 'You Lost 💀';
    }

    switch (c.status) {
      case ChallengeStatus.waiting:
        return isCreator
            ? 'Waiting for opponent to join…'
            : 'Pending — Accept to play';
      case ChallengeStatus.opponentJoined:
        return 'Opponent joined — Ready to play';
      case ChallengeStatus.creatorSubmitted:
        return isCreator
            ? 'Waiting for opponent…'
            : 'Creator played — Your turn!';
      case ChallengeStatus.opponentSubmitted:
        return isCreator
            ? 'Opponent played — Your turn!'
            : 'Waiting for creator…';
      case ChallengeStatus.declined:
        return 'Declined — Challenge did not start';
      case ChallengeStatus.expired:
        return 'Expired — Challenge did not start';
      case ChallengeStatus.expiredRefunded:
        return 'Expired — Stakes refunded';
      case ChallengeStatus.ghost:
        return 'Quick Match — Waiting for opponent';
      // Unreachable: isCompleted short-circuits above, but the switch must
      // still be total.
      case ChallengeStatus.completed:
        return 'Completed';
    }
  }

  Color get _statusColor {
    if (isCompleted) {
      if (isDraw) return AppColors.secondary;
      final winner = c.winnerUid(currentUid: uid);
      return winner == uid ? AppColors.correct : AppColors.wrong;
    }
    if (c.status == ChallengeStatus.declined) return AppColors.textMuted;
    if (c.status == ChallengeStatus.expiredRefunded) {
      return AppColors.textMuted;
    }
    if (c.status == ChallengeStatus.waiting && !isCreator) {
      return AppColors.accent;
    }
    return AppColors.textMuted;
  }

  // ── Action helpers ──────────────────────────────────────────────────────────
  bool get _canPlay {
    if (isCompleted) return false;
    if (isGhost) return false;

    if (isCreator && c.creatorScore == null) {
      return c.status == ChallengeStatus.opponentJoined ||
          c.status == ChallengeStatus.opponentSubmitted;
    }
    if (isOpponent && c.opponentScore == null) {
      return c.status == ChallengeStatus.opponentJoined ||
          c.status == ChallengeStatus.creatorSubmitted;
    }
    return false;
  }

  bool get _isWaitingForOtherPlayer {
    if (isCompleted) return false;
    if (isCreator && c.creatorScore != null && c.opponentScore == null) {
      return true;
    }
    if (isOpponent && c.opponentScore != null && c.creatorScore == null) {
      return true;
    }
    return false;
  }

  bool get _canAccept {
    if (isCreator || c.status != ChallengeStatus.waiting) return false;

    // Rival challenges are directly assigned to one opponent.
    // Code challenges can still be accepted by any non-creator who has the code.
    if (c.kind == ChallengeKind.rival) return isOpponent;
    return true;
  }

  // Only the specifically-invited opponent on a still-pending rival
  // challenge can decline it — mirrors declineChallenge's server-side check.
  bool get _canDecline {
    return !isCreator &&
        c.status == ChallengeStatus.waiting &&
        c.opponentUid == uid;
  }

  bool get _showCopyCode {
    return isCreator &&
        c.status == ChallengeStatus.waiting &&
        c.kind == ChallengeKind.code;
  }

  // ── Balance / affordability ────────────────────────────────────────────
  int get _requiredWp => c.wpStake ?? 0;

  bool _canAffordAC(BuildContext context) =>
      context.watch<UserDataProvider>().animeCoins >= c.stakeAmount;

  bool _canAffordWp(BuildContext context) =>
      _requiredWp <= 0 ||
      context.watch<UserDataProvider>().weeklyPoints >= _requiredWp;

  // ─── Challenge type (with fallback) ──────────────────────────────────────
  // `challengeType` is only written for Code challenges by createChallenge and
  // is absent on Quick Match documents, so `isQuickMatch` is the field that
  // decides the Quick Match case and `c.kind` handles the rest.
  String get _challengeType => switch (c.kind) {
        ChallengeKind.rival => '⚔️ Rival Challenge',
        ChallengeKind.quick => '⚡ Quick Match',
        ChallengeKind.code => '📤 Code Challenge',
        ChallengeKind.spar => '🤝 Spar',
      };

  // ─── Force Resolve recovery action ─────────────────────────────────────
  bool get _canForceResolve {
    if (isCompleted) return false;
    if (isGhost) return false;
    if (!isParticipant) return false;
    return c.creatorScore != null && c.opponentScore != null;
  }

  Future<void> _forceResolve() async {
    if (_isResolving) return;
    setState(() => _isResolving = true);

    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('forceResolveChallenge')
          .call({'challengeId': c.challengeId});

      if (!mounted) return;

      final data = result.data as Map;
      if (data['alreadyResolved'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Challenge was already resolved.'),
            backgroundColor: AppColors.textMuted,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Resolved! Outcome: ${data['outcome'] ?? 'unknown'}'),
            backgroundColor: AppColors.correct,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Force resolve failed: ${e.toString()}'),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final canAffordAC = _canAffordAC(context);
    final canAffordWp = _canAffordWp(context);
    final canAfford = canAffordAC && canAffordWp;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 28.r), // moderate
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Challenge type badge ──────────────────────────────────────
          _TypeBadge(type: _challengeType),

          SizedBox(height: 14.h), // moderate

          // ── Status header ─────────────────────────────────────────────
          _StatusHeader(
            statusText: _statusText,
            statusColor: _statusColor,
            isCompleted: isCompleted,
          ),

          SizedBox(height: 16.h), // moderate

          // ── VS card ────────────────────────────────────────────────────
          _VsCard(
            challenge: c,
            currentUid: uid,
            isCompleted: isCompleted,
          ),

          SizedBox(height: 16.h), // moderate

          // ── Challenge details ─────────────────────────────────────────
          _ChallengeDetailsCard(
            challenge: c,
            isCreator: isCreator,
          ),

          SizedBox(height: 16.h), // moderate

          // ── Stakes ─────────────────────────────────────────────────────
          _StakesCard(
            challenge: c,
            isCompleted: isCompleted,
          ),

          SizedBox(height: 18.h), // moderate

          // ── Actions ────────────────────────────────────────────────────
          // No completed branch: the parent redirects to
          // ChallengeResultPage the moment the challenge settles, so reaching
          // this point means the challenge is genuinely still in play.
          if (_canAccept && !canAfford) ...[
            _InsufficientBalanceWidget(
              requiredAC: c.stakeAmount,
              requiredWp: _requiredWp,
              missingAC: !canAffordAC,
              missingWp: !canAffordWp,
            ),
            if (_canDecline) ...[
              SizedBox(height: 10.h),
              _RejectButton(
                loading: _isRejecting,
                onTap: () => _onDecline(context),
              ),
            ],
          ] else if (_canAccept) ...[
            _AcceptButton(
              onTap: () => _onAccept(context, canAfford: canAfford),
              loading: _isAccepting,
            ),
            if (_canDecline) ...[
              SizedBox(height: 10.h),
              _RejectButton(
                loading: _isRejecting,
                onTap: () => _onDecline(context),
              ),
            ],
          ] else if (_canPlay)
            _PlayButton(
              onTap: () => _launchQuiz(context),
            )
          else if (_isWaitingForOtherPlayer) ...[
            _WaitingForOtherPlayerWidget(
              message: isCreator
                  ? 'Waiting for opponent to play…'
                  : 'Waiting for creator to play…',
            ),
            SizedBox(height: 10.h),
            _LobbyNudgeButton(
              challengeId: c.challengeId,
              otherUid:
                  isCreator ? (c.opponentUid ?? '') : c.creatorUid,
            ),
          ]
          else if (_showCopyCode)
            _CopyCodeButton(code: c.challengeId)
          else if (isCreator && c.status == ChallengeStatus.waiting)
            const _WaitingForOtherPlayerWidget(
              message: 'Waiting for opponent to join…',
            )
          else if (!isParticipant)
            const _SpectatorWidget(),

          // Recovery only: useful if both scores exist but the backend has not resolved yet.
          if (_canForceResolve) ...[
            SizedBox(height: 12.h),
            OutlinedButton.icon(
              onPressed: _isResolving ? null : _forceResolve,
              icon: _isResolving
                  ? SizedBox(
                      width: 18.w,
                      height: 18.h,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.warning_amber_rounded, size: 18.r),
              label: Text(_isResolving ? 'Resolving…' : '⚡ Force Resolve'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.wrong,
                side: BorderSide(color: AppColors.wrong.withOpacity(0.5)),
                padding: EdgeInsets.symmetric(vertical: 12.r),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14.r),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Actions ──────────────────────────────────────────────────────────────────
  String _friendlyAcceptError(String raw) {
    final s = raw.replaceFirst('Exception: ', '');
    return switch (s) {
      'insufficient_coins' => 'Not enough AC for this stake.',
      'insufficient_wp' => 'Not enough WP for this stake.',
      'daily_challenge_limit_reached' =>
        'Daily limit reached — max 5 challenges joined per day.',
      'too_many_active_challenges' =>
        'You already have 5 active challenges running.',
      'challenge_not_waiting' => 'This challenge is no longer available.',
      'cannot_join_own_challenge' => "That's your own challenge!",
      'not_friends' => 'Add them as a friend to spar.',
      _ => s,
    };
  }

  Future<void> _onAccept(BuildContext context,
      {required bool canAfford}) async {
    if (_isAccepting) return;

    // NOTE: previously this recomputed affordability here via
    // _canAffordAC(context)/_canAffordWp(context), which call
    // context.watch<UserDataProvider>() internally. context.watch() is only
    // legal inside build() — calling it from a button's onTap callback throws
    // a Provider assertion error immediately. In release mode that exception
    // is swallowed, so tapping "Accept & Play" silently did nothing. We now
    // reuse the `canAfford` value already computed in build() (where watch()
    // is valid) instead of re-deriving it here.
    if (!canAfford) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Insufficient balance for this stake.'),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
      setState(() {});
      return;
    }

    setState(() => _isAccepting = true);

    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('joinChallenge')
          .call({
        'challengeId': c.challengeId,
        ...AppUpdateService.instance.clientBuildStamp,
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Challenge accepted! Get ready to play.'),
          backgroundColor: AppColors.correct,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );

      // Removed the 500ms delay for instant transition
      _launchQuiz(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isAccepting = false);
      final message = e is FirebaseFunctionsException
          ? _friendlyAcceptError(e.message ?? e.code)
          : _friendlyAcceptError(e.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to join: $message'),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _friendlyDeclineError(String raw) {
    final s = raw.replaceFirst('Exception: ', '');
    return switch (s) {
      'challenge_not_pending' => 'This challenge is no longer pending.',
      'not_the_invited_opponent' => 'You can\'t decline this challenge.',
      _ => s,
    };
  }

  Future<void> _onDecline(BuildContext context) async {
    if (_isRejecting || _isAccepting) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Decline challenge?',
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: const Text(
          'Their stake will be refunded to them. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Decline',
                style: TextStyle(
                    color: AppColors.wrong, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isRejecting = true);

    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('declineChallenge')
          .call({'challengeId': c.challengeId});

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Challenge declined.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );

      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRejecting = false);
      final message = e is FirebaseFunctionsException
          ? _friendlyDeclineError(e.message ?? e.code)
          : _friendlyDeclineError(e.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to decline: $message'),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _launchQuiz(BuildContext context) {
    _ChallengeLobbyPageState.launchQuiz(context, c);
  }
}

// ─── Widget: Type Badge ──────────────────────────────────────────────────────
class _TypeBadge extends StatelessWidget {
  final String type;
  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final isRival = type.contains('Rival');
    final isQuick = type.contains('Quick');

    Color color;
    IconData icon;
    if (isRival) {
      color = const Color(0xFFFF6B00);
      icon = Icons.emoji_events_rounded;
    } else if (isQuick) {
      color = AppColors.primary;
      icon = Icons.bolt_rounded;
    } else {
      color = AppColors.secondary;
      icon = Icons.qr_code_rounded;
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14.r),
          SizedBox(width: 6.w),
          Text(
            type,
            style: TextStyle(
              color: color,
              fontSize: 11.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widget: Status Header ──────────────────────────────────────────────────
class _StatusHeader extends StatelessWidget {
  final String statusText;
  final Color statusColor;
  final bool isCompleted;

  const _StatusHeader({
    required this.statusText,
    required this.statusColor,
    required this.isCompleted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r), // moderate (was 12)
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(
          color: statusColor.withOpacity(0.25),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 4.w,
            height: 30.h,
            decoration: BoxDecoration(
              color: statusColor,
              borderRadius: BorderRadius.circular(2.r),
            ),
          ),
          SizedBox(width: 14.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isCompleted ? 'Match Complete' : 'Status',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 16.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          if (!isCompleted)
            Container(
              width: 8.w,
              height: 8.h,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor,
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withOpacity(0.5),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Widget: VS Card ────────────────────────────────────────────────────────
class _VsCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final bool isCompleted;

  const _VsCard({
    required this.challenge,
    required this.currentUid,
    required this.isCompleted,
  });

  @override
  Widget build(BuildContext context) {
    final isCreator = currentUid == challenge.creatorUid;
    final isOpponent = currentUid == challenge.opponentUid;

    final myScore = isCreator
        ? challenge.creatorScore
        : (isOpponent ? challenge.opponentScore : null);
    final canRevealOthersScore = isCompleted || myScore != null;

    final creatorScoreVisible = isCreator || canRevealOthersScore;
    final opponentScoreVisible = isOpponent || canRevealOthersScore;

    return Container(
      padding: EdgeInsets.all(16.r), // moderate (was 14)
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
              Text(
                isCompleted ? 'FINAL SCORE' : 'PLAYERS',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10.sp,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          SizedBox(height: 12.h), // moderate (was 10)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _PlayerTile(
                  name: challenge.creatorUsername,
                  score: challenge.creatorScore,
                  scoreVisible: creatorScoreVisible,
                  isCurrentUser: isCreator,
                  isWinner: isCompleted && challenge.outcome == 'creator_wins',
                  alignRight: false,
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12.r),
                child: Container(
                  width: 44.w,
                  height: 44.h,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(14.r),
                    border: Border.all(
                      color: AppColors.primary.withOpacity(0.2),
                    ),
                  ),
                  child: Text(
                    'VS',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 12.sp,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _PlayerTile(
                  name: challenge.opponentUsername ?? 'Opponent',
                  score: challenge.opponentScore,
                  scoreVisible: opponentScoreVisible,
                  isCurrentUser: isOpponent,
                  isWinner: isCompleted && challenge.outcome == 'opponent_wins',
                  alignRight: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayerTile extends StatelessWidget {
  final String name;
  final int? score;
  final bool scoreVisible;
  final bool isCurrentUser;
  final bool isWinner;
  final bool alignRight;

  const _PlayerTile({
    required this.name,
    required this.score,
    required this.scoreVisible,
    required this.isCurrentUser,
    required this.isWinner,
    required this.alignRight,
  });

  @override
  Widget build(BuildContext context) {
    final scoreColor = isWinner ? AppColors.correct : AppColors.textPrimary;

    final String scoreText;
    if (score == null) {
      scoreText = '…';
    } else if (!scoreVisible) {
      scoreText = '🔒';
    } else {
      scoreText = '$score';
    }

    return Column(
      crossAxisAlignment:
          alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (isWinner) ...[
          Text('👑', style: TextStyle(fontSize: 16.sp)),
          SizedBox(height: 2.h),
        ],
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 4.r),
          decoration: BoxDecoration(
            color: isCurrentUser
                ? AppColors.primary.withOpacity(0.10)
                : AppColors.surfaceAlt.withOpacity(0.5),
            borderRadius: BorderRadius.circular(8.r),
            border: Border.all(
              color: isCurrentUser
                  ? AppColors.primary.withOpacity(0.2)
                  : Colors.transparent,
            ),
          ),
          child: Text(
            isCurrentUser ? 'You' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isCurrentUser ? AppColors.primary : AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(height: 8.h),
        Text(
          scoreText,
          style: TextStyle(
            color: score != null && !scoreVisible
                ? AppColors.textMuted
                : scoreColor,
            fontSize: score != null && !scoreVisible ? 28.sp : 38.sp,
            fontWeight: FontWeight.w900,
            height: 0.9,
            letterSpacing: -1.5,
            shadows: isWinner
                ? [
                    Shadow(
                      color: AppColors.correct.withOpacity(0.3),
                      blurRadius: 12,
                    ),
                  ]
                : null,
          ),
        ),
        SizedBox(height: 2.h),
        Text(
          scoreVisible || score == null ? '/ 10' : 'hidden',
          style: TextStyle(
            color: AppColors.textMuted.withOpacity(0.5),
            fontSize: 11.sp,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// ─── Widget: Challenge Details ──────────────────────────────────────────────
class _ChallengeDetailsCard extends StatelessWidget {
  final ChallengeModel challenge;
  final bool isCreator;

  const _ChallengeDetailsCard({
    required this.challenge,
    required this.isCreator,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16.r), // moderate (was 14)
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DETAILS',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          SizedBox(height: 12.h),
          _DetailRow(
            icon: '🎬',
            label: 'Anime',
            value: challenge.animeTitle,
          ),
          SizedBox(height: 7.h), // moderate (was 6)
          _DetailRow(
            icon: '👤',
            label: 'Created by',
            value: challenge.creatorUsername,
          ),
          if (challenge.opponentUsername != null &&
              challenge.opponentUsername!.isNotEmpty) ...[
            SizedBox(height: 7.h),
            _DetailRow(
              icon: '👥',
              label: 'Opponent',
              value: challenge.opponentUsername!,
            ),
          ],
          SizedBox(height: 7.h),
          _DetailRow(
            icon: '📅',
            label: 'Created',
            value: _formatDate(challenge.createdAt),
          ),
          if (!challenge.isCompleted) ...[
            SizedBox(height: 7.h),
            _DetailRow(
              icon: '⏳',
              label: 'Expires',
              value: _formatTimeRemaining(challenge.timeRemaining),
              valueColor:
                  challenge.timeRemaining.inHours < 6 ? AppColors.wrong : null,
            ),
          ],
          // Removed the info box about sharing the code below stakes.
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'Just now';
  }

  String _formatTimeRemaining(Duration d) {
    if (d == Duration.zero) return 'Expired';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}

class _DetailRow extends StatelessWidget {
  final String icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(icon, style: TextStyle(fontSize: 14.sp)),
        SizedBox(width: 8.w),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 12.sp,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? AppColors.textPrimary,
            fontSize: 13.sp,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// ─── Widget: Stakes Card ────────────────────────────────────────────────────
class _StakesCard extends StatelessWidget {
  final ChallengeModel challenge;
  final bool isCompleted;

  const _StakesCard({
    required this.challenge,
    required this.isCompleted,
  });

  @override
  Widget build(BuildContext context) {
    final isQuickMatch = challenge.isQuickMatch;

    // Quick Match has no stake at all (stakeAmount is always 0, wpStake is
    // never set) — before completion there's nothing meaningful to preview
    // here, so the whole card is skipped rather than showing an empty
    // "REWARD" header with nothing under it.
    if (isQuickMatch && !isCompleted) {
      return const SizedBox.shrink();
    }

    final hasWP = challenge.wpStake != null && challenge.wpStake! > 0;

    return Container(
      padding: EdgeInsets.all(16.r), // moderate (was 14)
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isQuickMatch ? 'REWARD' : 'STAKES',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          SizedBox(height: 10.h), // moderate (was 8)
          // Quick Match never has a real stake — showing "0 AC" pills here
          // was meaningless clutter, so they're skipped entirely and this
          // card goes straight to the reward actually earned below.
          if (!isQuickMatch)
            Row(
              children: [
                _StakePill(
                  icon: '🪙',
                  label: '${challenge.stakeAmount} AC',
                  color: AppColors.accent,
                ),
                if (hasWP) ...[
                  SizedBox(width: 10.w),
                  _StakePill(
                    icon: '⭐',
                    label: '${challenge.wpStake} WP',
                    color: AppColors.secondary,
                  ),
                ],
              ],
            ),
          if (isCompleted) ...[
            if (!isQuickMatch) ...[
              SizedBox(height: 10.h), // moderate (was 8)
              const Divider(color: AppColors.divider),
              SizedBox(height: 10.h), // moderate (was 8)
            ],
            _RewardRow(
              challenge: challenge,
              currentUid: FirebaseAuth.instance.currentUser?.uid ?? '',
            ),
          ],
        ],
      ),
    );
  }
}

class _StakePill extends StatelessWidget {
  final String icon;
  final String label;
  final Color color;

  const _StakePill({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: TextStyle(fontSize: 14.sp)),
          SizedBox(width: 6.w),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widget: Reward row (was _OutcomeRow) ──────────────────────────────────
// This used to lead with an emoji + "Outcome: Win/Loss/Draw" label — but
// _StatusHeader at the top of the page already shows exactly that ("You Won
// 🏆" / "You Lost 💀" / "Draw 🤝"), so every completed challenge showed the
// same win/loss/draw verdict twice on one screen. This row now only shows
// the actual AC/WP reward, which the top banner doesn't convey.
class _RewardRow extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const _RewardRow({
    required this.challenge,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    final isDraw = challenge.isDraw;
    final iWon = challenge.didCurrentUserWin(currentUid);

    final int acChange;
    final int wpChange;

    if (challenge.isQuickMatch) {
      // Flat Quick Match rewards — mirrors ChallengeResultPage's
      // _acEarnedFor/_wpEarnedFor.
      acChange = iWon
          ? ChallengeModel.quickMatchAcWin
          : isDraw
              ? ChallengeModel.quickMatchAcDraw
              : ChallengeModel.quickMatchAcLose;
      wpChange = iWon
          ? ChallengeModel.quickMatchWpWin
          : isDraw
              ? ChallengeModel.quickMatchWpDraw
              : ChallengeModel.quickMatchWpLose;
    } else {
      acChange = isDraw
          ? ChallengeModel.payoutDraw(challenge.stakeAmount) -
              challenge.stakeAmount
          : (iWon ? ChallengeModel.payoutWin(challenge.stakeAmount) : 0);

      // WP: total credited = flat base reward (50/25) + stake settlement,
      // mirroring _resolveChallengeCore's cBaseWp += wpCreatorChange (see
      // ChallengeModel.wpTotalCredited). Code challenges (wpStake == 0)
      // still earn the flat base reward on a win/draw — previously shown
      // as +0 here. A loss credits nothing further (the stake was already
      // forfeited at create/join time), so it keeps "Nothing this time".
      final wpStake = challenge.wpStake ?? 0;
      wpChange = (iWon || isDraw)
          ? ChallengeModel.wpTotalCredited(
              wpStake: wpStake,
              won: iWon,
              isDraw: isDraw,
            )
          : 0;
    }

    final hasAc = acChange != 0;
    final hasWp = wpChange != 0;

    return Row(
      children: [
        Text(
          'You earned',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 13.sp,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        if (hasAc)
          Text(
            '${acChange > 0 ? '+' : ''}$acChange AC',
            style: TextStyle(
              color: acChange > 0 ? AppColors.accent : AppColors.wrong,
              fontSize: 14.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
        if (hasWp) ...[
          SizedBox(width: hasAc ? 10.w : 0.w),
          Text(
            '${wpChange > 0 ? '+' : ''}$wpChange WP',
            style: TextStyle(
              color: wpChange > 0 ? AppColors.correct : AppColors.wrong,
              fontSize: 14.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
        if (!hasAc && !hasWp)
          Text(
            'Nothing this time',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 13.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }
}

// ─── Widget: Accept Button (FIXED - stateless, no duplicate call) ──────────
class _AcceptButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool loading;

  const _AcceptButton({
    required this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppButton(
      variant: AppButtonVariant.gradient,
      label: loading ? 'Accepting…' : '⚔️ Accept & Play',
      icon: loading ? null : const Icon(Icons.flash_on_rounded),
      onPressed: loading ? null : onTap,
    );
  }
}

// ─── Widget: Reject/Decline Button ──────────────────────────────────────────
class _RejectButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;

  const _RejectButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: loading ? null : onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.wrong,
          side: BorderSide(color: AppColors.wrong.withOpacity(0.45)),
          padding: EdgeInsets.symmetric(vertical: 14.r),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14.r),
          ),
        ),
        child: loading
            ? SizedBox(
                width: 18.w,
                height: 18.h,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                'Decline',
                style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w800),
              ),
      ),
    );
  }
}

// ─── Widget: Lobby Nudge Button ───────────────────────────────────────────
// Preset "Your turn!" ping for a challenge waiting on the other side.
// Server verifies friendship, turn order and the once-per-day gate.
class _LobbyNudgeButton extends StatefulWidget {
  final String challengeId;
  final String otherUid;
  const _LobbyNudgeButton(
      {required this.challengeId, required this.otherUid});

  @override
  State<_LobbyNudgeButton> createState() => _LobbyNudgeButtonState();
}

class _LobbyNudgeButtonState extends State<_LobbyNudgeButton> {
  bool _busy = false;
  bool _done = false;

  Future<void> _nudge() async {
    if (_busy || _done || widget.otherUid.isEmpty) return;
    setState(() => _busy = true);
    try {
      await FirestoreService.instance.nudgeFriend(
        friendUid: widget.otherUid,
        challengeId: widget.challengeId,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nudge sent!'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not nudge — try again later.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed:
            (_busy || _done || widget.otherUid.isEmpty) ? null : _nudge,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.secondary,
          side: BorderSide(
              color: AppColors.secondary.withOpacity(0.45)),
          padding: EdgeInsets.symmetric(vertical: 12.r),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14.r),
          ),
        ),
        child: Text(
          _done
              ? 'Nudged ✓'
              : _busy
                  ? 'Sending…'
                  : 'Nudge them',
          style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

// ─── Widget: Play Button ────────────────────────────────────────────────────
class _PlayButton extends StatelessWidget {
  final VoidCallback onTap;

  const _PlayButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppButton(
      variant: AppButtonVariant.gradient,
      label: '⚡ Play Now',
      icon: const Icon(Icons.flash_on_rounded),
      onPressed: onTap,
    );
  }
}

// ─── Widget: Insufficient Balance ───────────────────────────────────────────
class _InsufficientBalanceWidget extends StatelessWidget {
  final int requiredAC;
  final int requiredWp;
  final bool missingAC;
  final bool missingWp;

  const _InsufficientBalanceWidget({
    required this.requiredAC,
    required this.requiredWp,
    required this.missingAC,
    required this.missingWp,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (missingAC) '$requiredAC AC',
      if (missingWp) '$requiredWp WP',
    ].join(' and ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.wrong.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.wrong.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: AppColors.wrong,
            size: 22,
          ),
          const SizedBox(height: 8),
          const Text(
            'Insufficient Balance',
            style: TextStyle(
              color: AppColors.wrong,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'You need $parts to accept this challenge.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widget: Waiting for Other Player ───────────────────────────────────────
class _WaitingForOtherPlayerWidget extends StatelessWidget {
  final String message;

  const _WaitingForOtherPlayerWidget({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.textMuted.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.textMuted.withOpacity(0.15),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            message,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widget: Copy Code Button ──────────────────────────────────────────────
class _CopyCodeButton extends StatelessWidget {
  final String code;

  const _CopyCodeButton({required this.code});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: code));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Challenge code copied!'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.copy_rounded, color: AppColors.primary, size: 18),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Share Challenge Code',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  code,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.5,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Tap to Copy',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Widget: Spectator ──────────────────────────────────────────────────────
class _SpectatorWidget extends StatelessWidget {
  const _SpectatorWidget();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.textMuted.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.textMuted.withOpacity(0.15),
        ),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.visibility_rounded, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Text(
            'You are not a participant in this challenge',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widget: Not Found ──────────────────────────────────────────────────────
class _NotFoundView extends StatelessWidget {
  const _NotFoundView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.divider),
            ),
            child: const Icon(Icons.error_outline_rounded,
                color: AppColors.textMuted, size: 40),
          ),
          const SizedBox(height: 20),
          const Text(
            'Challenge Not Found',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'This challenge may have expired or been deleted.',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          AppButton(
            variant: AppButtonVariant.gradient,
            label: 'Back to Challenges',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}
