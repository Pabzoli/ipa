import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/insufficient_coins_sheet.dart';
import 'questions.dart';
import 'solo_summary_page.dart';
import '../multiplayer/challenge_lobby_page.dart';
import '../multiplayer/challenge_result_page.dart';

export '../../core/widgets/insufficient_coins_sheet.dart';

enum QuizMode { solo, asyncChallenge }

const int _kQuestionCount = 10;

/// Hint cost per use (AC).  Max 2 hints per quiz session.
const int _kHintCost = 15;

/// Timer-pause cost (AC).  Adds +5 seconds.  Once per question.
const int _kTimerPauseCost = 20;

/// Coins awarded for completing a solo quiz.
const int _kQuizCoinReward = 8;

class QuestionsPage extends StatefulWidget {
  final QuizMode      mode;
  final List<String> selectedTitles; // used in solo mode
  final List<String>? questionIds;   // used in asyncChallenge mode
  final String?       challengeId;   // used in asyncChallenge mode
  final bool          isCreator;     // asyncChallenge: true=creator, false=opponent

  const QuestionsPage({
    super.key,
    this.mode           = QuizMode.solo,
    this.selectedTitles = const [],
    this.questionIds,
    this.challengeId,
    this.isCreator      = true,
  });

  @override
  State<QuestionsPage> createState() => _QuestionsPageState();
}

