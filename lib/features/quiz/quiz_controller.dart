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
//  QUICK MATCH ADDITIONS (Stage 12):
//  • isQuickMatch flag routes challenge completion to submitQuickMatchResult CF
//    instead of submitCreatorScore / submitOpponentScore.
//  • onQuickMatchComplete (optional) callback fires with the full result payload
//    so the parent page can navigate to QuickMatchResultPage.
//  • Non-quick-match asyncChallenge path is completely unchanged.
//
//  DAILY CHALLENGE ADDITIONS (Stage DC):
//  • isDailyChallenge constructor param (default false).
//  • When true, the 'isDailyChallenge' flag is included in the
//    submitQuizAnswers CF payload — the CF multiplies totalWP by 1.5 there.
//    The CF also sets dailyChallengeDate/dailyChallengeUsed atomically, so
//    no client-side stamp is needed after submission.
//  • If the CF is unreachable after retries, _isNavigating is reset and an
//    error snackbar is shown — no daily attempt is consumed.
//  • isDailyChallenge is a public field so QuestionsPage can forward it to
//    SoloSummaryPage without requiring a callback-signature change.
//    QuestionsPage should:
//      1. Accept isDailyChallenge in its own constructor (default false).
//      2. Pass it to QuizController(..., isDailyChallenge: isDailyChallenge).
//      3. In the onSoloComplete handler, pass controller.isDailyChallenge to
//         SoloSummaryPage(isDailyChallenge: controller.isDailyChallenge, ...).
// =============================================================================

import 'dart:async';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/widgets/insufficient_coins_sheet.dart';
import 'questions.dart';

// ── Public constants (referenced by widget files) ──────────────────────────

enum QuizMode { solo, asyncChallenge }

const int kQuestionCount  = 10;
const int kHintCost       = 15;
const int kTimerPauseCost = 20;
const int kQuizCoinReward = 8;
const int kMaxHints       = 2;
const int kTimerDuration  = 10;

/// How many times [_submitToServer] will attempt the [submitQuizAnswers] CF
/// before giving up and surfacing a retryable error. Attempts are separated
/// by an exponential back-off starting at 1 s (1 s, 2 s, …).
const int _kCfMaxAttempts = 2;

// ── Internal coin-op result ────────────────────────────────────────────────

enum _CoinResult { ok, insufficient, error }

// =============================================================================

class QuizController extends ChangeNotifier {
  QuizController({
    required this.mode,
    required this.selectedTitles,
    this.questionIds,
    this.challengeId,
    this.isCreator      = true,
    this.isQuickMatch   = false,
    this.isGhost        = false,
    this.opponentName   = '',
    this.isDailyChallenge = false,          // ← DC
    required UserDataProvider userDataProvider,
    required this.onQuestionAdvance,
    required this.onSoloComplete,
    required this.onChallengeComplete,
    this.onQuickMatchComplete,
    required this.onInsufficientCoins,
    required this.onError,
  }) : _ud = userDataProvider;

  // ── Config ─────────────────────────────────────────────────────────────────
  final QuizMode      mode;
  final List<String>  selectedTitles;
  final List<String>? questionIds;
  final String?       challengeId;
  final bool          isCreator;

  /// When true, challenge completion routes through [submitQuickMatchResult]
  /// CF and fires [onQuickMatchComplete] instead of [onChallengeComplete].
  final bool   isQuickMatch;

  /// Mirrors the isGhost flag returned by [joinMatchmakingQueue]. Passed
  /// through to [onQuickMatchComplete] so the result page can show the
  /// appropriate label.
  final bool   isGhost;

  /// Display name of the opponent (real or ghost). Passed through to
  /// [onQuickMatchComplete] for display on [QuickMatchResultPage].
  final String opponentName;

  /// When true this is the user's Daily Challenge session.
  ///
  /// Passed to the [submitQuizAnswers] Cloud Function which multiplies
  /// [totalWP] by 1.5 (round-up) server-side. The CF sets
  /// [dailyChallengeDate] and [dailyChallengeUsed] atomically — no
  /// client-side write is needed. Exposed as a public field so [QuestionsPage]
  /// can forward it directly to [SoloSummaryPage] without needing a
  /// callback-signature change.
  final bool isDailyChallenge;              // ← DC

