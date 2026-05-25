import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import 'challenge_model.dart';
import 'challenge_result_page.dart';

/// Shown to the CREATOR after they finish playing.
/// Streams the challenge doc in real time so the status updates
/// the moment the opponent joins and then finishes.
class ChallengeLobbyPage extends StatefulWidget {
  final String challengeId;
  const ChallengeLobbyPage({super.key, required this.challengeId});

  @override
  State<ChallengeLobbyPage> createState() => _ChallengeLobbyPageState();
}

class _ChallengeLobbyPageState extends State<ChallengeLobbyPage> {
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    // Tick every minute so the expiry countdown stays fresh
    _expiryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) { if (mounted) setState(() {}); },
    );
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<void> _shareViaWhatsApp(ChallengeModel c) async {
    final text = Uri.encodeComponent(
      '🎮 I challenge you to an anime quiz!\n\n'
      '📺 Anime: ${c.animeTitle}\n'
      '⚡ Bet: ${c.betAmount} pts\n'
      '🔑 Challenge Code: *${c.challengeId}*\n\n'
      'Open the app → Multiplayer → Join Challenge → enter the code above.\n'
      'You have 24 hours to accept!',
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
      const SnackBar(content: Text('Code copied to clipboard!')),
    );
  }

  String _formatRemaining(Duration d) {
    if (d == Duration.zero) return 'Expired';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m remaining';
    return '${m}m remaining';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // can only leave via "Go Home" after challenge expires
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: StreamBuilder<ChallengeModel?>(
              stream: FirestoreService.instance
                  .challengeStream(widget.challengeId),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(
                        color: AppColors.primary),
                  );
                }

                final c = snap.data;
                if (c == null) {
                  return _ChallengeGoneState(
                    onHome: () => Navigator.of(context)
                        .popUntil((r) => r.isFirst),
                  );
                }

                return _LobbyBody(
                  challenge:     c,
                  onShare:       () => _shareViaWhatsApp(c),
                  onCopy:        () => _copyCode(c.challengeId),
                  onViewResults: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChallengeResultPage(
                        challengeId: c.challengeId,
                      ),
                    ),
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

// ── Body ──────────────────────────────────────────────────────────────────────
class _LobbyBody extends StatelessWidget {
  final ChallengeModel   challenge;
  final VoidCallback     onShare;
  final VoidCallback     onCopy;
  final VoidCallback     onViewResults;
  final VoidCallback     onHome;
  final String Function(Duration) formatRemaining;

  const _LobbyBody({
    required this.challenge,
    required this.onShare,
    required this.onCopy,
    required this.onViewResults,
    required this.onHome,
    required this.formatRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final isComplete = challenge.isCompleted;
    final isExpired  = challenge.isExpired;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      child: Column(
        children: [
          // ── Title ───────────────────────────────────────────────────────
          const Text(
            'Challenge Created! 🎯',
            style: TextStyle(
              color:      AppColors.textPrimary,
              fontSize:   26,
              fontWeight: FontWeight.w900,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            isExpired  ? 'Challenge expired' :
            isComplete ? 'Both players have finished!' :
                         formatRemaining(challenge.timeRemaining),
            style: TextStyle(
              color:    isExpired ? AppColors.wrong : AppColors.textMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 32),

          // ── Code card ───────────────────────────────────────────────────
          GlassCard(
            borderColor: AppColors.primary.withOpacity(0.5),
            child: Column(
              children: [
                const Text(
                  'Your Challenge Code',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: onCopy,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        challenge.challengeId,
                        style: const TextStyle(
                          color:         AppColors.primary,
                          fontSize:      40,
                          fontWeight:    FontWeight.w900,
                          letterSpacing: 8,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Icon(Icons.copy_rounded,
                          color: AppColors.textMuted, size: 20),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tap to copy',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Your score ──────────────────────────────────────────────────
          GlassCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Your Score',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(
                      challenge.creatorScore != null
                          ? '${challenge.creatorScore} / 10'
                          : '—',
                      style: const TextStyle(
                        color:      AppColors.textPrimary,
                        fontSize:   22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                _StatusChip(challenge: challenge),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── Share button ────────────────────────────────────────────────
          if (!isComplete && !isExpired)
            GradientButton(
              label: 'Share via WhatsApp',
              icon:  Icons.share_rounded,
              onTap: onShare,
            ),

          if (!isComplete && !isExpired)
            const SizedBox(height: 12),

          // ── View Results / Go Home ───────────────────────────────────────
          if (isComplete)
            GradientButton(
              label: 'View Results',
              icon:  Icons.emoji_events_rounded,
              onTap: onViewResults,
            )
          else
            TextButton(
              onPressed: onHome,
              child: const Text(
                'Go Home',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),

          if (isComplete) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: onHome,
              child: const Text(
                'Go Home',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Status chip ───────────────────────────────────────────────────────────────
class _StatusChip extends StatelessWidget {
  final ChallengeModel challenge;
  const _StatusChip({required this.challenge});

  @override
  Widget build(BuildContext context) {
    final Color  color;
    final String label;
    final IconData icon;

    if (challenge.isCompleted) {
      color = AppColors.correct;
      label = 'Done';
      icon  = Icons.check_circle_rounded;
    } else if (challenge.isExpired) {
      color = AppColors.wrong;
      label = 'Expired';
      icon  = Icons.timer_off_rounded;
    } else if (challenge.status == ChallengeStatus.opponentJoined) {
      color = AppColors.secondary;
      label = 'Opponent Playing…';
      icon  = Icons.sports_esports_rounded;
    } else {
      color = AppColors.primary;
      label = 'Waiting for Opponent';
      icon  = Icons.hourglass_top_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:        color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color:      color,
              fontSize:   11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Challenge gone state (deleted/corrupted doc) ──────────────────────────────
class _ChallengeGoneState extends StatelessWidget {
  final VoidCallback onHome;
  const _ChallengeGoneState({required this.onHome});

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
              const Text(
                'Challenge not found.',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 15),
              ),
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