class _QuestionsPageState extends State<QuestionsPage>
    with SingleTickerProviderStateMixin {
  List<AnimeQuestion> _questions = [];
  bool _loadingQuestions = true;
  String? _errorMsg;

  int  _qIndex         = 0;
  int  _selectedOption = -1;
  int  _timerSeconds   = 10;
  int  _correctCount   = 0;
  bool _showResult     = false;
  bool _isNavigating   = false;
  bool _quitDialogOpen = false;
  DateTime? _questionStartTime;

  // ── Per-question state ─────────────────────────────────────────────────────
  late List<Set<int>> _eliminatedOptions;  // which wrong options are dimmed
  late List<bool>     _timerPauseUsed;     // whether +5 s was used this question

  // ── Session state (whole quiz) ────────────────────────────────────────────
  /// Total hints used in this quiz session. Capped at 2.
  int _sessionHintsUsed = 0;

  Timer? _timer;

  late AnimationController _slideCtrl;
  late Animation<Offset>   _slideAnim;

  @override
  void initState() {
    super.initState();

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..forward();

    _slideAnim = Tween<Offset>(
      begin: const Offset(0.08, 0),
      end:   Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut));

    _loadQuestions();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _slideCtrl.dispose();
    super.dispose();
  }

  // ── Question loading ───────────────────────────────────────────────────────

  Future<void> _loadQuestions() async {
    try {
      List<AnimeQuestion> all;
      if (widget.mode == QuizMode.asyncChallenge) {
        all = await FirestoreService.instance
            .fetchQuestionsByIds(widget.questionIds!);
      } else {
        all = await FirestoreService.instance
            .fetchQuestionsForTitles(widget.selectedTitles);
        all.shuffle(Random());
      }

      if (!mounted) return;

      final questions = all.take(_kQuestionCount).toList();

      setState(() {
        _questions         = questions;
        _loadingQuestions  = false;
        _errorMsg          = null;
        _eliminatedOptions = List.generate(questions.length, (_) => {});
        _timerPauseUsed    = List.filled(questions.length, false);
        _sessionHintsUsed  = 0;
        _qIndex            = 0;
        _selectedOption    = -1;
        _timerSeconds      = 10;
        _correctCount      = 0;
        _showResult        = false;
        _isNavigating      = false;
      });

      if (_questions.isNotEmpty) {
        _questionStartTime = DateTime.now();
        _startTimer();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingQuestions = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ── Timer ──────────────────────────────────────────────────────────────────

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _isNavigating) return;
      if (_timerSeconds == 0) {
        _timer?.cancel();
        _moveNext();
      } else {
        setState(() => _timerSeconds--);
      }
    });
  }

  // ── Answer selection ───────────────────────────────────────────────────────

  void _selectOption(int index) {
    if (_showResult || _isNavigating) return;

    // 1.5 s bot-block floor
    final elapsed = _questionStartTime == null
        ? 9999
        : DateTime.now().difference(_questionStartTime!).inMilliseconds;
    if (elapsed < 1500) return;

    final correct = _questions[_qIndex].correctAnswerIndex;

    setState(() {
      _selectedOption = index;
      _showResult     = true;
      if (index == correct) _correctCount++;
    });

    _timer?.cancel();

    if (index == correct) {
      if (widget.mode == QuizMode.solo) {
        context.read<UserDataProvider>().addScore(10);
      }
      context.read<UserDataProvider>().addWeeklyPoints(10);
    }

    Future.delayed(const Duration(milliseconds: 800), _moveNext);
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _moveNext() {
    if (!mounted || _isNavigating) return;

    _slideCtrl.reset();

    if (_qIndex < _questions.length - 1) {
      setState(() {
        _qIndex++;
        _selectedOption = -1;
        _showResult     = false;
        _timerSeconds   = 10;
      });

      _questionStartTime = DateTime.now();
      _startTimer();
      _slideCtrl.forward();
    } else {
      _isNavigating = true;
      _timer?.cancel();

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (widget.mode == QuizMode.asyncChallenge) {
          try {
            if (widget.isCreator) {
              await FirestoreService.instance
                  .submitCreatorScore(widget.challengeId!, _correctCount);
              if (!mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ChallengeLobbyPage(challengeId: widget.challengeId!),
                ),
                (route) => route.isFirst,
              );
            } else {
              await FirestoreService.instance
                  .submitOpponentScore(widget.challengeId!, _correctCount);
              if (!mounted) return;
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ChallengeResultPage(challengeId: widget.challengeId!),
                ),
                (route) => route.isFirst,
              );
            }
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content:         Text('Failed to save score: $e'),
                backgroundColor: AppColors.wrong,
              ),
            );
            setState(() => _isNavigating = false);
          }
        } else {
          // ── Solo quiz completion ──────────────────────────────────────────
          int coinsEarned = 0;
          try {
            final ud = context.read<UserDataProvider>();
            await ud.updateAnimeCoins(_kQuizCoinReward, 'earn_quiz');
            coinsEarned = _kQuizCoinReward;

            ud.claimReferralBonusIfEligible().catchError((e) {
              debugPrint('[QuestionsPage] referral claim error (ignored): $e');
            });
          } catch (e) {
            debugPrint('[QuestionsPage] coin award error (ignored): $e');
          }

          if (!mounted) return;

          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (_, a, __) => FadeTransition(
                opacity: a,
                child: SoloSummaryPage(
                  correctCount:   _correctCount,
                  totalQuestions: _questions.length,
                  selectedTitles: widget.selectedTitles,
                  coinsEarned:    coinsEarned,
                ),
              ),
              transitionDuration: const Duration(milliseconds: 400),
            ),
          );
        }
      });
    }
  }

  // ── SPEND SURFACE 1: Hint (15 AC, max 2 per session) ──────────────────────

  Future<void> _useHint() async {
    if (_isNavigating || _qIndex >= _questions.length) return;
    if (_sessionHintsUsed >= 2) return; // hard cap — button is already greyed

    final userData = context.read<UserDataProvider>();

    // Not enough coins — show the sheet, never hard-error.
    if (userData.animeCoins < _kHintCost) {
      if (mounted) {
        await showInsufficientCoinsSheet(context, needed: _kHintCost);
      }
      return;
    }

    try {
      await userData.updateAnimeCoins(-_kHintCost, 'spend_hint');
    } on InsufficientCoinsException {
      // Race condition: balance dropped between the check above and the
      // transaction. Show the sheet so the user can earn more.
      if (mounted) await showInsufficientCoinsSheet(context, needed: _kHintCost);
      return;
    } catch (e) {
      // Any other error (e.g. Firestore PERMISSION_DENIED, network failure).
      // Log it and show a generic snack — NOT the insufficient-coins sheet.
      debugPrint('[QuestionsPage] _useHint error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:         Text('Could not use hint — please try again. ($e)'),
            backgroundColor: AppColors.wrong,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    _applyHint();
  }

  void _applyHint() {
    if (_qIndex >= _questions.length) return;
    final q       = _questions[_qIndex];
    final correct = q.correctAnswerIndex;
    final elim    = _eliminatedOptions[_qIndex];

    final wrong = List.generate(q.options.length, (i) => i)
      ..removeWhere((i) => i == correct || elim.contains(i));

    if (wrong.isEmpty) return;

    setState(() {
      _eliminatedOptions[_qIndex].add(wrong[Random().nextInt(wrong.length)]);
      _sessionHintsUsed++; // track against the session cap
    });
  }

  // ── SPEND SURFACE 5: Timer Pause (20 AC, +5 s, once per question) ─────────

  Future<void> _useTimerPause() async {
    if (_isNavigating || _qIndex >= _questions.length) return;
    if (_timerPauseUsed[_qIndex]) return; // already used this question
    if (_showResult) return;               // answer already selected

    final userData = context.read<UserDataProvider>();

    if (userData.animeCoins < _kTimerPauseCost) {
      if (mounted) {
        await showInsufficientCoinsSheet(context, needed: _kTimerPauseCost);
      }
      return;
    }

    try {
      await userData.updateAnimeCoins(-_kTimerPauseCost, 'spend_timer');
    } on InsufficientCoinsException {
      if (mounted) await showInsufficientCoinsSheet(context, needed: _kTimerPauseCost);
      return;
    } catch (e) {
      debugPrint('[QuestionsPage] _useTimerPause error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:         Text('Could not pause timer — please try again. ($e)'),
            backgroundColor: AppColors.wrong,
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    // Pause, add 5 s, mark used, resume.
    _timer?.cancel();
    setState(() {
      _timerSeconds              += 5;
      _timerPauseUsed[_qIndex]  = true;
    });
    _startTimer();
  }

  // ── Quit ───────────────────────────────────────────────────────────────────

  void _confirmQuit() {
    if (widget.mode == QuizMode.asyncChallenge) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:         Text('You cannot quit an active challenge — finish the quiz!'),
          backgroundColor: AppColors.wrong,
        ),
      );
      return;
    }
    if (_quitDialogOpen || _isNavigating) return;

    _quitDialogOpen = true;
    _startTimer();

    showDialog(
      context:            context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Quit Quiz?',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('Your progress will be lost.',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _quitDialogOpen = false;
              if (!_showResult && !_isNavigating) _startTimer();
            },
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () {
              _isNavigating = true;
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('Quit',
                style: TextStyle(color: AppColors.wrong)),
          ),
        ],
      ),
    ).whenComplete(() => _quitDialogOpen = false);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final animeCoins = context.watch<UserDataProvider>().animeCoins;

    final showPauseBtn = !_loadingQuestions &&
        _questions.isNotEmpty &&
        _timerSeconds <= 5 &&
        !_showResult &&
        !_isNavigating &&
        _timerPauseUsed.isNotEmpty &&
        !_timerPauseUsed[_qIndex];

    return PopScope(
      canPop: false,
      onPopInvoked: (_) => _confirmQuit(),
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: _loadingQuestions
                ? _buildLoadingState()
                : _errorMsg != null
                    ? _ErrorState(message: _errorMsg!, onRetry: _loadQuestions)
                    : _questions.isEmpty
                        ? _ErrorState(
                            message:
                                'No questions found for the selected anime.',
                            onRetry: _loadQuestions)
                        : SlideTransition(
                            position: _slideAnim,
                            child: Column(
                              children: [
                                _buildHeader(animeCoins),
                                _buildProgressSegments(),
                                _buildTimerRow(),
                                Expanded(
                                  child: SingleChildScrollView(
                                    padding: const EdgeInsets.only(bottom: 24),
                                    child: Column(
                                      children: [
                                        _buildQuestionCard(),
                                        _buildOptions(),
                                      ],
                                    ),
                                  ),
                                ),
                                _buildBottomPowerupBar(
                                    animeCoins, showPauseBtn),
                              ],
                            ),
                          ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: AppColors.primary,
              strokeWidth: 3,
              strokeCap: StrokeCap.round,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Loading questions…',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  Widget _buildHeader(int animeCoins) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
      child: Row(
        children: [
          // Close button — minimal circle
          GestureDetector(
            onTap: _confirmQuit,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.divider, width: 1),
              ),
              child: const Icon(
                Icons.close_rounded,
                color: AppColors.textMuted,
                size: 18,
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Question counter — bold
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '${_qIndex + 1}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
                TextSpan(
                  text: ' / ${_questions.length}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          _CoinBalancePill(balance: animeCoins),
          const SizedBox(width: 8),
          _HintButton(
            coins: animeCoins,
            cost: _kHintCost,
            hintsUsed: _sessionHintsUsed,
            onTap: _useHint,
          ),
        ],
      ),
    );
  }

  // ── Segmented progress row ─────────────────────────────────────────────────

  Widget _buildProgressSegments() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: List.generate(_questions.length, (i) {
          final isCurrent = i == _qIndex;
          final isDone = i < _qIndex;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              height: isCurrent ? 5 : 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(99),
                color: isDone
                    ? AppColors.primary.withOpacity(0.7)
                    : isCurrent
                        ? AppColors.primary
                        : AppColors.divider,
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── Timer row — large centered countdown ──────────────────────────────────

  Widget _buildTimerRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TimerRing(seconds: _timerSeconds),
        ],
      ),
    );
  }

  // ── Bottom powerup bar ─────────────────────────────────────────────────────

  Widget _buildBottomPowerupBar(int animeCoins, bool showPauseBtn) {
    if (!showPauseBtn) return const SizedBox(height: 16);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Row(
        children: [
          Expanded(
            child: _TimerPauseButton(
              coins: animeCoins,
              cost: _kTimerPauseCost,
              onTap: _useTimerPause,
            ),
          ),
        ],
      ),
    );
  }

  // ── Question card ──────────────────────────────────────────────────────────

  Widget _buildQuestionCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: AppColors.primary.withOpacity(0.18),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: AppColors.primary.withOpacity(0.07),
              blurRadius: 40,
              spreadRadius: -4,
            ),
          ],
        ),
        child: Stack(
          children: [
            // Ghost question number watermark
            Positioned(
              top: -10,
              right: -4,
              child: Text(
                '${_qIndex + 1}',
                style: TextStyle(
                  color: AppColors.primary.withOpacity(0.06),
                  fontSize: 100,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Anime title chip
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.primary.withOpacity(0.2),
                        AppColors.primary.withOpacity(0.08),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppColors.primary.withOpacity(0.35), width: 1),
                  ),
                  child: Text(
                    _questions[_qIndex].animeTitle.toUpperCase(),
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.8,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  _questions[_qIndex].question,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    height: 1.5,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Options ────────────────────────────────────────────────────────────────

  Widget _buildOptions() {
    final q = _questions[_qIndex];
    final correct = q.correctAnswerIndex;
    final elim = _eliminatedOptions[_qIndex];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: List.generate(q.options.length, (i) {
          // ── Eliminated option: strikethrough ghost ──────────────────────
          if (elim.contains(i)) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Opacity(
                opacity: 0.22,
                child: IgnorePointer(
                  child: _OptionTile(
                    label: i < 4 ? ['A', 'B', 'C', 'D'][i] : '${i + 1}',
                    text: q.options[i],
                    border: AppColors.divider,
                    bg: AppColors.surface,
                    textColor: AppColors.textMuted,
                    badgeColor: AppColors.textMuted,
                    badgeFill: false,
                    strikethrough: true,
                    shadows: const [],
                    trailingIcon: null,
                  ),
                ),
              ),
            );
          }

          // ── State-dependent colors ──────────────────────────────────────
          Color border, bg, textColor, badgeColor;
          bool badgeFill = false;
          List<BoxShadow> shadows = [];
          Widget? trailingIcon;

          if (_showResult) {
            if (i == correct) {
              border = AppColors.correct;
              bg = AppColors.correct.withOpacity(0.13);
              textColor = AppColors.correct;
              badgeColor = AppColors.correct;
              badgeFill = true;
              trailingIcon = const Icon(Icons.check_circle_rounded,
                  color: AppColors.correct, size: 22);
              shadows = [
                BoxShadow(
                    color: AppColors.correct.withOpacity(0.2),
                    blurRadius: 20,
                    offset: const Offset(0, 4))
              ];
            } else if (i == _selectedOption) {
              border = AppColors.wrong;
              bg = AppColors.wrong.withOpacity(0.11);
              textColor = AppColors.wrong;
              badgeColor = AppColors.wrong;
              badgeFill = true;
              trailingIcon = const Icon(Icons.cancel_rounded,
                  color: AppColors.wrong, size: 22);
              shadows = [
                BoxShadow(
                    color: AppColors.wrong.withOpacity(0.15),
                    blurRadius: 14,
                    offset: const Offset(0, 3))
              ];
            } else {
              border = AppColors.divider.withOpacity(0.4);
              bg = AppColors.surface.withOpacity(0.35);
              textColor = AppColors.textMuted.withOpacity(0.5);
              badgeColor = AppColors.textMuted.withOpacity(0.4);
            }
          } else if (i == _selectedOption) {
            border = AppColors.secondary;
            bg = AppColors.secondary.withOpacity(0.1);
            textColor = AppColors.secondary;
            badgeColor = AppColors.secondary;
            badgeFill = true;
            shadows = [
              BoxShadow(
                  color: AppColors.secondary.withOpacity(0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 3))
            ];
          } else {
            border = AppColors.divider;
            bg = AppColors.surface;
            textColor = AppColors.textPrimary;
            badgeColor = AppColors.textSecondary;
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _OptionTile(
              label: i < 4 ? ['A', 'B', 'C', 'D'][i] : '${i + 1}',
              text: q.options[i],
              border: border,
              bg: bg,
              textColor: textColor,
              badgeColor: badgeColor,
              badgeFill: badgeFill,
              strikethrough: false,
              shadows: shadows,
              trailingIcon: trailingIcon,
              onTap: () => _selectOption(i),
            ),
          );
        }),
      ),
    );
  }
}

