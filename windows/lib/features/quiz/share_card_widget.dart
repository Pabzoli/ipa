// lib/features/quiz/share_card_widget.dart
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

/// A 9:16 result card captured off-screen and shared as a PNG image.
///
/// All sizes, colours, and fonts are hardcoded — do NOT rely on an inherited
/// Theme here, because captureFromWidget() renders outside the normal tree
/// and inherited values are unreliable.
class ShareCardWidget extends StatelessWidget {
  final int          correctCount;
  final int          totalQuestions;
  final List<String> selectedTitles;
  final String       username;
  final String       tierEmoji;
  final String       tierTitle;
  final Color        tierColor;
  final int          weeklyPoints;
  final int          totalScore;

  // Fixed card dimensions. Captured at pixelRatio 3.0 → 1080×1920.
  static const double kWidth  = 360;
  static const double kHeight = 640;

  const ShareCardWidget({
    super.key,
    required this.correctCount,
    required this.totalQuestions,
    required this.selectedTitles,
    required this.username,
    required this.tierEmoji,
    required this.tierTitle,
    required this.tierColor,
    required this.weeklyPoints,
    required this.totalScore,
  });

  double get _accuracy => correctCount / totalQuestions;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kWidth,
      height: kHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Dark radial background ──────────────────────────────────────
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.4),
                radius: 1.3,
                colors: [Color(0xFF1C0A30), Color(0xFF0A0A14)],
              ),
            ),
          ),

          // ── Ambient glow orbs ───────────────────────────────────────────
          Positioned(
            top: -55, right: -55,
            child: _GlowOrb(color: tierColor, size: 190),
          ),
          Positioned(
            bottom: -65, left: -65,
            child: const _GlowOrb(color: AppColors.primary, size: 210),
          ),

          // ── Content ─────────────────────────────────────────────────────
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
                _buildHero(),
                const SizedBox(height: 18),
                _buildProgressBar(),
                const SizedBox(height: 18),
                _buildBadges(),
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

  // ── Sub-builders ──────────────────────────────────────────────────────────

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
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
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
          // Accuracy chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: tierColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: tierColor.withOpacity(0.35)),
            ),
            child: Text(
              '${(_accuracy * 100).round()}% accuracy',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: tierColor,
              ),
            ),
          ),
        ],
      );

  Widget _buildHero() => Column(
        children: [
          // Tier emoji
          Text(tierEmoji, style: const TextStyle(fontSize: 48)),
          const SizedBox(height: 10),

          // Tier title — glowed with TextStyle.shadows (no BlendMode needed)
          Text(
            tierTitle.toUpperCase(),
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 21,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: 3,
              shadows: [
                Shadow(color: tierColor, blurRadius: 10),
                Shadow(color: tierColor, blurRadius: 22),
              ],
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          // Score fraction
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$correctCount',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 72,
                  fontWeight: FontWeight.w900,
                  color: tierColor,
                  height: 1,
                  shadows: [
                    Shadow(color: tierColor.withOpacity(0.5), blurRadius: 18),
                    Shadow(color: tierColor.withOpacity(0.25), blurRadius: 36),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  ' / $totalQuestions',
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3E3E5E),
                    height: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'correct answers',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF505070),
              letterSpacing: 1.8,
            ),
          ),
        ],
      );

  Widget _buildProgressBar() => Stack(
        children: [
          // Track
          Container(
            height: 7,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          // Fill — FractionallySizedBox works in off-screen renders
          FractionallySizedBox(
            widthFactor: _accuracy.clamp(0.02, 1.0),
            child: Container(
              height: 7,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [tierColor.withOpacity(0.55), tierColor],
                ),
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: tierColor.withOpacity(0.45),
                    blurRadius: 9,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _buildBadges() => Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: selectedTitles.map((title) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF111120),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2A2A42)),
            ),
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF7070A0),
              ),
            ),
          );
        }).toList(),
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
              color: AppColors.primary,
              shape: BoxShape.circle,
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
            icon: Icons.person_rounded,
            label: '@$username',
            color: AppColors.secondary,
          ),
          _StatChip(
            icon: Icons.local_fire_department_rounded,
            label: '$weeklyPoints pts\nthis week',
            color: AppColors.accent,
          ),
          _StatChip(
            icon: Icons.stars_rounded,
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
            end: Alignment.bottomRight,
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

// ── Private helpers ──────────────────────────────────────────────────────────

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
  Widget build(BuildContext context) => Container(
        height: 1,
        color: const Color(0xFF1E1E30),
      );
}