// lib/features/multiplayer/my_challenges_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';

import '../../core/constants/rival_economy.dart';
import '../../core/constants/share_links.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/weekly_points_pill.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/device_id_service.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/share_service.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_empty_state.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/rival_avatar.dart';
import '../../core/widgets/share_card.dart';
import '../friends/friend_nudge_button.dart';
import '../quiz/questions_page.dart';
import 'challenge_model.dart';
import 'challenge_lobby_page.dart';

class MyChallengesPage extends StatefulWidget {
  const MyChallengesPage({super.key});

  @override
  State<MyChallengesPage> createState() => _MyChallengesPageState();
}

class _MyChallengesPageState extends State<MyChallengesPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        elevation: 0,
        leading: const AppBackButton(),
        title: const Text('My Challenges'),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 12.r),
            child: const WeeklyPointsPill(),
          ),
        ],
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: AppColors.readable(AppColors.primary),
          indicatorWeight: 3,
          dividerColor: AppColors.divider,
          labelColor: AppColors.textPrimary,
          unselectedLabelColor: AppColors.textMuted,
          labelStyle: AppTypography.labelLarge,
          unselectedLabelStyle: AppTypography.labelLarge.copyWith(
              color: AppColors.textMuted, fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: 'Active'),
            Tab(text: 'Pending'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [
          _ActiveTab(),
          _PendingTab(),
        ],
      ),
    );
  }
}

// ─── Active Tab ──────────────────────────────────────────────────────────────
class _ActiveTab extends StatelessWidget {
  const _ActiveTab();

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return StreamBuilder<List<ChallengeModel>>(
      stream: FirestoreService.instance.getMyChallengesStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }
        final all = snap.data ?? [];
        final active = all
            .where((c) =>
                c.status == ChallengeStatus.waiting ||
                c.status == ChallengeStatus.opponentJoined ||
                c.status == ChallengeStatus.creatorSubmitted ||
                c.status == ChallengeStatus.opponentSubmitted)
            .toList();
        if (active.isEmpty) {
          return const AppEmptyState(
            icon: Icons.bolt_rounded,
            title: 'No active challenges',
            message: 'Create a new challenge or join one from the Battle tab.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.lg),
          itemCount: active.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
          itemBuilder: (_, i) => _ChallengeCard(
            challenge: active[i],
            currentUid: uid ?? '',
          ),
        );
      },
    );
  }
}

// ─── Pending Tab ──────────────────────────────────────────────────────────────
class _PendingTab extends StatelessWidget {
  const _PendingTab();

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return StreamBuilder<List<ChallengeModel>>(
      stream: FirestoreService.instance.getMyChallengesStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }
        final all = snap.data ?? [];
        final pending = all
            .where((c) =>
                (c.status == ChallengeStatus.waiting ||
                    c.status == ChallengeStatus.creatorSubmitted) &&
                c.opponentUid == uid &&
                c.opponentScore == null)
            .toList();
        if (pending.isEmpty) {
          return const AppEmptyState(
            icon: Icons.mail_outline_rounded,
            title: 'No pending challenges',
          );
        }
        return ListView.separated(
          padding: EdgeInsets.fromLTRB(20.r, 16.r, 20.r, 28.r),
          itemCount: pending.length,
          separatorBuilder: (_, __) => SizedBox(height: 16.h),
          itemBuilder: (_, i) => _InviteTicket(
            challenge: pending[i],
            currentUid: uid ?? '',
          ),
        );
      },
    );
  }
}

// ─── Invite Card ────────────────────────────────────────────────────────────
// One pending invitation, kept compact to match the Active tab: sender and
// anime on top, stake / time chips in the middle, accept / decline at the
// bottom. Tapping the card opens the lobby.
class _InviteTicket extends StatefulWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const _InviteTicket({
    required this.challenge,
    required this.currentUid,
  });

  @override
  State<_InviteTicket> createState() => _InviteTicketState();
}

class _InviteTicketState extends State<_InviteTicket> {
  bool _accepting = false;

  ChallengeModel get c => widget.challenge;

