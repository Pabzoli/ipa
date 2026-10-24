// =============================================================================
// questions_page.dart
// =============================================================================
// Updated:
//   • Replaced TimerSection with TimerWithPowerup.
//   • Removed PowerupBar – the power‑up is now beside the timer.
//   • Removed unused import of powerup_bar.dart.
//   • Removed Container with AppDecorations.heroBg to match the flat dark
//     background used in HomePage and MultiplayerHubPage.
//   • In quiz mode, onInsufficientCoins now shows a simple SnackBar instead
//     of the full bottom sheet, keeping the UI lightweight during gameplay.
//   • Quick Match unified with Rival/Code: onQuickMatchComplete and the
//     QuickMatchResultPage import/route have been removed. Quick Match
//     completions (ghost or real) now fire onChallengeComplete and land on
//     the same ChallengeResultPage as every other challenge type.
//   • onChallengeComplete no longer branches on role either — creator and
//     opponent both go straight to ChallengeResultPage.
// All other functionality unchanged.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_page_route.dart';
import 'quiz_controller.dart';
import 'solo_summary_page.dart';
import '../multiplayer/challenge_result_page.dart';
import '../../core/widgets/quiz_header.dart';
import '../../core/widgets/progress_segments.dart';
// TimerSection replaced by TimerWithPowerup
import '../../core/widgets/timer_section.dart';
import '../../core/widgets/question_card.dart';
import '../../core/widgets/options_list.dart';
// powerup_bar.dart no longer needed here
import '../../core/widgets/quiz_loading_skeleton.dart';
import '../../core/widgets/quiz_error_view.dart';

export '../../core/widgets/insufficient_coins_sheet.dart';
export 'quiz_controller.dart' show QuizMode;

// ── Page ───────────────────────────────────────────────────────────────────

class QuestionsPage extends StatefulWidget {
  final QuizMode mode;
  final List<String> selectedTitles;
  final String soloDifficulty;
  final List<String>? questionIds;
  final String? challengeId;
  final bool isCreator;

  final bool isQuickMatch;
  final bool isGhost;
  final String opponentName;
  final bool isGauntlet;

  /// Prepaid Gauntlet entry ticket from `enterDailyGauntlet` (null for the
  /// free daily attempt). The entry fee was already deducted before this page
  /// was entered; the ticket is consumed at submit WITHOUT a second charge.
  final String? gauntletTicketId;


  const QuestionsPage({
    super.key,
    this.mode = QuizMode.solo,
    this.selectedTitles = const [],
    this.soloDifficulty = 'easy',
    this.questionIds,
    this.challengeId,
    this.isCreator = true,
    this.isQuickMatch = false,
    this.isGhost = false,
    this.opponentName = '',
    this.isGauntlet = false,
    this.gauntletTicketId,
  });

  @override
  State<QuestionsPage> createState() => _QuestionsPageState();
}

