import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/ad_service.dart';
import '../quiz/questions.dart';
import '../quiz/solo_summary_page.dart';

const int _kQuestionCount = 10;

class QuestionsPage extends StatefulWidget {
  final List<String> selectedTitles;
  const QuestionsPage({super.key, required this.selectedTitles});

  @override
  State<QuestionsPage> createState() => _QuestionsPageState();
}

class _QuestionsPageState extends State<QuestionsPage>
    with SingleTickerProviderStateMixin {
  List<AnimeQuestion> _questions = [];
  bool _loadingQuestions = true;
  String? _errorMsg;

  int _qIndex = 0;
  int _selectedOption = -1;
  int _timerSeconds = 10;
  int _correctCount = 0;
  bool _showResult = false;
  bool _isNavigating = false;
  bool _quitDialogOpen = false;
  DateTime? _questionStartTime; // for 1.5s answer floor

  late List<Set<int>> _eliminatedOptions;
  late List<int> _hintPresses;

  Timer? _timer;

  late AnimationController _slideCtrl;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..forward();

    _slideAnim = Tween<Offset>(
      begin: const Offset(0.08, 0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut),
    );

    _loadQuestions();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _slideCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadQuestions() async {
    try {
      final all = await FirestoreService.instance
          .fetchQuestionsForTitles(widget.selectedTitles);

      all.shuffle(Random());

      if (!mounted) return;

      setState(() {
        _questions = all.take(_kQuestionCount).toList();
        _loadingQuestions = false;
        _errorMsg = null;
        _eliminatedOptions = List.generate(_questions.length, (_) => {});
        _hintPresses = List.filled(_questions.length, 0);
        _qIndex = 0;
        _selectedOption = -1;
        _timerSeconds = 10;
        _correctCount = 0;
        _showResult = false;
        _isNavigating = false;
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

  void _selectOption(int index) {
    if (_showResult || _isNavigating) return;

    // ── 1.5 s bot-block floor ────────────────────────────────────────────────
    final elapsed = _questionStartTime == null
        ? 9999
        : DateTime.now().difference(_questionStartTime!).inMilliseconds;
    if (elapsed < 1500) return; // silently ignore taps that arrive too fast

    final correct = _questions[_qIndex].correctAnswerIndex;

    setState(() {
      _selectedOption = index;
      _showResult = true;
      if (index == correct) _correctCount++;
    });

    _timer?.cancel();

    if (index == correct) {
      context.read<UserDataProvider>().addScore(10);
      context.read<UserDataProvider>().addWeeklyPoints(10);
    }

    Future.delayed(const Duration(milliseconds: 800), _moveNext);
  }

  void _moveNext() {
    if (!mounted || _isNavigating) return;

    _slideCtrl.reset();

    if (_qIndex < _questions.length - 1) {
      setState(() {
        _qIndex++;
        _selectedOption = -1;
        _showResult = false;
        _timerSeconds = 10;
      });

      _questionStartTime = DateTime.now();
      _startTimer();
      _slideCtrl.forward();
    } else {
      _isNavigating = true;
      _timer?.cancel();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, a, __) => FadeTransition(
              opacity: a,
              child: SoloSummaryPage(
                correctCount:   _correctCount,
                totalQuestions: _questions.length,
                selectedTitles: widget.selectedTitles,
              ),
            ),
            transitionDuration: const Duration(milliseconds: 400),
          ),
        );
      });
    }
  }

  Future<void> _useHint() async {
    if (_isNavigating || _qIndex >= _questions.length) return;
    if (_hintPresses[_qIndex] >= 1) return;

    final userData = context.read<UserDataProvider>();

    // No hints — offer rewarded ad
    if (userData.hints <= 0) {
      final shown = await AdService.instance.showRewarded(
        onRewarded: () async {
          await userData.addHint();
          await userData.addWeeklyPoints(30);
          if (mounted) _applyHint(); // use the earned hint immediately
        },
      );
      if (!shown && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Ad not ready yet — try again in a moment.')),
        );
      }
      return;
    }

    await userData.deductHint();
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
      _hintPresses[_qIndex]++;
    });
  }

  void _confirmQuit() {
    if (_quitDialogOpen || _isNavigating) return;

    _quitDialogOpen = true;
    _timer?.cancel();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Quit Quiz?',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'Your progress will be lost.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
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
            child: const Text(
              'Quit',
              style: TextStyle(color: AppColors.wrong),
            ),
          ),
        ],
      ),
    ).whenComplete(() {
      _quitDialogOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hints = context.watch<UserDataProvider>().hints;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop || _isNavigating) return;
        _confirmQuit();
      },
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: _loadingQuestions
            ? Container(
                decoration: AppDecorations.heroBg,
                child: const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              )
            : _errorMsg != null
                ? _buildErrorState()
                : _questions.isEmpty
                    ? _buildEmptyState()
                    : Container(
                        decoration: AppDecorations.heroBg,
                        child: SafeArea(
                          child: Column(
                            children: [
                              _buildHeader(hints),
                              Expanded(
                                child: SlideTransition(
                                  position: _slideAnim,
                                  child: FadeTransition(
                                    opacity: _slideCtrl,
                                    child: _buildQuestionCard(),
                                  ),
                                ),
                              ),
                              _buildOptions(),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Container(
      decoration: AppDecorations.heroBg,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_rounded,
                    color: AppColors.wrong, size: 64),
                const SizedBox(height: 16),
                Text(
                  _errorMsg!,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 15,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                GradientButton(
                  label: 'Try Again',
                  icon: Icons.refresh_rounded,
                  onTap: () {
                    setState(() {
                      _loadingQuestions = true;
                      _errorMsg = null;
                      _isNavigating = false;
                    });
                    _loadQuestions();
                  },
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Go Back',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      decoration: AppDecorations.heroBg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.quiz_rounded,
                color: AppColors.textMuted, size: 64),
            const SizedBox(height: 16),
            const Text(
              'No questions found',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(int hints) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Question ${_qIndex + 1} of ${_questions.length}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_qIndex + 1) / _questions.length,
                    backgroundColor: AppColors.divider,
                    valueColor:
                        const AlwaysStoppedAnimation(AppColors.primary),
                    minHeight: 4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          TimerRing(seconds: _timerSeconds),
          const SizedBox(width: 12),
          _HintButton(
            count: hints,
            used: _hintPresses.isNotEmpty && _hintPresses[_qIndex] >= 1,
            onTap: _useHint,
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: GlassCard(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _questions[_qIndex].animeTitle.toUpperCase(),
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _questions[_qIndex].question,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOptions() {
    final q = _questions[_qIndex];
    final correct = q.correctAnswerIndex;
    final elim = _eliminatedOptions[_qIndex];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: List.generate(q.options.length, (i) {
          if (elim.contains(i)) return const SizedBox(height: 58);

          Color border = AppColors.divider;
          Color bg = AppColors.surface;
          Color text = AppColors.textPrimary;

          if (_showResult) {
            if (i == correct) {
              border = AppColors.correct;
              bg = AppColors.correct.withOpacity(0.12);
              text = AppColors.correct;
            } else if (i == _selectedOption) {
              border = AppColors.wrong;
              bg = AppColors.wrong.withOpacity(0.12);
              text = AppColors.wrong;
            }
          } else if (i == _selectedOption) {
            border = AppColors.secondary;
            bg = AppColors.secondary.withOpacity(0.12);
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border, width: 1.5),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _selectOption(i),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        _Badge(index: i, color: border),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            q.options[i],
                            style: TextStyle(
                              color: text,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_showResult && i == correct)
                          const Icon(Icons.check_circle,
                              color: AppColors.correct, size: 20),
                        if (_showResult && i == _selectedOption && i != correct)
                          const Icon(Icons.cancel,
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

class _Badge extends StatelessWidget {
  final int index;
  final Color color;

  const _Badge({required this.index, required this.color});

  static const _letters = ['A', 'B', 'C', 'D'];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.5),
      ),
      child: Center(
        child: Text(
          index < _letters.length ? _letters[index] : '${index + 1}',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _HintButton extends StatelessWidget {
  final int count;
  final bool used;
  final VoidCallback onTap;

  const _HintButton({
    required this.count,
    required this.used,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final on = count > 0 && !used;

    return GestureDetector(
      onTap: on ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: on ? AppColors.accent.withOpacity(0.15) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? AppColors.accent : AppColors.divider),
        ),
        child: Row(
          children: [
            Icon(Icons.lightbulb_outline_rounded,
                color: on ? AppColors.accent : AppColors.textMuted, size: 18),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: TextStyle(
                color: on ? AppColors.accent : AppColors.textMuted,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}