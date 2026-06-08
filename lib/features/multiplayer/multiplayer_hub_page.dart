// lib/features/multiplayer/multiplayer_hub_page.dart
//
// ══════════════════════════════════════════════════════════════════════════════
//  VISUAL REDESIGN — same logic, elevated aesthetics
//  Changes vs previous version:
//  1. Deeper, richer colour palette with gradient anchor colours.
//  2. _ArenaBanner uses a LinearGradient + CustomPaint diagonal-stripe overlay
//     and a stronger multi-layer glow.
//  3. _HowItWorksStrip: circular numbered badges, coloured per-step accents.
//  4. _ActionCard: gradient-filled header zone, gradient border treatment.
//  5. QMWindowWidget: animated glowing border when window is open; layered
//     glow behind the card.
//  6. _TokenBar: segmented pill progress bar replaces dot indicators.
//  7. _SearchingDialog: three-ring concentric pulse animation.
//  8. _ActiveChallengeCard: left-accent border, status chip, better layout.
//  9. _HubAppBar: larger wordmark, gradient coin badge.
//  10. _RulesCard / _RuleRow: full-row tinted containers with left accent strip.
// ══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../quiz/quiz_controller.dart' show QuizMode;
import '../quiz/questions_page.dart';
import 'anime_select_page.dart';
import 'join_challenge_page.dart';

// =============================================================================
// ── Design tokens — mapped to AppColors from app_theme.dart ──────────────────
// =============================================================================

abstract final class _C {
  // ── Surfaces ──────────────────────────────────────────────────────────────
  static const bg       = AppColors.surfaceDim;
  static const surface  = AppColors.surface;
  static const elevated = AppColors.surfaceAlt;
  static const raised   = Color(0xFF1F1F30);

  // ── Primary accent — crimson ──────────────────────────────────────────────
  static const crimson       = AppColors.primary;      // Color(0xFFE63946)
  static const crimsonBright = Color(0xFFFF6B7A);
  static const crimsonGlow   = Color(0x1CE63946);
  static const crimsonFog    = Color(0x0CE63946);
  static const crimsonBorder = Color(0x55E63946);

  // ── Legacy aliases ────────────────────────────────────────────────────────
  static const amber       = crimson;
  static const amberBright = crimsonBright;
  static const amberGlow   = crimsonGlow;
  static const amberBorder = crimsonBorder;
  static const rose        = crimson;
  static const roseDim     = crimsonGlow;

  // ── Secondary accents ─────────────────────────────────────────────────────
  static const sky    = AppColors.secondary;            // Color(0xFF457B9D)
  static const skyDim = Color(0x16457B9D);

  static const green    = AppColors.correct;            // Color(0xFF38EF7D)
  static const greenDim = Color(0x1638EF7D);

  // ── Text ──────────────────────────────────────────────────────────────────
  static const text      = AppColors.textPrimary;       // Color(0xFFF8F8FF)
  static const textSub   = AppColors.textSecondary;     // Color(0xFFB0B0CC)
  static const textMuted = AppColors.textMuted;         // Color(0xFF6B6B8A)

  // ── Structure ─────────────────────────────────────────────────────────────
  static const divider = AppColors.divider;             // Color(0xFF2E2E42)
  static const border  = Color(0xFF252538);

