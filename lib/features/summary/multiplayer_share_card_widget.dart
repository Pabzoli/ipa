import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

class MultiplayerShareCardWidget extends StatelessWidget {
  final String playerDisplayName; // from FirebaseAuth.currentUser
  final String opponentName;      // widget.playerName
  final int    playerScore;
  final int    opponentScore;
  final int    totalQuestions;    // widget.questions.length
  final int    betScore;
  final String outcomeLabel;      // 'VICTORY!' | 'DRAW!' | 'DEFEAT'
  final Color  outcomeColor;      // drives every tint on the card
  final String rewardText;        // '+200 pts won' | '100 pts returned' | '−100 pts lost'
  final Color  rewardColor;       // same as outcomeColor in practice
  final int    weeklyPoints;
  final int    totalScore;

  // Fixed card dimensions. Captured at pixelRatio 3.0 → 1080×1920.
  static const double kWidth  = 360;
  static const double kHeight = 640;

  const MultiplayerShareCardWidget({
    super.key,
    required this.playerDisplayName,
    required this.opponentName,
    required this.playerScore,
    required this.opponentScore,
    required this.totalQuestions,
    required this.betScore,
    required this.outcomeLabel,
    required this.outcomeColor,
    required this.rewardText,
    required this.rewardColor,
    required this.weeklyPoints,
    required this.totalScore,
  });

  double get _playerRatio =>
      totalQuestions > 0 ? (playerScore / totalQuestions).clamp(0.02, 1.0) : 0.02;

  double get _opponentRatio =>
      totalQuestions > 0 ? (opponentScore / totalQuestions).clamp(0.02, 1.0) : 0.02;

