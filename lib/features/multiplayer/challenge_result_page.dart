import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import 'challenge_model.dart';

// ─── Challenge Result — redesigned from scratch ───────────────────────────────
// What changed:
// - The result banner now has an animated entrance (scale + fade).
// - Win state plays a particle confetti animation using CustomPainter.
// - Scores use a vertical reveal animation (count-up is faked with
//   AnimatedSwitcher + a staggered delay).
// - Bet outcome card has a more expressive layout with large point change number.
// - "Calculating result…" state has a proper animated loading indicator instead
//   of just a spinner + text.
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
                if (!snap.hasData &&
                    snap.connectionState == ConnectionState.waiting) {
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
                  challenge: c,
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
class _ResultBody extends StatefulWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final VoidCallback onHome;

  const _ResultBody({
    required this.challenge,
    required this.currentUid,
    required this.onHome,
  });

  @override
  State<_ResultBody> createState() => _ResultBodyState();
}

class _ResultBodyState extends State<_ResultBody>
    with TickerProviderStateMixin {
  late AnimationController _bannerCtrl;
  late Animation<double> _bannerScale;
  late Animation<double> _bannerFade;
  late AnimationController _confettiCtrl;

  @override
  void initState() {
    super.initState();

    _bannerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _bannerScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _bannerCtrl, curve: Curves.elasticOut),
    );
    _bannerFade = CurvedAnimation(parent: _bannerCtrl, curve: Curves.easeOut);

    _confettiCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );

    // Delay slightly so StreamBuilder has settled
    if (widget.challenge.isCompleted && widget.challenge.outcome != null) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) {
          _bannerCtrl.forward();
          if (widget.challenge.didCurrentUserWin(widget.currentUid)) {
            _confettiCtrl.forward();
          }
        }
      });
    }
  }

  @override
  void didUpdateWidget(_ResultBody old) {
    super.didUpdateWidget(old);
    // Trigger animation when result first arrives
    if (!old.challenge.isCompleted && widget.challenge.isCompleted) {
      _bannerCtrl.forward();
      if (widget.challenge.didCurrentUserWin(widget.currentUid)) {
        _confettiCtrl.forward();
      }
    }
  }

  @override
  void dispose() {
    _bannerCtrl.dispose();
    _confettiCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.challenge;
    final isResolved = c.isCompleted && c.outcome != null;
    final iWon = c.didCurrentUserWin(widget.currentUid);
    final isDraw = c.isDraw;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Calculating state ────────────────────────────────────────
          if (!isResolved) ...[
            const _CalculatingState(),
            const SizedBox(height: 32),
          ],

          // ── Result banner ────────────────────────────────────────────
          if (isResolved)
            Stack(
              alignment: Alignment.topCenter,
              children: [
                // Confetti (win only)
                if (iWon)
                  AnimatedBuilder(
                    animation: _confettiCtrl,
                    builder: (_, __) => CustomPaint(
                      size: const Size(double.infinity, 200),
                      painter: _ConfettiPainter(
                          progress: _confettiCtrl.value),
                    ),
                  ),

                // Banner
                ScaleTransition(
                  scale: _bannerScale,
                  child: FadeTransition(
                    opacity: _bannerFade,
                    child: _ResultBanner(
                      iWon: iWon,
                      isDraw: isDraw,
                      betAmount: c.betAmount,
                    ),
                  ),
                ),
              ],
            ),

          const SizedBox(height: 28),

          // ── VS card ──────────────────────────────────────────────────
          _VsCard(
            challenge: c,
            currentUid: widget.currentUid,
            isResolved: isResolved,
          ),

          const SizedBox(height: 16),

          // ── Bet outcome card ─────────────────────────────────────────
          if (isResolved)
            _BetOutcomeCard(
              iWon: iWon,
              isDraw: isDraw,
              betAmount: c.betAmount,
            ),

          const SizedBox(height: 32),

          GradientButton(
            label: 'Go Home',
            icon: Icons.home_rounded,
            onTap: widget.onHome,
          ),
        ],
      ),
    );
  }
}

