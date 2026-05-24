import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import 'models/challenge_model.dart';
import 'challenge_lobby_page.dart';
import 'challenge_result_page.dart';

class MyChallengesPage extends StatelessWidget {
  const MyChallengesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header ──────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 16, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new,
                            color: AppColors.textPrimary),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Text(
                        'My Challenges',
                        style: TextStyle(
                          color:      AppColors.textPrimary,
                          fontSize:   22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Tabs ─────────────────────────────────────────────────
                const TabBar(
                  labelColor:         AppColors.primary,
                  unselectedLabelColor: AppColors.textMuted,
                  indicatorColor:     AppColors.primary,
                  labelStyle: TextStyle(fontWeight: FontWeight.w700),
                  tabs: [
                    Tab(text: 'Active'),
                    Tab(text: 'Completed'),
                  ],
                ),

                Expanded(
                  child: TabBarView(
                    children: [
                      _ChallengeList(activeOnly: true),
                      _ChallengeList(activeOnly: false),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Challenge List ───────────────────────────────────────────────────────────
class _ChallengeList extends StatelessWidget {
  final bool activeOnly;
  const _ChallengeList({required this.activeOnly});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ChallengeModel>>(
      stream: FirestoreService.instance
          .myChallengesStream(activeOnly: activeOnly),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: AppColors.primary));
        }
        final challenges = snap.data ?? [];
        // Filter: active tab shows waiting+in_progress; completed tab shows completed.
        final filtered = activeOnly
            ? challenges
                .where((c) => c.isWaiting || c.isInProgress)
                .toList()
            : challenges.where((c) => c.isComplete).toList();

        if (filtered.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  activeOnly
                      ? Icons.sports_kabaddi_rounded
                      : Icons.history_rounded,
                  color:  AppColors.textMuted,
                  size:   52,
                ),
                const SizedBox(height: 12),
                Text(
                  activeOnly
                      ? 'No active challenges.\nCreate one to get started!'
                      : 'No completed challenges yet.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 15, height: 1.5),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding:     const EdgeInsets.fromLTRB(20, 16, 20, 32),
          itemCount:   filtered.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) => _ChallengeCard(
            challenge: filtered[i],
            onTap: () => _navigate(context, filtered[i]),
          ),
        );
      },
    );
  }

  void _navigate(BuildContext context, ChallengeModel c) {
    final uid       = FirebaseAuth.instance.currentUser?.uid;
    final isCreator = c.creatorUid == uid;
    final myScore   = isCreator
        ? (c.creatorScore ?? 0)
        : (c.opponentScore ?? 0);

    // Creator who hasn't played yet → lobby (loads questions + starts quiz).
    if (isCreator && !c.creatorHasPlayed && !c.isComplete) {
      Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ChallengeLobbyPage(challenge: c)),
      );
      return;
    }

    // Everyone else → result page (handles both waiting + completed states).
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChallengeResultPage(
          challengeId: c.challengeId,
          challenge:   c,
          isCreator:   isCreator,
          myScore:     myScore,
        ),
      ),
    );
  }
}

