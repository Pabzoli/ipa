import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import 'challenge_model.dart';
import 'challenge_result_page.dart';

// ─── Challenge Lobby — redesigned ─────────────────────────────────────────────
// What changed:
// - Added an animated radar/pulse waiting indicator so the waiting state
//   doesn't feel static and dead.
// - The challenge code is now displayed in two visual groups (like XXXX-XX)
//   with a glow effect on the primary colour.
// - Share options are a row of icon-buttons (WhatsApp + Copy) rather than a
//   single full-width button, saving vertical space.
// - A live status timeline shows the 3-stage progress: Created → Opponent
//   Joined → Complete.
// - Timer tick is moved to a separate 1-minute periodic so it doesn't
//   interfere with StreamBuilder rebuilds.
class ChallengeLobbyPage extends StatefulWidget {
  final String challengeId;
  const ChallengeLobbyPage({super.key, required this.challengeId});

  @override
  State<ChallengeLobbyPage> createState() => _ChallengeLobbyPageState();
}

class _ChallengeLobbyPageState extends State<ChallengeLobbyPage>
    with TickerProviderStateMixin {
  Timer? _expiryTimer;
  late AnimationController _pulseCtrl;
  late AnimationController _radarCtrl;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    _expiryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _pulseCtrl.dispose();
    _radarCtrl.dispose();
    super.dispose();
  }

  Future<void> _shareViaWhatsApp(ChallengeModel c) async {
    final text = Uri.encodeComponent(
      '⚔️ Anime quiz challenge!\n\n'
      '📺 ${c.animeTitle} · ${c.betAmount} pts bet\n'
      '🔑 Code: *${c.challengeId}*\n\n'
      'Open the app → Battle Arena → Join Challenge → enter code above.\n'
      '⏰ You have 24 hours!',
    );
    final uri = Uri.parse('https://wa.me/?text=$text');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WhatsApp not found on this device.')),
      );
    }
  }

  void _copyCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(children: [
          Icon(Icons.check_circle_outline_rounded,
              color: Colors.white, size: 16),
          SizedBox(width: 8),
          Text('Code copied to clipboard!'),
        ]),
        backgroundColor: AppColors.correct,
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatRemaining(Duration d) {
    if (d == Duration.zero) return 'Expired';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m left';
    return '${m}m left';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: StreamBuilder<ChallengeModel?>(
              stream: FirestoreService.instance
                  .challengeStream(widget.challengeId),
              builder: (context, snap) {
                if (!snap.hasData && snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  );
                }

                final c = snap.data;
                if (c == null) {
                  return _GoneState(
                    onHome: () => Navigator.of(context)
                        .popUntil((r) => r.isFirst),
                  );
                }

                return _LobbyBody(
                  challenge: c,
                  pulseCtrl: _pulseCtrl,
                  radarCtrl: _radarCtrl,
                  onShare: () => _shareViaWhatsApp(c),
                  onCopy: () => _copyCode(c.challengeId),
                  onViewResults: () => Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChallengeResultPage(
                          challengeId: c.challengeId),
                    ),
                    (r) => r.isFirst,
                  ),
                  onHome: () =>
                      Navigator.of(context).popUntil((r) => r.isFirst),
                  formatRemaining: _formatRemaining,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ── Lobby body ─────────────────────────────────────────────────────────────────
class _LobbyBody extends StatelessWidget {
  final ChallengeModel challenge;
  final AnimationController pulseCtrl;
  final AnimationController radarCtrl;
  final VoidCallback onShare;
  final VoidCallback onCopy;
  final VoidCallback onViewResults;
  final VoidCallback onHome;
  final String Function(Duration) formatRemaining;

  const _LobbyBody({
    required this.challenge,
    required this.pulseCtrl,
    required this.radarCtrl,
    required this.onShare,
    required this.onCopy,
    required this.onViewResults,
    required this.onHome,
    required this.formatRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final isComplete = challenge.isCompleted;
    final isExpired = challenge.isExpired;
    final isWaiting = !isComplete &&
        !isExpired &&
        challenge.status == ChallengeStatus.waiting;
    final opponentPlaying =
        challenge.status == ChallengeStatus.opponentJoined;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Challenge Created!',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isExpired
                          ? 'This challenge has expired'
                          : isComplete
                              ? 'Both players have finished ✅'
                              : formatRemaining(challenge.timeRemaining),
                      style: TextStyle(
                        color: isExpired
                            ? AppColors.wrong
                            : AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              _StatusBadge(challenge: challenge),
            ],
          ),

          const SizedBox(height: 24),

          // ── Your score strip ─────────────────────────────────────────
          _ScoreStrip(score: challenge.creatorScore),

          const SizedBox(height: 20),

          // ── Animated waiting indicator OR done banner ────────────────
          if (isWaiting)
            _RadarWaiting(
              pulseCtrl: pulseCtrl,
              radarCtrl: radarCtrl,
              animeTitle: challenge.animeTitle,
            )
          else if (opponentPlaying)
            _OpponentPlayingBanner()
          else if (isComplete)
            _CompleteBanner()
          else if (isExpired)
            _ExpiredBanner(),

          const SizedBox(height: 20),

          // ── Code card (only shown while waiting/opponent playing) ────
          if (!isComplete)
            _CodeCard(
              code: challenge.challengeId,
              onCopy: onCopy,
            ),

          const SizedBox(height: 16),

          // ── Share actions (only while active) ───────────────────────
          if (isWaiting) ...[
            _ShareActions(
              onWhatsApp: onShare,
              onCopy: onCopy,
            ),
            const SizedBox(height: 20),
          ],

          // ── Status timeline ──────────────────────────────────────────
          _StatusTimeline(challenge: challenge),

          const SizedBox(height: 28),

          // ── CTA ──────────────────────────────────────────────────────
          if (isComplete)
            GradientButton(
              label: 'View Results',
              icon: Icons.emoji_events_rounded,
              onTap: onViewResults,
            )
          else
            TextButton(
              onPressed: onHome,
              child: const Text(
                'Go Home (challenge stays live)',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ),

          if (isComplete) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: onHome,
              child: const Text(
                'Go Home',
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Score strip ────────────────────────────────────────────────────────────────
class _ScoreStrip extends StatelessWidget {
  final int? score;
  const _ScoreStrip({required this.score});

  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            const Text('🎯', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Your Score',
                style: TextStyle(
                    color: AppColors.textMuted, fontSize: 13),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: Text(
                score != null ? '$score / 10' : '—',
                key: ValueKey(score),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      );
}

// ── Animated radar waiting indicator ──────────────────────────────────────────
// Why: The old waiting state was just text. This custom painter creates
// expanding radar rings that communicate "actively waiting" visually.
class _RadarWaiting extends StatelessWidget {
  final AnimationController pulseCtrl;
  final AnimationController radarCtrl;
  final String animeTitle;

  const _RadarWaiting({
    required this.pulseCtrl,
    required this.radarCtrl,
    required this.animeTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Radar rings
          AnimatedBuilder(
            animation: radarCtrl,
            builder: (_, __) => CustomPaint(
              size: const Size(160, 160),
              painter: _RadarPainter(
                progress: radarCtrl.value,
                color: AppColors.primary,
              ),
            ),
          ),
          // Center pulsing dot
          AnimatedBuilder(
            animation: pulseCtrl,
            builder: (_, __) => Container(
              width: 48 + pulseCtrl.value * 4,
              height: 48 + pulseCtrl.value * 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary
                    .withOpacity(0.15 + pulseCtrl.value * 0.05),
              ),
              child: const Center(
                child: Text('⏳', style: TextStyle(fontSize: 22)),
              ),
            ),
          ),
          // Label
          const Positioned(
            bottom: 16,
            child: Text(
              'Waiting for opponent…',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double progress;
  final Color color;
  const _RadarPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    for (int i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final r = t * maxR;
      final opacity = (1.0 - t) * 0.3;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..color = color.withOpacity(opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.progress != progress;
}

// ── Opponent playing banner ────────────────────────────────────────────────────
class _OpponentPlayingBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) => _InfoBanner(
        emoji: '🎮',
        title: 'Opponent is playing!',
        subtitle: 'Results will appear here when they finish.',
        color: AppColors.secondary,
      );
}

class _CompleteBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) => _InfoBanner(
        emoji: '✅',
        title: 'Challenge complete!',
        subtitle: 'Tap View Results to see who won.',
        color: AppColors.correct,
      );
}

class _ExpiredBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) => _InfoBanner(
        emoji: '⏰',
        title: 'Challenge expired',
        subtitle: 'Your bet has been refunded.',
        color: AppColors.wrong,
      );
}

class _InfoBanner extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Color color;
  const _InfoBanner({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: color,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

// ── Code card ─────────────────────────────────────────────────────────────────
class _CodeCard extends StatelessWidget {
  final String code;
  final VoidCallback onCopy;
  const _CodeCard({required this.code, required this.onCopy});

  // Split code: first 3 chars + last 3 chars with visual separator
  String get _formatted =>
      '${code.substring(0, 3)} - ${code.substring(3)}';

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      borderColor: AppColors.primary.withOpacity(0.4),
      child: Column(
        children: [
          const Text(
            'CHALLENGE CODE',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onCopy,
            child: ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA78BFA), Color(0xFF60A5FA)],
              ).createShader(r),
              child: Text(
                _formatted,
                style: const TextStyle(
                  color: Colors.white, // overridden by ShaderMask
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.touch_app_rounded,
                  color: AppColors.textMuted, size: 12),
              SizedBox(width: 4),
              Text(
                'Tap to copy',
                style:
                    TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Share actions row ──────────────────────────────────────────────────────────
// Why: Two visual buttons side-by-side (WhatsApp green + copy grey) is
// faster to act on than a single button that only does WhatsApp.
class _ShareActions extends StatelessWidget {
  final VoidCallback onWhatsApp;
  final VoidCallback onCopy;
  const _ShareActions({required this.onWhatsApp, required this.onCopy});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            flex: 3,
            child: _ShareBtn(
              label: 'Share via WhatsApp',
              icon: Icons.chat_rounded,
              color: const Color(0xFF25D366),
              onTap: onWhatsApp,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: _ShareBtn(
              label: 'Copy Code',
              icon: Icons.copy_rounded,
              color: AppColors.textMuted,
              onTap: onCopy,
              outlined: true,
            ),
          ),
        ],
      );
}

class _ShareBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool outlined;

  const _ShareBtn({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: outlined ? Colors.transparent : color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: color.withOpacity(outlined ? 0.4 : 0.5),
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 17),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
}

// ── Status timeline ────────────────────────────────────────────────────────────
// Why: A 3-step timeline (Created → Joined → Done) shows the user exactly
// where in the challenge lifecycle things are without them needing to infer
// it from the status string alone.
class _StatusTimeline extends StatelessWidget {
  final ChallengeModel challenge;
  const _StatusTimeline({required this.challenge});

  @override
  Widget build(BuildContext context) {
    final s = challenge.status;
    final isComplete = challenge.isCompleted;
    final opponentJoined =
        s == ChallengeStatus.opponentJoined || isComplete;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'PROGRESS',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        _TimelineStep(
          label: 'Challenge created',
          sub: 'You played ${challenge.creatorScore ?? "—"} / 10',
          done: true,
          isLast: false,
        ),
        _TimelineStep(
          label: 'Opponent joined',
          sub: opponentJoined
              ? (challenge.opponentUsername ?? 'Opponent') +
                  ' is playing'
              : 'Waiting for them to enter your code',
          done: opponentJoined,
          isLast: false,
        ),
        _TimelineStep(
          label: 'Challenge resolved',
          sub: isComplete ? 'Results are ready!' : 'Pending',
          done: isComplete,
          isLast: true,
        ),
      ],
    );
  }
}

class _TimelineStep extends StatelessWidget {
  final String label;
  final String sub;
  final bool done;
  final bool isLast;
  const _TimelineStep({
    required this.label,
    required this.sub,
    required this.done,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final color = done ? AppColors.correct : AppColors.divider;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dot + line
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withOpacity(0.15),
                    border: Border.all(color: color, width: 2),
                  ),
                  child: done
                      ? const Icon(Icons.check_rounded,
                          color: AppColors.correct, size: 12)
                      : null,
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: color.withOpacity(0.4),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: done
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Status badge ───────────────────────────────────────────────────────────────
class _StatusBadge extends StatelessWidget {
  final ChallengeModel challenge;
  const _StatusBadge({required this.challenge});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;

    if (challenge.isCompleted) {
      color = AppColors.correct;
      label = 'Done ✅';
    } else if (challenge.isExpired) {
      color = AppColors.wrong;
      label = 'Expired';
    } else if (challenge.status == ChallengeStatus.opponentJoined) {
      color = AppColors.secondary;
      label = 'Playing…';
    } else {
      color = AppColors.primary;
      label = 'Waiting';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// ── Challenge gone state ───────────────────────────────────────────────────────
class _GoneState extends StatelessWidget {
  final VoidCallback onHome;
  const _GoneState({required this.onHome});

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
                'It may have been deleted or expired.',
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