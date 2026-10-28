// lib/features/multiplayer/challenge_lobby_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/rival_economy.dart';
import '../../core/constants/share_links.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/rival_avatar.dart';
import '../../core/widgets/share_card.dart';
import '../../core/widgets/weekly_points_pill.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/device_id_service.dart';
import '../../core/services/share_service.dart';
import '../../core/providers/user_data_provider.dart';
import '../friends/friend_nudge_button.dart';
import '../quiz/questions_page.dart';
import 'challenge_model.dart';
import 'challenge_result_page.dart';

// ─── Challenge Lobby ──────────────────────────────────────────────────────────
//
// Scope of this page is strictly PRE-completion: waiting for an opponent,
// accepting, declining, and playing. The moment the challenge settles it
// hands off to ChallengeResultPage and gets out of the way.
//
// Layout: the match is an "arena" (two players split by a diagonal), a stat
// grid with the facts that matter before you commit, and a bottom dock that
// holds the one action the current state allows.
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
          body = ChallengeLobbyContent(
            challenge: challenge,
            currentUid: _uid ?? '',
          );
        }

        return Scaffold(
          backgroundColor: AppColors.surfaceDim,
          appBar: AppBar(
            backgroundColor: AppColors.surfaceDim,
            elevation: 0,
            leading: const AppBackButton(),
            title: Text('Challenge Lobby', style: AppTypography.heading3),
            actions: [
              if (showBalance)
                Padding(
                  padding: EdgeInsets.only(right: 8.r),
                  child: Consumer<UserDataProvider>(
                    builder: (context, userData, child) {
                      return Row(
                        children: [
                          _BalancePill(
                            emoji: '🪙',
                            amount: userData.animeCoins,
                            color: AppColors.readable(AppColors.accent),
                          ),
                          SizedBox(width: 6.w),
                          const WeeklyPointsPill(),
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

// ─── Balance Pill ─────────────────────────────────────────────────────────────
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
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(color: color.withValues(alpha: 0.38)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: AppTypography.bodyLarge),
          SizedBox(width: 4.w),
          Text(
            '$amount',
            style: AppTypography.labelLarge.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

// ─── Lobby Content ────────────────────────────────────────────────────────────
class ChallengeLobbyContent extends StatefulWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const ChallengeLobbyContent({
    super.key,
    required this.challenge,
    required this.currentUid,
  });

  @override
  State<ChallengeLobbyContent> createState() => _ChallengeLobbyContentState();
}

class _ChallengeLobbyContentState extends State<ChallengeLobbyContent> {
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
  bool get isGhost => c.isGhostMatch;

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
            : 'Pending';
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

  // A seat is still takeable while the invite is open — including after the
  // creator played first (their score is promoted to creator_submitted) — and
  // while the joiner's own score is unset.
  bool get _isJoinableStatus =>
      c.status == ChallengeStatus.waiting ||
      c.status == ChallengeStatus.creatorSubmitted;

  bool get _canAccept {
    if (isCreator || !_isJoinableStatus || c.opponentScore != null) return false;

    // Rival challenges are directly assigned to one opponent.
    // Code challenges can still be accepted by any non-creator who has the code.
    if (c.kind == ChallengeKind.rival) return isOpponent;
    return true;
  }

  // Only the specifically-invited opponent on a still-takeable rival
  // challenge can decline it — mirrors declineChallenge's server-side check.
  bool get _canDecline {
    return !isCreator &&
        _isJoinableStatus &&
        c.opponentScore == null &&
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
          .call({
        'challengeId': c.challengeId,
        'deviceId': await DeviceIdService.instance.value(),
        ...AppUpdateService.instance.clientBuildStamp,
      });

      if (!mounted) return;

      final data = result.data as Map;
      if (data['alreadyResolved'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Challenge was already resolved.'),
            backgroundColor: AppColors.textMuted,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Resolved! Outcome: ${data['outcome'] ?? 'unknown'}'),
            backgroundColor: AppColors.successSurface,
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

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20.r, 4.h, 20.r, 24.h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Arena(
                  challenge: c,
                  currentUid: uid,
                  statusText: _statusText,
                  statusColor: _statusColor,
                  isCompleted: isCompleted,
                ),

                SizedBox(height: 14.h),

                _LedgerGrid(challenge: c),

                // Recovery only: useful if both scores exist but the backend has not resolved yet.
                if (_canForceResolve) ...[
                  SizedBox(height: 14.h),
                  AppButton(
                    variant: AppButtonVariant.outline,
                    color: AppColors.readable(AppColors.wrong),
                    label: _isResolving ? 'Resolving…' : '⚡ Force Resolve',
                    loading: _isResolving,
                    onPressed: _isResolving ? null : _forceResolve,
                  ),
                ],
              ],
            ),
          ),
        ),
        _Dock(
          child: _dock(
            context,
            canAffordAC: canAffordAC,
            canAffordWp: canAffordWp,
          ),
        ),
      ],
    );
  }

  // The dock shows exactly one primary intent for the current state.
  Widget _dock(
    BuildContext context, {
    required bool canAffordAC,
    required bool canAffordWp,
  }) {
    final canAfford = canAffordAC && canAffordWp;

    if (_canAccept && !canAfford) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _BalanceNotice(
            requiredAC: c.stakeAmount,
            requiredWp: _requiredWp,
            missingAC: !canAffordAC,
            missingWp: !canAffordWp,
          ),
          SizedBox(height: 12.h),
          _acceptRow(context, canAfford),
        ],
      );
    }
    if (_canAccept) return _acceptRow(context, canAfford);

    if (_canPlay) {
      return _PlayButton(onTap: () => _launchQuiz(context));
    }

    if (_isWaitingForOtherPlayer) {
      return Row(
        children: [
          Expanded(
            child: _WaitingNote(
              message: isCreator
                  ? 'Waiting for opponent to play…'
                  : 'Waiting for creator to play…',
            ),
          ),
          SizedBox(width: 10.w),
          FriendNudgeButton(
            friendUid: isCreator ? (c.opponentUid ?? '') : c.creatorUid,
            challengeId: c.challengeId,
            variant: AppButtonVariant.outline,
            size: AppButtonSize.medium,
          ),
        ],
      );
    }

    if (_showCopyCode) return _CodeShare(code: c.challengeId);

    if (isCreator && c.status == ChallengeStatus.waiting) {
      return const _WaitingNote(message: 'Waiting for opponent to join…');
    }

    if (!isParticipant) {
      return const _WaitingNote(
        message: 'You are watching this challenge',
        icon: Icons.visibility_rounded,
      );
    }

    return const SizedBox.shrink();
  }

  Widget _acceptRow(BuildContext context, bool canAfford) {
    final accept = _AcceptButton(
      onTap: () => _onAccept(canAfford: canAfford),
      loading: _isAccepting,
    );
    if (!_canDecline) return accept;
    return Row(
      children: [
        Expanded(
          child: _RejectButton(
            loading: _isRejecting,
            onTap: _onDecline,
          ),
        ),
        SizedBox(width: 10.w),
        Expanded(flex: 2, child: accept),
      ],
    );
  }

  // ── Actions ──────────────────────────────────────────────────────────────────
  String _friendlyAcceptError(String raw, {bool premiumActive = false}) {
    final joinLimit = premiumActive ? kDailyJoinPremium : kDailyJoinFree;
    final activeLimit =
        premiumActive ? kActiveChallengesPremium : kActiveChallengesFree;
    final s = raw.replaceFirst('Exception: ', '');
    return switch (s) {
      'insufficient_coins' => 'Not enough AC for this stake.',
      'insufficient_wp' => 'Not enough WP for this stake.',
      'daily_challenge_limit_reached' =>
        'Daily limit reached — max $joinLimit challenges joined per day.',
      'too_many_active_challenges' =>
        'You already have $activeLimit active challenges running.',
      'challenge_not_waiting' => 'This challenge is no longer available.',
      'cannot_join_own_challenge' => "That's your own challenge!",
      'not_friends' => 'Add them as a friend to spar.',
      _ => s,
    };
  }

  Future<void> _onAccept({required bool canAfford}) async {
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
        'deviceId': await DeviceIdService.instance.value(),
        ...AppUpdateService.instance.clientBuildStamp,
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Challenge accepted! Get ready to play.'),
          backgroundColor: AppColors.successSurface,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );

      // Removed the 500ms delay for instant transition
      _launchQuiz(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isAccepting = false);
      final premiumActive =
          context.read<UserDataProvider>().premiumActive;
      final message = e is FirebaseFunctionsException
          ? _friendlyAcceptError(e.message ?? e.code, premiumActive: premiumActive)
          : _friendlyAcceptError(e.toString(), premiumActive: premiumActive);
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

  Future<void> _onDecline() async {
    if (_isRejecting || _isAccepting) return;

    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => AppDialog(
        icon: Icons.person_off_rounded,
        iconColor: AppColors.readable(AppColors.wrong),
        title: 'Decline challenge?',
        content: 'Their stake will be refunded to them. This can\'t be undone.',
        actions: [
          AppButton(
            variant: AppButtonVariant.text,
            color: AppColors.textSecondary,
            label: 'Cancel',
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            variant: AppButtonVariant.primary,
            color: AppColors.readable(AppColors.wrong),
            label: 'Decline',
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isRejecting = true);

    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('declineChallenge')
          .call({
        'challengeId': c.challengeId,
        'deviceId': await DeviceIdService.instance.value(),
        ...AppUpdateService.instance.clientBuildStamp,
      });

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

// ─── Arena ──────────────────────────────────────────────────────────────────
// The two players sit on either side of a diagonal split, with the live status
// in a strip along the bottom edge.
class _Arena extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final String statusText;
  final Color statusColor;
  final bool isCompleted;

  const _Arena({
    required this.challenge,
    required this.currentUid,
    required this.statusText,
    required this.statusColor,
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.feature),
      child: AppCard(
        tier: AppCardTier.feature,
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 188.h,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: const _SlashPainter(
                        left: AppColors.secondary,
                        right: AppColors.primary,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _Fighter(
                          name: challenge.creatorUsername,
                          score: challenge.creatorScore,
                          scoreVisible: creatorScoreVisible,
                          isYou: isCreator,
                          isWinner:
                              isCompleted && challenge.outcome == 'creator_wins',
                          color: AppColors.secondary,
                          alignEnd: false,
                        ),
                      ),
                      Expanded(
                        child: _Fighter(
                          name: challenge.opponentUsername ?? 'Open slot',
                          score: challenge.opponentScore,
                          scoreVisible: opponentScoreVisible,
                          isYou: isOpponent,
                          isWinner:
                              isCompleted && challenge.outcome == 'opponent_wins',
                          color: AppColors.readable(AppColors.primary),
                          alignEnd: true,
                        ),
                      ),
                    ],
                  ),
                  _VsBadge(),
                ],
              ),
            ),
            _StatusStrip(
              text: statusText,
              color: statusColor,
              live: !isCompleted,
            ),
          ],
        ),
      ),
    );
  }
}

