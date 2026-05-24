// lib/features/multiplayer/challenge_lobby_page.dart
//
// Shown to the CREATOR immediately after challenge creation.
// Responsibilities:
//   1. Display the 6-character share code with copy + WhatsApp share.
//   2. Pre-load the 10 questions in the background.
//   3. Allow creator to start the quiz (once questions are ready).
//   4. If creator somehow returns here (edge-case), stream challenge state
//      and redirect to result page if challenge is already completed.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import '../quiz/questions.dart';
import 'models/challenge_model.dart';
import 'challenge_quiz_page.dart';

class ChallengeLobbyPage extends StatefulWidget {
  final ChallengeModel challenge;
  const ChallengeLobbyPage({super.key, required this.challenge});

  @override
  State<ChallengeLobbyPage> createState() => _ChallengeLobbyPageState();
}

class _ChallengeLobbyPageState extends State<ChallengeLobbyPage>
    with SingleTickerProviderStateMixin {
  List<AnimeQuestion>? _questions;
  String?              _loadError;
  bool                 _codeCopied = false;

  // ── FIX: Navigation guard ───────────────────────────────────────────────────
  // Prevents double-tap from calling Navigator.pushReplacement twice.
  // A second tap during the push animation would try to replace the route
  // that is already being replaced, causing a navigation hierarchy error
  // which manifests as the UI appearing frozen.
  bool _isNavigating = false;

  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.97, end: 1.03).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _loadQuestions();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadQuestions() async {
    // Reset error state before retrying.
    if (mounted) setState(() => _loadError = null);
    try {
      final qs = await FirestoreService.instance
          .fetchQuestionsByIds(widget.challenge.questionIds);
      if (!mounted) return;
      setState(() => _questions = qs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.challenge.code));
    setState(() => _codeCopied = true);
    Future.delayed(const Duration(seconds: 2),
        () { if (mounted) setState(() => _codeCopied = false); });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content:         Text('Challenge code copied to clipboard!'),
        backgroundColor: AppColors.correct,
        duration:        Duration(seconds: 2),
      ),
    );
  }

  Future<void> _shareWhatsApp() async {
    final code    = widget.challenge.code;
    final anime   = widget.challenge.animeTitle;
    final bet     = widget.challenge.betAmount;
    final message = Uri.encodeComponent(
      '🎌 I challenge you to an anime quiz!\n\n'
      'Anime: $anime\nBet: $bet pts\nCode: *$code*\n\n'
      'Open the app → Challenge a Friend → Join a Challenge → Enter code $code',
    );
    final url = Uri.parse('https://wa.me/?text=$message');

    final launched = await launchUrl(url, mode: LaunchMode.externalApplication);

    if (!launched && mounted) {
      _copyCode();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "WhatsApp not found — code copied! Paste it anywhere to share."),
          backgroundColor: AppColors.correct,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  // ── FIX: _startQuiz with navigation guard ─────────────────────────────────
  // BEFORE: No guard — rapid double-taps called Navigator.pushReplacement
  //         twice on the same context, corrupting the navigation stack and
  //         causing the UI to appear frozen/stuck.
  //
  // ALSO:   fetchQuestionsByIds now throws when it gets 0 results, so
  //         _loadError is shown instead of a silent null-onTap button.
  //
  // AFTER:  _isNavigating flag blocks any call after the first. Mounted check
  //         added after every await as additional safety.
  void _startQuiz() {
    // Double-tap guard: ignore if we're already navigating.
    if (_isNavigating) return;
    // Safety checks — should never be false here, but be defensive.
    if (_questions == null || _questions!.isEmpty) return;
    if (!mounted) return;

    setState(() => _isNavigating = true);

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        // FIX: The FadeTransition belongs in transitionsBuilder, NOT
        // pageBuilder. In pageBuilder it still animated correctly but
        // was semantically wrong and could confuse the Navigator's
        // route-management bookkeeping.
        pageBuilder: (_, __, ___) => ChallengeQuizPage(
          challenge: widget.challenge,
          questions: _questions!,
          isCreator: true,
        ),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final challenge   = widget.challenge;
    final codeChars   = challenge.code.split('');
    final questsReady = _questions != null && _questions!.isNotEmpty;
    final loading     = _questions == null && _loadError == null;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        Navigator.of(context).popUntil((r) => r.isFirst);
      },
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header ─────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: AppColors.textMuted),
                        onPressed: () =>
                            Navigator.of(context).popUntil((r) => r.isFirst),
                      ),
                      const Expanded(
                        child: Text(
                          'Challenge Created!',
                          style: TextStyle(
                            color:      AppColors.textPrimary,
                            fontSize:   22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ── Info card ───────────────────────────────────────
                        GlassCard(
                          borderColor: AppColors.primary.withOpacity(0.3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  _InfoChip(
                                    icon:  Icons.movie_filter_rounded,
                                    label: challenge.animeTitle,
                                    color: AppColors.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  _InfoChip(
                                    icon:  Icons.bolt_rounded,
                                    label: '${challenge.betAmount} pts',
                                    color: AppColors.secondary,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  const Icon(Icons.timer_outlined,
                                      color: AppColors.textMuted, size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    challenge.expiryLabel,
                                    style: const TextStyle(
                                        color:    AppColors.textMuted,
                                        fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 28),

                        // ── Share code section ──────────────────────────────
                        const Text(
                          'Share this code',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color:      AppColors.textSecondary,
                            fontSize:   13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // ── Code boxes ─────────────────────────────────────
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: codeChars
                              .map((c) => _CodeBox(char: c))
                              .toList(),
                        ),

                        const SizedBox(height: 20),

                        // ── Share buttons ──────────────────────────────────
                        Row(
                          children: [
                            Expanded(
                              child: _ShareButton(
                                icon:   _codeCopied
                                    ? Icons.check_rounded
                                    : Icons.copy_rounded,
                                label:  _codeCopied ? 'Copied!' : 'Copy Code',
                                onTap:  _copyCode,
                                active: _codeCopied,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _ShareButton(
                                icon:  Icons.send_rounded,
                                label: 'WhatsApp',
                                onTap: _shareWhatsApp,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 28),

                        // ── Instructions ───────────────────────────────────
                        GlassCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                'How it works',
                                style: TextStyle(
                                  color:      AppColors.textPrimary,
                                  fontSize:   14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 12),
                              _StepRow(
                                  step: '1',
                                  text: 'Share the code with your friend.'),
                              SizedBox(height: 8),
                              _StepRow(
                                  step: '2',
                                  text:
                                      'Your friend joins via "Join a Challenge".'),
                              SizedBox(height: 8),
                              _StepRow(
                                  step: '3',
                                  text:
                                      'Both of you answer 10 questions. Highest score wins the bet!'),
                            ],
                          ),
                        ),

                        const SizedBox(height: 36),

                        // ── Start quiz CTA ──────────────────────────────────
                        if (_loadError != null)
                          Column(
                            children: [
                              Text(
                                _loadError!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: AppColors.wrong, fontSize: 14),
                              ),
                              const SizedBox(height: 12),
                              GradientButton(
                                label: 'Retry Loading',
                                icon:  Icons.refresh_rounded,
                                onTap: _loadQuestions,
                              ),
                            ],
                          )
                        else if (loading)
                          const Column(
                            children: [
                              CircularProgressIndicator(
                                  color: AppColors.primary),
                              SizedBox(height: 12),
                              Text(
                                'Preparing questions…',
                                style: TextStyle(
                                    color:    AppColors.textMuted,
                                    fontSize: 13),
                              ),
                            ],
                          )
                        else
                          // ── FIX: Wire _pulseAnim to the CTA button ─────────
                          // _pulseAnim was animated but never used — the pulse
                          // controller was burning CPU with no visual benefit.
                          // Now it makes the CTA gently scale to draw attention.
                          ScaleTransition(
                            scale: _pulseAnim,
                            child: GradientButton(
                              label:  _isNavigating
                                  ? 'Loading quiz…'
                                  : "I'm Ready — Start Quiz",
                              icon:   _isNavigating
                                  ? Icons.hourglass_top_rounded
                                  : Icons.play_arrow_rounded,
                              // questsReady will always be true here because
                              // fetchQuestionsByIds now throws on empty results
                              // (sets _loadError) instead of returning [].
                              onTap: (questsReady && !_isNavigating)
                                  ? _startQuiz
                                  : null,
                            ),
                          ),

                        const SizedBox(height: 12),
                        const Center(
                          child: Text(
                            'You can share the code AFTER finishing the quiz too.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: AppColors.textMuted, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
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

// ─── Small Widgets ────────────────────────────────────────────────────────────

class _CodeBox extends StatelessWidget {
  final String char;
  const _CodeBox({required this.char});

  @override
  Widget build(BuildContext context) => Container(
        width:  48,
        height: 60,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color:        AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border:       Border.all(
              color: AppColors.primary.withOpacity(0.5), width: 2),
          boxShadow: [
            BoxShadow(
              color:       AppColors.primary.withOpacity(0.15),
              blurRadius:  12,
              spreadRadius: 0,
            ),
          ],
        ),
        child: Center(
          child: Text(
            char,
            style: const TextStyle(
              color:       AppColors.textPrimary,
              fontSize:    24,
              fontWeight:  FontWeight.w900,
              letterSpacing: 0,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
}

class _ShareButton extends StatelessWidget {
  final IconData icon;
  final String   label;
  final VoidCallback onTap;
  final bool     active;
  const _ShareButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: active
                ? AppColors.correct.withOpacity(0.15)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? AppColors.correct : AppColors.divider,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  color: active ? AppColors.correct : AppColors.textSecondary,
                  size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: active ? AppColors.correct : AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  const _InfoChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color:        color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color:      color,
                    fontSize:   13,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class _StepRow extends StatelessWidget {
  final String step;
  final String text;
  const _StepRow({required this.step, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width:  24,
            height: 24,
            decoration: BoxDecoration(
              color:        AppColors.primary.withOpacity(0.15),
              shape:        BoxShape.circle,
              border: Border.all(
                  color: AppColors.primary.withOpacity(0.4)),
            ),
            child: Center(
              child: Text(
                step,
                style: const TextStyle(
                  color:      AppColors.primary,
                  fontSize:   12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color:    AppColors.textSecondary,
                fontSize: 13,
                height:   1.4,
              ),
            ),
          ),
        ],
      );
}