import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import 'challenge_model.dart';

/// Shown to BOTH players after the challenge is resolved.
/// Streams the doc so if the Cloud Function hasn't resolved yet,
/// the page auto-updates when it does (no manual refresh needed).
class ChallengeResultPage extends StatelessWidget {
  final String challengeId;
  const ChallengeResultPage({super.key, required this.challengeId});

  @override
  Widget build(BuildContext context) {
    final currentUid =
        FirebaseAuth.instance.currentUser?.uid ?? '';

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: StreamBuilder<ChallengeModel?>(
              stream: FirestoreService.instance
                  .challengeStream(challengeId),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(
                        color: AppColors.primary),
                  );
                }
                final c = snap.data;
                if (c == null) {
                  return _NotFound(
                    onHome: () => Navigator.of(context)
                        .popUntil((r) => r.isFirst),
                  );
                }

                return _ResultBody(
                  challenge:  c,
                  currentUid: currentUid,
                  onHome: () => Navigator.of(context)
                      .popUntil((r) => r.isFirst),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ── Body ──────────────────────────────────────────────────────────────────────
class _ResultBody extends StatelessWidget {
  final ChallengeModel challenge;
  final String         currentUid;
  final VoidCallback   onHome;

  const _ResultBody({
    required this.challenge,
    required this.currentUid,
    required this.onHome,
  });

  @override
  Widget build(BuildContext context) {
    final isResolved = challenge.isCompleted && challenge.outcome != null;
    final iWon       = challenge.didCurrentUserWin(currentUid);
    final isDraw     = challenge.isDraw;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
      child: Column(
        children: [
          // ── Result banner ────────────────────────────────────────────
          if (!isResolved) ...[
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 16),
            const Text(
              'Calculating result…',
              style: TextStyle(color: AppColors.textMuted, fontSize: 15),
            ),
          ] else ...[
            _ResultBanner(
              iWon:         iWon,
              isDraw:       isDraw,
              betAmount:    challenge.betAmount,
            ),
          ],

          const SizedBox(height: 32),

          // ── Scores side by side ──────────────────────────────────────
          GlassCard(
            child: Row(
              children: [
                Expanded(
                  child: _PlayerScore(
                    name:       challenge.creatorUsername,
                    score:      challenge.creatorScore,
                    isWinner:   isResolved &&
                        challenge.outcome == 'creator_wins',
                    isCurrentUser:
                        currentUid == challenge.creatorUid,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color:        AppColors.primary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'VS',
                    style: TextStyle(
                      color:      AppColors.primary,
                      fontWeight: FontWeight.w900,
                      fontSize:   14,
                    ),
                  ),
                ),
                Expanded(
                  child: _PlayerScore(
                    name:       challenge.opponentUsername ??
                        'Opponent',
                    score:      challenge.opponentScore,
                    isWinner:   isResolved &&
                        challenge.outcome == 'opponent_wins',
                    isCurrentUser:
                        currentUid == challenge.opponentUid,
                    alignRight: true,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Bet outcome ──────────────────────────────────────────────
          if (isResolved)
            GlassCard(
              borderColor: (iWon
                      ? AppColors.correct
                      : isDraw
                          ? AppColors.secondary
                          : AppColors.wrong)
                  .withOpacity(0.4),
              child: Row(
                children: [
                  Icon(
                    iWon    ? Icons.trending_up_rounded :
                    isDraw  ? Icons.compare_arrows_rounded :
                              Icons.trending_down_rounded,
                    color: iWon    ? AppColors.correct :
                           isDraw  ? AppColors.secondary :
                                     AppColors.wrong,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          iWon   ? 'You won ${challenge.betAmount * 2} pts! 🎉' :
                          isDraw ? 'Draw — ${challenge.betAmount} pts refunded' :
                                   'You lost ${challenge.betAmount} pts',
                          style: TextStyle(
                            color: iWon    ? AppColors.correct :
                                   isDraw  ? AppColors.secondary :
                                             AppColors.wrong,
                            fontSize:   16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          iWon   ? 'Score transferred to your balance' :
                          isDraw ? 'Your bet was returned' :
                                   "Your opponent's bet was added to their balance",
                          style: const TextStyle(
                            color:    AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 32),

          GradientButton(
            label: 'Go Home',
            icon:  Icons.home_rounded,
            onTap: onHome,
          ),
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────
class _ResultBanner extends StatelessWidget {
  final bool iWon;
  final bool isDraw;
  final int  betAmount;
  const _ResultBanner({
    required this.iWon,
    required this.isDraw,
    required this.betAmount,
  });

  @override
  Widget build(BuildContext context) {
    final color = iWon   ? AppColors.correct :
                  isDraw ? AppColors.secondary :
                           AppColors.wrong;
    final emoji = iWon   ? '🏆' : isDraw ? '🤝' : '😔';
    final title = iWon   ? 'You Won!' :
                  isDraw ? 'It\'s a Draw!' :
                           'You Lost';

    return Column(
      children: [
        Container(
          width:  80,
          height: 80,
          decoration: BoxDecoration(
            color:  color.withOpacity(0.15),
            shape:  BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: Text(emoji, style: const TextStyle(fontSize: 36)),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          style: TextStyle(
            color:      color,
            fontSize:   32,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _PlayerScore extends StatelessWidget {
  final String name;
  final int?   score;
  final bool   isWinner;
  final bool   isCurrentUser;
  final bool   alignRight;

  const _PlayerScore({
    required this.name,
    required this.score,
    required this.isWinner,
    required this.isCurrentUser,
    this.alignRight = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: alignRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: alignRight
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              if (isWinner)
                const Text('👑 ', style: TextStyle(fontSize: 14)),
              Flexible(
                child: Text(
                  isCurrentUser ? 'You' : name,
                  style: TextStyle(
                    color: isCurrentUser
                        ? AppColors.primary
                        : AppColors.textMuted,
                    fontSize:   12,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: Text(
              score != null ? '$score / 10' : '…',
              key: ValueKey(score),
              style: TextStyle(
                color:      isWinner
                    ? AppColors.correct
                    : AppColors.textPrimary,
                fontSize:   26,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      );
}

class _NotFound extends StatelessWidget {
  final VoidCallback onHome;
  const _NotFound({required this.onHome});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_rounded,
                  color: AppColors.wrong, size: 56),
              const SizedBox(height: 16),
              const Text('Challenge not found.',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 15)),
              const SizedBox(height: 24),
              GradientButton(
                  label: 'Go Home',
                  icon:  Icons.home_rounded,
                  onTap: onHome),
            ],
          ),
        ),
      );
}