class _SlashPainter extends CustomPainter {
  final Color left;
  final Color right;

  const _SlashPainter({required this.left, required this.right});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final mid = w / 2;
    const lean = 26.0;
    final rect = Offset.zero & size;

    final leftPath = Path()
      ..moveTo(0, 0)
      ..lineTo(mid + lean, 0)
      ..lineTo(mid - lean, h)
      ..lineTo(0, h)
      ..close();
    final rightPath = Path()
      ..moveTo(mid + lean, 0)
      ..lineTo(w, 0)
      ..lineTo(w, h)
      ..lineTo(mid - lean, h)
      ..close();

    canvas.drawPath(
      leftPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [left.withValues(alpha: 0.55), left.withValues(alpha: 0.12)],
        ).createShader(rect),
    );
    canvas.drawPath(
      rightPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [right.withValues(alpha: 0.55), right.withValues(alpha: 0.12)],
        ).createShader(rect),
    );
    canvas.drawLine(
      Offset(mid + lean, 0),
      Offset(mid - lean, h),
      Paint()
        ..color = AppColors.textPrimary.withValues(alpha: 0.85)
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant _SlashPainter old) =>
      old.left != left || old.right != right;
}

class _VsBadge extends StatelessWidget {
  const _VsBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46.r,
      height: 46.r,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        shape: BoxShape.circle,
        border: Border.all(
            color: AppColors.textPrimary.withValues(alpha: 0.85), width: 2),
      ),
      child: Text(
        'VS',
        style: AppTypography.labelLarge.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _Fighter extends StatelessWidget {
  final String name;
  final int? score;
  final bool scoreVisible;
  final bool isYou;
  final bool isWinner;
  final Color color;
  final bool alignEnd;

  const _Fighter({
    required this.name,
    required this.score,
    required this.scoreVisible,
    required this.isYou,
    required this.isWinner,
    required this.color,
    required this.alignEnd,
  });

  @override
  Widget build(BuildContext context) {
    final isHidden = score != null && !scoreVisible;
    final String scoreText;
    if (score == null) {
      scoreText = '…';
    } else if (isHidden) {
      scoreText = '🔒';
    } else {
      scoreText = '$score';
    }

    final align = alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 12.r),
      child: Column(
        crossAxisAlignment: align,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 22.r,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isWinner)
                  Text('👑', style: AppTypography.titleMedium),
                if (isWinner && isYou) SizedBox(width: 6.w),
                if (isYou)
                  Container(
                    padding:
                        EdgeInsets.symmetric(horizontal: 8.r, vertical: 2.r),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceDim.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(AppRadii.full),
                    ),
                    child: Text(
                      'You',
                      style: AppTypography.labelSmall.copyWith(
                        color: AppColors.textPrimary,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: 6.h),
          RivalAvatar(
            name: name,
            size: 58.r,
            color: color,
            highlight: isWinner,
          ),
          SizedBox(height: 8.h),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: alignEnd ? TextAlign.end : TextAlign.start,
            style: AppTypography.labelLarge
                .copyWith(color: AppColors.textPrimary),
          ),
          SizedBox(height: 4.h),
          Text(
            scoreText,
            style: AppTypography.heading1.copyWith(
              fontSize: isHidden ? 24.sp : 38.sp,
              height: 1,
              color: isWinner
                  ? AppColors.readable(AppColors.correct)
                  : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  final String text;
  final Color color;
  final bool live;

  const _StatusStrip({
    required this.text,
    required this.color,
    required this.live,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 12.r),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (live) ...[
            Container(
              width: 8.r,
              height: 8.r,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.6),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
            SizedBox(width: 10.w),
          ],
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: AppTypography.bodyLarge.copyWith(
                color: AppColors.readable(color),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Ledger ─────────────────────────────────────────────────────────────────
// The two facts that matter before committing: what is at stake and how long
// is left. Names already sit in the arena.
class _LedgerGrid extends StatelessWidget {
  final ChallengeModel challenge;

  const _LedgerGrid({required this.challenge});

  @override
  Widget build(BuildContext context) {
    final c = challenge;
    final wp = c.wpStake ?? 0;
    final isFree = c.stakeAmount <= 0 && wp <= 0;

    final String stakeValue;
    if (isFree) {
      stakeValue = 'Free';
    } else {
      stakeValue = [
        if (c.stakeAmount > 0) '${c.stakeAmount} AC',
        if (wp > 0) '$wp WP',
      ].join(' + ');
    }

    final remaining = c.timeRemaining;
    final lifetime = c.expiresAt.difference(c.createdAt);
    final fraction = lifetime.inSeconds <= 0
        ? 0.0
        : (remaining.inSeconds / lifetime.inSeconds).clamp(0.0, 1.0);
    final urgent = remaining.inHours < 6;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LedgerTile(label: 'Stake', value: stakeValue),
        SizedBox(height: 10.h),
        _LedgerTile(
          label: 'Time left',
          value: _formatTimeLeft(remaining),
          valueColor: urgent ? AppColors.wrong : null,
          footer: LinearProgressIndicator(
            value: fraction.toDouble(),
            minHeight: 4.r,
            backgroundColor: AppColors.divider,
            color: urgent ? AppColors.wrong : AppColors.accent,
            borderRadius: BorderRadius.circular(AppRadii.full),
          ),
        ),
      ],
    );
  }
}

class _LedgerTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? footer;

  const _LedgerTile({
    required this.label,
    required this.value,
    this.valueColor,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.all(14.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.bodySmall),
          SizedBox(height: 6.h),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.titleLarge.copyWith(
              color: valueColor ?? AppColors.textPrimary,
            ),
          ),
          if (footer != null) ...[
            SizedBox(height: 10.h),
            footer!,
          ],
        ],
      ),
    );
  }
}