class _QuestionsPageState extends State<QuestionsPage>
    with SingleTickerProviderStateMixin {
  late QuizController _controller;
  late AnimationController _slideCtrl;
  late Animation<Offset> _slideAnim;

  bool _quitDialogOpen = false;

  @override
  void initState() {
    super.initState();

    AdService.instance.setQuizActive(true);
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    )..forward();

    _slideAnim = Tween<Offset>(
      begin: const Offset(0.06, 0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _slideCtrl,
        curve: Curves.easeInOutCubicEmphasized,
      ),
    );

    _controller = QuizController(
      mode: widget.mode,
      selectedTitles: widget.selectedTitles,
      soloDifficulty: widget.soloDifficulty,
      questionIds: widget.questionIds,
      challengeId: widget.challengeId,
      isCreator: widget.isCreator,
      isQuickMatch: widget.isQuickMatch,
      isGauntlet: widget.isGauntlet,
      gauntletTicketId: widget.gauntletTicketId,
      userDataProvider: context.read<UserDataProvider>(),

      onQuestionAdvance: (_) {
        _slideCtrl.reset();
        _slideCtrl.forward();
      },

      onSoloComplete: (correct, total, coins, wp,
          {isGauntlet = false,
          streak = 0,
          gauntletPerQuestionWP = const [],
          achievementCoins = 0}) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          AppPageRoute(
            builder: (_) => SoloSummaryPage(
              correctCount: correct,
              totalQuestions: total,
              selectedTitles: widget.selectedTitles,
              soloDifficulty: widget.soloDifficulty,
              coinsEarned: coins,
              wpEarned: wp,
              achievementCoins: achievementCoins,
              isGauntlet: isGauntlet,
              gauntletStreak: streak,
              gauntletPerQuestionWP: gauntletPerQuestionWP,
            ),
          ),
        );
      },

      // Fires for every async challenge completion — Rival, Code, and Quick
      // Match (ghost or real) alike. ALL roles land on the Result page.
      //
      // This used to branch on role: the creator was sent back to
      // ChallengeLobbyPage while the opponent went to the Result page. That
      // split had no basis in challenge type — it hit Rival, Code and Quick
      // Match identically — and it stranded the creator, because a lobby
      // entered with showHomeButton: true suppresses both of its own
      // "waiting for opponent" branches, leaving a live screen with no
      // status text, no play button and no way to the result.
      //
      // The Result page is already built to be the one destination for both
      // halves of the race: it renders a live "waiting" state when the
      // current user has submitted but the opponent has not, shows a LIVE
      // chip, uses "—" for the missing score, and fires its full reveal
      // animation from didUpdateWidget the moment `outcome` lands. So the
      // creator gets a progress screen instead of a dead end, and the
      // challenge is over the moment resolution lands — no manual tap
      // through an intermediate lobby.
      onChallengeComplete: (cId, isCreator, correct) {
        if (!mounted) return;
        Navigator.pushAndRemoveUntil(
          context,
          AppPageRoute(builder: (_) => ChallengeResultPage(challengeId: cId)),
          (r) => r.isFirst,
        );
      },

      // ── In‑quiz insufficient coins → simple snackbar ──────────────────
      onInsufficientCoins: (needed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Not enough Anime Coins (need $needed 🪙)'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            backgroundColor: AppColors.wrong.withValues(alpha: 0.9),
          ),
        );
        return Future.value(); // no waiting needed
      },

      onError: (msg, {VoidCallback? onRetry}) {
        if (!mounted) return;
        // Replace any queued retryable snackbar so repeated failures never
        // stack a stale "Retry" action on top of the current one.
        if (onRetry != null) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: AppColors.wrong,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            // Retryable failures keep the snackbar up long enough to act on.
            duration: onRetry == null
                ? const Duration(seconds: 4)
                : const Duration(seconds: 8),
            action: onRetry == null
                ? null
                : SnackBarAction(
                    label: 'Retry',
                    textColor: Colors.white,
                    onPressed: onRetry,
                  ),
          ),
        );
      },
    );

    _controller.loadQuestions();
  }

  @override
  void dispose() {
    AdService.instance.setQuizActive(false);
    _slideCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _confirmQuit() {
    // A live challenge cannot be quit — but once the final submission has
    // failed there is no way to finish in place (the last answer is locked and
    // there is no submit control), so let the player leave. The server settles
    // the abandoned challenge as a forfeit, exactly as if they had walked away.
    if (widget.mode == QuizMode.asyncChallenge && !_controller.submitFailed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You cannot quit an active challenge!'),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_quitDialogOpen || _controller.isNavigating) return;

    _quitDialogOpen = true;

    showAppDialog<void>(
      context,
      barrierDismissible: false,
      builder: (ctx) => AppDialog(
        icon: Icons.help_outline_rounded,
        title: 'Quit Quiz?',
        content: widget.isGauntlet && widget.gauntletTicketId != null
            ? 'Your progress will be lost.\n\n'
                  'The retry fee is non-refundable.'
            : 'Your progress will be lost.',
        actions: [
          AppButton(
            label: 'Keep Playing',
            variant: AppButtonVariant.text,
            onPressed: () {
              Navigator.pop(ctx);
              _quitDialogOpen = false;
            },
          ),
          AppButton(
            label: 'Quit',
            variant: AppButtonVariant.text,
            color: AppColors.wrong,
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    ).whenComplete(() => _quitDialogOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<QuizController>.value(
      value: _controller,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (_, __) => _confirmQuit(),
        child: Scaffold(
          backgroundColor: AppColors.surfaceDim,
          body: SafeArea(
            bottom: false,
            child: _QuizBody(
              slideAnim: _slideAnim,
              onQuit: _confirmQuit,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Quiz body (unchanged) ───────────────────────────────────────────────────

class _QuizBody extends StatelessWidget {
  final Animation<Offset> slideAnim;
  final VoidCallback onQuit;

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
          SizedBox(height: 4.h),
          const QuizProgressSegments(),
          // Use the new TimerWithPowerup (which includes the power‑up button)
          const TimerWithPowerup(),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewPadding.bottom + 24,
              ),
              child: Column(
                children: [
                  const QuestionCardWidget(),
                  OptionsListWidget(key: ValueKey(ctrl.qIndex)),
                ],
              ),
            ),
          ),
          // PowerupBar removed – button is now beside the timer
        ],
      ),
    );
  }
}