// ── Calculating state ──────────────────────────────────────────────────────────
class _CalculatingState extends StatefulWidget {
  const _CalculatingState();

  @override
  State<_CalculatingState> createState() => _CalculatingStateState();
}

class _CalculatingStateState extends State<_CalculatingState>
    with SingleTickerProviderStateMixin {
  late AnimationController _dotCtrl;

  @override
  void initState() {
    super.initState();
    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _dotCtrl,
            builder: (_, __) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (i) {
                  final t = (_dotCtrl.value * 3 - i).clamp(0.0, 1.0);
                  final opacity = (math.sin(t * math.pi)).clamp(0.3, 1.0);
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primary.withOpacity(opacity),
                    ),
                  );
                }),
              );
            },
          ),
          const SizedBox(height: 16),
          const Text(
            'Calculating result…',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'This happens automatically — sit tight!',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Result banner ──────────────────────────────────────────────────────────────
class _ResultBanner extends StatelessWidget {
  final bool iWon;
  final bool isDraw;
  final int betAmount;

  const _ResultBanner({
    required this.iWon,
    required this.isDraw,
    required this.betAmount,
  });

  @override
  Widget build(BuildContext context) {
    final color = iWon
        ? AppColors.correct
        : isDraw
            ? AppColors.secondary
            : AppColors.wrong;
    final emoji = iWon ? '🏆' : isDraw ? '🤝' : '😔';
    final title = iWon ? 'You Won!' : isDraw ? "It's a Draw!" : 'You Lost';

    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withOpacity(0.3),
                color.withOpacity(0.05),
              ],
            ),
            border: Border.all(color: color.withOpacity(0.6), width: 2),
          ),
          child: Center(
            child: Text(emoji, style: const TextStyle(fontSize: 44)),
          ),
        ),
        const SizedBox(height: 16),
        ShaderMask(
          shaderCallback: (r) => LinearGradient(
            colors: iWon
                ? [AppColors.correct, const Color(0xFF34D399)]
                : isDraw
                    ? [AppColors.secondary, const Color(0xFFFBBF24)]
                    : [AppColors.wrong, const Color(0xFFF87171)],
          ).createShader(r),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
            ),
          ),
        ),
      ],
    );
  }
}