  final UserDataProvider _ud;

  // ── Callbacks ──────────────────────────────────────────────────────────────

  /// Fired when the question index increments. Parent resets slide animation.
  final void Function(int newIndex) onQuestionAdvance;

  /// Solo quiz finished. Parent navigates to SoloSummaryPage.
  ///
  /// [wpEarned] is the server-validated weekly-points total returned by the
  /// submitQuizAnswers CF (already includes the 1.5× DC multiplier when
  /// applicable). This callback is only invoked on a successful CF response;
  /// on exhausted retries the controller surfaces an error instead.
  final void Function(int correct, int total, int coinsEarned, int wpEarned)
      onSoloComplete;

  /// Non-quick async challenge finished. Parent navigates to lobby or result
  /// page. Unchanged from pre-Stage-12 behaviour.
  final void Function(String cId, bool isCreator, int correct)
      onChallengeComplete;

  /// Quick Match finished. Nullable so existing [QuizController] construction
  /// sites that don't use Quick Match don't need to provide it.
  ///
  /// Parameters
  /// ----------
  /// [correct]       Number of questions answered correctly (server-validated).
  /// [total]         Total questions in the match.
  /// [opponentScore] Opponent's correct count. For ghost matches this is the
  ///                 stored ghost score; for real-opponent matches it is 0
  ///                 (the opponent hasn't played yet — result is async).
  /// [wpEarned]      Weekly Points awarded immediately. Ghost matches resolve
  ///                 immediately (35 / 15 / 5 WP). Real-opponent matches defer
  ///                 to the resolveChallengeOutcome trigger (0 here).
  /// [acEarned]      Anime Coins awarded immediately (ghost: 10 / 5 / 0;
  ///                 real: 0 — trigger handles it).
  /// [isGhost]       Server-confirmed ghost flag (mirrors [QuizController.isGhost]).
  /// [opponentName]  Display name forwarded from construction.
  final void Function(
    int    correct,
    int    total,
    int    opponentScore,
    int    wpEarned,
    int    acEarned,
    bool   isGhost,
    String opponentName,
  )? onQuickMatchComplete;

  /// Show InsufficientCoinsSheet. Awaitable so the controller can wait for
  /// the sheet to close before returning.
  final Future<void> Function(int needed) onInsufficientCoins;

  /// Show a SnackBar error message.
  final void Function(String msg) onError;

  // ── Loading / error ────────────────────────────────────────────────────────
  bool    _isLoading = true;
  String? _errorMsg;

  bool    get isLoading => _isLoading;
  String? get errorMsg  => _errorMsg;

  // ── Questions ──────────────────────────────────────────────────────────────
  List<AnimeQuestion> _questions      = [];
  List<Set<int>>      _eliminatedOpts = [];
  List<bool>          _timerPauseUsed = [];

  List<AnimeQuestion> get questions      => List.unmodifiable(_questions);
  int                 get totalQuestions => _questions.length;

  AnimeQuestion? get currentQuestion =>
      _questions.isNotEmpty && _qIndex < _questions.length
          ? _questions[_qIndex]
          : null;

  Set<int> get currentEliminated =>
      _qIndex < _eliminatedOpts.length ? _eliminatedOpts[_qIndex] : {};

  bool get currentTimerPauseUsed =>
      _qIndex < _timerPauseUsed.length && _timerPauseUsed[_qIndex];

  // ── Progress ───────────────────────────────────────────────────────────────
  int  _qIndex         = 0;
  int  _selectedOption = -1;
  int  _correctCount   = 0;
  bool _showResult     = false;
  bool _isNavigating   = false;
  bool _disposed       = false;

  int  get qIndex         => _qIndex;
  int  get selectedOption => _selectedOption;
  int  get correctCount   => _correctCount;
  bool get showResult     => _showResult;
  bool get isNavigating   => _isNavigating;

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
  List<int> _answerTimings   = [];