  // Background centre tinted 10% by the outcome colour so each result
  // feels distinct without being garish.
  Color get _bgCentre =>
      Color.lerp(const Color(0xFF0C0C18), outcomeColor, 0.10)!;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kWidth,
      height: kHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Outcome-tinted radial background ─────────────────────────────
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.6),
                radius: 1.35,
                colors: [_bgCentre, const Color(0xFF060609)],
              ),
            ),
          ),

          // ── Ambient glow orbs ─────────────────────────────────────────────
          Positioned(
            top: -55, right: -55,
            child: _GlowOrb(color: outcomeColor, size: 200),
          ),
          Positioned(
            bottom: -60, left: -60,
            child: const _GlowOrb(color: AppColors.primary, size: 185),
          ),

          // ── Content ───────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 22),
                _buildTopBar(),
                const SizedBox(height: 14),
                const _HRule(),
                const SizedBox(height: 22),
                _buildOutcomeBanner(),
                const SizedBox(height: 22),
                _buildVsSection(),
                const SizedBox(height: 18),
                _buildRewardChip(),
                const SizedBox(height: 18),
                _buildDecorativeDivider(),
                const SizedBox(height: 16),
                _buildStats(),
                const SizedBox(height: 16),
                _buildCTA(),
                const SizedBox(height: 22),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Section builders ─────────────────────────────────────────────────────

  Widget _buildTopBar() => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Branding
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.primary, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text(
                'AnimeQuiz',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          // Context chip — "Ranked Match" differentiates from solo
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: outcomeColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: outcomeColor.withOpacity(0.35)),
            ),
            child: Text(
              'Ranked Match',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: outcomeColor,
              ),
            ),
          ),
        ],
      );

  Widget _buildOutcomeBanner() => Column(
        children: [
          // Large glowing outcome label — the card's centrepiece
          Text(
            outcomeLabel,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 36,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: 2.5,
              shadows: [
                Shadow(color: outcomeColor, blurRadius: 14),
                Shadow(color: outcomeColor, blurRadius: 30),
              ],
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 5),
          Text(
            'vs $opponentName',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF5A5A7A),
              letterSpacing: 0.5,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );

  Widget _buildVsSection() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A18),
        borderRadius: BorderRadius.circular(20),
        // Subtle outcome-tinted border makes the card feel cohesive
        border: Border.all(
          color: outcomeColor.withOpacity(0.15),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          // ── Score numbers row ──────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Player side
              Expanded(
                child: _ScoreColumn(
                  label:      'You',
                  score:      playerScore,
                  totalQ:     totalQuestions,
                  scoreColor: outcomeColor,
                  labelColor: outcomeColor.withOpacity(0.65),
                ),
              ),
              // VS vertical divider
              SizedBox(
                height: 88, // matches approximate column content height
                child: Column(
                  children: [
                    Expanded(
                      child: Container(
                        width: 1, color: const Color(0xFF1E1E2E)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: const Text(
                        'VS',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF303050),
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        width: 1, color: const Color(0xFF1E1E2E)),
                    ),
                  ],
                ),
              ),
              // Opponent side — always muted regardless of outcome
              Expanded(
                child: _ScoreColumn(
                  label:      opponentName,
                  score:      opponentScore,
                  totalQ:     totalQuestions,
                  scoreColor: const Color(0xFF4A4A6A),
                  labelColor: const Color(0xFF3A3A5A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // ── Progress bars row ──────────────────────────────────────────
          // Player bar in outcome colour; opponent always dim.
          // Even in a draw the two bars are the same length, making the
          // tie obvious at a glance.
          Row(
            children: [
              Expanded(
                child: _ProgressBar(ratio: _playerRatio, color: outcomeColor),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: _ProgressBar(
                  ratio: _opponentRatio,
                  color: const Color(0xFF252540),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRewardChip() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
        decoration: BoxDecoration(
          color: rewardColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: rewardColor.withOpacity(0.25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              // Derive loss from score comparison — no extra bool parameter
              playerScore < opponentScore
                  ? Icons.trending_down_rounded
                  : Icons.trending_up_rounded,
              color: rewardColor, size: 20,
            ),
            const SizedBox(width: 10),
            Text(
              rewardText,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: rewardColor,
              ),
            ),
          ],
        ),
      );

  Widget _buildDecorativeDivider() => Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, Color(0xFF2E2E42)],
                ),
              ),
            ),
          ),
          Container(
            width: 5, height: 5,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              color: AppColors.primary, shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF2E2E42), Colors.transparent],
                ),
              ),
            ),
          ),
        ],
      );

  Widget _buildStats() => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _StatChip(
            icon:  Icons.person_rounded,
            label: '@$playerDisplayName',
            color: AppColors.secondary,
          ),
          _StatChip(
            icon:  Icons.local_fire_department_rounded,
            label: '$weeklyPoints pts\nthis week',
            color: AppColors.accent,
          ),
          _StatChip(
            icon:  Icons.stars_rounded,
            label: '$totalScore pts\ntotal',
            color: AppColors.correct,
          ),
        ],
      );

  Widget _buildCTA() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end:   Alignment.bottomRight,
            colors: [
              AppColors.primary.withOpacity(0.16),
              AppColors.primary.withOpacity(0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.primary.withOpacity(0.35),
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Can you beat me?',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 3),
            Text(
              'Download AnimeQuiz',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.primary.withOpacity(0.8),
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
}

// ── Private helper widgets ────────────────────────────────────────────────────
// Kept private to this file. The solo card has its own copies — that's
// intentional; extracting to a shared file would couple two unrelated screens.

class _ScoreColumn extends StatelessWidget {
  final String label;
  final int    score;
  final int    totalQ;
  final Color  scoreColor;
  final Color  labelColor;

  const _ScoreColumn({
    required this.label,
    required this.score,
    required this.totalQ,
    required this.scoreColor,
    required this.labelColor,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: labelColor,
              letterSpacing: 0.5,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            '$score',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 58,
              fontWeight: FontWeight.w900,
              color: scoreColor,
              height: 1,
              shadows: [
                Shadow(
                  color: scoreColor.withOpacity(0.4),
                  blurRadius: 14,
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'of $totalQ',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 10,
              color: Color(0xFF3E3E5E),
            ),
          ),
        ],
      );
}

class _ProgressBar extends StatelessWidget {
  final double ratio;
  final Color  color;
  const _ProgressBar({required this.ratio, required this.color});

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          Container(
            height: 6,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          // FractionallySizedBox renders correctly in captureFromWidget
          // as long as a targetSize is provided on the outer call.
          FractionallySizedBox(
            widthFactor: ratio,
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [color.withOpacity(0.55), color],
                ),
                borderRadius: BorderRadius.circular(3),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.4),
                    blurRadius: 8,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}

class _GlowOrb extends StatelessWidget {
  final Color  color;
  final double size;
  const _GlowOrb({required this.color, required this.size});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withOpacity(0.18),
              color.withOpacity(0.06),
              Colors.transparent,
            ],
          ),
        ),
      );
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 5),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      );
}

class _HRule extends StatelessWidget {
  const _HRule();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: const Color(0xFF1A1A2E));
}