  String _friendlyJoinError(String raw, {bool premiumActive = false}) {
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
      'not_friends' => 'Add them as a friend to spar.',
      _ => s,
    };
  }

  void _open() {
    Navigator.push(
      context,
      AppPageRoute(
        builder: (_) => ChallengeLobbyPage(challengeId: c.challengeId),
      ),
    );
  }

  Future<void> _accept() async {
    if (_accepting) return;
    setState(() => _accepting = true);
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

      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      _launchQuizFor(context, c, widget.currentUid);
    } catch (e) {
      if (!mounted) return;
      setState(() => _accepting = false);
      final raw = e is FirebaseFunctionsException
          ? (e.message ?? e.code)
          : e.toString();
      final premiumActive = context.read<UserDataProvider>().premiumActive;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Failed to join: ${_friendlyJoinError(raw, premiumActive: premiumActive)}'),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = c.kind.accentColor;
    final wp = c.wpStake ?? 0;
    final isFree = c.stakeAmount <= 0 && wp <= 0;

    final ud = context.watch<UserDataProvider>();
    final short = c.stakeAmount > ud.animeCoins || wp > ud.weeklyPoints;

    final remaining = c.timeRemaining;
    final urgent = remaining.inHours < 6;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: _open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RivalAvatar(
                name: c.creatorUsername,
                size: 40.r,
                color: accent,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.animeTitle.isEmpty ? 'Anime duel' : c.animeTitle,
                      style: AppTypography.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'from ${c.creatorUsername}',
                      style: AppTypography.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _KindChip(kind: c.kind),
              const SizedBox(width: AppSpacing.sm),
              if (isFree)
                const _ChipLabel(icon: '🎁', label: 'Free')
              else ...[
                if (c.stakeAmount > 0)
                  _ChipLabel(
                    icon: '🪙',
                    label: '${c.stakeAmount} AC',
                    color: short ? AppColors.wrong : null,
                  ),
                if (wp > 0) ...[
                  const SizedBox(width: AppSpacing.sm),
                  _ChipLabel(
                    icon: '⭐',
                    label: '$wp WP',
                    color: short ? AppColors.wrong : null,
                  ),
                ],
              ],
              const Spacer(),
              _ChipLabel(
                icon: '⏳',
                label: _formatTimeLeft(remaining),
                color: urgent ? AppColors.wrong : null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: _PendingDeclineButton(challengeId: c.challengeId),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                flex: 2,
                child: AppButton(
                  label: _accepting ? 'Accepting…' : 'Accept',
                  size: AppButtonSize.small,
                  loading: _accepting,
                  onPressed: _accepting ? null : _accept,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Pending Decline Button ─────────────────────────────────────────────────
// Only rendered on the Pending tab, where every card satisfies
// declineChallenge's gate (status waiting + opponentUid == me). Reuses the
// same callable + confirm copy as ChallengeLobbyPage._onDecline so the refund
// wording can never drift between the two surfaces.
class _PendingDeclineButton extends StatefulWidget {
  final String challengeId;
  const _PendingDeclineButton({required this.challengeId});

  @override
  State<_PendingDeclineButton> createState() => _PendingDeclineButtonState();
}

class _PendingDeclineButtonState extends State<_PendingDeclineButton> {
  bool _busy = false;

  String _friendlyDeclineError(String raw) {
    final s = raw.replaceFirst('Exception: ', '');
    return switch (s) {
      'challenge_not_pending' => 'This challenge is no longer pending.',
      'not_the_invited_opponent' => 'You can\'t decline this challenge.',
      _ => s,
    };
  }

  Future<void> _onDecline() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Decline challenge?', style: AppTypography.titleLarge),
        content: Text(
          'Their stake will be refunded to them. This can\'t be undone.',
          style: AppTypography.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: AppTypography.labelLarge
                    .copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Decline',
                style: AppTypography.labelLarge
                    .copyWith(color: AppColors.readable(AppColors.wrong))),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('declineChallenge')
          .call({
        'challengeId': widget.challengeId,
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
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

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: 'Decline',
      size: AppButtonSize.small,
      variant: AppButtonVariant.outline,
      color: AppColors.readable(AppColors.wrong),
      loading: _busy,
      onPressed: _busy ? null : _onDecline,
    );
  }
}

// ─── Active Challenge Card ──────────────────────────────────────────────────
class _ChallengeCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const _ChallengeCard({
    required this.challenge,
    required this.currentUid,
  });

  String get _statusText {
    switch (challenge.status) {
      case ChallengeStatus.waiting:
        return 'Waiting';
      case ChallengeStatus.opponentJoined:
        return 'Opponent joined';
      case ChallengeStatus.creatorSubmitted:
        return 'Creator played';
      case ChallengeStatus.opponentSubmitted:
        return 'Opponent played';
      case ChallengeStatus.completed:
        return challenge.outcome ?? 'Completed';
      case ChallengeStatus.expired:
        return 'Expired';
      case ChallengeStatus.expiredRefunded:
        return 'Refunded';
      default:
        return 'Unknown';
    }
  }

  String get _opponentName {
    if (currentUid == challenge.creatorUid) {
      return challenge.opponentUsername ?? 'Opponent';
    }
    return challenge.creatorUsername;
  }

  bool get _isYourTurn {
    if (currentUid.isEmpty) return false;
    if (challenge.status == ChallengeStatus.opponentJoined) {
      return currentUid == challenge.creatorUid &&
          challenge.creatorScore == null;
    }
    if (challenge.status == ChallengeStatus.creatorSubmitted) {
      return currentUid == challenge.opponentUid &&
          challenge.opponentScore == null;
    }
    if (challenge.status == ChallengeStatus.opponentSubmitted) {
      return currentUid == challenge.creatorUid &&
          challenge.creatorScore == null;
    }
    return false;
  }

  bool get _isWaitingForOpponent {
    if (currentUid.isEmpty) return false;
    if (currentUid == challenge.creatorUid) {
      return challenge.creatorScore != null &&
          challenge.opponentScore == null &&
          challenge.status != ChallengeStatus.completed;
    }
    if (currentUid == challenge.opponentUid) {
      return challenge.opponentScore != null &&
          challenge.creatorScore == null &&
          challenge.status != ChallengeStatus.completed;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final showPlay = _isYourTurn;
    final showWaiting = _isWaitingForOpponent;
    final showCopyCode = challenge.kind == ChallengeKind.code &&
        challenge.status == ChallengeStatus.waiting &&
        currentUid == challenge.creatorUid;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      accentColor: showPlay ? AppColors.primary : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40.r,
                height: 40.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.textMuted.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  challenge.animeTitle.isNotEmpty
                      ? challenge.animeTitle[0].toUpperCase()
                      : '?',
                  style: AppTypography.titleLarge
                      .copyWith(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      challenge.animeTitle,
                      style: AppTypography.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'vs $_opponentName',
                      style: AppTypography.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: AppColors.textMuted.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border: Border.all(
                    color: AppColors.textMuted.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  _statusText,
                  style: AppTypography.labelMedium
                      .copyWith(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _KindChip(kind: challenge.kind),
              const SizedBox(width: AppSpacing.sm),
              if (challenge.stakeAmount > 0)
                _ChipLabel(
                  icon: '🪙',
                  label: '${challenge.stakeAmount} AC',
                ),
              if (challenge.wpStake != null && challenge.wpStake! > 0) ...[
                const SizedBox(width: AppSpacing.sm),
                _ChipLabel(
                  icon: '⭐',
                  label: '${challenge.wpStake} WP',
                ),
              ],
              const Spacer(),
              _ChipLabel(
                icon: '⏳',
                label: _formatTimeLeft(challenge.timeRemaining),
              ),
            ],
          ),
          if (showCopyCode) ...[
            const SizedBox(height: AppSpacing.md),
            _CodeCopyRow(code: challenge.challengeId),
          ],
          if (showPlay || showWaiting) ...[
            const SizedBox(height: AppSpacing.md),
            if (showPlay)
              AppButton(
                label: 'Play Now',
                size: AppButtonSize.small,
                onPressed: () => _launchQuizFor(context, challenge, currentUid),
              ),
            if (showWaiting)
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                      ),
                      child: Text(
                        '⏳ Waiting for $_opponentName…',
                        style: AppTypography.bodySmall
                            .copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FriendNudgeButton(
                    friendUid: currentUid == challenge.creatorUid
                        ? (challenge.opponentUid ?? '')
                        : challenge.creatorUid,
                    challengeId: challenge.challengeId,
                    variant: AppButtonVariant.outline,
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  final ChallengeKind kind;
  const _KindChip({required this.kind});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: kind.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: kind.accentColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kind.icon, size: 12.r, color: kind.accentColor),
          const SizedBox(width: AppSpacing.xs),
          Text(
            kind.shortLabel.toUpperCase(),
            style: AppTypography.labelSmall.copyWith(
              color: kind.accentColor,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeCopyRow extends StatelessWidget {
  final String code;
  const _CodeCopyRow({required this.code});

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
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: AppColors.secondarySoft,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: AppColors.secondaryBorder),
          ),
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 16.r, color: AppColors.secondary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Code',
                style: AppTypography.labelMedium
                    .copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  code,
                  style: AppTypography.titleMedium.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Tap to copy',
                style: AppTypography.labelMedium
                    .copyWith(color: AppColors.secondary),
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
                  color: AppColors.secondary,
                  size: 16.r,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChipLabel extends StatelessWidget {
  final String icon;
  final String label;
  final Color? color;
  const _ChipLabel({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: AppTypography.labelMedium),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: AppTypography.labelMedium
                .copyWith(color: color ?? AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────
void _launchQuizFor(
  BuildContext context,
  ChallengeModel challenge,
  String currentUid,
) {
  final isCreator = currentUid == challenge.creatorUid;
  final isQuickMatch = challenge.isQuickMatch;
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

String _formatTimeLeft(Duration d) {
  if (d == Duration.zero) return 'Expired';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}