  /// Read-only view of the answer index recorded for each question so far
  /// (0-based option index, or -1 for a timeout / unanswered question).
  ///
  /// Used by [QuestionsPage] when forwarding the completed session to
  /// [QuickMatchResultPage] → [saveGhostSession] CF.
  List<int> get selectedAnswers => List.unmodifiable(_selectedAnswers);

  // ── Hints ──────────────────────────────────────────────────────────────────
  int  _sessionHintsUsed = 0;

  int  get sessionHintsUsed => _sessionHintsUsed;
  int  get hintsLeft        => kMaxHints - _sessionHintsUsed;
  bool get hintsExhausted   => hintsLeft <= 0;

  // ── Timer ──────────────────────────────────────────────────────────────────
  int       _timerSeconds   = kTimerDuration;
  Timer?    _timer;
  DateTime? _questionStartTime;

  int  get timerSeconds    => _timerSeconds;
  bool get timerIsUrgent   => _timerSeconds <= 5;
  bool get timerIsCritical => _timerSeconds <= 2;

  // ── Convenience pass-through ───────────────────────────────────────────────
  int get animeCoins => _ud.animeCoins;

  // ── Computed ───────────────────────────────────────────────────────────────
  bool get canShowTimerPause =>
      !_isLoading &&
      _questions.isNotEmpty &&
      timerIsUrgent &&
      !_showResult &&
      !_isNavigating &&
      !currentTimerPauseUsed;

  // ── Load ───────────────────────────────────────────────────────────────────

  Future<void> loadQuestions() async {
    _isLoading = true;
    _errorMsg  = null;
    _notify();

    try {
      List<AnimeQuestion> all;

      if (mode == QuizMode.asyncChallenge) {
        all = await FirestoreService.instance
            .fetchQuestionsByIds(questionIds!);
      } else {
        all = await FirestoreService.instance
            .fetchQuestionsForTitles(selectedTitles);
        all.shuffle(Random());
      }

      if (_disposed) return;

      final taken = all.take(kQuestionCount).toList();

      _questions        = taken;
      _isLoading        = false;
      _errorMsg         = null;
      _eliminatedOpts   = List.generate(taken.length, (_) => {});
      _timerPauseUsed   = List.filled(taken.length, false);
      _sessionHintsUsed = 0;
      _qIndex           = 0;
      _selectedOption   = -1;
      _timerSeconds     = kTimerDuration;
      _correctCount     = 0;
      _showResult       = false;
      _isNavigating     = false;
      _selectedAnswers  = [];
      _answerTimings    = [];

      _notify();

      if (taken.isNotEmpty) {
        _questionStartTime = DateTime.now();
        _startTimer();
      }
    } catch (e) {
      if (_disposed) return;
      _isLoading = false;
      _errorMsg  = e.toString().replaceFirst('Exception: ', '');
      _notify();
    }
  }