// ─── Challenge Card ───────────────────────────────────────────────────────────
class _ChallengeCard extends StatelessWidget {
  final ChallengeModel challenge;
  final VoidCallback   onTap;
  const _ChallengeCard({required this.challenge, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final uid       = FirebaseAuth.instance.currentUser?.uid;
    final isCreator = challenge.creatorUid == uid;
    final opponent  = isCreator
        ? (challenge.opponentUsername ?? 'Waiting for opponent…')
        : challenge.creatorUsername;
    final myScore   = isCreator
        ? challenge.creatorScore
        : challenge.opponentScore;
    final theirScore = isCreator
        ? challenge.opponentScore
        : challenge.creatorScore;

    final statusColor  = _statusColor(challenge);
    final statusLabel  = _statusLabel(challenge, isCreator);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: statusColor.withOpacity(0.3), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Top row: opponent + status badge ──────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius:          18,
                      backgroundColor: AppColors.primary.withOpacity(0.12),
                      child: Text(
                        opponent[0].toUpperCase(),
                        style: const TextStyle(
                          color:      AppColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'vs $opponent',
                          style: const TextStyle(
                            color:      AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize:   15,
                          ),
                        ),
                        Text(
                          challenge.animeTitle,
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                _StatusBadge(label: statusLabel, color: statusColor),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(color: AppColors.divider, height: 1),
            const SizedBox(height: 12),

            // ── Bottom row: scores + bet ───────────────────────────────
            Row(
              children: [
                // My score
                Expanded(
                  child: _ScoreTile(
                    label: 'You',
                    score: myScore,
                    total: challenge.questionIds.length,
                  ),
                ),
                Container(width: 1, height: 36, color: AppColors.divider),
                // Their score
                Expanded(
                  child: _ScoreTile(
                    label:   opponent.split(' ').first,
                    score:   theirScore,
                    total:   challenge.questionIds.length,
                    alignEnd: true,
                  ),
                ),
                Container(width: 1, height: 36, color: AppColors.divider),
                // Bet
                Expanded(
                  child: Column(
                    children: [
                      const Text('Bet',
                          style: TextStyle(
                              color: AppColors.textMuted, fontSize: 11)),
                      Text(
                        '${challenge.betAmount}',
                        style: const TextStyle(
                          color:      AppColors.secondary,
                          fontWeight: FontWeight.w800,
                          fontSize:   16,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // ── Outcome ribbon (completed only) ───────────────────────
            if (challenge.isComplete) ...[
              const SizedBox(height: 10),
              _OutcomeRibbon(challenge: challenge, isCreator: isCreator),
            ],

            // ── Expiry (active only) ──────────────────────────────────
            if (!challenge.isComplete) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.timer_outlined,
                      color: AppColors.textMuted, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    challenge.expiryLabel,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _statusColor(ChallengeModel c) {
    if (c.isComplete)   return AppColors.correct;
    if (c.isInProgress) return AppColors.secondary;
    return AppColors.primary;
  }

  String _statusLabel(ChallengeModel c, bool isCreator) {
    if (c.isComplete) return 'Finished';
    if (c.isInProgress) {
      final uid    = FirebaseAuth.instance.currentUser?.uid;
      final iAmCreator = c.creatorUid == uid;
      if (iAmCreator && !c.creatorHasPlayed)  return 'Your turn';
      if (!iAmCreator && !c.opponentHasPlayed) return 'Your turn';
      return 'Opponent playing';
    }
    return 'Waiting';
  }
}

// ─── Small Widgets ────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color  color;
  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color:        color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color:      color,
                fontSize:   11,
                fontWeight: FontWeight.w700)),
      );
}

class _ScoreTile extends StatelessWidget {
  final String label;
  final int?   score;
  final int    total;
  final bool   alignEnd;
  const _ScoreTile({
    required this.label,
    required this.score,
    required this.total,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 11),
              overflow: TextOverflow.ellipsis),
          Text(
            score != null ? '$score/$total' : '—',
            style: TextStyle(
              color:      score != null
                  ? AppColors.textPrimary
                  : AppColors.textMuted,
              fontWeight: FontWeight.w800,
              fontSize:   15,
            ),
            textAlign: alignEnd ? TextAlign.right : TextAlign.center,
          ),
        ],
      );
}

class _OutcomeRibbon extends StatelessWidget {
  final ChallengeModel challenge;
  final bool           isCreator;
  const _OutcomeRibbon(
      {required this.challenge, required this.isCreator});

  @override
  Widget build(BuildContext context) {
    final iWon = challenge.outcome ==
        (isCreator
            ? ChallengeOutcome.creatorWins
            : ChallengeOutcome.opponentWins);
    final isDraw = challenge.outcome == ChallengeOutcome.draw;

    final color = iWon ? AppColors.correct
                : isDraw ? AppColors.secondary
                : AppColors.wrong;
    final label = iWon ? '🏆 You won +${challenge.betAmount} pts'
                : isDraw ? '🤝 Draw — bet refunded'
                : '💀 You lost −${challenge.betAmount} pts';

    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: TextStyle(
              color:      color,
              fontSize:   12,
              fontWeight: FontWeight.w700)),
    );
  }
}