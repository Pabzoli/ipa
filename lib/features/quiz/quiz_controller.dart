// =============================================================================
// quiz_controller.dart
// =============================================================================
// Design decisions:
//  • ChangeNotifier owns ALL mutable quiz state — zero business logic in build().
//  • Navigation and UI side-effects (sheets, snackbars) are handled via
//    callbacks injected at construction time, so the controller never touches
//    BuildContext directly.
//  • UserDataProvider is injected once at construction; same object reference
//    throughout the controller's lifetime (safe with Provider).
//  • _disposed flag guards every async gap against post-dispose notifyListeners.
//  • _spendCoins() centralises the coin-deduction + InsufficientCoins guard so
//    useHint() and useTimerPause() share identical error-handling behaviour.
//  • Timer expiry on the last question sets isNavigating = true and calls the
//    appropriate completion callback via Future.microtask, giving any in-flight
//    rebuilds time to finish before navigation is triggered.
//  • _selectedAnswers / _answerTimings are appended at the top of _advance()
//    (before any state is reset) so every question — answered or timed-out —
//    is captured. Timing is seconds-remaining when the answer locked in; -1
//    for a timeout where no selection was made.
//  • Solo completion calls the submitQuizAnswers Cloud Function for server-side
//    validation. The CF is the ONLY valid write path for totalScore,
//    weeklyPoints, and animeCoins (all three are blacklisted in Firestore
//    security rules for direct client writes). On CF failure the controller
//    retries up to _kCfMaxAttempts times with a short back-off delay, then
//    surfaces a retryable error snackbar and resets _isNavigating so the user
//    can try again — it never silently awards nothing via a doomed Firestore
//    write.
//
//  QUICK MATCH ADDITIONS (Stage 13 — unified with Rival/Code):
//  • isQuickMatch flag routes challenge completion through
//    submitQuickMatchResult CF instead of submitCreatorScore /
//    submitOpponentScore.
//  • Ghost matches resolve synchronously (the CF returns the full,
//    already-credited result) and real 2-player matches resolve
//    asynchronously via the resolveChallengeOutcome trigger — but BOTH now
//    fire the same onChallengeComplete callback used by Rival/Code, so they
//    share the exact same live ChallengeResultPage flow (waiting state,
//    payout display, everything).
//    QuickMatchResultPage and the onQuickMatchComplete callback have been
//    removed entirely — there is no separate Quick Match result UI anymore.
//  • Every completed Quick Match (ghost or real) also fires-and-forgets a
//    saveGhostSession CF call so the ghost pool keeps growing from all
//    Quick Match play, not just ghost matches.
//  • Non-quick-match asyncChallenge path is completely unchanged.
//
// =============================================================================

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/play_integrity_service.dart';
import '../../core/constants/solo_economy.dart';
import '../../core/constants/blitz_economy.dart';
import 'questions.dart';

// ── Public constants (referenced by widget files) ──────────────────────────

enum QuizMode { solo, asyncChallenge, gauntlet }

const int kQuestionCount = 10;

// ── Gauntlet Blitz (90s time-attack) ─────────────────────────────────────────
// Answer as many questions as you can in [kBlitzSeconds] seconds, up to
// [kBlitzMaxQuestions] questions (difficulty ramp 10/10/10). Unanswered
// questions score nothing. Settlement routes through the submitRun CF
// (kind=gauntlet), which awards difficulty-based WP (5/8/12, raw-capped)
// and tiered gamble AC — there is no streak and no milestone.
// Hints and Timer Pause are disabled in Blitz (server rejects hints;
// the pause button is hidden).
const int kBlitzQuestionCount = kBlitzMaxQuestions;

/// Cost of a same-day Blitz retry, enforced atomically server-side inside
/// the enterDailyGauntlet transaction (the client never pre-deducts it).
/// Single-value alias kept for error fallbacks only — use blitz_economy
/// curves for all UI labels (see lib/core/constants/blitz_economy.dart).
const int kGauntletRetryCost = 40;

const int kHintCost = 10;

/// Timer Pause cost (20 AC): freezes the current question's countdown until
/// the player answers. Enforced server-side in the spendCoins CF
/// (type 'spend_timer', amount must equal 20).
const int kTimerPauseCost = 20;
const int kQuizCoinReward = 8;

/// Hints allowed per QUESTION, not per session: the allowance refreshes as the
/// player advances. Mirrors QUIZ_RUN_MAX_HINTS in functions/index.js (enforced
/// server-side per question by `useQuizHint`) — change both together.
const int kMaxHints = 2;
const int kTimerDuration = 10;

/// How many times [_submitToServer] will attempt the [submitQuizAnswers] CF
/// before giving up and surfacing a retryable error. Attempts are separated
/// by an exponential back-off starting at 1 s (1 s, 2 s, …).
const int _kCfMaxAttempts = 2;

/// Bridge used to invoke the final submission Cloud Function.
///
/// [name] is either `submitChallengeScore` or `submitQuickMatchResult` and
/// [payload] is the callable data map. Production leaves the controller's
/// `submitCaller` null, so the real [FirebaseFunctions] client is used; tests
/// inject a fake to drive the success / failure outcomes offline.
typedef QuizSubmitCaller = Future<Map<String, dynamic>> Function(
  String name,
  Map<String, dynamic> payload,
);

// =============================================================================

class QuizController extends ChangeNotifier {
  QuizController({
    required this.mode,
    required this.selectedTitles,
    this.soloDifficulty = 'easy',
    this.soloSessionId,
    this.questionIds,
    this.challengeId,
    this.isCreator = true,
    this.isQuickMatch = false,
    this.isGauntlet = false, // ← Gauntlet Blitz
    this.gauntletTicketId,
    this.gauntletRunId,
    QuizSubmitCaller? submitCaller,
    required UserDataProvider userDataProvider,
    required this.onQuestionAdvance,
    required this.onSoloComplete,
    required this.onChallengeComplete,
    required this.onInsufficientCoins,
    required this.onError,
  })  : _submitCaller = submitCaller,
        _ud = userDataProvider;

  // ── Config ─────────────────────────────────────────────────────────────────
  final QuizMode mode;
  final List<String> selectedTitles;

  /// Homepage solo difficulty ('easy' | 'medium' | 'hard').
  /// Selects the question mix (see kSoloDifficultyMixes) and the reward
  /// table applied server-side in submitQuizAnswers. Challenge / Blitz
  /// modes ignore it.
  final String soloDifficulty;

  /// Server-minted solo run id (`startSoloCooldowns` / the paid retry).
  ///
  /// `submitQuizAnswers` refuses a solo submission that does not match the
  /// user's active server session, and consumes it on the award — so two
  /// stacked sessions can never both be paid. Null for challenge and Blitz
  /// modes, which submit elsewhere.
  final String? soloSessionId;

  final List<String>? questionIds;
  final String? challengeId;
  final bool isCreator;

  /// When true, challenge completion routes through [submitQuickMatchResult]
  /// CF. Ghost and real matches both then fire [onChallengeComplete] — the
  /// same live ChallengeResultPage flow Rival/Code challenges use.
  final bool isQuickMatch;

  /// When true this is a Gauntlet Blitz session — up to 30 mixed-anime
  /// questions answered against a 90-second global clock. Completion routes
  /// through the submitRun CF (kind=gauntlet), which awards difficulty-based
  /// WP and the tiered gamble AC from its own answer key. Exposed as a public
  /// field so [QuestionsPage] can forward it to [SoloSummaryPage].
  final bool isGauntlet; // ← Gauntlet Blitz