// ─── Dock ───────────────────────────────────────────────────────────────────
class _Dock extends StatelessWidget {
  final Widget child;
  const _Dock({required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(20.r, 14.h, 20.r, 14.h),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: child,
      ),
    );
  }
}

class _BalanceNotice extends StatelessWidget {
  final int requiredAC;
  final int requiredWp;
  final bool missingAC;
  final bool missingWp;

  const _BalanceNotice({
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
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: AppColors.wrong.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.wrong.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              color: AppColors.readable(AppColors.wrong), size: 20.r),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              'You need $parts to accept this challenge.',
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingNote extends StatelessWidget {
  final String message;
  final IconData? icon;

  const _WaitingNote({required this.message, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 14.r),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null)
            Icon(icon, color: AppColors.textMuted, size: 18.r)
          else
            SizedBox(
              width: 16.r,
              height: 16.r,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.textMuted,
              ),
            ),
          SizedBox(width: 10.w),
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeShare extends StatelessWidget {
  final String code;
  const _CodeShare({required this.code});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
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
          padding: EdgeInsets.symmetric(horizontal: 16.r, vertical: 12.r),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: AppColors.primaryBorder),
          ),
          child: Row(
            children: [
              Icon(Icons.copy_rounded, color: AppColors.primary, size: 18.r),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Challenge code', style: AppTypography.bodySmall),
                    SizedBox(height: 2.h),
                    Text(
                      code,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.heading3
                          .copyWith(letterSpacing: 2.5),
                    ),
                  ],
                ),
              ),
              Text(
                'Tap to copy',
                style: AppTypography.labelMedium
                    .copyWith(color: AppColors.readable(AppColors.primary)),
              ),
              const SizedBox(width: AppSpacing.xs),
              IconButton(
                tooltip: 'Share challenge',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 40,
                ),
                onPressed: () => ShareService.instance.shareCard(
                  context,
                  card: ShareCard.forChallenge(code),
                  logicalSize: kShareCardSize,
                  fileName: 'animequiz-challenge-card',
                  text: challengeShareMessage(code),
                  subject: 'AnimeQuiz challenge',
                ),
                icon: Icon(
                  Icons.share_rounded,
                  color: AppColors.readable(AppColors.primary),
                  size: 18.r,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Widget: Accept / Decline / Play ────────────────────────────────────────
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
      size: AppButtonSize.large,
      label: loading ? 'Accepting…' : '⚔️ Accept & Play',
      icon: loading ? null : const Icon(Icons.flash_on_rounded),
      loading: loading,
      onPressed: loading ? null : onTap,
    );
  }
}

