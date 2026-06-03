// =============================================================================
// questions_page.dart
// =============================================================================
// What changed and why:
//
//  ARCHITECTURE
//  • All 400+ lines of mixed state/logic/UI split into QuizController +
//    focused sub-widgets. This page is now ~130 lines.
//  • QuizController is provided to the subtree via ChangeNotifierProvider.value
//    so every child widget can read it without prop-drilling.
//  • Navigation callbacks are closures defined here, keeping this page as the
//    single source of navigation authority.
//
//  QUICK MATCH (Stage 12)
//  • Three new optional params: isQuickMatch, isGhost, opponentName.
//    These are forwarded to QuizController and gate which completion path fires.
//  • onQuickMatchComplete navigates to QuickMatchResultPage (pushAndRemoveUntil
//    back to root) for both ghost and real-opponent quick matches.
//  • onChallengeComplete (non-quick async challenges) is completely unchanged.
//
//  ANIMATIONS
//  • Slide curve upgraded to Curves.easeInOutCubicEmphasized (Material 3).
//  • Options stagger in independently per question (see options_list.dart).
//
//  QUIT DIALOG
//  • Extracted into _QuitDialog widget (<80 lines). Uses FilledButton.tonal
//    for the destructive action instead of a plain TextButton.
//
//  SAFE AREA
//  • SafeArea(bottom: false) so PowerupBar can handle its own bottom inset
//    via MediaQuery.of(context).viewPadding.bottom — prevents double-padding.
//
//  SNACKBAR
//  • Floating behaviour + rounded corners for all error snackbars.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/insufficient_coins_sheet.dart';
import 'quiz_controller.dart';
import 'solo_summary_page.dart';
import '../multiplayer/challenge_lobby_page.dart';
import '../multiplayer/challenge_result_page.dart';
import '../multiplayer/quick_match_result_page.dart';
import '../../core/widgets/quiz_header.dart';
import '../../core/widgets/progress_segments.dart';
import '../../core/widgets/timer_section.dart';
import '../../core/widgets/question_card.dart';
import '../../core/widgets/options_list.dart';
import '../../core/widgets/powerup_bar.dart';
import '../../core/widgets/quiz_loading_skeleton.dart';
import '../../core/widgets/quiz_error_view.dart';

export '../../core/widgets/insufficient_coins_sheet.dart';
export 'quiz_controller.dart' show QuizMode;

// ── Page ───────────────────────────────────────────────────────────────────

class QuestionsPage extends StatefulWidget {
  final QuizMode      mode;
  final List<String>  selectedTitles;
  final List<String>? questionIds;
  final String?       challengeId;
  final bool          isCreator;

  /// When true, challenge completion calls [submitQuickMatchResult] CF and
  /// navigates to [QuickMatchResultPage] instead of the lobby / result page.
  final bool   isQuickMatch;

  /// Mirrors the isGhost flag from [joinMatchmakingQueue]. Forwarded to
  /// [QuizController] and ultimately surfaced on [QuickMatchResultPage].
  final bool   isGhost;

  /// Display name of the opponent (real player or ghost username). Forwarded
  /// to [QuizController] and shown on [QuickMatchResultPage].
  final String opponentName;
  final bool   isDailyChallenge;

  const QuestionsPage({
    super.key,
    this.mode           = QuizMode.solo,
    this.selectedTitles = const [],
    this.questionIds,
    this.challengeId,
    this.isCreator      = true,
    this.isQuickMatch   = false,
    this.isGhost        = false,
    this.opponentName   = '',
    this.isDailyChallenge = false,
  });

  @override
  State<QuestionsPage> createState() => _QuestionsPageState();
}