// ── Option tile ────────────────────────────────────────────────────────────

class _OptionTile extends StatelessWidget {
  final String label;
  final String text;
  final Color border;
  final Color bg;
  final Color textColor;
  final Color badgeColor;
  final bool badgeFill;
  final bool strikethrough;
  final List<BoxShadow> shadows;
  final Widget? trailingIcon;
  final VoidCallback? onTap;

  const _OptionTile({
    required this.label,
    required this.text,
    required this.border,
    required this.bg,
    required this.textColor,
    required this.badgeColor,
    required this.badgeFill,
    required this.strikethrough,
    required this.shadows,
    required this.trailingIcon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border, width: 1.5),
        boxShadow: shadows,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(19),
          splashColor: border.withOpacity(0.12),
          highlightColor: border.withOpacity(0.06),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            child: Row(
              children: [
                // Letter badge — sharp rounded rectangle
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: badgeFill
                        ? badgeColor.withOpacity(0.25)
                        : badgeColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                      color: badgeColor.withOpacity(badgeFill ? 0.6 : 0.3),
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: badgeColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      decoration: strikethrough
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      decorationColor: textColor,
                    ),
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: 10),
                  trailingIcon!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Error state ─────────────────────────────────────────────────────────────

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppColors.wrong.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppColors.wrong.withOpacity(0.25), width: 1.5),
                ),
                child: const Center(
                  child: Text('⚠️', style: TextStyle(fontSize: 32)),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                message,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 15,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              GradientButton(
                  label: 'Try Again',
                  icon: Icons.refresh_rounded,
                  onTap: onRetry),
            ],
          ),
        ),
      );
}