  /// Prepaid entry ticket minted by `enterDailyGauntlet` (null for the free
  /// daily attempt). Forwarded to submitRun so the server consumes
  /// it WITHOUT charging again. The entry fee was already deducted before the
  /// quiz page was entered (non-refundable on quit).
  final String? gauntletTicketId;

  /// Server-minted Blitz run id returned by `enterDailyGauntlet` (runV2).
  /// The controller resolves the sanitized questions from it via getQuizRun.
  final String? gauntletRunId;

  final UserDataProvider _ud;

  /// Test seam for the final challenge / quick-match submission. Null in
  /// production, where [_invokeSubmitCallable] goes straight to
  /// [FirebaseFunctions].
  final QuizSubmitCaller? _submitCaller;

  // ── Callbacks ──────────────────────────────────────────────────────────────

  /// Fired when the question index increments. Parent resets slide animation.
  final void Function(int newIndex) onQuestionAdvance;

  /// Solo quiz finished. Parent navigates to SoloSummaryPage.
  ///
  /// [wpEarned] is the server-validated weekly-points total returned by the
  /// submitRun CF. This callback is only invoked on a successful CF response;
  /// on exhausted retries the controller surfaces an error instead.
  ///
  /// Blitz runs additionally report [answeredCount] (questions attempted
  /// before the clock ran out) and [gauntletPerQuestionWP] (weekly points
  /// earned per question position — 0 for a wrong or unanswered question,
  /// otherwise the difficulty WP). Only meaningful when [isGauntlet] is
  /// true; solo runs pass empty defaults.
  ///
  /// [achievementCoins] is the separately-returned `achievementAC` grant
  /// (0 when no tier was crossed). It is rendered with a distinct
  /// trophy/purple UI from base [coinsEarned] everywhere.
  final void Function(
    int correct,
    int total,
    int coinsEarned,
    int wpEarned, {
    bool isGauntlet,
    // Deprecated streak-era slot: callers pass 0, closures ignore it.
    int streak,
    int answeredCount,
    List<int> gauntletPerQuestionWP,
    int achievementCoins,
  }) onSoloComplete;

  /// Async challenge finished — quick match or not. The parent navigates to
  /// ChallengeResultPage for every role and every challenge type; the result
  /// page itself renders the live "waiting for opponent" state until the
  /// outcome lands.
  final void Function(String cId, bool isCreator, int correct)
      onChallengeComplete;

  /// Show InsufficientCoinsSheet. Awaitable so the controller can wait for
  /// the sheet to close before returning.
  final Future<void> Function(int needed) onInsufficientCoins;

  /// Show a SnackBar error message.
  ///
  /// [onRetry] is non-null for failures the player can retry in place (the
  /// final challenge / quick-match submission); the page renders it as the
  /// snackbar's "Retry" action.
  final void Function(String msg, {void Function()? onRetry}) onError;

  // ── Loading / error ────────────────────────────────────────────────────────
  bool _isLoading = true;
  String? _errorMsg;

  bool get isLoading => _isLoading;
  String? get errorMsg => _errorMsg;

  // ── Questions ──────────────────────────────────────────────────────────────
  List<AnimeQuestion> _questions = [];
  List<Set<int>> _eliminatedOpts = [];
  List<bool> _timerPauseUsed = [];

  List<AnimeQuestion> get questions => List.unmodifiable(_questions);
  int get totalQuestions => _questions.length;

  AnimeQuestion? get currentQuestion =>
      _questions.isNotEmpty && _qIndex < _questions.length
          ? _questions[_qIndex]
          : null;

  Set<int> get currentEliminated =>
      _qIndex < _eliminatedOpts.length ? _eliminatedOpts[_qIndex] : {};

  bool get currentTimerPauseUsed =>
      _qIndex < _timerPauseUsed.length && _timerPauseUsed[_qIndex];

  // ── Progress ───────────────────────────────────────────────────────────────
  int _qIndex = 0;
  int _selectedOption = -1;
  int _correctCount = 0;
  bool _showResult = false;
  bool _isNavigating = false;
  bool _disposed = false;

  /// True when the final score submission of an async challenge / quick match
  /// failed. The page exposes a "Retry" snackbar action while this is set and
  /// permits leaving through the normal quit flow (the server settles the
  /// abandoned match as a forfeit) instead of trapping the player here.
  bool _submitFailed = false;

  int get qIndex => _qIndex;
  int get selectedOption => _selectedOption;
  int get correctCount => _correctCount;
  bool get showResult => _showResult;
  bool get isNavigating => _isNavigating;
  bool get submitFailed => _submitFailed;

  // ── Answer history (submitted to CF at quiz completion) ────────────────────
  //
  // Both lists grow in lock-step: one entry per question, appended by
  // _advance() before state is reset. The CF uses these to validate the score
  // server-side rather than trusting the client-reported correctCount.
  //
  //  _selectedAnswers[i]  option index chosen by the player (0-based), or -1
  //                       if the question timed out without a selection.
  //  _answerTimings[i]    seconds remaining on the countdown when the answer
  //                       was locked in, or -1 for a timeout.

  List<int> _selectedAnswers = [];
  List<int> _answerTimings = [];

  /// Server-minted run id (solo session id for solo, a quizRuns doc otherwise).
  String? _runId;

  /// Per-question result from the server. Null means "answered, correctness
  /// withheld until settlement" (Blitz / challenge end-only reveal).
  List<bool?> _answerResults = [];

  /// Correctness of the question currently showing its feedback.
  /// Null in Blitz (end-only reveal) until settlement.
  bool? _lastAnswerCorrect;

  /// True while a solo answer is being locked server-side.
  bool _submittingAnswer = false;

  /// In-flight duel answer locks by question index (optimistic: the UI never
  /// waits for these). Awaited at final submit so transient failures become a
  /// short wait instead of lost points.
  final Map<int, Future<bool>> _pendingLocks = {};

  /// Duel questions whose background lock gave up (permanent server states
  /// are excluded — those surface at submit). Retried once at final submit.
  final Set<int> _lockFailed = {};

  /// True once the run settled; suppresses cancelRun in dispose.
  bool _completed = false;

  /// Server-computed Blitz WP per question (client no longer has the key).
  List<int> _serverGauntletPerQuestionWP = const [];

  /// Server-revealed correct option per question (solo only, wrong answers
  /// only). The server returns `correctIndex` for the locked question; the
  /// client never holds the full key. Null = not revealed (correct answer or
  /// end-only mode).
  List<int?> _revealedCorrect = const [];

  /// Correct option to highlight for the current question, or null when
  /// nothing should be revealed (answered correctly, or end-only mode).
  int? get revealedCorrectForCurrent =>
      _qIndex >= 0 && _qIndex < _revealedCorrect.length
          ? _revealedCorrect[_qIndex]
          : null;

  String? get runId => _runId;
  bool? get lastAnswerCorrect => _lastAnswerCorrect;
  List<bool?> get answerResults => List.unmodifiable(_answerResults);
  List<int> get gauntletPerQuestionWP =>
      List.unmodifiable(_serverGauntletPerQuestionWP);

  /// True while a solo answer lock (`submitAnswer`) is in flight. The options
  /// UI uses this to disable tiles so a second tap during the lock cannot be
  /// silently swallowed.
  bool get isLockingAnswer => _submittingAnswer;