  // ── Timer ──────────────────────────────────────────────────────────────────

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || _isNavigating) return;
      if (_timerSeconds <= 0) {
        _timer?.cancel();
        _advance();
      } else {
        _timerSeconds--;
        _notify();
      }
    });
  }

  // ── Select option ──────────────────────────────────────────────────────────

  void selectOption(int index) {
    if (_showResult || _isNavigating || currentQuestion == null) return;

    // 1.5 s anti-bot floor
    final elapsed = _questionStartTime == null
        ? 9999
        : DateTime.now().difference(_questionStartTime!).inMilliseconds;
    if (elapsed < 1500) return;

    final correct = currentQuestion!.correctAnswerIndex;

    _selectedOption = index;
    _showResult     = true;
    if (index == correct) _correctCount++;
    _notify();

    _timer?.cancel();

    Future.delayed(const Duration(milliseconds: 900), () {
      if (!_disposed) _advance();
    });
  }

  // ── Advance ────────────────────────────────────────────────────────────────

  void _advance() {
    if (_isNavigating) return;

    _selectedAnswers.add(_selectedOption);
    _answerTimings.add(_selectedOption == -1 ? -1 : _timerSeconds);

    if (_qIndex < _questions.length - 1) {
      _qIndex++;
      _selectedOption = -1;
      _showResult     = false;
      _timerSeconds   = kTimerDuration;
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

  // ── Solo completion: submit to Cloud Function ──────────────────────────────

  Future<void> _submitToServer() async {
    final cfQuestionIds = _questions.map((q) => q.id).toList();
    final uid           = FirebaseAuth.instance.currentUser?.uid ?? 'anon';
    final sessionId     = '${uid}_${DateTime.now().millisecondsSinceEpoch}';

    _ud.claimReferralBonusIfEligible().catchError((Object e) {
      debugPrint('[QuizController] referral bonus (ignored): $e');
    });

    // ── Retry loop ────────────────────────────────────────────────────────────
    // totalScore, weeklyPoints, and animeCoins are server-only fields blocked
    // by Firestore security rules.  The submitQuizAnswers CF is the ONLY valid
    // write path for all three — there is no client-side fallback.
    //
    // On transient failure we retry up to _kCfMaxAttempts times with an
    // exponential back-off (attempt 1 → 1 s delay, attempt 2 → 2 s, …).
    // If every attempt fails we surface a retryable error snackbar and reset
    // _isNavigating so the user can tap "Submit" again without restarting the
    // quiz.  This matches the pattern used by _finishQuickMatch.
    Object? lastError;

    for (int attempt = 1; attempt <= _kCfMaxAttempts; attempt++) {
      try {
        final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('submitQuizAnswers');

        // isDailyChallenge is always included in the payload (true or false).
        // The CF multiplies totalWP by 1.5 when isDailyChallenge == true.
        final result = await callable.call<Map<Object?, Object?>>({
          'questionIds':      cfQuestionIds,
          'selectedAnswers':  _selectedAnswers,
          'timings':          _answerTimings,
          'sessionId':        sessionId,
          'isDailyChallenge': isDailyChallenge,               // ← DC flag
        });

        if (_disposed) return;

        final data         = Map<String, dynamic>.from(result.data);
        final correctCount = (data['correctCount'] as num).toInt();
        final totalWP      = (data['totalWP']      as num?)?.toInt() ?? 0;
        final acEarned     = (data['acEarned']      as num?)?.toInt() ?? 0;

        onSoloComplete(correctCount, _questions.length, acEarned, totalWP);
        return; // ← success; exit retry loop
      } catch (e) {
        lastError = e;
        debugPrint(
          '[QuizController] submitQuizAnswers attempt $attempt/$_kCfMaxAttempts '
          'failed: $e',
        );
        if (attempt < _kCfMaxAttempts && !_disposed) {
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
    }

    // ── All attempts exhausted ────────────────────────────────────────────────
    // Do NOT write to Firestore directly — totalScore, weeklyPoints, and
    // animeCoins are all blacklisted by security rules and would throw
    // Permission Denied, silently awarding the user nothing anyway.
    //
    // Instead, reset navigation state and surface a retryable error so the
    // user is informed and can try again (same pattern as _finishQuickMatch).
    if (!_disposed) {
      _isNavigating = false;
      _notify();
      onError(
        'Could not save your result — please check your connection and try again.',
      );
      debugPrint(
        '[QuizController] submitQuizAnswers failed after $_kCfMaxAttempts '
        'attempts: $lastError',
      );
    }
  }

    // ── Challenge completion ───────────────────────────────────────────────────
  //
  // Routes to _finishQuickMatch for quick matches, otherwise uses the existing
  // submitCreatorScore / submitOpponentScore path (completely unchanged).

  Future<void> _finishChallenge() async {
    if (isQuickMatch) {
      await _finishQuickMatch();
      return;
    }

    // ── Standard async challenge (non-quick) — unchanged ──────────────────
    try {
      if (isCreator) {
        await FirestoreService.instance
            .submitCreatorScore(challengeId!, _correctCount);
      } else {
        await FirestoreService.instance
            .submitOpponentScore(challengeId!, _correctCount);
      }
      if (!_disposed) {
        onChallengeComplete(challengeId!, isCreator, _correctCount);
      }
    } catch (e) {
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError('Failed to save score: $e');
      }
    }
  }

  // ── Quick Match completion ─────────────────────────────────────────────────
  //
  // Calls the submitQuickMatchResult Cloud Function which:
  //   • Ghost match → scores immediately, awards WP + AC, returns full result.
  //   • Real match  → writes creatorScore / opponentScore to the challenge doc;
  //                   resolveChallengeOutcome trigger awards AC + updates stats
  //                   when both scores are present. Returns minimal payload.
  //
  // On any CF failure the error snackbar is shown and navigation is reset so
  // the player can retry (same pattern as _finishChallenge).

  Future<void> _finishQuickMatch() async {
    final cfQuestionIds = _questions.map((q) => q.id).toList();

    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('submitQuickMatchResult');

      final result = await callable.call<Map<Object?, Object?>>({
        'challengeId':     challengeId,
        'questionIds':     cfQuestionIds,
        'selectedAnswers': _selectedAnswers,
        'timings':         _answerTimings,
      });

      if (_disposed) return;

      final data = Map<String, dynamic>.from(result.data);

      // correctCount is server-validated for both ghost and real paths.
      final correctCount  = (data['correctCount']  as num).toInt();
      // isGhost is confirmed server-side; mirrors the constructor flag.
      final isGhostResult = (data['isGhost']       as bool?) ?? isGhost;
      // wpEarned and acEarned are non-zero only on the ghost path; real-match
      // rewards are handled asynchronously by resolveChallengeOutcome.
      final wpEarned      = (data['wpEarned']      as num?)?.toInt() ?? 0;
      final acEarned      = (data['acEarned']      as num?)?.toInt() ?? 0;
      // opponentScore: ghost path returns the stored ghost score; real path
      // returns 0 (opponent hasn't played yet — async resolution pending).
      final oppScore      = (data['opponentScore'] as num?)?.toInt() ?? 0;

      onQuickMatchComplete?.call(
        correctCount,
        _questions.length,
        oppScore,
        wpEarned,
        acEarned,
        isGhostResult,
        opponentName,
      );
    } catch (e) {
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError('Failed to save Quick Match result: $e');
      }
    }
  }

  // ── Hint ───────────────────────────────────────────────────────────────────

  Future<void> useHint() async {
    if (_isNavigating || currentQuestion == null || hintsExhausted) return;

    final result = await _spendCoins(kHintCost, 'spend_hint');
    if (result != _CoinResult.ok || _disposed) return;

    final q       = currentQuestion!;
    final correct = q.correctAnswerIndex;
    final elim    = _eliminatedOpts[_qIndex];

    final wrong = List.generate(q.options.length, (i) => i)
      ..removeWhere((i) => i == correct || elim.contains(i));

    if (wrong.isEmpty) return;

    _eliminatedOpts[_qIndex].add(wrong[Random().nextInt(wrong.length)]);
    _sessionHintsUsed++;
    _notify();
  }

  // ── Timer pause ────────────────────────────────────────────────────────────

  Future<void> useTimerPause() async {
    if (_isNavigating || currentQuestion == null) return;
    if (currentTimerPauseUsed || _showResult) return;

    final result = await _spendCoins(kTimerPauseCost, 'spend_timer');
    if (result != _CoinResult.ok || _disposed) return;

    _timer?.cancel();
    _timerSeconds            += 5;
    _timerPauseUsed[_qIndex] = true;
    _notify();
    _startTimer();
  }

  // ── Coin helper ────────────────────────────────────────────────────────────

  Future<_CoinResult> _spendCoins(int amount, String type) async {
    if (_ud.animeCoins < amount) {
      await onInsufficientCoins(amount);
      return _CoinResult.insufficient;
    }
    try {
      await _ud.spendCoins(amount, type);
      return _CoinResult.ok;
    } on InsufficientCoinsException {
      await onInsufficientCoins(amount);
      return _CoinResult.insufficient;
    } catch (e) {
      debugPrint('[QuizController] _spendCoins error: $e');
      onError('Transaction failed — please try again.');
      return _CoinResult.error;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}