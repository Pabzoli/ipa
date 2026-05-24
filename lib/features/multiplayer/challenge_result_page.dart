// lib/features/multiplayer/challenge_result_page.dart
//
// Shown to BOTH players after completing the quiz.
//
// States:
//  • Waiting  — current player finished but the other hasn't yet.
//               Shows the share code again so creator can nudge their friend.
//               Streams the Firestore doc and auto-transitions when done.
//  • Complete — both scores present.
//               Animated reveal: winner banner, score bars, points change.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import 'models/challenge_model.dart';

class ChallengeResultPage extends StatefulWidget {
  final String            challengeId;
  final ChallengeModel    challenge;      // initial snapshot; stream keeps it fresh
  final bool              isCreator;
  final int               myScore;
  final ChallengeOutcome? resolvedOutcome; // non-null when resolved on quiz exit

  const ChallengeResultPage({
    super.key,
    required this.challengeId,
    required this.challenge,
    required this.isCreator,
    required this.myScore,
    this.resolvedOutcome,
  });

  @override
  State<ChallengeResultPage> createState() => _ChallengeResultPageState();
}

class _ChallengeResultPageState extends State<ChallengeResultPage>
    with SingleTickerProviderStateMixin {

  // ── Firestore stream ──────────────────────────────────────────────────────
  late final Stream<ChallengeModel> _stream;

  // ── Reveal animation (plays once when challenge becomes complete) ─────────
  late final AnimationController _revealCtrl;
  late final Animation<double>   _scaleAnim;
  late final Animation<double>   _fadeAnim;
  bool _revealed   = false;
  bool _codeCopied = false;

  @override
  void initState() {
    super.initState();

    _stream = FirestoreService.instance.challengeStream(widget.challengeId);

    _revealCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 750),
    );
    _scaleAnim = Tween<double>(begin: 0.55, end: 1.0).animate(
        CurvedAnimation(parent: _revealCtrl, curve: Curves.elasticOut));
    _fadeAnim  = CurvedAnimation(parent: _revealCtrl, curve: Curves.easeIn);

    // If already resolved on entry (opponent was last to play), reveal immediately.
    if (widget.resolvedOutcome != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _triggerReveal());
    }
  }

  @override
  void dispose() {
    _revealCtrl.dispose();
    super.dispose();
  }

  void _triggerReveal() {
    if (_revealed || !mounted) return;
    _revealed = true;
    _revealCtrl.forward();
  }

  void _copyCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    setState(() => _codeCopied = true);
    Future.delayed(const Duration(seconds: 2),
        () { if (mounted) setState(() => _codeCopied = false); });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content:         Text('Code copied to clipboard!'),
        backgroundColor: AppColors.correct,
        duration:        Duration(seconds: 2),
      ),
    );
  }

  void _goHome() => Navigator.of(context).popUntil((r) => r.isFirst);

  // ── Result helpers ────────────────────────────────────────────────────────
  bool _iWon(ChallengeModel c) => c.outcome ==
      (widget.isCreator ? ChallengeOutcome.creatorWins : ChallengeOutcome.opponentWins);

  bool _isDraw(ChallengeModel c) => c.outcome == ChallengeOutcome.draw;

  int _myFinalScore(ChallengeModel c) => widget.isCreator
      ? (c.creatorScore  ?? widget.myScore)
      : (c.opponentScore ?? widget.myScore);

  int _theirFinalScore(ChallengeModel c) => widget.isCreator
      ? (c.opponentScore ?? 0)
      : (c.creatorScore  ?? 0);

  String _theirName(ChallengeModel c) => widget.isCreator
      ? (c.opponentUsername ?? 'Opponent')
      : c.creatorUsername;

  int _pointsChange(ChallengeModel c) {
    if (_isDraw(c))  return 0;
    return _iWon(c) ? c.betAmount : -c.betAmount;
  }

  // ── Root build ────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (_) => _goHome(),
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: StreamBuilder<ChallengeModel>(
            stream:      _stream,
            initialData: widget.challenge,
            builder: (context, snap) {
              final challenge = snap.data ?? widget.challenge;

              // Trigger reveal as soon as the live doc marks the challenge complete.
              if (challenge.isComplete && !_revealed) {
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _triggerReveal());
              }

              return SafeArea(
                child: AnimatedSwitcher(
                  duration:         const Duration(milliseconds: 500),
                  switchInCurve:    Curves.easeOut,
                  switchOutCurve:   Curves.easeIn,
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: challenge.isComplete
                      ? _ResultsView(
                          key:          const ValueKey('results'),
                          challenge:    challenge,
                          iWon:         _iWon(challenge),
                          isDraw:       _isDraw(challenge),
                          myScore:      _myFinalScore(challenge),
                          theirScore:   _theirFinalScore(challenge),
                          theirName:    _theirName(challenge),
                          pointsChange: _pointsChange(challenge),
                          scaleAnim:    _scaleAnim,
                          fadeAnim:     _fadeAnim,
                          onGoHome:     _goHome,
                        )
                      : _WaitingView(
                          key:        const ValueKey('waiting'),
                          challenge:  challenge,
                          myScore:    widget.myScore,
                          codeCopied: _codeCopied,
                          onCopy:     _copyCode,
                          onGoHome:   _goHome,
                        ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WAITING VIEW
// ─────────────────────────────────────────────────────────────────────────────

class _WaitingView extends StatelessWidget {
  final ChallengeModel challenge;
  final int            myScore;
  final bool           codeCopied;
  final void Function(String) onCopy;
  final VoidCallback           onGoHome;

  const _WaitingView({
    super.key,
    required this.challenge,
    required this.myScore,
    required this.codeCopied,
    required this.onCopy,
    required this.onGoHome,
  });

  @override
  Widget build(BuildContext context) {
    final codeChars = challenge.code.split('');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Header ─────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.home_rounded,
                    color: AppColors.textMuted),
                onPressed: onGoHome,
              ),
              const Text(
                'Waiting for Opponent',
                style: TextStyle(
                  color:      AppColors.textPrimary,
                  fontSize:   20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── My score recap ─────────────────────────────────────────
                GlassCard(
                  borderColor: AppColors.primary.withOpacity(0.35),
                  child: Row(
                    children: [
                      Container(
                        width:  52, height: 52,
                        decoration: BoxDecoration(
                          color:  AppColors.primary.withOpacity(0.12),
                          shape:  BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_circle_outline_rounded,
                            color: AppColors.primary, size: 28),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Your score',
                                style: TextStyle(
                                    color: AppColors.textMuted, fontSize: 13)),
                            Text(
                              '$myScore / ${challenge.questionIds.length}',
                              style: const TextStyle(
                                color:      AppColors.textPrimary,
                                fontSize:   28,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Text('Saved ✓',
                          style: TextStyle(
                              color:    AppColors.correct,
                              fontSize: 12,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                // ── Pulsing wait indicator ─────────────────────────────────
                const _PulsingWaitIndicator(
                  label:    "Your friend hasn't played yet",
                  sublabel: 'This screen updates automatically when they finish.',
                ),

                const SizedBox(height: 32),

                // ── Share code reminder ────────────────────────────────────
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color:        AppColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppColors.primary.withOpacity(0.25)),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'Remind your friend',
                        style: TextStyle(
                          color:      AppColors.textSecondary,
                          fontSize:   13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Mini code boxes
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ...codeChars.take(3).map((c) => _MiniCodeBox(char: c)),
                          const SizedBox(width: 10),
                          ...codeChars.skip(3).map((c) => _MiniCodeBox(char: c)),
                        ],
                      ),

                      const SizedBox(height: 14),

                      OutlinedButton.icon(
                        onPressed: () => onCopy(challenge.code),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              codeCopied ? AppColors.correct : AppColors.primary,
                          side: BorderSide(
                            color: codeCopied
                                ? AppColors.correct
                                : AppColors.primary.withOpacity(0.5),
                          ),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 20),
                        ),
                        icon: Icon(codeCopied
                            ? Icons.check_rounded
                            : Icons.copy_rounded,
                            size: 16),
                        label: Text(
                          codeCopied ? 'Copied!' : 'Copy Code',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                TextButton(
                  onPressed: onGoHome,
                  child: const Text(
                    "Go Home — I'll check back later",
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULTS VIEW
// ─────────────────────────────────────────────────────────────────────────────

class _ResultsView extends StatelessWidget {
  final ChallengeModel    challenge;
  final bool              iWon;
  final bool              isDraw;
  final int               myScore;
  final int               theirScore;
  final String            theirName;
  final int               pointsChange;
  final Animation<double> scaleAnim;
  final Animation<double> fadeAnim;
  final VoidCallback      onGoHome;

  const _ResultsView({
    super.key,
    required this.challenge,
    required this.iWon,
    required this.isDraw,
    required this.myScore,
    required this.theirScore,
    required this.theirName,
    required this.pointsChange,
    required this.scaleAnim,
    required this.fadeAnim,
    required this.onGoHome,
  });

  Color get _bannerColor =>
      iWon ? AppColors.correct : isDraw ? AppColors.secondary : AppColors.wrong;

  IconData get _bannerIcon => iWon
      ? Icons.emoji_events_rounded
      : isDraw
          ? Icons.handshake_rounded
          : Icons.sentiment_dissatisfied_rounded;

  String get _bannerText =>
      iWon ? 'You Won!' : isDraw ? "It's a Draw!" : 'You Lost';

  String get _pointsLabel {
    if (isDraw)         return 'Bet refunded — ${challenge.betAmount} pts returned';
    if (pointsChange > 0) return '+$pointsChange pts earned!';
    return '$pointsChange pts lost';
  }

  @override
  Widget build(BuildContext context) {
    final maxScore = challenge.questionIds.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Header ─────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.home_rounded,
                    color: AppColors.textMuted),
                onPressed: onGoHome,
              ),
              const Text(
                'Challenge Results',
                style: TextStyle(
                  color:      AppColors.textPrimary,
                  fontSize:   20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [

                // ── Winner banner (scale+fade entrance) ────────────────────
                ScaleTransition(
                  scale: scaleAnim,
                  child: FadeTransition(
                    opacity: fadeAnim,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 28, horizontal: 24),
                      decoration: BoxDecoration(
                        color: _bannerColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                            color: _bannerColor.withOpacity(0.45),
                            width: 2),
                        boxShadow: [
                          BoxShadow(
                            color:      _bannerColor.withOpacity(0.2),
                            blurRadius: 36,
                            offset:     const Offset(0, 14),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Icon(_bannerIcon,
                              color: _bannerColor, size: 60),
                          const SizedBox(height: 12),
                          Text(
                            _bannerText,
                            style: TextStyle(
                              color:      _bannerColor,
                              fontSize:   34,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 8),
                            decoration: BoxDecoration(
                              color: _bannerColor.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _pointsLabel,
                              style: TextStyle(
                                color:      _bannerColor,
                                fontSize:   14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // ── Scoreboard ─────────────────────────────────────────────
                FadeTransition(
                  opacity: fadeAnim,
                  child: GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SCOREBOARD',
                          style: TextStyle(
                            color:         AppColors.textMuted,
                            fontSize:      11,
                            fontWeight:    FontWeight.w800,
                            letterSpacing: 1.8,
                          ),
                        ),
                        const SizedBox(height: 16),

                        _ScoreboardRow(
                          name:     'You',
                          score:    myScore,
                          maxScore: maxScore,
                          barColor: iWon ? AppColors.correct : AppColors.primary,
                          isHighlighted: iWon || isDraw,
                        ),

                        const SizedBox(height: 8),
                        const Divider(color: AppColors.divider, height: 20),

                        _ScoreboardRow(
                          name:     theirName,
                          score:    theirScore,
                          maxScore: maxScore,
                          barColor: !iWon && !isDraw
                              ? AppColors.correct
                              : AppColors.textMuted,
                          isHighlighted: !iWon || isDraw,
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // ── Match details ──────────────────────────────────────────
                FadeTransition(
                  opacity: fadeAnim,
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color:        AppColors.surface.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Column(
                      children: [
                        _DetailLine(
                            label: 'Anime',
                            value: challenge.animeTitle),
                        const _Spacer(),
                        _DetailLine(
                            label: 'Bet per player',
                            value: '${challenge.betAmount} pts'),
                        if (!isDraw) ...[
                          const _Spacer(),
                          _DetailLine(
                            label:      'Winner',
                            value:      iWon ? 'You' : theirName,
                            valueColor: AppColors.correct,
                          ),
                        ],
                        const _Spacer(),
                        _DetailLine(
                          label:      'Net change',
                          value:      isDraw
                              ? '±0 pts'
                              : pointsChange > 0
                                  ? '+$pointsChange pts'
                                  : '$pointsChange pts',
                          valueColor: isDraw
                              ? AppColors.textSecondary
                              : pointsChange > 0
                                  ? AppColors.correct
                                  : AppColors.wrong,
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // ── Actions ────────────────────────────────────────────────
                FadeTransition(
                  opacity: fadeAnim,
                  child: GradientButton(
                    label: 'Challenge Again',
                    icon:  Icons.replay_rounded,
                    onTap: onGoHome,
                  ),
                ),

                const SizedBox(height: 12),

                FadeTransition(
                  opacity: fadeAnim,
                  child: TextButton(
                    onPressed: onGoHome,
                    child: const Text(
                      'Go Home',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// REUSABLE SMALL WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

/// Pulsing hourglass shown while waiting for the opponent.
class _PulsingWaitIndicator extends StatefulWidget {
  final String label;
  final String sublabel;
  const _PulsingWaitIndicator(
      {required this.label, required this.sublabel});

  @override
  State<_PulsingWaitIndicator> createState() => _PulsingWaitIndicatorState();
}

class _PulsingWaitIndicatorState extends State<_PulsingWaitIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync:    this,
        duration: const Duration(milliseconds: 1100))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          FadeTransition(
            opacity: _anim,
            child: const Icon(Icons.hourglass_top_rounded,
                color: AppColors.secondary, size: 52),
          ),
          const SizedBox(height: 14),
          Text(
            widget.label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color:      AppColors.textPrimary,
              fontSize:   17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.sublabel,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.textMuted, fontSize: 13, height: 1.5),
          ),
        ],
      );
}

class _ScoreboardRow extends StatelessWidget {
  final String name;
  final int    score;
  final int    maxScore;
  final Color  barColor;
  final bool   isHighlighted;

  const _ScoreboardRow({
    required this.name,
    required this.score,
    required this.maxScore,
    required this.barColor,
    required this.isHighlighted,
  });

  @override
  Widget build(BuildContext context) {
    final pct = maxScore > 0 ? (score / maxScore).clamp(0.0, 1.0) : 0.0;

    return Row(
      children: [
        // Avatar circle
        Container(
          width:  40, height: 40,
          decoration: BoxDecoration(
            shape:  BoxShape.circle,
            color:  isHighlighted
                ? barColor.withOpacity(0.15)
                : AppColors.surface,
            border: Border.all(
                color: isHighlighted ? barColor : AppColors.divider),
          ),
          child: Center(
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                color:      isHighlighted ? barColor : AppColors.textMuted,
                fontWeight: FontWeight.w800,
                fontSize:   16,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),

        // Name + bar + score
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      name,
                      style: TextStyle(
                        color:      isHighlighted
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontSize:   14,
                        fontWeight: isHighlighted
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '$score / $maxScore',
                    style: TextStyle(
                      color:      isHighlighted
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontSize:   14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: TweenAnimationBuilder<double>(
                  tween:    Tween(begin: 0.0, end: pct),
                  duration: const Duration(milliseconds: 900),
                  curve:    Curves.easeOut,
                  builder:  (_, v, __) => LinearProgressIndicator(
                    value:           v,
                    minHeight:       7,
                    backgroundColor: AppColors.divider,
                    valueColor:      AlwaysStoppedAnimation(barColor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniCodeBox extends StatelessWidget {
  final String char;
  const _MiniCodeBox({required this.char});

  @override
  Widget build(BuildContext context) => Container(
        width:  36, height: 44,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color:        AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(
              color: AppColors.primary.withOpacity(0.45), width: 1.5),
        ),
        child: Center(
          child: Text(
            char,
            style: const TextStyle(
              color:      AppColors.textPrimary,
              fontSize:   20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      );
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _DetailLine(
      {required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 14)),
          Text(
            value,
            style: TextStyle(
              color:      valueColor ?? AppColors.textPrimary,
              fontSize:   14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
}

class _Spacer extends StatelessWidget {
  const _Spacer();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 10);
}