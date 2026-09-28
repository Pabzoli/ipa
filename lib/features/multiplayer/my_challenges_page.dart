// lib/features/multiplayer/my_challenges_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/firestore_service.dart';
import '../quiz/quiz_controller.dart' show QuizMode;
import '../quiz/questions_page.dart';
import 'challenge_model.dart';
import 'challenge_lobby_page.dart';
import 'challenge_result_page.dart';

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
    _tabCtrl = TabController(length: 3, vsync: this);
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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'My Challenges',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: AppColors.primary,
          labelColor: AppColors.textPrimary,
          unselectedLabelColor: AppColors.textMuted,
          labelStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700),
          unselectedLabelStyle:
              TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: 'Active'),
            Tab(text: 'Pending'),
            Tab(text: 'Completed'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [
          _ActiveTab(),
          _PendingTab(),
          _CompletedTab(),
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
          return const _EmptyState(
            icon: '⚔️',
            title: 'No active challenges',
            subtitle: 'Create a new challenge or join one from the Battle tab.',
          );
        }
        return ListView.builder(
          padding: EdgeInsets.all(16.r),
          itemCount: active.length,
          itemBuilder: (_, i) => _ChallengeCard(
            challenge: active[i],
            currentUid: uid ?? '',
            type: _CardType.active,
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
                c.status == ChallengeStatus.waiting && c.opponentUid == uid)
            .toList();
        if (pending.isEmpty) {
          return const _EmptyState(
            icon: '📬',
            title: 'No pending challenges',
            subtitle: 'You have no invitations to accept right now.',
          );
        }
        return ListView.builder(
          padding: EdgeInsets.all(16.r),
          itemCount: pending.length,
          itemBuilder: (_, i) => _ChallengeCard(
            challenge: pending[i],
            currentUid: uid ?? '',
            type: _CardType.pending,
          ),
        );
      },
    );
  }
}

// ─── Completed Tab ────────────────────────────────────────────────────────────
class _CompletedTab extends StatelessWidget {
  const _CompletedTab();

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
        final completed = all
            .where((c) =>
                c.status == ChallengeStatus.completed ||
                c.status == ChallengeStatus.expired ||
                c.status == ChallengeStatus.expiredRefunded)
            .toList();
        if (completed.isEmpty) {
          return const _EmptyState(
            icon: '📜',
            title: 'No completed challenges',
            subtitle: 'Your match history will appear here.',
          );
        }
        return ListView.builder(
          padding: EdgeInsets.all(16.r),
          itemCount: completed.length,
          itemBuilder: (_, i) => _ChallengeCard(
            challenge: completed[i],
            currentUid: uid ?? '',
            type: _CardType.completed,
          ),
        );
      },
    );
  }
}

// ─── Challenge Card ──────────────────────────────────────────────────────────
enum _CardType { active, pending, completed }