  // ── Gradient helpers ──────────────────────────────────────────────────────
  static const LinearGradient crimsonGrad = LinearGradient(
    colors: [AppColors.primary, Color(0xFFFF4D5E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient skyGrad = LinearGradient(
    colors: [AppColors.secondary, Color(0xFF70AEFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient bannerGrad = LinearGradient(
    colors: [Color(0xFF1C0A0D), Color(0xFF0E0E1C)],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );
}

// =============================================================================
// ── Diagonal-stripe painter (banner decoration) ───────────────────────────────
// =============================================================================

class _StripePainter extends CustomPainter {
  final Color color;
  const _StripePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const spacing = 24.0;
    for (double x = -size.height; x < size.width + size.height; x += spacing) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.color != color;
}

// =============================================================================
// ── Entry hub ─────────────────────────────────────────────────────────────────
// =============================================================================

class MultiplayerHubPage extends StatefulWidget {
  const MultiplayerHubPage({super.key});

  @override
  State<MultiplayerHubPage> createState() => _MultiplayerHubPageState();
}

class _MultiplayerHubPageState extends State<MultiplayerHubPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Navigation helpers ───────────────────────────────────────────────────

  void _goCreate() =>
      Navigator.push(context, _slideRoute(const AnimeSelectPage()));

  void _goJoin() =>
      Navigator.push(context, _slideRoute(const JoinChallengePage()));

  void _goQuickMatch() => _startMatchmaking();

  Future<void> _startMatchmaking() async {
    if (!mounted) return;

    final result = await showDialog<_MatchResult?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SearchingDialog(),
    );

    if (!mounted) return;
    if (result == null) return;

    if (result.qmWindowClosed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Quick Match is only available during scheduled windows. '
          'Check the timer below.',
        ),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    if (result.noTokens) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No tokens left — watch an ad for one more.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    if (result.noMatch) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'No opponents available right now. Try again in a few minutes.',
        ),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    Navigator.push(
      context,
      _slideRoute(
        QuestionsPage(
          mode:           QuizMode.asyncChallenge,
          selectedTitles: [result.animeTitle],
          questionIds:    result.questionIds,
          challengeId:    result.challengeId,
          isCreator:      result.isCreator,
          isQuickMatch:   true,
          isGhost:        result.isGhost,
          opponentName:   result.opponentName,
        ),
      ),
    );
  }

  PageRoute _slideRoute(Widget page) => PageRouteBuilder(
        pageBuilder: (_, a, __) => page,
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 350),
      );

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final animeCoins = context.watch<UserDataProvider>().animeCoins;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text(
              'MULTIPLAYER',
              style: TextStyle(
                color:         AppColors.primary,
                fontSize:      9,
                fontWeight:    FontWeight.w800,
                letterSpacing: 2.8,
                height:        1,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Battle Arena',
              style: TextStyle(
                color:         AppColors.textPrimary,
                fontSize:      20,
                fontWeight:    FontWeight.w900,
                letterSpacing: -0.7,
                height:        1.0,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withOpacity(0.18),
                    AppColors.primary.withOpacity(0.08),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _C.crimsonBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🪙', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 5),
                  Text(
                    '$animeCoins',
                    style: const TextStyle(
                      color:         _C.crimsonBright,
                      fontSize:      14,
                      fontWeight:    FontWeight.w900,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 56),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),

              _ArenaBanner(pulseAnim: _pulseAnim),
              const SizedBox(height: 20),

              const _HowItWorksStrip(),
              const SizedBox(height: 20),

              const _ActiveChallengesSection(),

              // Create / Join challenge cards — above Quick Match
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _ActionCard(
                        emoji: '⚔️',
                        title: 'Create\nChallenge',
                        subtitle:
                            'Pick anime, set stake,\nplay first. Share code.',
                        gradient: _C.crimsonGrad,
                        glowColor: _C.crimson,
                        onTap: _goCreate,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionCard(
                        emoji: '🎯',
                        title: 'Join\nChallenge',
                        subtitle:
                            'Got a 6-char code?\nEnter it and battle.',
                        gradient: _C.skyGrad,
                        glowColor: _C.sky,
                        onTap: _goJoin,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              QMWindowWidget(onStartMatchmaking: _goQuickMatch),
              const SizedBox(height: 20),

              const _RulesCard(),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// ── Match result data class ────────────────────────────────────────────────────
// =============================================================================

class _MatchResult {
  final bool noMatch;
  final bool qmWindowClosed;
  final bool noTokens;
  final List<String> questionIds;
  final String challengeId;
  final bool isGhost;
  final bool isCreator;
  final String opponentName;
  final String animeTitle;

  const _MatchResult.noMatch()
      : noMatch = true,
        qmWindowClosed = false,
        noTokens = false,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '';

  const _MatchResult.qmWindowClosed()
      : noMatch = false,
        qmWindowClosed = true,
        noTokens = false,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '';

  const _MatchResult.noTokens()
      : noMatch = false,
        qmWindowClosed = false,
        noTokens = true,
        questionIds = const [],
        challengeId = '',
        isGhost = false,
        isCreator = true,
        opponentName = '',
        animeTitle = '';

  const _MatchResult({
    required this.questionIds,
    required this.challengeId,
    required this.isGhost,
    required this.isCreator,
    required this.opponentName,
    required this.animeTitle,
  })  : noMatch = false,
        qmWindowClosed = false,
        noTokens = false;
}

// =============================================================================
// ── Searching dialog ──────────────────────────────────────────────────────────
// =============================================================================

class _SearchingDialog extends StatefulWidget {
  const _SearchingDialog();

  @override
  State<_SearchingDialog> createState() => _SearchingDialogState();
}

class _SearchingDialogState extends State<_SearchingDialog>
    with SingleTickerProviderStateMixin {
  int    _remaining    = 60;
  bool   _leaving      = false;
  String _displayTitle = 'Any Anime';
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _startCountdown();
    _callMatchmaking();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _remaining = (_remaining - 1).clamp(0, 60);
      });
    });
  }

  Future<void> _callMatchmaking() async {
    const pollInterval = Duration(seconds: 5);
    const maxWait      = Duration(seconds: 60);
    final deadline     = DateTime.now().add(maxWait);

    while (mounted && !_leaving) {
      try {
        final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('joinMatchmakingQueue');

        final result = await callable.call<Map<Object?, Object?>>({});

        if (!mounted || _leaving) return;

        final data       = Map<String, dynamic>.from(result.data);
        final matched    = (data['matched']    as bool?)   ?? false;
        final isGhost    = (data['isGhost']    as bool?)   ?? false;
        final animeTitle = (data['animeTitle'] as String?) ?? '';

        if (matched) {
          _countdownTimer?.cancel();
          Navigator.of(context).pop(
            _MatchResult(
              questionIds:  List<String>.from(data['questionIds'] as List),
              challengeId:  data['challengeId'] as String,
              isGhost:      false,
              isCreator:    (data['isCreator'] as bool?) ?? true,
              opponentName: (data['opponentUsername'] as String?) ?? 'Opponent',
              animeTitle:   animeTitle,
            ),
          );
          return;
        }

        if (isGhost) {
          _countdownTimer?.cancel();
          Navigator.of(context).pop(
            _MatchResult(
              questionIds:  List<String>.from(data['questionIds'] as List),
              challengeId:  data['challengeId'] as String,
              isGhost:      true,
              isCreator:    true,
              opponentName: (data['ghostUsername'] as String?) ?? 'Recorded Opponent',
              animeTitle:   animeTitle,
            ),
          );
          return;
        }

        if (DateTime.now().isBefore(deadline)) {
          await Future.delayed(pollInterval);
          continue;
        }

        _countdownTimer?.cancel();
        Navigator.of(context).pop(const _MatchResult.noMatch());
        return;

      } on FirebaseFunctionsException catch (e) {
        if (!mounted || _leaving) return;
        if (e.message == 'outside_qm_window') {
          _countdownTimer?.cancel();
          Navigator.of(context).pop(const _MatchResult.qmWindowClosed());
          return;
        }
        if (e.message == 'no_qm_tokens') {
          _countdownTimer?.cancel();
          Navigator.of(context).pop(const _MatchResult.noTokens());
          return;
        }
        if (DateTime.now().isBefore(deadline)) {
          await Future.delayed(pollInterval);
          continue;
        }
        _countdownTimer?.cancel();
        Navigator.of(context).pop(const _MatchResult.noMatch());
        return;

      } catch (_) {
        if (!mounted || _leaving) return;
        if (DateTime.now().isBefore(deadline)) {
          await Future.delayed(pollInterval);
          continue;
        }
        _countdownTimer?.cancel();
        Navigator.of(context).pop(const _MatchResult.noMatch());
        return;
      }
    }
  }

  Future<void> _handleCancel() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    _countdownTimer?.cancel();

    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('leaveMatchmakingQueue')
          .call();
    } catch (_) {}

    if (!mounted) return;
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _remaining / 60.0;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) _handleCancel();
      },
      child: Dialog(
        backgroundColor: _C.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: _C.crimson.withOpacity(0.30), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 34, 28, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Concentric-ring pulsing badge ─────────────────────────
              _ConcentricPulseBadge(),
              const SizedBox(height: 22),

              // ── Status chip ───────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: _C.crimsonGlow,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _C.crimsonBorder, width: 1),
                ),
                child: const Text(
                  'FINDING OPPONENT',
                  style: TextStyle(
                    color: _C.crimsonBright,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.5,
                  ),
                ),
              ),
              const SizedBox(height: 10),

              Text(
                _displayTitle,
                style: const TextStyle(
                  color: _C.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),

              // ── Circular countdown ────────────────────────────────────
              SizedBox(
                width: 88,
                height: 88,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 88,
                      height: 88,
                      child: CircularProgressIndicator(
                        value: progress,
                        backgroundColor: _C.elevated,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color.lerp(_C.crimson, _C.crimsonBright, 1 - progress)!,
                        ),
                        strokeWidth: 4.5,
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_remaining',
                          style: const TextStyle(
                            color: _C.text,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            height: 1,
                          ),
                        ),
                        const Text(
                          'sec',
                          style: TextStyle(
                            color: _C.textMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),

              // ── Cancel button ─────────────────────────────────────────
              GestureDetector(
                onTap: _leaving ? null : _handleCancel,
                child: AnimatedOpacity(
                  opacity: _leaving ? 0.35 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 13),
                    decoration: BoxDecoration(
                      color: _C.elevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _C.border.withOpacity(0.7),
                      ),
                    ),
                    child: const Text(
                      'Cancel Search',
                      style: TextStyle(
                        color: _C.textSub,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Concentric-ring pulse badge ───────────────────────────────────────────────

class _ConcentricPulseBadge extends StatefulWidget {
  @override
  State<_ConcentricPulseBadge> createState() => _ConcentricPulseBadgeState();
}

class _ConcentricPulseBadgeState extends State<_ConcentricPulseBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _ring1;
  late Animation<double>   _ring2;
  late Animation<double>   _ring3;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _ring1 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 1.0, curve: Curves.easeOut),
      ),
    );
    _ring2 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.18, 1.0, curve: Curves.easeOut),
      ),
    );
    _ring3 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.36, 1.0, curve: Curves.easeOut),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outermost ring
              Opacity(
                opacity: (1.0 - _ring3.value).clamp(0.0, 1.0),
                child: Container(
                  width:  44 + 44 * _ring3.value,
                  height: 44 + 44 * _ring3.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _C.crimson.withOpacity(0.18),
                      width: 1,
                    ),
                  ),
                ),
              ),
              // Middle ring
              Opacity(
                opacity: (1.0 - _ring2.value).clamp(0.0, 1.0),
                child: Container(
                  width:  44 + 30 * _ring2.value,
                  height: 44 + 30 * _ring2.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _C.crimson.withOpacity(0.28),
                      width: 1,
                    ),
                  ),
                ),
              ),
              // Inner ring
              Opacity(
                opacity: (1.0 - _ring1.value).clamp(0.0, 1.0),
                child: Container(
                  width:  44 + 16 * _ring1.value,
                  height: 44 + 16 * _ring1.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _C.crimson.withOpacity(0.40),
                      width: 1,
                    ),
                  ),
                ),
              ),
              // Core badge
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [Color(0x30E63946), Color(0x10E63946)],
                  ),
                  border: Border.all(
                    color: _C.crimson.withOpacity(0.45),
                    width: 1.5,
                  ),
                ),
                child: const Center(
                  child: Text('⚡', style: TextStyle(fontSize: 24)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// ── QMWindowWidget ─────────────────────────────────────────────────────────────
// =============================================================================

class QMWindowWidget extends StatefulWidget {
  final VoidCallback onStartMatchmaking;
  const QMWindowWidget({super.key, required this.onStartMatchmaking});

  @override
  State<QMWindowWidget> createState() => _QMWindowWidgetState();
}

class _QMWindowWidgetState extends State<QMWindowWidget>
    with SingleTickerProviderStateMixin {
  Timer?    _countdownTimer;
  Duration  _timeToNext  = Duration.zero;
  bool      _watchingAd  = false;

  late AnimationController _borderCtrl;
  late Animation<double>   _borderAnim;

  @override
  void initState() {
    super.initState();
    _updateCountdown();
    _countdownTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _updateCountdown();
    });
    _borderCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _borderAnim = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _borderCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _borderCtrl.dispose();
    super.dispose();
  }

  void _updateCountdown() {
    final next = QMWindowSchedule.nextWindowStart();
    setState(() {
      _timeToNext = next.difference(DateTime.now().toUtc());
      if (_timeToNext.isNegative) _timeToNext = Duration.zero;
    });
  }

  String _formatCountdown(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  String _buildCountdownLabel() {
    final next = QMWindowSchedule.nextWindowStart();
    final diff = next.difference(DateTime.now().toUtc());
    final clamped = diff.isNegative ? Duration.zero : diff;
    final nextWindow = QMWindowSchedule.windows.firstWhere(
      (w) => w.startUTC == next.hour,
      orElse: () => QMWindowSchedule.windows.first,
    );
    return 'Next: ${nextWindow.name} in ${_formatCountdown(clamped)}';
  }

  Future<void> _handleWatchAd(BuildContext context) async {
    if (_watchingAd) return;
    setState(() => _watchingAd = true);

    final shown = await AdService.instance.showQMTokenAd(
      context: context,
      onTokenGranted: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('🎟 +1 token granted!'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      },
    );

    if (!shown && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Ad not ready yet — try again in a moment.'),
        behavior: SnackBarBehavior.floating,
      ));
    }

    if (mounted) setState(() => _watchingAd = false);
  }

  @override
  Widget build(BuildContext context) {
    final udp          = context.watch<UserDataProvider>();
    final qmTokens     = udp.qmTokens;
    final qmAdTokenUsed = udp.qmAdTokenUsed;
    final activeWindow = QMWindowSchedule.currentWindow();
    final isWindowOpen = activeWindow != null;

    return AnimatedBuilder(
      animation: _borderAnim,
      builder: (_, child) => Container(
        decoration: BoxDecoration(
          color: _C.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isWindowOpen
                ? _C.crimson.withOpacity(_borderAnim.value)
                : _C.border.withOpacity(0.5),
            width: isWindowOpen ? 1.5 : 1,
          ),
          boxShadow: isWindowOpen
              ? [
                  BoxShadow(
                    color: _C.crimson.withOpacity(0.08 * _borderAnim.value),
                    blurRadius: 24,
                    spreadRadius: 2,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: child,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header row ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isWindowOpen ? _C.crimsonGlow : _C.elevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isWindowOpen
                          ? _C.crimsonBorder
                          : _C.border.withOpacity(0.5),
                    ),
                  ),
                  child: const Center(
                    child: Text('⚡', style: TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Quick Match',
                            style: TextStyle(
                              color: _C.text,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _LiveChip(isLive: isWindowOpen),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        isWindowOpen
                            ? '${activeWindow.name} window is open'
                            : 'Opens 3× daily — windows gated',
                        style: const TextStyle(
                          color: _C.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Divider(height: 1, thickness: 1, color: _C.divider),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isWindowOpen)
                  _TokenBar(tokens: qmTokens)
                else
                  _CountdownChip(label: _buildCountdownLabel()),

                const SizedBox(height: 14),

                _QMButton(
                  enabled: isWindowOpen && qmTokens > 0,
                  onTap:   widget.onStartMatchmaking,
                ),

                if (isWindowOpen && qmTokens == 0 && !qmAdTokenUsed) ...[
                  const SizedBox(height: 10),
                  _AdButton(
                    loading: _watchingAd,
                    onTap: _watchingAd
                        ? null
                        : () => _handleWatchAd(context),
                  ),
                ],

                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Live / closed chip ────────────────────────────────────────────────────────

class _LiveChip extends StatefulWidget {
  final bool isLive;
  const _LiveChip({required this.isLive});

  @override
  State<_LiveChip> createState() => _LiveChipState();
}

class _LiveChipState extends State<_LiveChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _blink;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _blink = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blink,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: widget.isLive ? _C.greenDim : _C.elevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: widget.isLive
                ? _C.green.withOpacity(0.45)
                : _C.border.withOpacity(0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isLive)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _C.green.withOpacity(_blink.value),
                  ),
                ),
              ),
            Text(
              widget.isLive ? 'LIVE' : '○ CLOSED',
              style: TextStyle(
                color: widget.isLive ? _C.green : _C.textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Token bar ─────────────────────────────────────────────────────────────────

class _TokenBar extends StatelessWidget {
  final int tokens;
  const _TokenBar({required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: _C.crimsonGlow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _C.crimsonBorder),
      ),
      child: Row(
        children: [
          const Text('🎟', style: TextStyle(fontSize: 15)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$tokens ${tokens == 1 ? "token" : "tokens"} remaining',
                  style: const TextStyle(
                    color: _C.crimsonBright,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                // Segmented progress pills
                Row(
                  children: List.generate(3, (i) {
                    final filled = i < tokens;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: 4,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: filled
                                ? _C.crimson
                                : _C.crimson.withOpacity(0.18),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Countdown chip ────────────────────────────────────────────────────────────

class _CountdownChip extends StatelessWidget {
  final String label;
  const _CountdownChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: _C.elevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _C.border.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.timer_outlined, color: _C.textMuted, size: 15),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: _C.textSub,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Find a Match button ───────────────────────────────────────────────────────

class _QMButton extends StatelessWidget {
  final bool      enabled;
  final VoidCallback? onTap;
  const _QMButton({required this.enabled, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        opacity: enabled ? 1.0 : 0.30,
        duration: const Duration(milliseconds: 200),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            gradient: enabled ? _C.crimsonGrad : null,
            color:    enabled ? null : _C.elevated,
            borderRadius: BorderRadius.circular(14),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: _C.crimson.withOpacity(0.30),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.bolt_rounded,
                color: enabled ? Colors.white : _C.textMuted,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Find a Match',
                style: TextStyle(
                  color:       enabled ? Colors.white : _C.textMuted,
                  fontSize:    15,
                  fontWeight:  FontWeight.w900,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Watch-ad button ───────────────────────────────────────────────────────────

class _AdButton extends StatelessWidget {
  final bool loading;
  final VoidCallback? onTap;
  const _AdButton({required this.loading, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: _C.elevated,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: _C.border.withOpacity(0.6)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _C.textMuted,
                ),
              )
            else
              const Text('📺', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            Text(
              loading ? 'Loading ad…' : 'Watch ad for extra token',
              style: const TextStyle(
                color:      _C.textMuted,
                fontSize:   12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// ── Hub sub-widgets ────────────────────────────────────────────────────────────
// =============================================================================

// ── Arena banner ──────────────────────────────────────────────────────────────

class _ArenaBanner extends StatelessWidget {
  final Animation<double> pulseAnim;
  const _ArenaBanner({required this.pulseAnim});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseAnim,
      builder: (_, __) => Container(
        height: 176,
        decoration: BoxDecoration(
          gradient: _C.bannerGrad,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _C.crimson.withOpacity(0.10 + 0.22 * pulseAnim.value),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: _C.crimson.withOpacity(0.05 * pulseAnim.value),
              blurRadius: 28,
              spreadRadius: 4,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            children: [
              // Diagonal stripe texture
              Positioned.fill(
                child: CustomPaint(
                  painter: _StripePainter(
                    color: _C.crimson.withOpacity(0.025),
                  ),
                ),
              ),

              // Glow blobs
              Positioned(
                right: -30,
                top: -30,
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _C.crimson
                        .withOpacity(0.04 * pulseAnim.value),
                  ),
                ),
              ),
              Positioned(
                left: -20,
                bottom: -20,
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _C.sky.withOpacity(0.05),
                  ),
                ),
              ),

              // Content
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 20),
                child: Row(
                  children: [
                    _GlowIcon(
                      emoji:     '⚔️',
                      size:      84,
                      glowColor: _C.crimson,
                      pulse:     pulseAnim.value,
                    ),
                    const SizedBox(width: 20),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(
                              color: _C.crimsonGlow,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: _C.crimsonBorder,
                                width: 0.5,
                              ),
                            ),
                            child: const Text(
                              'ASYNC MULTIPLAYER',
                              style: TextStyle(
                                color:         _C.crimsonBright,
                                fontSize:      9,
                                fontWeight:    FontWeight.w800,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),

                          const Text(
                            'Challenge\nyour rival',
                            style: TextStyle(
                              color:         _C.text,
                              fontSize:      26,
                              fontWeight:    FontWeight.w900,
                              letterSpacing: -1.0,
                              height:        1.06,
                            ),
                          ),
                          const SizedBox(height: 10),

                          const Text(
                            'Play now · They play when ready\nWinner takes all',
                            style: TextStyle(
                              color:  _C.textMuted,
                              fontSize: 12,
                              height:   1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Glowing icon bubble ───────────────────────────────────────────────────────

class _GlowIcon extends StatelessWidget {
  final String emoji;
  final double size;
  final Color  glowColor;
  final double pulse;

  const _GlowIcon({
    required this.emoji,
    required this.size,
    required this.glowColor,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer glow
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: glowColor.withOpacity(0.06 * pulse),
            ),
          ),
          // Inner ring
          Container(
            width: size * 0.70,
            height: size * 0.70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  glowColor.withOpacity(0.16),
                  glowColor.withOpacity(0.06),
                ],
              ),
              border: Border.all(
                color: glowColor.withOpacity(0.18 + 0.28 * pulse),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text(
                emoji,
                style: TextStyle(fontSize: size * 0.38),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── How-it-works strip ────────────────────────────────────────────────────────

class _HowItWorksStrip extends StatelessWidget {
  const _HowItWorksStrip();

  static const _steps = [
    (num: '1', emoji: '🎮', label: 'You play\nfirst',   color: _C.crimson),
    (num: '2', emoji: '📤', label: 'Share\nyour code',  color: _C.sky),
    (num: '3', emoji: '🏆', label: 'Best score\nwins',  color: _C.green),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _C.border.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          for (int i = 0; i < _steps.length; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(height: 1, color: _C.divider),
              ),
            _StepBadge(
              number: _steps[i].num,
              emoji:  _steps[i].emoji,
              label:  _steps[i].label,
              accent: _steps[i].color,
            ),
          ],
        ],
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  final String number;
  final String emoji;
  final String label;
  final Color  accent;

  const _StepBadge({
    required this.number,
    required this.emoji,
    required this.label,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: accent.withOpacity(0.28),
                ),
              ),
              child: Center(
                child: Text(emoji, style: const TextStyle(fontSize: 22)),
              ),
            ),
            Positioned(
              top: -5,
              right: -5,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: accent.withOpacity(0.4),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    number,
                    style: const TextStyle(
                      color:      Colors.white,
                      fontSize:   9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color:     _C.textMuted,
            fontSize:  10,
            height:    1.35,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ── Action card (Create / Join) ───────────────────────────────────────────────

class _ActionCard extends StatefulWidget {
  final String   emoji;
  final String   title;
  final String   subtitle;
  final Gradient gradient;
  final Color    glowColor;
  final VoidCallback onTap;

  const _ActionCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.gradient,
    required this.glowColor,
    required this.onTap,
  });

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleCtrl;
  late Animation<double>   _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.96).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnim,
      child: GestureDetector(
        onTapDown:  (_) => _scaleCtrl.forward(),
        onTapUp:    (_) { _scaleCtrl.reverse(); widget.onTap(); },
        onTapCancel:()  => _scaleCtrl.reverse(),
        child: Container(
          decoration: BoxDecoration(
            color: _C.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: widget.glowColor.withOpacity(0.28),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Gradient header
              Container(
                height: 92,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      widget.glowColor.withOpacity(0.20),
                      widget.glowColor.withOpacity(0.06),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(17),
                  ),
                ),
                child: Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: widget.gradient,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: widget.glowColor.withOpacity(0.35),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        widget.emoji,
                        style: const TextStyle(fontSize: 24),
                      ),
                    ),
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            style: TextStyle(
                              color:         widget.glowColor,
                              fontSize:      15,
                              fontWeight:    FontWeight.w900,
                              letterSpacing: -0.3,
                              height:        1.15,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          color: widget.glowColor.withOpacity(0.50),
                          size: 11,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      widget.subtitle,
                      style: const TextStyle(
                        color:    _C.textMuted,
                        fontSize: 11,
                        height:   1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Payout rules card ─────────────────────────────────────────────────────────

class _RulesCard extends StatelessWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _C.border.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _C.elevated,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: _C.border.withOpacity(0.5)),
                  ),
                  child: const Center(
                    child: Text('⚖️', style: TextStyle(fontSize: 15)),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Payout Rules',
                  style: TextStyle(
                    color:         _C.text,
                    fontSize:      15,
                    fontWeight:    FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: _C.elevated,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _C.border.withOpacity(0.5)),
                  ),
                  child: const Text(
                    '5% platform fee',
                    style: TextStyle(
                      color:      _C.textMuted,
                      fontSize:   10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Divider(height: 1, thickness: 1, color: _C.divider),

          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Column(
              children: [
                _RuleRow(
                  emoji:          '🏆',
                  label:          'WIN',
                  labelColor:     const Color(0xFF4ADE80),
                  labelBg:        const Color(0xFF052E16),
                  accentColor:    const Color(0xFF4ADE80),
                  detail:         "Your stake + 80% of opponent's",
                  highlight:      '1.8×',
                  highlightColor: const Color(0xFF4ADE80),
                ),
                const SizedBox(height: 8),
                _RuleRow(
                  emoji:          '🤝',
                  label:          'DRAW',
                  labelColor:     const Color(0xFFFBBF24),
                  labelBg:        const Color(0xFF3D1900),
                  accentColor:    const Color(0xFFFBBF24),
                  detail:         'Both stakes refunded minus 5% fee',
                  highlight:      '~0.95×',
                  highlightColor: const Color(0xFFFBBF24),
                ),
                const SizedBox(height: 8),
                _RuleRow(
                  emoji:          '💀',
                  label:          'LOSE',
                  labelColor:     const Color(0xFFFB7185),
                  labelBg:        const Color(0xFF3D0011),
                  accentColor:    const Color(0xFFFB7185),
                  detail:         'Your stake goes to your opponent',
                  highlight:      '0×',
                  highlightColor: const Color(0xFFFB7185),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
            child: Row(
              children: const [
                Icon(Icons.timer_outlined, color: _C.textMuted, size: 12),
                SizedBox(width: 6),
                Text(
                  'Unclaimed challenges expire after 48 hours',
                  style: TextStyle(color: _C.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  final String emoji;
  final String label;
  final Color  labelColor;
  final Color  labelBg;
  final Color  accentColor;
  final String detail;
  final String highlight;
  final Color  highlightColor;

  const _RuleRow({
    required this.emoji,
    required this.label,
    required this.labelColor,
    required this.labelBg,
    required this.accentColor,
    required this.detail,
    required this.highlight,
    required this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: labelBg.withOpacity(0.35),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: labelColor.withOpacity(0.18), width: 1),
      ),
      child: Row(
        children: [
          // Left accent strip
          Container(
            width: 3,
            height: 28,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),

          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: labelBg,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              label,
              style: TextStyle(
                color:         labelColor,
                fontSize:      9,
                fontWeight:    FontWeight.w900,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(width: 8),

          Expanded(
            child: Text(
              detail,
              style: const TextStyle(
                color:    _C.textSub,
                fontSize: 12,
                height:   1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),

          Text(
            highlight,
            style: TextStyle(
              color:      highlightColor,
              fontSize:   14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ── Active Challenges Section ─────────────────────────────────────────────────
// =============================================================================

class _ActiveChallengesSection extends StatefulWidget {
  const _ActiveChallengesSection();

  @override
  State<_ActiveChallengesSection> createState() =>
      _ActiveChallengesSectionState();
}

class _ActiveChallengesSectionState extends State<_ActiveChallengesSection> {
  static const _activeStatuses = [
    'waiting',
    'opponent_joined',
    'creator_submitted',
    'opponent_submitted',
  ];

  StreamSubscription<QuerySnapshot>? _creatorSub;
  StreamSubscription<QuerySnapshot>? _opponentSub;

  List<QueryDocumentSnapshot> _creatorDocs  = [];
  List<QueryDocumentSnapshot> _opponentDocs = [];
  bool _loading = true;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _setupStreams();
  }

  void _setupStreams() {
    final uid = _uid;
    if (uid == null) {
      setState(() => _loading = false);
      return;
    }

    final db = FirebaseFirestore.instance;

    _creatorSub = db
        .collection('challenges')
        .where('creatorUid', isEqualTo: uid)
        .where('status', whereIn: _activeStatuses)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _creatorDocs = snap.docs;
        _loading     = false;
      });
    });

    _opponentSub = db
        .collection('challenges')
        .where('opponentUid', isEqualTo: uid)
        .where('status', whereIn: _activeStatuses)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _opponentDocs = snap.docs;
        _loading      = false;
      });
    });
  }

  @override
  void dispose() {
    _creatorSub?.cancel();
    _opponentSub?.cancel();
    super.dispose();
  }

  List<QueryDocumentSnapshot> get _merged {
    final seen   = <String>{};
    final result = <QueryDocumentSnapshot>[];
    for (final doc in [..._creatorDocs, ..._opponentDocs]) {
      if (seen.add(doc.id)) result.add(doc);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final challenges = _merged;
    if (challenges.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 12),
          child: Row(
            children: [
              const Text(
                'Active Challenges',
                style: TextStyle(
                  color:         _C.text,
                  fontSize:      15,
                  fontWeight:    FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _C.crimsonGlow,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _C.crimsonBorder),
                ),
                child: Text(
                  '${challenges.length}',
                  style: const TextStyle(
                    color:      _C.crimsonBright,
                    fontSize:   11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Spacer(),
              const Text(
                'See all',
                style: TextStyle(
                  color:      _C.sky,
                  fontSize:   12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        for (final doc in challenges)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ActiveChallengeCard(doc: doc),
          ),

        const SizedBox(height: 8),
      ],
    );
  }
}

// ── Single active challenge card ──────────────────────────────────────────────

class _ActiveChallengeCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _ActiveChallengeCard({required this.doc});

  PageRoute _slide(Widget page) => PageRouteBuilder(
        pageBuilder: (_, a, __) => page,
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 350),
      );

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final uid  = FirebaseAuth.instance.currentUser?.uid ?? '';

    final animeTitle       = data['animeTitle']       as String? ?? 'Unknown Anime';
    final status           = data['status']           as String? ?? '';
    final isQuickMatch     = data['isQuickMatch']     as bool?   ?? false;
    final creatorUid       = data['creatorUid']       as String? ?? '';
    final creatorUsername  = data['creatorUsername']  as String? ?? 'You';
    final opponentUsername = data['opponentUsername'] as String? ?? '—';
    final stakeAmount      = data['stakeAmount']      as int?    ?? 0;
    final questionIds      =
        (data['questionIds'] as List<dynamic>?)?.cast<String>() ?? [];
    final challengeId      = doc.id;
    final isCreator        = creatorUid == uid;

    final creatorScore  = data['creatorScore'];
    final opponentScore = data['opponentScore'];

    String statusLabel;
    bool   needsAction = false;

    if (isQuickMatch) {
      final hasPlayed = isCreator
          ? creatorScore != null
          : opponentScore != null;
      if (hasPlayed) {
        statusLabel = 'Waiting for opponent…';
      } else {
        statusLabel = 'Quick Match — play now!';
        needsAction = true;
      }
    } else {
      switch (status) {
        case 'waiting':
          statusLabel = isCreator
              ? 'Waiting for opponent to join'
              : 'Pending';
        case 'opponent_joined':
          if (isCreator) {
            statusLabel = creatorScore != null
                ? 'You played — waiting for opponent'
                : 'Opponent joined — play now!';
            needsAction = creatorScore == null;
          } else {
            statusLabel = opponentScore != null
                ? 'You played — waiting for creator'
                : 'Creator played — your turn!';
            needsAction = opponentScore == null;
          }
        case 'creator_submitted':
          if (isCreator) {
            statusLabel = 'Waiting for opponent to play';
          } else {
            statusLabel = 'Creator played — your turn!';
            needsAction = true;
          }
        case 'opponent_submitted':
          if (!isCreator) {
            statusLabel = 'Waiting for creator to play';
          } else {
            statusLabel = 'Opponent played — your turn!';
            needsAction = true;
          }
        default:
          statusLabel = status;
      }
    }

    final opponentName = isCreator ? opponentUsername : creatorUsername;
    final accentColor  = isQuickMatch ? _C.crimson : _C.sky;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: needsAction
              ? _C.crimson.withOpacity(0.45)
              : _C.border.withOpacity(0.50),
          width: needsAction ? 1.5 : 1,
        ),
        boxShadow: needsAction
            ? [
                BoxShadow(
                  color: _C.crimson.withOpacity(0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          // Match type icon
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: accentColor.withOpacity(0.30),
              ),
            ),
            child: Center(
              child: Text(
                isQuickMatch ? '⚡' : '⚔️',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Info column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  animeTitle,
                  style: const TextStyle(
                    color:      _C.text,
                    fontSize:   13,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  'vs $opponentName',
                  style: const TextStyle(color: _C.textMuted, fontSize: 11),
                ),
                const SizedBox(height: 4),
                // Status chip
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: needsAction
                        ? _C.crimson.withOpacity(0.14)
                        : _C.elevated,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: needsAction
                          ? _C.crimson.withOpacity(0.35)
                          : _C.border.withOpacity(0.4),
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color:      needsAction ? _C.crimsonBright : _C.textMuted,
                      fontSize:   10,
                      fontWeight: needsAction
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
                if (!isQuickMatch && stakeAmount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '🪙 $stakeAmount AC staked',
                    style: const TextStyle(
                        color: _C.textMuted, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Right action
          if (status == 'waiting' && isCreator && !isQuickMatch)
            _CopyCodeButton(code: challengeId)
          else if (needsAction && questionIds.isNotEmpty)
            _PlayNowButton(
              onTap: () => Navigator.push(
                context,
                _slide(
                  QuestionsPage(
                    mode:         QuizMode.asyncChallenge,
                    questionIds:  questionIds,
                    challengeId:  challengeId,
                    isCreator:    isCreator,
                    isQuickMatch: isQuickMatch,
                    isGhost:      false,
                    opponentName: opponentName,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Tap-to-copy challenge code ────────────────────────────────────────────────

class _CopyCodeButton extends StatelessWidget {
  final String code;
  const _CopyCodeButton({required this.code});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: code));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Challenge code copied!'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _C.elevated,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: _C.border.withOpacity(0.65)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              code,
              style: const TextStyle(
                color:         _C.text,
                fontSize:      13,
                fontWeight:    FontWeight.w900,
                letterSpacing: 2.5,
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              'tap to copy',
              style: TextStyle(color: _C.textMuted, fontSize: 9),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Play Now action button ────────────────────────────────────────────────────

class _PlayNowButton extends StatelessWidget {
  final VoidCallback onTap;
  const _PlayNowButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          gradient: _C.crimsonGrad,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: _C.crimson.withOpacity(0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Text(
          'Play',
          style: TextStyle(
            color:      Colors.white,
            fontSize:   13,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}