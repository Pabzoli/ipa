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
import 'questions.dart';

// ── Public constants (referenced by widget files) ──────────────────────────

enum QuizMode { solo, asyncChallenge, gauntlet }

const int kQuestionCount = 10;

// ── Daily Gauntlet (replaces the old 1.5× Daily Challenge) ──────────────────
/// Exactly 7 mixed-anime questions; escalating WP per position, awarded by
/// the submitDailyGauntlet CF. Order is positional — the client must preserve
/// the question order it received so client/server tiers stay aligned.
const int kGauntletQuestionCount = 7;

/// Weekly points per correct answer by question position (1-indexed):
/// Q1–Q3 → 15, Q4–Q5 → 20, Q6–Q7 → 25. Must mirror the server's
/// GAUNTLET_TIERS in functions/index.js — change both together.
const List<int> kGauntletTiers = [15, 15, 15, 20, 20, 25, 25];

/// Cost of a same-day Gauntlet retry, enforced atomically server-side inside
/// the submitDailyGauntlet transaction (the client never pre-deducts it).
/// Single-value alias kept for error fallbacks only — use gauntlet_economy
/// curves for all UI labels (see lib/core/constants/gauntlet_economy.dart).
const int kGauntletRetryCost = 40;

const int kHintCost = 10;

/// Timer Pause cost (20 AC): freezes the current question's countdown until
/// the player answers. Enforced server-side in the spendCoins CF
/// (type 'spend_timer', amount must equal 20).
const int kTimerPauseCost = 20;
const int kQuizCoinReward = 8;
const int kMaxHints = 2;
const int kTimerDuration = 10;

/// How many times [_submitToServer] will attempt the [submitQuizAnswers] CF
/// before giving up and surfacing a retryable error. Attempts are separated
/// by an exponential back-off starting at 1 s (1 s, 2 s, …).
const int _kCfMaxAttempts = 2;

// =============================================================================

class QuizController extends ChangeNotifier {
  QuizController({
    required this.mode,
    required this.selectedTitles,
    this.questionIds,
    this.challengeId,
    this.isCreator = true,
    this.isQuickMatch = false,
    this.isDailyChallenge = false, // ← DC
    this.isGauntlet = false, // ← Daily Gauntlet
    this.gauntletTicketId,
    required UserDataProvider userDataProvider,
    required this.onQuestionAdvance,
    required this.onSoloComplete,
    required this.onChallengeComplete,
    required this.onInsufficientCoins,
    required this.onError,
  }) : _ud = userDataProvider;

  // ── Config ─────────────────────────────────────────────────────────────────
  final QuizMode mode;
  final List<String> selectedTitles;
  final List<String>? questionIds;
  final String? challengeId;
  final bool isCreator;

  /// When true, challenge completion routes through [submitQuickMatchResult]
  /// CF. Ghost and real matches both then fire [onChallengeComplete] — the
  /// same live ChallengeResultPage flow Rival/Code challenges use.
  final bool isQuickMatch;

  /// When true this is the user's Daily Challenge session.
  ///
  /// Passed to the [submitQuizAnswers] Cloud Function which multiplies
  /// [totalWP] by 1.5 (round-up) server-side. The CF sets
  /// [dailyChallengeDate] and [dailyChallengeUsed] atomically — no
  /// client-side write is needed. Exposed as a public field so [QuestionsPage]
  /// can forward it directly to [SoloSummaryPage] without needing a
  /// callback-signature change.
  final bool isDailyChallenge; // ← DC

  /// When true this is a Daily Gauntlet session — 7 mixed-anime questions
  /// loaded from [questionIds] (positional order matters: the WP tier for
  /// each question is derived from its index). Completion routes through the
  /// submitDailyGauntlet Cloud Function, which awards the escalating WP tiers,
  /// applies the daily soft cap, enforces the 40 AC retry cost atomically, and
  /// updates the Gauntlet streak/milestones. Exposed as a public field so
  /// [QuestionsPage] can forward it to [SoloSummaryPage].
  final bool isGauntlet; // ← Daily Gauntlet

  /// Prepaid entry ticket minted by `enterDailyGauntlet` (null for the free
  /// daily attempt). Forwarded to submitDailyGauntlet so the server consumes
  /// it WITHOUT charging again. The entry fee was already deducted before the
  /// quiz page was entered (non-refundable on quit).
  final String? gauntletTicketId;

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
  ///
  /// Daily Gauntlet runs additionally report [streak] (post-run Gauntlet
  /// streak from the submitDailyGauntlet CF) and [gauntletPerQuestionWP]
  /// (weekly points earned per question position — 0 for a wrong answer,
  /// otherwise the positional tier). Only meaningful when [isGauntlet] is
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
    int streak,
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
  final void Function(String msg) onError;

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