  /// Solo reveals right/wrong immediately; Blitz and challenges reveal at
  /// settlement only (the server omits the correct option entirely).
  bool get revealsAnswerDuringPlay => mode == QuizMode.solo;

  /// Read-only view of the answer index recorded for each question so far
  /// (0-based option index, or -1 for a timeout / unanswered question).
  List<int> get selectedAnswers => List.unmodifiable(_selectedAnswers);

  // ── Hints (per question) ───────────────────────────────────────────────────
  /// Hints already spent on each question, indexed by question. Sized with the
  /// run, so every new question starts with the full kMaxHints allowance.
  List<int> _hintsUsedPerQuestion = const [];

  int get hintsUsedThisQuestion =>
      _qIndex >= 0 && _qIndex < _hintsUsedPerQuestion.length
          ? _hintsUsedPerQuestion[_qIndex]
          : 0;

  int get hintsLeft => kMaxHints - hintsUsedThisQuestion;
  bool get hintsExhausted => hintsLeft <= 0;

  /// Question index of the in-flight `useQuizHint` call, or -1 when idle.
  /// Tracks the index (not a bool) so a slow hint for a previous question
  /// never blocks a hint on the current one after an advance.
  int _hintInFlightIndex = -1;

  /// True while a hint for the current question is awaiting the server.
  /// The header uses this to show a spinner and block double-taps — the
  /// same instant-feedback role the timer-freeze plays for pause.
  bool get isHintLoading => _hintInFlightIndex == _qIndex;

  // ── Timer ──────────────────────────────────────────────────────────────────
  int _timerSeconds = kTimerDuration;
  Timer? _timer;
  DateTime? _questionStartTime;

  /// Blitz global clock: seconds left in the 90s run. Only ticks when
  /// [isGauntlet] is true; solo/challenge runs ignore it.
  int _blitzSecondsLeft = kBlitzSeconds;

  /// Seconds left on the Blitz clock (== [kBlitzSeconds] for non-Blitz runs).
  int get blitzSecondsLeft => _blitzSecondsLeft;

  /// True once the Blitz clock has hit zero (submission in flight or done).
  bool get _blitzTimeUp => isGauntlet && _blitzSecondsLeft <= 0;

  /// True while the current question's countdown is frozen by the Timer Pause
  /// power-up. The timer stays frozen until the player answers (no auto-resume,
  /// no extra seconds added). Reset on every advance / load.
  bool _timerPaused = false;

  int get timerSeconds => _timerSeconds;
  bool get timerIsUrgent => _timerSeconds <= 5;
  bool get timerIsCritical => _timerSeconds <= 2;
  bool get isTimerPaused => _timerPaused;

  // ── Convenience pass-through ───────────────────────────────────────────────
  int get animeCoins => _ud.animeCoins;

  // ── Computed ───────────────────────────────────────────────────────────────
  /// Timer Pause is disabled in Blitz: the global clock never freezes.
  bool get canShowTimerPause =>
      !isGauntlet &&
      !_isLoading &&
      _questions.isNotEmpty &&
      timerIsUrgent &&
      !_showResult &&
      !_isNavigating &&
      !_timerPaused &&
      !currentTimerPauseUsed;

  // ── Load ───────────────────────────────────────────────────────────────────

  Future<void> loadQuestions() async {
    _isLoading = true;
    _errorMsg = null;
    _notify();

    try {
      // The server mints the run: it picks the question set, records the
      // answer key, and returns sanitized questions (no correctAnswerIndex).
      // A patched client can no longer choose easy questions or supply the
      // answer key.
      final run = await _fetchQuizRun();
      if (_disposed) return;

      final rawQuestions = (run['questions'] as List<dynamic>? ?? const []);
      final all = rawQuestions
          .whereType<Map<dynamic, dynamic>>()
          .map((q) => AnimeQuestion.fromWire(Map<String, dynamic>.from(q)))
          .toList();

      _runId = (run['runId'] as String?)?.trim();

      if (all.isEmpty) {
        throw Exception('No questions found for the selected anime.');
      }

      final taken = all;

      _questions = taken;
      _isLoading = false;
      _errorMsg = null;
      _eliminatedOpts = List.generate(taken.length, (_) => {});
      _timerPauseUsed = List.filled(taken.length, false);
      _timerPaused = false;
      _hintsUsedPerQuestion = List<int>.filled(taken.length, 0);
      _hintInFlightIndex = -1;
      _qIndex = 0;
      _selectedOption = -1;
      _timerSeconds = kTimerDuration;
      _blitzSecondsLeft = kBlitzSeconds;
      _correctCount = 0;
      _showResult = false;
      _isNavigating = false;
      _submitFailed = false;
      _selectedAnswers = [];
      _answerTimings = [];
      _answerResults = [];
      _lastAnswerCorrect = null;
      _revealedCorrect = List<int?>.filled(taken.length, null);
      _submittingAnswer = false;
      _completed = false;
      _pendingLocks.clear();
      _lockFailed.clear();
      // Duel resume: the server returns our own locked picks. Skip past
      // them — replaying locked questions is pointless (already scored) and
      // re-showing them is the preview this fixes.
      var resumeIndex = 0;
      if (mode == QuizMode.asyncChallenge) {
        final locked = run['lockedAnswers'];
        if (locked is List && locked.isNotEmpty) {
          while (resumeIndex < locked.length &&
              resumeIndex < taken.length &&
              locked[resumeIndex] is int) {
            resumeIndex++;
          }
          if (resumeIndex > 0) {
            _selectedAnswers = List<int>.generate(
              resumeIndex,
              (i) => (locked[i] as num).toInt(),
              growable: true,
            );
            _answerTimings = List<int>.filled(resumeIndex, -1, growable: true);
            _answerResults =
                List<bool?>.filled(resumeIndex, null, growable: true);
            _qIndex = resumeIndex;
          }
        }
      }
      _serverGauntletPerQuestionWP = const [];

      _notify();

      if (resumeIndex >= taken.length && taken.isNotEmpty) {
        // Killed after locking the last answer but before the submit
        // landed: everything is already scored, so settle immediately
        // instead of replaying the set.
        _isNavigating = true;
        _notify();
        Future.microtask(() async {
          if (_disposed) return;
          if (mode == QuizMode.asyncChallenge) {
            await _finishChallenge();
          } else {
            await _submitToServer();
          }
        });
        return;
      }

      if (taken.isNotEmpty) {
        _questionStartTime = DateTime.now();
        _startTimer();
      }
    } catch (e, st) {
      if (_disposed) return;
      _isLoading = false;
      debugPrint('[GhostMatch][loadQuestions] ERROR: $e');
      debugPrintStack(stackTrace: st);
      _errorMsg = e.toString().replaceFirst('Exception: ', '');
      _notify();
    }
  }

