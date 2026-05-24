// lib/features/multiplayer/challenge_quiz_page.dart
//
// Replaces multiplayer_page.dart entirely.
// All opponent-simulation code is removed.
// Receives pre-loaded questions; saves score to Firestore when done;
// navigates to ChallengeResultPage.

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import '../../core/providers/user_data_provider.dart';
import '../quiz/questions.dart';
import 'models/challenge_model.dart';
import 'challenge_result_page.dart';

const int _kQuestions = 10;
const int _kTimerSecs = 10;

class ChallengeQuizPage extends StatefulWidget {
  final ChallengeModel      challenge;
  final List<AnimeQuestion> questions;
  final bool                isCreator;

  const ChallengeQuizPage({
    super.key,
    required this.challenge,
    required this.questions,
    required this.isCreator,
  });

  @override
  State<ChallengeQuizPage> createState() => _ChallengeQuizPageState();
}

class _ChallengeQuizPageState extends State<ChallengeQuizPage>
    with SingleTickerProviderStateMixin {
  // ── Quiz state ───────────────────────────────────────────────────────────────
  int  _qIndex         = 0;
  int  _selectedOption = -1;
  int  _timerSeconds   = _kTimerSecs;
  int  _playerScore    = 0;
  bool _waitingNext    = false;
  bool _showResult     = false;
  bool _saving         = false;

  // ── FIX: Navigation guard ────────────────────────────────────────────────────
  // Prevents _finishQuiz from being called more than once if setState triggers
  // an extra rebuild while the Firestore transaction is in flight.
  bool _hasFinished = false;

  late List<Set<int>> _eliminatedOptions;
  late List<int>      _userAnswers;

  // ── Animation ────────────────────────────────────────────────────────────────
  late AnimationController _slideCtrl;
  late Animation<Offset>   _slideAnim;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 350),
    )..forward();
    _slideAnim = Tween<Offset>(
            begin: const Offset(0.08, 0), end: Offset.zero)
        .animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut));

    _eliminatedOptions =
        List.generate(widget.questions.length, (_) => <int>{});
    _userAnswers = List.filled(widget.questions.length, -1);

    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _slideCtrl.dispose();
    super.dispose();
  }

  // ── Timer ─────────────────────────────────────────────────────────────────
  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_timerSeconds <= 0) {
        _timer?.cancel();
        _onTimeout();
      } else {
        setState(() => _timerSeconds--);
      }
    });
  }

  void _onTimeout() {
    if (!mounted) return;
    setState(() {
      _showResult  = true;
      _waitingNext = true;
    });
    Future.delayed(const Duration(milliseconds: 1200), _moveNext);
  }

  // ── Answering ─────────────────────────────────────────────────────────────
  void _selectAnswer(int index) {
    if (_waitingNext || _showResult) return;
    _timer?.cancel();

    final correct = widget.questions[_qIndex].correctAnswerIndex;
    setState(() {
      _selectedOption       = index;
      _userAnswers[_qIndex] = index;
      _showResult           = true;
      _waitingNext          = true;
      if (index == correct) _playerScore++;
    });

    if (index == correct) {
      // Use read (not watch) in a callback — this is the correct pattern.
      context.read<UserDataProvider>().addWeeklyPoints(10);
    }

    Future.delayed(const Duration(milliseconds: 1300), _moveNext);
  }

  void _moveNext() {
    if (!mounted) return;
    _slideCtrl.reset();

    if (_qIndex < widget.questions.length - 1) {
      setState(() {
        _waitingNext    = false;
        _showResult     = false;
        _qIndex++;
        _selectedOption = -1;
        _timerSeconds   = _kTimerSecs;
      });
      _startTimer();
      _slideCtrl.forward();
    } else {
      _finishQuiz();
    }
  }

  // ── Finish ────────────────────────────────────────────────────────────────
  Future<void> _finishQuiz() async {
    // FIX: Guard prevents _finishQuiz being entered twice (e.g. if _onTimeout
    // and a delayed _moveNext both fire near-simultaneously on the last Q).
    if (_hasFinished) return;
    _hasFinished = true;

    _timer?.cancel();
    if (mounted) setState(() => _saving = true);

    try {
      final outcome = await FirestoreService.instance.saveScoreAndMaybeResolve(
        challengeId: widget.challenge.challengeId,
        score:       _playerScore,
        isCreator:   widget.isCreator,
      );

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          // FIX: page in pageBuilder, transition in transitionsBuilder.
          pageBuilder: (_, __, ___) => ChallengeResultPage(
            challengeId:     widget.challenge.challengeId,
            challenge:       widget.challenge,
            isCreator:       widget.isCreator,
            myScore:         _playerScore,
            resolvedOutcome: outcome,
          ),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    } catch (e) {
      // Allow retry by resetting the guard.
      _hasFinished = false;
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Error saving score: ${e.toString().replaceFirst('Exception: ', '')}'),
          backgroundColor: AppColors.wrong,
          action: SnackBarAction(
            label:    'Retry',
            onPressed: _finishQuiz,
            textColor: Colors.white,
          ),
        ),
      );
    }
  }

  // ── Hint ──────────────────────────────────────────────────────────────────
  Future<void> _useHint() async {
    final elim = _eliminatedOptions[_qIndex];
    if (elim.isNotEmpty) return; // already used hint on this question

    // Use read in a callback — correct pattern.
    final userData = context.read<UserDataProvider>();
    if (userData.hints <= 0) return;

    final correct = widget.questions[_qIndex].correctAnswerIndex;
    final wrong   = List.generate(
            widget.questions[_qIndex].options.length, (i) => i)
        ..removeWhere((i) => i == correct || elim.contains(i));

    if (wrong.isEmpty) return;

    await userData.deductHint();
    if (!mounted) return;
    setState(() {
      _eliminatedOptions[_qIndex].add(wrong[Random().nextInt(wrong.length)]);
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  // FIX: All context.watch calls are at the TOP of build, never inside helper
  // methods. Calling context.watch inside _buildQuestionCard or _buildOptions
  // (which are invoked from build) is technically allowed but creates confusing
  // dependency tracking and was causing extra rebuilds. Centralising them here
  // makes the dependency graph explicit and eliminates any possibility of a
  // watch being called in a non-build execution path.
  @override
  Widget build(BuildContext context) {
    // Read all provider values once, at the top.
    final hints = context.watch<UserDataProvider>().hints;

    final q        = widget.questions[_qIndex];
    final elapsed  = _kTimerSecs - _timerSeconds;
    final progress = elapsed / _kTimerSecs;

    // FIX: _saving now shows a Stack-based overlay instead of returning a
    // completely different widget tree. Previously, returning _SavingScreen()
    // (a bare Scaffold) when _saving=true swapped out the entire widget tree
    // mid-frame, removing the PopScope and confusing the Navigator's internal
    // route bookkeeping. The Stack overlay keeps the same widget tree intact.
    return PopScope(
      canPop: false, // prevent accidental back-press mid-quiz
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: AppColors.surfaceDim,
            body: Container(
              decoration: AppDecorations.heroBg,
              child: SafeArea(
                child: Column(
                  children: [
                    // ── Top bar ─────────────────────────────────────────────
                    _buildHeader(hints),

                    // ── Timer bar ───────────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.0, end: progress),
                        duration: const Duration(milliseconds: 300),
                        builder: (_, value, __) => ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value:           1 - value,
                            minHeight:       6,
                            backgroundColor: AppColors.surface,
                            valueColor: AlwaysStoppedAnimation(
                              _timerSeconds <= 3
                                  ? AppColors.wrong
                                  : _timerSeconds <= 6
                                      ? AppColors.secondary
                                      : AppColors.primary,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Question card ───────────────────────────────────────
                    Expanded(
                      child: SlideTransition(
                        position: _slideAnim,
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              const SizedBox(height: 16),
                              _buildQuestionCard(q, hints),
                              const SizedBox(height: 12),
                              _buildOptions(q),
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Saving overlay (keeps widget tree intact) ─────────────────────
          if (_saving)
            const _SavingOverlay(),
        ],
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _buildHeader(int hints) {
    final opponentName = widget.isCreator
        ? (widget.challenge.opponentUsername ?? 'Waiting...')
        : widget.challenge.creatorUsername;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: _ScoreLabel(
              label: 'You',
              score: _playerScore,
            ),
          ),

          // Timer bubble
          Container(
            width:  64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface,
              border: Border.all(
                color: _timerSeconds <= 3
                    ? AppColors.wrong
                    : AppColors.divider,
                width: 2,
              ),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Text(
                '$_timerSeconds',
                key:   ValueKey(_timerSeconds),
                style: TextStyle(
                  color: _timerSeconds <= 3
                      ? AppColors.wrong
                      : AppColors.textPrimary,
                  fontSize:   22,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),

          // Opponent placeholder
          Expanded(
            child: _ScoreLabel(
              label: opponentName,
              score: null,
              right: true,
            ),
          ),
        ],
      ),
    );
  }

  // ── Question Card ─────────────────────────────────────────────────────────
  // FIX: hints passed as a parameter instead of calling context.watch here.
  Widget _buildQuestionCard(AnimeQuestion q, int hints) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GlassCard(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Q ${_qIndex + 1} / ${widget.questions.length}',
                  style: const TextStyle(
                    color:      AppColors.textMuted,
                    fontSize:   13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _HintBtn(
                  count:  hints,
                  active: !_showResult &&
                      _eliminatedOptions[_qIndex].isEmpty &&
                      hints > 0,
                  onTap:  _useHint,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              q.question,
              style: const TextStyle(
                color:      AppColors.textPrimary,
                fontSize:   18,
                fontWeight: FontWeight.w700,
                height:     1.45,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ── Options ───────────────────────────────────────────────────────────────
  Widget _buildOptions(AnimeQuestion q) {
    final correct = q.correctAnswerIndex;
    final elim    = _eliminatedOptions[_qIndex];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: List.generate(q.options.length, (i) {
          if (elim.contains(i)) return const SizedBox(height: 56);

          Color border = AppColors.divider;
          Color bg     = AppColors.surface;
          Color text   = AppColors.textPrimary;

          if (_showResult || _waitingNext) {
            if (i == correct) {
              border = AppColors.correct;
              bg     = AppColors.correct.withOpacity(0.12);
              text   = AppColors.correct;
            } else if (i == _selectedOption && i != correct) {
              border = AppColors.wrong;
              bg     = AppColors.wrong.withOpacity(0.12);
              text   = AppColors.wrong;
            }
          } else if (i == _selectedOption) {
            border = AppColors.secondary;
            bg     = AppColors.secondary.withOpacity(0.12);
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color:        bg,
                borderRadius: BorderRadius.circular(16),
                border:       Border.all(color: border, width: 1.5),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: (_waitingNext || _showResult)
                      ? null
                      : () => _selectAnswer(i),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 14),
                    child: Row(
                      children: [
                        _Badge(index: i, color: border),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            q.options[i],
                            style: TextStyle(
                              color:      text,
                              fontSize:   15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_showResult && i == correct)
                          const Icon(Icons.check_circle_rounded,
                              color: AppColors.correct, size: 20),
                        if (_showResult &&
                            i == _selectedOption &&
                            i != correct)
                          const Icon(Icons.cancel_rounded,
                              color: AppColors.wrong, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─── Saving Overlay ───────────────────────────────────────────────────────────
// FIX: This is now a Stack overlay, NOT a replacement Scaffold.
// Previously _SavingScreen returned a bare Scaffold which replaced the entire
// widget tree (including PopScope) when _saving=true. This caused Navigator's
// route bookkeeping to lose track of the PopScope, sometimes preventing the
// subsequent Navigator.pushReplacement from completing correctly.
//
// Using a Stack overlay keeps the widget tree identical — only the visual
// layer changes, so all route/context references remain stable.
class _SavingOverlay extends StatelessWidget {
  const _SavingOverlay();

  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.surfaceDim.withOpacity(0.92),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.primary),
              SizedBox(height: 20),
              Text(
                'Saving your score…',
                style: TextStyle(
                  color:      AppColors.textPrimary,
                  fontSize:   18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Hold tight!',
                style: TextStyle(color: AppColors.textMuted, fontSize: 14),
              ),
            ],
          ),
        ),
      );
}

// ─── Reusable Quiz Widgets ────────────────────────────────────────────────────

class _ScoreLabel extends StatelessWidget {
  final String  label;
  final int?    score;
  final bool    right;
  const _ScoreLabel({required this.label, required this.score, this.right = false});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment:
            right ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color:      AppColors.textMuted,
              fontSize:   11,
              fontWeight: FontWeight.w600,
            ),
            maxLines:  1,
            overflow:  TextOverflow.ellipsis,
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Text(
              score != null ? '$score' : '?',
              key:   ValueKey(score),
              style: TextStyle(
                color:      score != null
                    ? AppColors.textPrimary
                    : AppColors.textMuted,
                fontSize:   22,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      );
}

class _Badge extends StatelessWidget {
  final int   index;
  final Color color;
  const _Badge({required this.index, required this.color});
  static const _l = ['A', 'B', 'C', 'D'];

  @override
  Widget build(BuildContext context) => Container(
        width:  32,
        height: 32,
        decoration: BoxDecoration(
          color:  color.withOpacity(0.15),
          shape:  BoxShape.circle,
          border: Border.all(color: color, width: 1.5),
        ),
        child: Center(
          child: Text(
            index < _l.length ? _l[index] : '${index + 1}',
            style: TextStyle(
                color:      color,
                fontWeight: FontWeight.w800,
                fontSize:   13),
          ),
        ),
      );
}

class _HintBtn extends StatelessWidget {
  final int          count;
  final bool         active;
  final VoidCallback onTap;
  const _HintBtn({
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: active ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color:        active
                ? AppColors.accent.withOpacity(0.15)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(
                color: active ? AppColors.accent : AppColors.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lightbulb_outline_rounded,
                color:  active ? AppColors.accent : AppColors.textMuted,
                size:   16,
              ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  color:      active ? AppColors.accent : AppColors.textMuted,
                  fontWeight: FontWeight.w700,
                  fontSize:   13,
                ),
              ),
            ],
          ),
        ),
      );
}