  int get qIndex => _qIndex;
  int get selectedOption => _selectedOption;
  int get correctCount => _correctCount;
  bool get showResult => _showResult;
  bool get isNavigating => _isNavigating;

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

  /// Read-only view of the answer index recorded for each question so far
  /// (0-based option index, or -1 for a timeout / unanswered question).
  List<int> get selectedAnswers => List.unmodifiable(_selectedAnswers);

  // ── Hints ──────────────────────────────────────────────────────────────────
  int _sessionHintsUsed = 0;

  int get sessionHintsUsed => _sessionHintsUsed;
  int get hintsLeft => kMaxHints - _sessionHintsUsed;
  bool get hintsExhausted => hintsLeft <= 0;

  // ── Timer ──────────────────────────────────────────────────────────────────
  int _timerSeconds = kTimerDuration;
  Timer? _timer;
  DateTime? _questionStartTime;

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
  bool get canShowTimerPause =>
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
      List<AnimeQuestion> all;

      if (isGauntlet) {
        // Daily Gauntlet: load the exact 7 pre-picked mixed-anime questions.
        // Positional order is preserved (fetchQuestionsByIds returns them in
        // the given id order) so the WP tier for each index matches the CF.
        all = await FirestoreService.instance.fetchQuestionsByIds(questionIds!);
      } else if (mode == QuizMode.asyncChallenge) {
        all = await FirestoreService.instance.fetchQuestionsByIds(questionIds!);
      } else {
        // Order is owned by fetchQuestionsForTitles (shuffled within tiers,
        // interleaved E,M,H across titles) — do NOT re-shuffle here.
        all = await FirestoreService.instance
            .fetchQuestionsForTitles(selectedTitles);
      }

      if (_disposed) return;

      // Gauntlet runs keep exactly the 7 supplied questions; every other mode
      // clamps to the standard 10-question session.
      final taken = all
          .take(isGauntlet ? kGauntletQuestionCount : kQuestionCount)
          .toList();

      _questions = taken;
      _isLoading = false;
      _errorMsg = null;
      _eliminatedOpts = List.generate(taken.length, (_) => {});
      _timerPauseUsed = List.filled(taken.length, false);
      _timerPaused = false;
      _sessionHintsUsed = 0;
      _qIndex = 0;
      _selectedOption = -1;
      _timerSeconds = kTimerDuration;
      _correctCount = 0;
      _showResult = false;
      _isNavigating = false;
      _selectedAnswers = [];
      _answerTimings = [];

      _notify();

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
    _showResult = true;
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

  // ── Daily Gauntlet completion: submit to submitDailyGauntlet CF ────────────