class _ChallengeCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final _CardType type;

  const _ChallengeCard({
    required this.challenge,
    required this.currentUid,
    required this.type,
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

  Color get _statusColor {
    if (type == _CardType.completed) {
      if (challenge.outcome == 'draw') return AppColors.secondary;
      final winner = challenge.winnerUid(currentUid: currentUid);
      return winner == currentUid ? AppColors.correct : AppColors.wrong;
    }
    if (type == _CardType.pending) return AppColors.accent;
    return AppColors.textMuted;
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
    if (type == _CardType.completed) return false;
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

  void _navigateToChallenge(BuildContext context) {
    // A settled challenge has no lobby state left to show, so history cards go
    // straight to the result page rather than bouncing through a screen that
    // immediately redirects anyway.
    if (challenge.isSettled) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChallengeResultPage(
            challengeId: challenge.challengeId,
          ),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChallengeLobbyPage(
          challengeId: challenge.challengeId,
        ),
      ),
    );
  }

  Future<void> _acceptAndPlay(BuildContext context) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('joinChallenge')
          .call({'challengeId': challenge.challengeId});

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Challenge accepted! Get ready to play.'),
          backgroundColor: AppColors.correct,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );

      await Future.delayed(const Duration(milliseconds: 500));
      if (!context.mounted) return;

      // Navigate directly to QuestionsPage after accepting
      _launchQuiz(context);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Failed to join: ${e.toString().replaceFirst('Exception: ', '')}'),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _launchQuiz(BuildContext context) {
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

  @override
  Widget build(BuildContext context) {
    final isCompleted = type == _CardType.completed;
    final isPending = type == _CardType.pending;
    final showAccept = isPending;
    final showPlay = _isYourTurn;
    final showWaiting = _isWaitingForOpponent;

    return GestureDetector(
      onTap: () => _navigateToChallenge(context),
      child: Container(
        margin: EdgeInsets.only(bottom: 12.r),
        padding: EdgeInsets.all(14.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(
            color: (showAccept || showPlay)
                ? AppColors.primary.withOpacity(0.35)
                : AppColors.divider,
            width: (showAccept || showPlay) ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40.w,
                  height: 40.h,
                  decoration: BoxDecoration(
                    color: _statusColor.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      challenge.animeTitle.isNotEmpty
                          ? challenge.animeTitle[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: _statusColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 16.sp,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        challenge.animeTitle,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w800,
                          fontSize: 15.sp,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        'vs $_opponentName',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12.sp,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 3.r),
                  decoration: BoxDecoration(
                    color: _statusColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8.r),
                    border: Border.all(color: _statusColor.withOpacity(0.3)),
                  ),
                  child: Text(
                    _statusText,
                    style: TextStyle(
                      color: _statusColor,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10.h),
            Row(
              children: [
                if (challenge.stakeAmount > 0)
                  _ChipLabel(
                    icon: '🪙',
                    label: '${challenge.stakeAmount} AC',
                  ),
                if (challenge.wpStake != null && challenge.wpStake! > 0) ...[
                  SizedBox(width: 8.w),
                  _ChipLabel(
                    icon: '⭐',
                    label: '${challenge.wpStake} WP',
                  ),
                ],
                const Spacer(),
                if (!isCompleted) ...[
                  _ChipLabel(
                    icon: '⏳',
                    label: _formatTime(challenge.timeRemaining),
                  ),
                ],
              ],
            ),
            if (showAccept || showPlay || showWaiting || isCompleted) ...[
              SizedBox(height: 12.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (showAccept)
                    ElevatedButton(
                      onPressed: () => _acceptAndPlay(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                            horizontal: 18.r, vertical: 10.r),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10.r)),
                      ),
                      child: Text(
                        'Accept & Play',
                        style: TextStyle(
                            fontSize: 13.sp, fontWeight: FontWeight.w800),
                      ),
                    ),
                  if (showPlay)
                    ElevatedButton(
                      onPressed: () => _launchQuiz(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                            horizontal: 18.r, vertical: 10.r),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10.r)),
                      ),
                      child: Text(
                        'Play Now',
                        style: TextStyle(
                            fontSize: 13.sp, fontWeight: FontWeight.w800),
                      ),
                    ),
                  if (showWaiting)
                    Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
                      decoration: BoxDecoration(
                        color: AppColors.textMuted.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8.r),
                      ),
                      child: Text(
                        '⏳ Waiting for opponent…',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (isCompleted)
                    TextButton(
                      onPressed: () => _navigateToChallenge(context),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'View →',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 12.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(Duration d) {
    if (d == Duration.zero) return 'Expired';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}

class _ChipLabel extends StatelessWidget {
  final String icon;
  final String label;
  const _ChipLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: TextStyle(fontSize: 12.sp)),
          SizedBox(width: 4.w),
          Text(
            label,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty State ──────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final String icon;
  final String title;
  final String subtitle;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(icon, style: TextStyle(fontSize: 48.sp)),
            SizedBox(height: 16.h),
            Text(
              title,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 8.h),
            Text(
              subtitle,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 14.sp,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