class _QuestionsPageState extends State<QuestionsPage>
    with SingleTickerProviderStateMixin {
  late QuizController     _controller;
  late AnimationController _slideCtrl;
  late Animation<Offset>   _slideAnim;

  bool _quitDialogOpen = false;

  @override
  void initState() {
    super.initState();

    _slideCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 380),
    )..forward();

    _slideAnim = Tween<Offset>(
      begin: const Offset(0.06, 0),
      end:   Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _slideCtrl,
        curve:  Curves.easeInOutCubicEmphasized,
      ),
    );

    _controller = QuizController(
      mode:             widget.mode,
      selectedTitles:   widget.selectedTitles,
      questionIds:      widget.questionIds,
      challengeId:      widget.challengeId,
      isCreator:        widget.isCreator,
      isQuickMatch:     widget.isQuickMatch,
      isGhost:          widget.isGhost,
      opponentName:     widget.opponentName,
      isDailyChallenge:  widget.isDailyChallenge,
      userDataProvider: context.read<UserDataProvider>(),

      onQuestionAdvance: (_) {
        _slideCtrl.reset();
        _slideCtrl.forward();
      },

      onSoloComplete: (correct, total, coins, wp) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, animation, __) => FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve:  Curves.easeOut,
              ),
              child: SoloSummaryPage(
                correctCount:   correct,
                totalQuestions: total,
                selectedTitles: widget.selectedTitles,
                coinsEarned:    coins,
                wpEarned:       wp,
                isDailyChallenge: _controller.isDailyChallenge,
              ),
            ),
            transitionDuration: const Duration(milliseconds: 400),
          ),
        );
      },

      // ── Non-quick async challenge (unchanged) ──────────────────────────────
      onChallengeComplete: (cId, isCreator, correct) {
        if (!mounted) return;
        final route = isCreator
            ? MaterialPageRoute(
                builder: (_) => ChallengeLobbyPage(challengeId: cId),
              )
            : MaterialPageRoute(
                builder: (_) => ChallengeResultPage(challengeId: cId),
              );
        Navigator.pushAndRemoveUntil(context, route, (r) => r.isFirst);
      },

      // ── Quick Match result ─────────────────────────────────────────────────
      // Fires for both ghost and real-opponent quick matches.
      // Ghost:        full result immediately (wpEarned / acEarned / opponentScore set).
      // Real opponent: wpEarned / acEarned = 0 (deferred to trigger);
      //               opponentScore = 0 (opponent hasn't played yet).
      onQuickMatchComplete: (
        correct,
        total,
        opponentScore,
        wpEarned,
        acEarned,
        isGhost,
        opponentName,
      ) {
        if (!mounted) return;
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (_) => QuickMatchResultPage(
              localCorrect:   correct,
              opponentScore:  opponentScore,
              totalQuestions: total,
              opponentName:   opponentName,
              coinsEarned:    acEarned,
              wpEarned:       wpEarned,
              isGhost:        isGhost,
              // ── Ghost-pool replenishment ─────────────────────────────────
              // selectedTitles always has exactly one entry on the QM path.
              animeTitle:  widget.selectedTitles.first,
              // widget.questionIds is set from the joinMatchmakingQueue CF
              // response before QuestionsPage is pushed, so it is never null
              // here.  The fallback reads IDs from the controller in case the
              // page is ever reached via a code path that skips pre-fetching.
              questionIds: widget.questionIds ??
                  _controller.questions.map((q) => q.id).toList(),
              answers:     _controller.selectedAnswers,
            ),
          ),
          (r) => r.isFirst,
        );
      },

      onInsufficientCoins: (needed) async {
        if (mounted) await showInsufficientCoinsSheet(context, needed: needed);
      },

      onError: (msg) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:         Text(msg),
            backgroundColor: AppColors.wrong,
            behavior:        SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      },
    );

    _controller.loadQuestions();
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  // ── Quit ───────────────────────────────────────────────────────────────────

  void _confirmQuit() {
    if (widget.mode == QuizMode.asyncChallenge) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:         Text('You cannot quit an active challenge!'),
          backgroundColor: AppColors.wrong,
          behavior:        SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_quitDialogOpen || _controller.isNavigating) return;

    _quitDialogOpen = true;

    showDialog<void>(
      context:            context,
      barrierDismissible: false,
      builder: (ctx) => _QuitDialog(
        onStay: () {
          Navigator.pop(ctx);
          _quitDialogOpen = false;
        },
        onQuit: () {
          Navigator.pop(ctx);
          Navigator.pop(context);
        },
      ),
    ).whenComplete(() => _quitDialogOpen = false);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<QuizController>.value(
      value: _controller,
      child: PopScope(
        canPop: false,
        onPopInvoked: (_) => _confirmQuit(),
        child: Scaffold(
          backgroundColor: AppColors.surfaceDim,
          body: Container(
            decoration: AppDecorations.heroBg,
            child: SafeArea(
              bottom: false,
              child: _QuizBody(
                slideAnim: _slideAnim,
                onQuit:    _confirmQuit,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Quiz body ─────────────────────────────────────────────────────────────

class _QuizBody extends StatelessWidget {
  final Animation<Offset> slideAnim;
  final VoidCallback       onQuit;

  const _QuizBody({required this.slideAnim, required this.onQuit});

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();

    if (ctrl.isLoading) {
      return const QuizLoadingSkeletonView();
    }

    if (ctrl.errorMsg != null) {
      return QuizErrorView(
        message: ctrl.errorMsg!,
        onRetry: ctrl.loadQuestions,
      );
    }

    if (ctrl.questions.isEmpty) {
      return QuizErrorView(
        message: 'No questions found for the selected anime.',
        onRetry: ctrl.loadQuestions,
      );
    }

    return SlideTransition(
      position: slideAnim,
      child: Column(
        children: [
          QuizHeader(onQuit: onQuit),
          const SizedBox(height: 4),
          const QuizProgressSegments(),
          const TimerSection(),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewPadding.bottom + 24,
              ),
              child: Column(
                children: [
                  const QuestionCardWidget(),
                  // ValueKey re-creates OptionsListWidget on each question so
                  // stagger animations replay from scratch.
                  OptionsListWidget(key: ValueKey(ctrl.qIndex)),
                ],
              ),
            ),
          ),
          const PowerupBar(),
        ],
      ),
    );
  }
}

// ── Quit dialog ───────────────────────────────────────────────────────────

class _QuitDialog extends StatelessWidget {
  final VoidCallback onStay;
  final VoidCallback onQuit;

  const _QuitDialog({required this.onStay, required this.onQuit});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: const Text(
        'Quit Quiz?',
        style: TextStyle(
          color:      AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: const Text(
        'Your progress will be lost.',
        style: TextStyle(color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: onStay,
          child:     const Text('Keep Playing'),
        ),
        FilledButton.tonal(
          onPressed: onQuit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.wrong.withOpacity(0.15),
            foregroundColor: AppColors.wrong,
          ),
          child: const Text('Quit'),
        ),
      ],
    );
  }
}