  /// Submits the 7-question Gauntlet run. The CF awards the positional WP
  /// tiers (15/15/15/20/20/25/25) under the daily soft cap and updates the
  /// Gauntlet streak + milestones atomically.
  ///
  /// PREPAID FLOW: the retry cost was already deducted by `enterDailyGauntlet`
  /// BEFORE the quiz page was entered (ticket in [gauntletTicketId]); the CF
  /// consumes that ticket WITHOUT charging again. Legacy submits without a
  /// ticket still deduct atomically server-side.
  ///
  /// Error handling mirrors the solo path: on a definitive
  /// `resource-exhausted` (insufficient_coins) the InsufficientCoinsSheet is
  /// surfaced with the retry cost; on transient failures we retry with the
  /// same back-off, then surface a retryable error and reset _isNavigating.
  Future<void> _submitGauntletToServer() async {
    final cfQuestionIds = _questions.map((q) => q.id).toList();

    // Ensure the user is authenticated before attempting the CF call.
    // FirebaseAuth.instance.currentUser can be null briefly during app
    // startup or auth state restoration. Without a valid user, no ID
    // token is attached to the HTTPS callable request and the CF rejects
    // with 'unauthenticated'. We surface a clear error instead of retrying
    // a doomed request.
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      debugPrint('[QuizController] submitDailyGauntlet: no authenticated user');
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError(
          'You need to be signed in to submit your Gauntlet result. '
          'Please sign in and try again.',
        );
      }
      return;
    }

    // Force-refresh the ID token to ensure a valid, unexpired token is
    // attached to the HTTPS callable request. Without this, an expired
    // token causes the CF to reject with 'unauthenticated'.
    try {
      await currentUser.getIdToken(true);
    } catch (e) {
      debugPrint(
          '[QuizController] submitDailyGauntlet: token refresh failed: $e');
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError(
          'Your session has expired. Please sign in again to save '
          'your Gauntlet result.',
        );
      }
      return;
    }

    final uid = currentUser.uid;
    final sessionId = '${uid}_${DateTime.now().millisecondsSinceEpoch}';

    Object? lastError;

    for (int attempt = 1; attempt <= _kCfMaxAttempts; attempt++) {
      try {
        final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('submitDailyGauntlet');

        final result = await callable.call<Map<Object?, Object?>>({
          'questionIds': cfQuestionIds,
          'selectedAnswers': _selectedAnswers,
          'timings': _answerTimings,
          'sessionId': sessionId,
          if (gauntletTicketId != null) 'gauntletTicketId': gauntletTicketId,
        });

        if (_disposed) return;

        final data = Map<String, dynamic>.from(result.data);
        final correctCount = (data['correctCount'] as num).toInt();
        final totalWP = (data['totalWP'] as num?)?.toInt() ?? 0;
        final acEarned = (data['acEarned'] as num?)?.toInt() ?? 0;
        final streak = (data['streak'] as num?)?.toInt() ?? 0;
        final achievementCoins = (data['achievementAC'] as num?)?.toInt() ?? 0;
        final perQuestionWP = _gauntletPerQuestionWP();

        onSoloComplete(
          correctCount,
          _questions.length,
          acEarned,
          totalWP,
          isGauntlet: true,
          streak: streak,
          gauntletPerQuestionWP: perQuestionWP,
          achievementCoins: achievementCoins,
        );
        return; // ← success; exit retry loop
      } on FirebaseFunctionsException catch (e) {
        // Definitive rejections are not transient — stop retrying immediately.
        final isInsufficient = e.code == 'resource-exhausted' &&
            (e.message?.startsWith('insufficient_coins') ?? false);
        final isUnauthenticated = e.code == 'unauthenticated';
        debugPrint(
          '[QuizController] submitDailyGauntlet rejected '
          '(code=${e.code}, message=${e.message})',
        );
        if (isInsufficient && !_disposed) {
          _isNavigating = false;
          _notify();
          final needed = int.tryParse(e.message?.split(':').last ?? '') ??
              kGauntletRetryCost;
          await onInsufficientCoins(needed);
          return;
        }
        if (isUnauthenticated && !_disposed) {
          _isNavigating = false;
          _notify();
          onError(
            'Your session has expired. Please sign in again to save '
            'your Gauntlet result.',
          );
          return;
        }
        lastError = e;
        break;
      } catch (e) {
        lastError = e;
        debugPrint(
          '[QuizController] submitDailyGauntlet attempt '
          '$attempt/$_kCfMaxAttempts failed: $e',
        );
        if (attempt < _kCfMaxAttempts && !_disposed) {
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
    }

    if (!_disposed) {
      _isNavigating = false;
      _notify();
      onError(
        'Could not save your Gauntlet result — please check your connection '
        'and try again.',
      );
      debugPrint(
        '[QuizController] submitDailyGauntlet failed after '
        '$_kCfMaxAttempts attempts: $lastError',
      );
    }
  }

  /// Weekly points earned per question position: the positional tier when
  /// correct, 0 otherwise. Mirrors the server's tier ladder client-side purely
  /// for display; the authoritative total comes from the CF response.
  List<int> _gauntletPerQuestionWP() {
    final out = <int>[];
    for (int i = 0; i < _questions.length; i++) {
      final tier =
          i < kGauntletTiers.length ? kGauntletTiers[i] : kGauntletTiers.last;
      final correct = _selectedAnswers.length > i &&
          _selectedAnswers[i] == _questions[i].correctAnswerIndex;
      out.add(correct ? tier : 0);
    }
    return out;
  }

  // ── Solo completion: submit to Cloud Function ──────────────────────────────

  Future<void> _submitToServer() async {
    // Daily Gauntlet has its own submission path (submitDailyGauntlet CF).
    if (isGauntlet) {
      await _submitGauntletToServer();
      return;
    }

    final cfQuestionIds = _questions.map((q) => q.id).toList();

    // Ensure the user is authenticated before attempting the CF call.
    // FirebaseAuth.instance.currentUser can be null briefly during app
    // startup or auth state restoration — without a valid user, no ID
    // token is attached and the CF rejects with 'unauthenticated'.
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      debugPrint('[QuizController] submitQuizAnswers: no authenticated user');
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError(
          'You need to be signed in to submit your quiz result. '
          'Please sign in and try again.',
        );
      }
      return;
    }

    // Force-refresh the ID token to ensure a valid, unexpired token is
    // attached to the HTTPS callable request. Without this, an expired
    // token causes the CF to reject with 'unauthenticated'.
    try {
      await currentUser.getIdToken(true);
    } catch (e) {
      debugPrint(
          '[QuizController] submitQuizAnswers: token refresh failed: $e');
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

    final uid = currentUser.uid;
    final sessionId = '${uid}_${DateTime.now().millisecondsSinceEpoch}';

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
          'questionIds': cfQuestionIds,
          'selectedAnswers': _selectedAnswers,
          'timings': _answerTimings,
          'sessionId': sessionId,
          'isDailyChallenge': isDailyChallenge, // ← DC flag
        });

        if (_disposed) return;

        final data = Map<String, dynamic>.from(result.data);
        final correctCount = (data['correctCount'] as num).toInt();
        final totalWP = (data['totalWP'] as num?)?.toInt() ?? 0;
        final acEarned = (data['acEarned'] as num?)?.toInt() ?? 0;
        final achievementCoins = (data['achievementAC'] as num?)?.toInt() ?? 0;

        onSoloComplete(
          correctCount,
          _questions.length,
          acEarned,
          totalWP,
          achievementCoins: achievementCoins,
        );
        return; // ← success; exit retry loop
      } on FirebaseFunctionsException catch (e) {
        // Definitive rejections are not transient — stop retrying immediately.
        final isUnauthenticated = e.code == 'unauthenticated';
        debugPrint(
          '[QuizController] submitQuizAnswers rejected '
          '(code=${e.code}, message=${e.message})',
        );
        if (isUnauthenticated && !_disposed) {
          _isNavigating = false;
          _notify();
          onError(
            'Your session has expired. Please sign in again to save '
            'your result.',
          );
          return;
        }
        lastError = e;
        break;
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
    final cfQuestionIds = _questions.map((q) => q.id).toList();

    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('submitQuickMatchResult');

      final result = await callable.call<Map<Object?, Object?>>({
        'challengeId': challengeId,
        'questionIds': cfQuestionIds,
        'selectedAnswers': _selectedAnswers,
        'timings': _answerTimings,
      });

      if (_disposed) return;

      final data = Map<String, dynamic>.from(result.data);

      // correctCount is server-validated for both ghost and real paths.
      final correctCount = (data['correctCount'] as num).toInt();

      // Replenish the ghost pool with this session regardless of whether the
      // opponent was a ghost or a real player — non-fatal, never blocks
      // navigation.
      unawaited(_saveGhostSession(correctCount: correctCount));

      if (!_disposed) {
        onChallengeComplete(challengeId!, isCreator, correctCount);
      }
    } catch (e) {
      if (!_disposed) {
        _isNavigating = false;
        _notify();
        onError('Failed to save Quick Match result: $e');
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
  Future<void> _saveGhostSession({required int correctCount}) async {
    try {
      final username =
          FirebaseAuth.instance.currentUser?.displayName ?? 'Anonymous';

      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('saveGhostSession')
          .call<Map<String, dynamic>>({
        // Normalized to the lowercase Firestore contract (see seed script).
        // Quick Match sessions are single-anime so `first` is exact; solo
        // multi-anime sessions never reach here.
        'animeTitle': selectedTitles.isNotEmpty
            ? selectedTitles.first.trim().toLowerCase()
            : '',
        'questionIds': _questions.map((q) => q.id).toList(),
        'answers': _selectedAnswers,
        'score': correctCount,
        'username': username,
      });
    } catch (e) {
      debugPrint('[QuizController] saveGhostSession failed (non-fatal): $e');
    }
  }

  // ── Hint ───────────────────────────────────────────────────────────────────

  Future<void> useHint() async {
    if (_isNavigating || currentQuestion == null || hintsExhausted) return;

    if (!_ud.canAffordCoins(kHintCost)) {
      await onInsufficientCoins(kHintCost);
      return;
    }

    final q = currentQuestion!;
    final correct = q.correctAnswerIndex;
    final elim = _eliminatedOpts[_qIndex];

    final wrong = List.generate(q.options.length, (i) => i)
      ..removeWhere((i) => i == correct || elim.contains(i));

    if (wrong.isEmpty) return;

    final removedIndex = wrong[Random().nextInt(wrong.length)];
    final questionIndexAtSpend = _qIndex;
    final reservationId = _ud.reserveCoins(kHintCost);

    _eliminatedOpts[_qIndex].add(removedIndex);
    _sessionHintsUsed++;
    _notify();

    try {
      await _ud.commitReservedCoinSpend(reservationId, 'spend_hint');
    } on InsufficientCoinsException {
      if (!_disposed && _qIndex == questionIndexAtSpend) {
        _eliminatedOpts[_qIndex].remove(removedIndex);
        _sessionHintsUsed = max(0, _sessionHintsUsed - 1);
        _notify();
      }
      await onInsufficientCoins(kHintCost);
    } catch (e) {
      if (!_disposed && _qIndex == questionIndexAtSpend) {
        _eliminatedOpts[_qIndex].remove(removedIndex);
        _sessionHintsUsed = max(0, _sessionHintsUsed - 1);
        _notify();
      }
      debugPrint('[QuizController] useHint commit error: $e');
      onError('Transaction failed — please try again.');
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
      onError('Transaction failed — please try again.');
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