  /// Resolves the server-minted run for this session. The response contains
  /// sanitized questions only — never `correctAnswerIndex`.
  Future<Map<String, dynamic>> _fetchQuizRun() async {
    final payload = <String, dynamic>{
      ...AppUpdateService.instance.clientBuildStamp,
    };

    if (isGauntlet) {
      payload['mode'] = 'gauntlet';
      final rid = gauntletRunId?.trim();
      if (rid != null && rid.isNotEmpty) payload['runId'] = rid;
      if (gauntletTicketId != null) {
        payload['gauntletTicketId'] = gauntletTicketId;
      }
    } else if (mode == QuizMode.asyncChallenge) {
      payload['mode'] = isQuickMatch ? 'quickmatch' : 'challenge';
      payload['challengeId'] = challengeId;
    } else {
      payload['mode'] = 'solo';
      final sid = soloSessionId?.trim();
      if (sid != null && sid.isNotEmpty) payload['sessionId'] = sid;
      payload['titles'] = selectedTitles;
      payload['difficulty'] = normalizeSoloDifficulty(soloDifficulty);
    }

    final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('getQuizRun')
        .call<Map<Object?, Object?>>(payload);
    return Map<String, dynamic>.from(result.data);
  }

  // ── Timer ──────────────────────────────────────────────────────────────────

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || _isNavigating) return;
      // Solo answer lock in flight: freeze the countdown (don't decrement)
      // so a slow lock never steals answer time. Duel never sets this flag
      // (optimistic lock), so quick-match keeps ticking normally.
      if (_submittingAnswer) return;
      // Timer Pause freezes the countdown until the player answers. The pause
      // path cancels the timer, but guard here too so a restarted timer can
      // never tick through a pause.
      if (_timerPaused) return;
      // Blitz global clock ticks alongside the per-question countdown and
      // wins every race: at zero the run submits immediately.
      if (isGauntlet) {
        _blitzSecondsLeft--;
        if (_blitzSecondsLeft <= 0) {
          _blitzSecondsLeft = 0;
          _timer?.cancel();
          _notify();
          _finishBlitzTimeUp();
          return;
        }
      }
      if (_timerSeconds <= 0) {
        _timer?.cancel();
        _advance();
      } else {
        _timerSeconds--;
        _notify();
      }
    });
  }

  /// Blitz clock hit zero mid-run: record the in-flight question (if any) as
  /// unanswered, pad the rest, and submit. Guarded by [_isNavigating] so the
  /// expiry, a tap dwell, and a per-question timeout cannot triple-submit.
  void _finishBlitzTimeUp() {
    if (_isNavigating) return;
    // In-flight question never answered (or its dwell hasn't fired yet).
    if (_selectedAnswers.length == _qIndex && _qIndex < _questions.length) {
      _answerResults.add(null);
      _selectedAnswers.add(_selectedOption);
      _answerTimings.add(-1);
    }
    while (_selectedAnswers.length < _questions.length) {
      _answerResults.add(null);
      _selectedAnswers.add(-1);
      _answerTimings.add(-1);
    }
    _isNavigating = true;
    _timer?.cancel();
    _notify();

    Future.microtask(() async {
      if (_disposed) return;
      await _submitToServer();
    });
  }

  // ── Select option ──────────────────────────────────────────────────────────

  Future<void> selectOption(int index) async {
    if (_showResult ||
        _isNavigating ||
        _submittingAnswer ||
        currentQuestion == null) {
      return;
    }

    // 1.5 s anti-bot floor
    final elapsed = _questionStartTime == null
        ? 9999
        : DateTime.now().difference(_questionStartTime!).inMilliseconds;
    if (elapsed < 1500) return;

    // Duel (challenge / quick-match) takes the optimistic path and never
    // waits: _submittingAnswer stays false so the timer and tiles stay live
    // for the next question. Solo sets it below and clears it on every exit.
    // (Previously this flag was set before the duel branch and never cleared,
    // which froze the timer at Q2+ and disabled all option tiles — the
    // "have to quit after question 1" freeze.)
    if (mode == QuizMode.asyncChallenge && _runId != null) {
      // Optimistic duel lock: highlight now, lock in the background, advance
      // on the normal dwell. The player never waits for the network — the
      // lock lands while they read the next question. Correctness stays
      // hidden until the result; the lock is an acknowledgement only, but it
      // is a REAL lock: quitting leaves it standing, which is what kills the
      // preview-then-replay exploit without slowing the duel down.
      _fireDuelLock(index);
      return;
    }

    _submittingAnswer = true;
    bool? correct;

    // Solo answers lock server-side and the UI waits: it learns {correct,
    // correctIndex} for the locked question before advancing. Duels take the
    // optimistic path above (_fireDuelLock) and never reach this branch.
    //
    // The lock is the anti-preview mechanism: quitting (or killing the app)
    // leaves locked answers standing, and a resume continues from the first
    // unlocked question instead of replaying the fixed set for free.
    //
    // The tap highlights instantly (optimistic) and correctness is revealed
    // when the lock returns — the tile shows a spinner meanwhile. The timer
    // stays frozen for the whole lock (_startTimer early-outs while
    // _submittingAnswer is true), so a slow lock never steals answer time.
    // On a wrong solo answer the server also reveals the correct option for
    // that locked question only (no probing: the answer can no longer change).
    int? revealedCorrect;
    if (mode == QuizMode.solo && _runId != null) {
      _selectedOption = index;
      _notify();
      try {
        // Bounded so a stalled network can never leave the timer frozen and
        // the tiles showing a spinner forever (the old hang required a quit).
        final data = await _invokeSubmitCallable('submitAnswer', {
          'runId': _runId,
          'questionIndex': _qIndex,
          'selectedAnswer': index,
          ...AppUpdateService.instance.clientBuildStamp,
        }).timeout(
          const Duration(seconds: 12),
          onTimeout: () => throw TimeoutException('submitAnswer timed out'),
        );
        correct = data['correct'] == true;
        if (correct != true) {
          final ci = (data['correctIndex'] as num?)?.toInt();
          final optionCount = currentQuestion?.options.length ?? 0;
          if (ci != null && ci >= 0 && ci < optionCount && ci != index) {
            revealedCorrect = ci;
          }
        }
      } on FirebaseFunctionsException catch (e) {
        if (_disposed) return;
        _submittingAnswer = false;
        _selectedOption = -1;
        _notify();
        debugPrint(
            '[QuizController] submitAnswer failed: ${e.code} ${e.message}');
        // Permanent states: retrying the same lock can never succeed, so
        // surface a specific message with no Retry action.
        final expired = e.code == 'failed-precondition' &&
            (e.message ?? '') == 'run_expired';
        final notActive = e.code == 'failed-precondition' &&
            ((e.message ?? '') == 'run_not_active' ||
                (e.message ?? '') == 'run_cancelled' ||
                (e.message ?? '') == 'run_already_submitted');
        final outOfOrder = e.code == 'failed-precondition' &&
            (e.message ?? '') == 'answer_out_of_order';
        final updateRequired = e.code == 'failed-precondition' &&
            ((e.message ?? '').contains('App update required') ||
                (e.message ?? '') == 'legacy_quiz_path');
        if (expired) {
          onError('This run expired — start a new quiz.');
          return;
        }
        if (notActive) {
          onError('This run is no longer active — start a new quiz.');
          return;
        }
        if (outOfOrder) {
          // A stale in-flight lock (e.g. a timed-out question's best-effort
          // lock landing late) collided with this tap. The server kept the
          // first write; re-reading is unnecessary — just let the player tap
          // again, the next lock carries the current index.
          onError(
            'That tap arrived out of order — please tap your answer again.',
            onRetry: () => selectOption(index),
          );
          return;
        }
        if (updateRequired) {
          onError(
            'App update required: please update to the latest version.',
          );
          return;
        }
        if (e.code == 'unauthenticated') {
          onError('Your session expired — sign in again, then retry.');
          return;
        }
        onError(
          'Could not lock your answer — please try again.',
          onRetry: () => selectOption(index),
        );
        return;
      } catch (e) {
        if (_disposed) return;
        _submittingAnswer = false;
        _selectedOption = -1;
        _notify();
        debugPrint('[QuizController] submitAnswer failed: $e');
        onError(
          'Could not lock your answer — please try again.',
          onRetry: () => selectOption(index),
        );
        return;
      }
    }

    if (_disposed) return;
    _submittingAnswer = false;
    _selectedOption = index;
    _showResult = true;
    _lastAnswerCorrect = correct;
    if (revealedCorrect != null &&
        _qIndex >= 0 &&
        _qIndex < _revealedCorrect.length) {
      _revealedCorrect[_qIndex] = revealedCorrect;
    }
    if (correct == true) _correctCount++;
    _notify();

    _timer?.cancel();

    // Blitz runs at pace: a short dwell keeps the 90s clock honest. Solo
    // keeps the longer dwell so the revealed correct answer can be read.
    final dwell = revealedCorrect != null
        ? const Duration(milliseconds: 2200)
        : isGauntlet
            ? const Duration(milliseconds: 350)
            : const Duration(milliseconds: 900);
    Future.delayed(dwell, () {
      if (!_disposed) _advance();
    });
  }

  /// Optimistic duel answer lock (challenge / quick-match). Sets the selection
  /// UI state synchronously so the tap feels instant, fires the server lock
  /// in the background, and advances on the normal 900 ms dwell. The player
  /// never waits for a round trip — the lock lands while they read the next
  /// question. Re-taps during the dwell are ignored via [_showResult], so the
  /// locked answer always matches the recorded one.
  void _fireDuelLock(int index) {
    final lockIndex = _qIndex;
    final lockRunId = _runId;
    // Defensive: never leave the answer lock flag set — it freezes the timer
    // tick and disables every option tile on the next question.
    _submittingAnswer = false;
    if (lockRunId == null || lockRunId.isEmpty) {
      // No server run (offline resume edge): still advance locally so the
      // player is never stranded on a dead question.
      _selectedOption = index;
      _showResult = true;
      _notify();
      _timer?.cancel();
      Future.delayed(const Duration(milliseconds: 900), () {
        if (!_disposed) _advance();
      });
      return;
    }
    _selectedOption = index;
    _showResult = true;
    _notify();
    _timer?.cancel();
    _pendingLocks[lockIndex] = _lockDuelAnswer(lockRunId, lockIndex, index);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!_disposed) _advance();
    });
  }

  /// Locks one duel answer server-side with retries. Returns true when the
  /// lock landed. Permanent server states (cancelled run, filled seat, dead
  /// challenge, forced update) return false immediately — those surface at
  /// final submit instead of mid-duel.
  Future<bool> _lockDuelAnswer(
    String runId,
    int questionIndex,
    int selectedAnswer,
  ) async {
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _invokeSubmitCallable('submitAnswer', {
          'runId': runId,
          'questionIndex': questionIndex,
          'selectedAnswer': selectedAnswer,
          ...AppUpdateService.instance.clientBuildStamp,
        });
        _lockFailed.remove(questionIndex);
        return true;
      } on FirebaseFunctionsException catch (e) {
        final msg = e.message ?? '';
        if (e.code == 'failed-precondition' &&
            (msg == 'run_cancelled' ||
                msg == 'run_expired' ||
                msg == 'run_already_submitted' ||
                msg == 'score_already_submitted' ||
                msg == 'challenge_not_active' ||
                msg == 'challenge_not_found' ||
                msg.contains('App update required') ||
                msg == 'legacy_quiz_path')) {
          debugPrint('[QuizController] duel lock refused: ${e.code} $msg');
          return false;
        }
      } catch (e) {
        debugPrint('[QuizController] duel lock failed (attempt $attempt): $e');
      }
      if (attempt < maxAttempts) {
        await Future.delayed(Duration(seconds: attempt));
      }
    }
    _lockFailed.add(questionIndex);
    return false;
  }

  /// Waits for in-flight duel locks (usually already done) and retries the
  /// ones that gave up, so transient network failures become a short wait at
  /// submit instead of lost points. Bounded: a dead network fails fast into
  /// the normal submit error path.
  Future<void> _awaitPendingLocks() async {
    if (_pendingLocks.isEmpty) return;
    try {
      await Future.wait(_pendingLocks.values).timeout(
        const Duration(seconds: 10),
      );
    } catch (_) {
      // Timeouts and lock errors are handled below; never trap the submit.
    }
    if (_lockFailed.isEmpty || _disposed) return;
    final retry = _lockFailed.toList();
    _lockFailed.clear();
    final runId = _runId;
    if (runId == null) return;
    for (final i in retry) {
      if (_disposed) return;
      if (i < 0 || i >= _selectedAnswers.length) continue;
      try {
        await _invokeSubmitCallable('submitAnswer', {
          'runId': runId,
          'questionIndex': i,
          'selectedAnswer': _selectedAnswers[i],
          ...AppUpdateService.instance.clientBuildStamp,
        }).timeout(const Duration(seconds: 5));
      } catch (_) {
        // Still failing: the gap scores -1 via the server fill, and the
        // submit below surfaces a dead run honestly.
      }
    }
  }

  // ── Advance ────────────────────────────────────────────────────────────────

  void _advance() {
    if (_isNavigating) return;
    // Self-heal: no question transition may ever leave the answer lock set.
    // A stuck flag freezes the timer tick and disables every option tile on
    // the next question (the Q1 freeze). Reset here as well as on every lock
    // exit so one bad path can never strand the run.
    _submittingAnswer = false;
    // Blitz clock ran out while a dwell was pending: finish instead of
    // advancing onto another question.
    if (_blitzTimeUp) {
      _finishBlitzTimeUp();
      return;
    }

    // Best-effort lock for a timed-out question. The final submitRun treats
    // any missing slot as -1 regardless, so a dropped request cannot change
    // the score — but locking it keeps duel resumes exact.
    if ((mode == QuizMode.solo || mode == QuizMode.asyncChallenge) &&
        _runId != null &&
        _selectedOption == -1) {
      unawaited(() async {
        try {
          await _invokeSubmitCallable('submitAnswer', {
            'runId': _runId,
            'questionIndex': _qIndex,
            'selectedAnswer': -1,
            ...AppUpdateService.instance.clientBuildStamp,
          });
        } catch (e) {
          debugPrint('[QuizController] timeout lock failed (ignored): $e');
        }
      }());
    }

    _answerResults.add(
      revealsAnswerDuringPlay
          ? (_selectedOption == -1 ? false : _lastAnswerCorrect)
          : null,
    );
    _lastAnswerCorrect = null;

    _selectedAnswers.add(_selectedOption);
    _answerTimings.add(_selectedOption == -1 ? -1 : _timerSeconds);

    if (_qIndex < _questions.length - 1) {
      _qIndex++;
      _selectedOption = -1;
      _showResult = false;
      _timerSeconds = kTimerDuration;
      _timerPaused = false;
      _notify();

      _questionStartTime = DateTime.now();
      _startTimer();
      onQuestionAdvance(_qIndex);
    } else {
      _isNavigating = true;
      _timer?.cancel();
      _notify();

      Future.microtask(() async {
        if (_disposed) return;
        if (mode == QuizMode.asyncChallenge) {
          await _finishChallenge();
        } else {
          await _submitToServer();
        }
      });
    }
  }

  // ── Completion: submit the server-minted run ───────────────────────────────
  //
  // Solo and Blitz both settle through `submitRun`; the server awards the
  // difficulty-based Blitz WP, tiered gamble AC, daily cap, and achievements
  // from its own answer key.

  Future<void> _submitToServer() async {
    await _submitRunToServer();
  }

  /// Single settlement path for solo and Blitz. `submitRun` scores the
  /// answers against the server-held key and returns the authoritative
  /// totals; the client never computes or supplies a score.
  Future<void> _submitRunToServer() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError(
          'You need to be signed in to submit your result. '
          'Please sign in and try again.',
        );
      }
      return;
    }

    try {
      await currentUser.getIdToken(true);
    } catch (e) {
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError(
          'Your session has expired. Please sign in again to save '
          'your result.',
        );
      }
      return;
    }

    final rid = _runId;
    if (rid == null || rid.isEmpty) {
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError(
          'This run could not be verified — start a new quiz to earn rewards.',
        );
      }
      return;
    }

    Object? lastError;
    for (int attempt = 1; attempt <= _kCfMaxAttempts; attempt++) {
      try {
        final data = await _invokeSubmitCallable('submitRun', {
          'runId': rid,
          if (isGauntlet) 'answers': _selectedAnswers,
          ...AppUpdateService.instance.clientBuildStamp,
        });
        if (_disposed) return;
        _completed = true;

        final correctCount = (data['correctCount'] as num?)?.toInt() ?? 0;
        final totalWP = (data['totalWP'] as num?)?.toInt() ?? 0;
        final acEarned = (data['acEarned'] as num?)?.toInt() ?? 0;
        final achievementCoins = (data['achievementAC'] as num?)?.toInt() ?? 0;

        if (isGauntlet) {
          final answeredCount =
              (data['answeredCount'] as num?)?.toInt() ?? correctCount;
          final perQuestion =
              (data['perQuestionWP'] as List<dynamic>? ?? const [])
                  .whereType<num>()
                  .map((n) => n.toInt())
                  .toList();
          _serverGauntletPerQuestionWP = perQuestion;
          onSoloComplete(
            correctCount,
            _questions.length,
            acEarned,
            totalWP,
            isGauntlet: true,
            streak: 0,
            answeredCount: answeredCount,
            gauntletPerQuestionWP: perQuestion,
            achievementCoins: achievementCoins,
          );
        } else {
          onSoloComplete(
            correctCount,
            _questions.length,
            acEarned,
            totalWP,
            achievementCoins: achievementCoins,
          );
        }
        return;
      } on FirebaseFunctionsException catch (e) {
        final isUnauthenticated = e.code == 'unauthenticated';
        final isNoActiveSession = e.code == 'failed-precondition' &&
            (e.message ?? '') == 'no_active_solo_session';
        final isExpired = e.code == 'failed-precondition' &&
            (e.message ?? '') == 'run_expired';
        final isBusy = e.code == 'failed-precondition' &&
            (e.message ?? '') == 'run_in_progress';
        final isInsufficient = e.code == 'resource-exhausted' &&
            (e.message?.startsWith('insufficient_coins') ?? false);
        final isUpdateRequired = e.code == 'failed-precondition' &&
            (e.message?.startsWith('App update required') ?? false);
        if (isUpdateRequired && !_disposed) {
          _isNavigating = false;
          _notify();
          onError(e.message ?? 'App update required: please update the app.');
          return;
        }
        if (isInsufficient && !_disposed) {
          _isNavigating = false;
          _notify();
          final needed = int.tryParse(e.message?.split(':').last ?? '') ?? 0;
          await onInsufficientCoins(needed);
          return;
        }
        if (isUnauthenticated && !_disposed) {
          _isNavigating = false;
          _notify();
          onError(
            'Your session has expired. Please sign in again to save your result.',
          );
          return;
        }
        if (isNoActiveSession && !_disposed) {
          _isNavigating = false;
          _notify();
          onError(
            'This run could not be verified — start a new quiz to earn rewards.',
          );
          return;
        }
        if (isExpired && !_disposed) {
          _isNavigating = false;
          _notify();
          onError(
            'This run expired — start a new quiz to earn rewards.',
          );
          return;
        }
        lastError = e;
        if (isBusy && attempt < _kCfMaxAttempts && !_disposed) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        break;
      } catch (e) {
        lastError = e;
        debugPrint(
          '[QuizController] submitRun attempt $attempt/$_kCfMaxAttempts failed: $e',
        );
        if (attempt < _kCfMaxAttempts && !_disposed) {
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
    }

    if (!_disposed) {
      _isNavigating = false;
      _notify();
      // Solo/Blitz have no submit button — without a Retry action a failed
      // save strands the player on the last question with no way to finish.
      // Re-entering sets the navigating guard again so input stays blocked.
      onError(
        'Could not save your result — please check your connection and try again.',
        onRetry: () {
          if (_disposed || _isNavigating) return;
          _isNavigating = true;
          _notify();
          unawaited(_submitRunToServer());
        },
      );
      debugPrint(
        '[QuizController] submitRun failed after $_kCfMaxAttempts attempts: $lastError',
      );
    }
  }

  // ── Challenge completion ───────────────────────────────────────────────────
  //
  // Routes to _finishQuickMatch for quick matches, otherwise uses the existing
  // submitCreatorScore / submitOpponentScore path (completely unchanged).

  /// Runs a final-submission callable through the injected test seam when one
  /// is present, otherwise through the real [FirebaseFunctions] client. Both
  /// paths return the callable's data map.
  Future<Map<String, dynamic>> _invokeSubmitCallable(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final injected = _submitCaller;
    if (injected != null) return injected(name, payload);

    // Integrity is log-only server-side: never let it gate gameplay.
    // The token fetch is two hops (challenge callable + native Play call),
    // so cap it at a short budget and send without it on timeout — exactly
    // like the shipped build, which sends no token at all.
    final integrity = await _integrityWithBudget(name);
    final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable(name)
        .call<Map<Object?, Object?>>({...payload, ...integrity});
    return Map<String, dynamic>.from(result.data);
  }

  /// Best-effort integrity fields with a fixed time budget. Returns `{}` on
  /// timeout or failure so the submission proceeds without a token.
  Future<Map<String, String>> _integrityWithBudget(String action) async {
    try {
      return await PlayIntegrityService.instance.tokenFields(action).timeout(
            const Duration(milliseconds: 600),
            onTimeout: () => const <String, String>{},
          );
    } catch (_) {
      return const <String, String>{};
    }
  }

  Future<void> _finishChallenge() async {
    if (isQuickMatch) {
      await _finishQuickMatch();
      return;
    }

    // ── Standard async challenge (Rival / Code / Spar) ────────────────────
    // The score is computed SERVER-side from the submitted answers by
    // submitChallengeScore, exactly like Quick Match. The old path wrote
    // creatorScore / opponentScore straight to Firestore, which made the payout
    // input client-attested — a patched client could claim a perfect score and
    // take the opponent's stake. firestore.rules now denies that write.
    // Drain optimistic locks first: usually instant, occasionally a short
    // wait that saves points on a flaky network.
    await _awaitPendingLocks();
    if (_disposed) return;
    try {
      // The server rejects an empty id; keeping the call unconditional lets
      // the retry path surface the real server error instead of a local one.
      final data = await _invokeSubmitCallable('submitRun', {
        'runId': _runId ?? '',
        'answers': _selectedAnswers,
        ...AppUpdateService.instance.clientBuildStamp,
      });

      if (_disposed) return;
      _completed = true;
      final correctCount =
          (data['correctCount'] as num?)?.toInt() ?? _correctCount;
      onChallengeComplete(challengeId!, isCreator, correctCount);
    } catch (e) {
      if (!_disposed) {
        _isNavigating = false;
        _submitFailed = true;
        _notify();
        onError('Failed to save score: $e', onRetry: retrySubmit);
      }
    }
  }

  // ── Retry a failed final submission ────────────────────────────────────────
  //
  // The final challenge / quick-match submission has no re-enterable UI: once
  // the last question advances, _advance is done and the answer tiles are
  // locked. Without this method a transient CF failure stranded the player on
  // the last question — quitting was blocked and there was nothing to tap.
  //
  // Exposed through the "Retry" action on the failure snackbar. A no-op unless
  // a submission actually failed, so a stale snackbar tap can never re-submit.

  Future<void> retrySubmit() async {
    if (_disposed || _isNavigating || !_submitFailed) return;
    if (mode != QuizMode.asyncChallenge) return;

    _submitFailed = false;
    _isNavigating = true;
    _notify();

    // _finishChallenge routes quick matches to _finishQuickMatch internally.
    await _finishChallenge();
  }

  /// Drives the final submission exactly like the last question advancing.
  ///
  /// Test-only entry point: lets the failure → retry path run without a loaded
  /// quiz or a live Cloud Function (see the injected `submitCaller`). The
  /// submission callables score from a server-stored run, so the seam seeds a
  /// run id when the test has not loaded a quiz.
  @visibleForTesting
  Future<void> finishRunForTest({String runId = 'test-run'}) {
    _runId ??= runId;
    return _finishChallenge();
  }

  // ── Quick Match completion ─────────────────────────────────────────────────
  //
  // Calls the submitQuickMatchResult Cloud Function which:
  //   • Ghost match → scores immediately, awards WP + AC server-side.
  //   • Real match  → writes creatorScore / opponentScore to the challenge doc;
  //                   resolveChallengeOutcome trigger awards AC + updates stats
  //                   when both scores are present.
  //
  // Either way, completion now routes through onChallengeComplete — the exact
  // same live ChallengeResultPage flow Rival/Code challenges use. Ghost
  // matches have already resolved by the time the challenge doc is read, so
  // the result page opens already settled. Real matches open the result page
  // in its live waiting state and reveal the outcome the moment the
  // resolveChallengeOutcome trigger writes it. Either role, either mode, one
  // destination.
  //
  // Every completed Quick Match — ghost or real — also feeds a copy of this
  // session back into the ghost pool via _saveGhostSession, fire-and-forget,
  // so future matchmaking always has fresh opponents to draw from.
  //
  // On any CF failure the error snackbar is shown and navigation is reset so
  // the player can retry (same pattern as _finishChallenge).

  Future<void> _finishQuickMatch() async {
    // Drain optimistic locks first: usually instant, occasionally a short
    // wait that saves points on a flaky network.
    await _awaitPendingLocks();
    if (_disposed) return;
    try {
      // The server rejects an empty id; keeping the call unconditional lets
      // the retry path surface the real server error instead of a local one.
      final data = await _invokeSubmitCallable('submitRun', {
        'runId': _runId ?? '',
        'answers': _selectedAnswers,
        ...AppUpdateService.instance.clientBuildStamp,
      });

      if (_disposed) return;
      _completed = true;

      // correctCount is server-validated for both ghost and real paths.
      final correctCount = (data['correctCount'] as num?)?.toInt() ?? 0;

      // Replenish the ghost pool from the completed run regardless of whether
      // the opponent was a ghost or a real player. The server verifies the run
      // is submitted and owned by this UID; non-fatal, never blocks navigation.
      unawaited(_saveGhostSession());

      if (!_disposed) {
        onChallengeComplete(challengeId!, isCreator, correctCount);
      }
    } catch (e) {
      if (!_disposed) {
        _isNavigating = false;
        _submitFailed = true;
        _notify();
        onError('Failed to save Quick Match result: $e', onRetry: retrySubmit);
      }
    }
  }

  // ── Ghost pool replenishment ─────────────────────────────────────────────
  //
  // Saves this completed Quick Match session — regardless of whether the
  // opponent was a ghost or a real player — back into the ghost pool via the
  // saveGhostSession CF, so future matchmaking always has fresh sessions to
  // draw from when no live opponent is available. Fire-and-forget and
  // non-fatal: a failure here should never disrupt the result flow.
  Future<void> _saveGhostSession() async {
    final rid = _runId;
    if (rid == null || rid.isEmpty) return;
    try {
      final username =
          FirebaseAuth.instance.currentUser?.displayName ?? 'Anonymous';

      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('saveGhostSession')
          .call<Map<String, dynamic>>({
        // The server derives the question set and answers from the completed
        // run; the client no longer posts an arbitrary perfect session.
        'runId': rid,
        // Normalized to the lowercase Firestore contract (see seed script).
        // Quick Match sessions are single-anime so `first` is exact.
        'animeTitle': selectedTitles.isNotEmpty
            ? selectedTitles.first.trim().toLowerCase()
            : '',
        'username': username,
        ...AppUpdateService.instance.clientBuildStamp,
      });
    } catch (e) {
      debugPrint('[QuizController] saveGhostSession failed (non-fatal): $e');
    }
  }

  // ── Hint ───────────────────────────────────────────────────────────────────

  Future<void> useHint() async {
    if (isGauntlet) {
      onError('Hints are disabled in Blitz — every second counts.');
      return;
    }
    if (_isNavigating || currentQuestion == null || hintsExhausted) return;
    // Same-question double-tap guard: the button shows a spinner while the
    // server picks the elimination, so a second tap must be a no-op rather
    // than a second charge.
    if (_hintInFlightIndex == _qIndex) return;

    final rid = _runId;
    if (rid == null || rid.isEmpty) {
      onError('Hints are unavailable for this run.');
      return;
    }

    // Optimistic reservation (same as useTimerPause): the coin pill drops
    // instantly via the provider notification, and the hint button shows a
    // spinner. The elimination itself still comes from the server — the
    // client never predicts which option is wrong, so security is unchanged.
    // The client no longer holds the answer key, so the server picks a wrong
    // option and deducts the 10 AC in the same transaction.
    final questionIndex = _qIndex;
    final int reservationId;
    try {
      reservationId = _ud.reserveCoins(kHintCost);
    } on InsufficientCoinsException {
      await onInsufficientCoins(kHintCost);
      return;
    }
    _hintInFlightIndex = questionIndex;
    _notify();

    void clearFlight() {
      if (_hintInFlightIndex == questionIndex) {
        _hintInFlightIndex = -1;
        _notify();
      }
    }

    try {
      // Bounded so a stalled network clears the spinner instead of leaving
      // the hint button stuck in "Finding a wrong option…" forever.
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('useQuizHint')
          .call<Map<Object?, Object?>>({
        'runId': rid,
        'questionIndex': questionIndex,
        ...AppUpdateService.instance.clientBuildStamp,
      }).timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException('useQuizHint timed out'),
      );
      final data = Map<String, dynamic>.from(result.data);
      final newBalance = (data['newBalance'] as num?)?.toInt();
      // Server already charged: consume the local reservation against the
      // authoritative balance (never call spendCoins — that would charge
      // twice). Stale responses (user advanced mid-flight) still settle
      // the coins, but never touch the new question's tiles.
      _ud.settleReservationWithBalance(reservationId, newBalance);
      if (_disposed || _qIndex != questionIndex) {
        clearFlight();
        return;
      }
      final eliminated = (data['eliminatedIndex'] as num?)?.toInt();
      if (eliminated == null || eliminated < 0) {
        clearFlight();
        onError('No more options to eliminate.');
        return;
      }
      _eliminatedOpts[questionIndex].add(eliminated);
      if (questionIndex < _hintsUsedPerQuestion.length) {
        _hintsUsedPerQuestion[questionIndex]++;
      }
      clearFlight();
    } on FirebaseFunctionsException catch (e) {
      _ud.rollbackReservedCoinSpend(reservationId);
      clearFlight();
      if (e.code == 'resource-exhausted' &&
          (e.message?.startsWith('insufficient_coins') ?? false)) {
        await onInsufficientCoins(kHintCost);
        return;
      }
      if (e.code == 'resource-exhausted' &&
          (e.message ?? '') == 'hint_limit_reached') {
        // The server is authoritative: sync the local counter so the button
        // disables for the rest of this question instead of retrying.
        if (questionIndex < _hintsUsedPerQuestion.length) {
          _hintsUsedPerQuestion[questionIndex] = kMaxHints;
          _notify();
        }
        onError('No more hints for this question.');
        return;
      }
      debugPrint('[QuizController] useQuizHint failed: ${e.code} ${e.message}');
      if (e.code == 'failed-precondition' &&
          (e.message ?? '') == 'run_expired') {
        onError('This run expired — hints are unavailable.');
        return;
      }
      if (e.code == 'failed-precondition' &&
          ((e.message ?? '') == 'run_not_active' ||
              (e.message ?? '') == 'question_already_answered')) {
        onError('Too late — that question is already locked in.');
        return;
      }
      if (e.code == 'failed-precondition' &&
          (e.message ?? '').contains('App update required')) {
        onError('App update required: please update to the latest version.');
        return;
      }
      if (e.code == 'unauthenticated') {
        onError('Your session expired — sign in again, then retry.');
        return;
      }
      onError('Could not use hint — please try again.');
    } catch (e) {
      _ud.rollbackReservedCoinSpend(reservationId);
      clearFlight();
      debugPrint('[QuizController] useQuizHint failed: $e');
      onError('Could not use hint — please try again.');
    }
  }

  // ── Timer pause (freeze until answered) ────────────────────────────────────
  //
  // Freezes the countdown at its current value until the player answers.
  // No seconds are added and the timer does NOT auto-resume — answering
  // (selectOption) or advancing clears the pause. One use per question.
  // Coin spend uses the same reservation flow as hints (type 'spend_timer',
  // cost kTimerPauseCost, enforced server-side in spendCoins CF).

  Future<void> useTimerPause() async {
    if (isGauntlet) {
      onError('Timer Pause is disabled in Blitz — the clock never stops.');
      return;
    }
    if (_isNavigating || currentQuestion == null) return;
    if (currentTimerPauseUsed || _showResult || _timerPaused) return;

    if (!_ud.canAffordCoins(kTimerPauseCost)) {
      await onInsufficientCoins(kTimerPauseCost);
      return;
    }

    final questionIndexAtSpend = _qIndex;
    final reservationId = _ud.reserveCoins(kTimerPauseCost);

    // Freeze: stop ticking, keep _timerSeconds as-is.
    _timer?.cancel();
    _timerPaused = true;
    _timerPauseUsed[_qIndex] = true;
    _notify();

    try {
      await _ud.commitReservedCoinSpend(reservationId, 'spend_timer');
    } on InsufficientCoinsException {
      // Refund path: unfreeze and resume ticking so the player isn't stuck
      // with a dead timer after a failed spend.
      if (!_disposed && _qIndex == questionIndexAtSpend && !_showResult) {
        _timerPaused = false;
        _timerPauseUsed[_qIndex] = false;
        _notify();
        _startTimer();
      }
      await onInsufficientCoins(kTimerPauseCost);
    } catch (e) {
      if (!_disposed && _qIndex == questionIndexAtSpend && !_showResult) {
        _timerPaused = false;
        _timerPauseUsed[_qIndex] = false;
        _notify();
        _startTimer();
      }
      debugPrint('[QuizController] useTimerPause commit error: $e');
      // Transient (network / contention): let the player retry. Permanent
      // states (auth, update gate) name themselves so a retry loop cannot
      // spin forever.
      if (e is FirebaseFunctionsException) {
        if (e.code == 'unauthenticated') {
          onError('Your session expired — sign in again, then retry.');
          return;
        }
        if (e.code == 'failed-precondition' &&
            (e.message ?? '').contains('App update required')) {
          onError('App update required: please update to the latest version.');
          return;
        }
      }
      onError(
        'Transaction failed — please try again.',
        onRetry: () => useTimerPause(),
      );
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Explicitly cancels the current run (quit flow). Unlike the fire-and-
  /// forget [dispose] fallback, the first attempt is awaited, so quitting
  /// releases the one-active-run lock in the common case instead of leaving a
  /// stuck `run_in_progress` behind when the background cancel never lands.
  /// On failure a bounded background retry (2 more tries) keeps attempting
  /// while the app is alive. Marks the run completed so [dispose] does not
  /// refire. Returns true when the server confirmed (or there was nothing to
  /// cancel). Never traps the caller: return false on failure and let the
  /// home page's stuck-run recovery handle it.
  Future<bool> cancelCurrentRun() async {
    final rid = _runId;
    if (rid == null || rid.isEmpty || _completed) return true;
    try {
      await FirestoreService.instance
          .cancelRun(rid)
          .timeout(const Duration(seconds: 10));
      _completed = true;
      return true;
    } catch (e) {
      debugPrint('[QuizController] cancelCurrentRun failed, retrying: $e');
      unawaited(_retryCancelInBackground(rid));
      return false;
    }
  }

  /// Bounded backstop for a failed foreground cancel: 2 more attempts a few
  /// seconds apart. Fire-and-forget by design — success just clears the lock
  /// earlier than the run's natural expiry.
  Future<void> _retryCancelInBackground(String runId) async {
    for (int i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (_completed) return;
      try {
        await FirestoreService.instance
            .cancelRun(runId)
            .timeout(const Duration(seconds: 10));
        _completed = true;
        return;
      } catch (e) {
        debugPrint('[QuizController] background cancel retry failed: $e');
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();

    // Quitting without settling must not leave the one-active-run lock held.
    // Fire-and-forget: the page is already gone, and a failure only means the
    // run expires naturally.
    final rid = _runId;
    if (rid != null && rid.isNotEmpty && !_completed) {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('cancelRun');
      unawaited(() async {
        try {
          await callable.call<Map<String, dynamic>>({'runId': rid});
        } catch (e) {
          debugPrint('[QuizController] cancelRun failed (ignored): $e');
        }
      }());
    }

    super.dispose();
  }
}