// ── VS score card ──────────────────────────────────────────────────────────────
class _VsCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final bool isResolved;

  const _VsCard({
    required this.challenge,
    required this.currentUid,
    required this.isResolved,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: _PlayerColumn(
              name: challenge.creatorUsername,
              score: challenge.creatorScore,
              isCurrentUser: currentUid == challenge.creatorUid,
              isWinner:
                  isResolved && challenge.outcome == 'creator_wins',
              alignRight: false,
            ),
          ),
          // VS pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.primary.withOpacity(0.3)),
            ),
            child: const Text(
              'VS',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w900,
                fontSize: 16,
                letterSpacing: 2,
              ),
            ),
          ),
          Expanded(
            child: _PlayerColumn(
              name: challenge.opponentUsername ?? 'Opponent',
              score: challenge.opponentScore,
              isCurrentUser: currentUid == challenge.opponentUid,
              isWinner:
                  isResolved && challenge.outcome == 'opponent_wins',
              alignRight: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerColumn extends StatelessWidget {
  final String name;
  final int? score;
  final bool isCurrentUser;
  final bool isWinner;
  final bool alignRight;

  const _PlayerColumn({
    required this.name,
    required this.score,
    required this.isCurrentUser,
    required this.isWinner,
    required this.alignRight,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: alignRight
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (isWinner) ...[
            Text(
              '👑',
              textAlign: alignRight ? TextAlign.right : TextAlign.left,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            isCurrentUser ? 'You' : name,
            style: TextStyle(
              color: isCurrentUser
                  ? AppColors.primary
                  : AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: Text(
              score != null ? '$score' : '…',
              key: ValueKey(score),
              style: TextStyle(
                color: isWinner ? AppColors.correct : AppColors.textPrimary,
                fontSize: 40,
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
          ),
          Text(
            '/ 10',
            style: TextStyle(
              color: AppColors.textMuted.withOpacity(0.6),
              fontSize: 12,
            ),
          ),
        ],
      );
}

// ── Bet outcome card ───────────────────────────────────────────────────────────
// Why: The old card showed the text and icon but the point change felt
// underwhelming. The new card gives the point change a massive number so
// the emotional impact is immediate.
class _BetOutcomeCard extends StatelessWidget {
  final bool iWon;
  final bool isDraw;
  final int betAmount;

  const _BetOutcomeCard({
    required this.iWon,
    required this.isDraw,
    required this.betAmount,
  });

  @override
  Widget build(BuildContext context) {
    final color = iWon
        ? AppColors.correct
        : isDraw
            ? AppColors.secondary
            : AppColors.wrong;

    final sign = iWon ? '+' : isDraw ? '±' : '-';
    final points = iWon ? betAmount * 2 : betAmount;
    final title = iWon
        ? 'Points earned'
        : isDraw
            ? 'Points refunded'
            : 'Points lost';
    final sub = iWon
        ? 'You got both bets! 🎉'
        : isDraw
            ? 'Your bet was returned'
            : "Your opponent takes the pot";

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3), width: 1.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color.withOpacity(0.8),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sub,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Big point delta
          Text(
            '$sign$points',
            style: TextStyle(
              color: color,
              fontSize: 36,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Confetti painter (win only) ────────────────────────────────────────────────
// Why: A win without confetti feels incomplete. This custom painter draws
// 40 dots that fall with varying speeds and colours — pure CSS is unavailable
// in Flutter so a CustomPainter is the right tool here.
class _ConfettiPainter extends CustomPainter {
  final double progress;
  static final _rand = math.Random(42); // fixed seed = consistent shapes
  static final _particles = List.generate(
    40,
    (i) => _Particle(
      x: _rand.nextDouble(),
      startY: -0.1 - _rand.nextDouble() * 0.3,
      speed: 0.4 + _rand.nextDouble() * 0.6,
      size: 4 + _rand.nextDouble() * 6,
      color: _colors[i % _colors.length],
      rotation: _rand.nextDouble() * math.pi * 2,
    ),
  );

  static const _colors = [
    Color(0xFF7C3AED),
    Color(0xFF60A5FA),
    Color(0xFF34D399),
    Color(0xFFFBBF24),
    Color(0xFFF472B6),
    Color(0xFFA78BFA),
  ];

  const _ConfettiPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in _particles) {
      final y = (p.startY + progress * p.speed) % 1.2;
      if (y < 0 || y > 1.1) continue;
      final x = p.x * size.width;
      final py = y * size.height;
      final opacity = (1.0 - y).clamp(0.0, 1.0);

      canvas.save();
      canvas.translate(x, py);
      canvas.rotate(p.rotation + progress * math.pi * 2);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.5),
        Paint()..color = p.color.withOpacity(opacity * 0.85),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.progress != progress;
}

class _Particle {
  final double x;
  final double startY;
  final double speed;
  final double size;
  final Color color;
  final double rotation;
  const _Particle({
    required this.x,
    required this.startY,
    required this.speed,
    required this.size,
    required this.color,
    required this.rotation,
  });
}

// ── Not found ──────────────────────────────────────────────────────────────────
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
              const Text('🔍', style: TextStyle(fontSize: 56)),
              const SizedBox(height: 16),
              const Text(
                'Challenge not found',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'It may have been deleted or already expired.',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              GradientButton(
                label: 'Go Home',
                icon: Icons.home_rounded,
                onTap: onHome,
              ),
            ],
          ),
        ),
      );
}