// ── Coin Balance Pill ─────────────────────────────────────────────────────
/// Always-visible gold pill showing the player's live anime coin balance.
/// Separate from the hint button so the two pieces of info are distinct.

class _CoinBalancePill extends StatelessWidget {
  final int balance;
  const _CoinBalancePill({required this.balance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFBBF24).withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFFFBBF24).withOpacity(0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🪙', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 5),
          Text(
            '$balance',
            style: const TextStyle(
              color: Color(0xFFFBBF24),
              fontWeight: FontWeight.w800,
              fontSize: 14,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Hint Button (SPEND SURFACE 1) ─────────────────────────────────────────
/// Shows how many hints remain this session (max 2) rather than the coin
/// balance, so the player can see at a glance what they have left.
/// The coin balance is displayed separately in [_CoinBalancePill].

class _HintButton extends StatelessWidget {
  final int coins;
  final int cost;
  final int hintsUsed;
  final VoidCallback onTap;

  const _HintButton({
    required this.coins,
    required this.cost,
    required this.hintsUsed,
    required this.onTap,
  });

  static const int _maxHints = 2;

  @override
  Widget build(BuildContext context) {
    final hintsLeft = _maxHints - hintsUsed;
    final exhausted = hintsLeft <= 0;
    final canAfford = coins >= cost;
    final active = !exhausted && canAfford;

    final accent = active ? AppColors.secondary : AppColors.textMuted;

    return Tooltip(
      message: exhausted
          ? 'No hints left this quiz'
          : !canAfford
              ? 'Need $cost 🪙'
              : 'Hint  −$cost 🪙  ($hintsLeft left)',
      child: GestureDetector(
        onTap: active ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? AppColors.secondary.withOpacity(0.1)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? AppColors.secondary.withOpacity(0.35)
                  : AppColors.divider,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lightbulb_rounded, color: accent, size: 15),
              const SizedBox(width: 5),
              Text(
                exhausted ? '0' : '$hintsLeft',
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  letterSpacing: -0.3,
                ),
              ),
              if (!exhausted) ...[
                const SizedBox(width: 4),
                Text(
                  '−${cost}🪙',
                  style: TextStyle(
                    color: accent.withOpacity(0.6),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Timer Pause Button (SPEND SURFACE 5) ──────────────────────────────────
/// Pulsing "+5s — 20🪙" button shown when the timer reaches 5 seconds.
/// Disappears after first use on a question.

class _TimerPauseButton extends StatefulWidget {
  final int coins;
  final int cost;
  final VoidCallback onTap;

  const _TimerPauseButton({
    required this.coins,
    required this.cost,
    required this.onTap,
  });

  @override
  State<_TimerPauseButton> createState() => _TimerPauseButtonState();
}

class _TimerPauseButtonState extends State<_TimerPauseButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.97, end: 1.03)
        .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canAfford = widget.coins >= widget.cost;

    return ScaleTransition(
      scale: _scale,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: canAfford
                ? AppColors.secondary.withOpacity(0.14)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: canAfford
                  ? AppColors.secondary.withOpacity(0.55)
                  : AppColors.divider,
              width: 1.5,
            ),
            boxShadow: canAfford
                ? [
                    BoxShadow(
                      color: AppColors.secondary.withOpacity(0.22),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    )
                  ]
                : [],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.hourglass_top_rounded,
                color: canAfford ? AppColors.secondary : AppColors.textMuted,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                '+5 seconds  ·  ${widget.cost}🪙',
                style: TextStyle(
                  color: canAfford ? AppColors.secondary : AppColors.textMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}