class _RejectButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onTap;

  const _RejectButton({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppButton(
      variant: AppButtonVariant.outline,
      size: AppButtonSize.medium,
      color: AppColors.readable(AppColors.wrong),
      label: 'Decline',
      loading: loading,
      onPressed: loading ? null : onTap,
    );
  }
}

class _PlayButton extends StatelessWidget {
  final VoidCallback onTap;

  const _PlayButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppButton(
      variant: AppButtonVariant.gradient,
      size: AppButtonSize.large,
      label: '⚡ Play Now',
      icon: const Icon(Icons.flash_on_rounded),
      onPressed: onTap,
    );
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────
String _formatTimeLeft(Duration d) {
  if (d == Duration.zero) return 'Expired';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

// ─── Widget: Not Found ──────────────────────────────────────────────────────
class _NotFoundView extends StatelessWidget {
  const _NotFoundView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24.r),
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
              child: Icon(Icons.error_outline_rounded,
                  color: AppColors.textMuted, size: 40.r),
            ),
            SizedBox(height: 20.h),
            Text('Challenge Not Found', style: AppTypography.heading3),
            SizedBox(height: 8.h),
            Text(
              'This challenge may have expired or been deleted.',
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium,
            ),
            SizedBox(height: 24.h),
            AppButton(
              variant: AppButtonVariant.gradient,
              label: 'Back to Challenges',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}
