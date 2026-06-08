// lib/features/quiz/solo_summary_page.dart
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/widgets/insufficient_coins_sheet.dart';
import '../../core/services/firestore_service.dart';       // for InsufficientCoinsException
import '../../core/services/ad_service.dart';
import '../../core/providers/user_data_provider.dart';
import 'questions_page.dart';
import 'share_card_widget.dart';

/// Cost to reset the daily cooldown and replay immediately (spend_retry).
const int _kRetryCost = 40;

class SoloSummaryPage extends StatefulWidget {
  final int          correctCount;
  final int          totalQuestions;
  final List<String> selectedTitles;

  /// Coins that were just earned for completing this quiz.
  /// Returned by the submitQuizAnswers CF (or the fallback path) and passed
  /// from [QuestionsPage] so the animation and badge need no extra round-trip.
  final int coinsEarned;

  /// Weekly points awarded for this quiz session.
  /// Returned by the submitQuizAnswers CF as [totalWP] (already includes the
  /// 1.5× DC multiplier when applicable, or estimated as correctCount × 10
  /// on the fallback path) and passed from [QuestionsPage].
  final int wpEarned;

  /// Whether this result came from a Daily Challenge session.
  ///
  /// When true, a prominent "⚡ Daily Challenge — 1.5× WP Applied" banner is
  /// shown on the result card to explain the boosted [wpEarned] figure.
  /// Passed from [QuestionsPage] via [controller.isDailyChallenge].
  final bool isDailyChallenge;                             // ← DC

  /// Called after a successful 40 AC retry payment clears the SharedPreferences
  /// cooldown entries, so the caller (HomePage) can also remove the titles from
  /// its in-memory [_locks] map and immediately re-enable them in the UI.
  ///
  /// Null-safe — passing null is valid (e.g. when navigating from a retry quiz
  /// that has no parent HomePageState to notify).
  final VoidCallback? onRetryLockCleared;

  const SoloSummaryPage({
    super.key,
    required this.correctCount,
    required this.totalQuestions,
    required this.selectedTitles,
    this.coinsEarned      = 0,
    this.wpEarned         = 0,
    this.isDailyChallenge = false,                         // ← DC
    this.onRetryLockCleared,                               // ← lock fix
  });

  @override
  State<SoloSummaryPage> createState() => _SoloSummaryPageState();
}

class _SoloSummaryPageState extends State<SoloSummaryPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _scaleAnim;
  late Animation<double>   _fadeAnim;

  bool _navigating = false;
  bool _isSharing  = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _scaleAnim = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fadeAnim  = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // ── 1. Coin earn animation for quiz completion reward ─────────────────
      // Fires at 400 ms so the score UI has settled before the overlay appears.
      if (widget.coinsEarned > 0) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) CoinEarnAnimation.show(context, amount: widget.coinsEarned);
        });
      }

      // ── 2. P-05 Ad sequence ───────────────────────────────────────────────
      // Increment the session counter first, then fire the ad chain.
      // This is intentionally not awaited at the top level — the ad sequence
      // runs independently of the UI (which has already rendered the results).
      _runAdSequence();
    });
  }

  /// Runs the result-screen ad sequence.
  ///
  /// Increments the session quiz count (for any non-ad consumers), waits
  /// 500 ms so the player sees their score, then delegates the interstitial
  /// frequency/cooldown/cap decision entirely to AdService.
  Future<void> _runAdSequence() async {
    if (!mounted) return;

    final userData = context.read<UserDataProvider>();

    userData.incrementSessionQuizCount();

    // Let the player see their result before any ad.
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    await AdService.instance.recordResultAndMaybeShowInterstitial(
      isPremium: userData.premiumActive,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  _Tier get _tier {
    final ratio = widget.correctCount / widget.totalQuestions;
    if (ratio == 1.0) return _Tier.perfect;
    if (ratio >= 0.8) return _Tier.great;
    if (ratio >= 0.5) return _Tier.good;
    return _Tier.keepPracticing;
  }

  // ── Share ──────────────────────────────────────────────────────────────────

  Future<void> _shareResult() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);

    try {
      final fbUser   = FirebaseAuth.instance.currentUser;
      final username = (fbUser?.displayName?.isNotEmpty == true)
          ? fbUser!.displayName!
          : fbUser?.email?.split('@').first ?? 'Player';

      final userData = context.read<UserDataProvider>();

      final bytes = await ScreenshotController().captureFromWidget(
        Theme(
          data: AppTheme.dark,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ShareCardWidget(
              correctCount:   widget.correctCount,
              totalQuestions: widget.totalQuestions,
              selectedTitles: widget.selectedTitles,
              username:       username,
              tierEmoji:      _tier.emoji,
              tierTitle:      _tier.title,
              tierColor:      _tier.color,
              weeklyPoints:   userData.weeklyPoints,
              totalScore:     userData.weeklyPoints, // mirrors WP; remove once ShareCardWidget.totalScore is made optional
            ),
          ),
        ),
        context:    context,
        delay:      const Duration(milliseconds: 300),
        pixelRatio: 3.0,
        targetSize: const Size(ShareCardWidget.kWidth, ShareCardWidget.kHeight),
      );

      final dir  = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/animequiz_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);

      if (!mounted) return;

      await Share.shareXFiles(
        [XFile(file.path)],
        text: '🎌 I scored ${widget.correctCount}/${widget.totalQuestions}'
            ' on AnimeQuiz!\nCan you beat me?',
      );
    } catch (e, st) {
      debugPrint('[ShareResult] error: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Couldn\'t generate share card — please try again.')),
      );
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (_) => _goHome(),
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const SizedBox(height: 32),

                    // ── Result emoji + title ───────────────────────────────
                    ScaleTransition(
                      scale: _scaleAnim,
                      child: Column(
                        children: [
                          Text(_tier.emoji,
                              style: const TextStyle(fontSize: 72)),
                          const SizedBox(height: 16),
                          Text(
                            _tier.title,
                            style: const TextStyle(
                              color:      AppColors.textPrimary,
                              fontSize:   28,
                              fontWeight: FontWeight.w900,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _tier.subtitle,
                            style: const TextStyle(
                              color:    AppColors.textSecondary,
                              fontSize: 14,
                              height:   1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // ── ⚡ Daily Challenge banner (shown only when active) ──
                    // Appears above the score card so it's the first thing the
                    // user reads after the tier emoji.
                    if (widget.isDailyChallenge) ...[
                      Container(
                        width:   double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 13),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFF59E0B).withOpacity(0.18),
                              const Color(0xFFFF6B00).withOpacity(0.12),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: const Color(0xFFF59E0B).withOpacity(0.55)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('⚡',
                                style: TextStyle(fontSize: 20)),
                            const SizedBox(width: 10),
                            const Text(
                              'Daily Challenge',
                              style: TextStyle(
                                color:      Color(0xFFF59E0B),
                                fontSize:   14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '·  1.5× WP applied',
                              style: TextStyle(
                                color:      const Color(0xFFF59E0B)
                                    .withOpacity(0.80),
                                fontSize:   13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // ── Score card ─────────────────────────────────────────
                    GlassCard(
                      borderColor: _tier.color.withOpacity(0.4),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment:  MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${widget.correctCount}',
                                style: TextStyle(
                                  color:      _tier.color,
                                  fontSize:   64,
                                  fontWeight: FontWeight.w900,
                                  height:     1,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(
                                  ' / ${widget.totalQuestions}',
                                  style: const TextStyle(
                                    color:      AppColors.textSecondary,
                                    fontSize:   24,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text('correct answers',
                              style: TextStyle(
                                  color:    AppColors.textMuted,
                                  fontSize: 13)),
                          const SizedBox(height: 20),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value:           widget.correctCount /
                                               widget.totalQuestions,
                              backgroundColor: AppColors.divider,
                              valueColor: AlwaysStoppedAnimation(_tier.color),
                              minHeight:  10,
                            ),
                          ),
                          const SizedBox(height: 20),

                          // ── Coins earned badge (shown when > 0) ──────────
                          if (widget.coinsEarned > 0) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFBBF24).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: const Color(0xFFFBBF24)
                                        .withOpacity(0.35)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text('🪙',
                                      style: TextStyle(fontSize: 18)),
                                  const SizedBox(width: 8),
                                  Text(
                                    '+${widget.coinsEarned} coins earned!',
                                    style: const TextStyle(
                                      color:      Color(0xFFFBBF24),
                                      fontSize:   14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          // ── Weekly points earned badge (shown when > 0) ──
                          // wpEarned is the server-validated total returned by
                          // the submitQuizAnswers CF (or correctCount × 10 on
                          // the fallback path). When isDailyChallenge is true,
                          // this value already includes the 1.5× multiplier
                          // applied by the CF. Sky-blue distinguishes it from
                          // the accent-purple score badge and gold coins badge.
                          if (widget.wpEarned > 0) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF38BDF8).withOpacity(0.10),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: const Color(0xFF38BDF8)
                                        .withOpacity(0.35)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.leaderboard_rounded,
                                    color: Color(0xFF38BDF8),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '+${widget.wpEarned} weekly pts earned!'
                                    '${widget.isDailyChallenge ? '  ⚡' : ''}',
                                    style: const TextStyle(
                                      color:      Color(0xFF38BDF8),
                                      fontSize:   14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ── Hint nudge ─────────────────────────────────────────
                    if (widget.correctCount < 5)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color:        AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border:       Border.all(color: AppColors.divider),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.info_outline_rounded,
                                color: AppColors.textMuted, size: 20),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Struggling? Use hints next round to '
                                'eliminate wrong answers.',
                                style: TextStyle(
                                  color:    AppColors.textSecondary,
                                  fontSize: 13,
                                  height:   1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 32),

                    // ── Actions ────────────────────────────────────────────

                    // ── SPEND SURFACE 3: Try Again (40 AC) ────────────────
                    // Only shown for regular quizzes. Daily Challenge is
                    // strictly 1 attempt per day — no retry is offered.
                    if (!widget.isDailyChallenge) ...[
                      GestureDetector(
                        onTap: _tryAgainWithCoins,
                        child: Container(
                          width:  double.infinity,
                          height: 52,
                          decoration: BoxDecoration(
                            color: AppColors.accent.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: AppColors.accent.withOpacity(0.40)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('🔄', style: TextStyle(fontSize: 16)),
                              SizedBox(width: 8),
                              Text(
                                'Try Again  —  40🪙',
                                style: TextStyle(
                                  color:      AppColors.accent,
                                  fontSize:   14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // ── Share Result ───────────────────────────────────────
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _isSharing
                          ? _ShareLoadingIndicator(
                              key: const ValueKey('loading'))
                          : _ShareButton(
                              key:   const ValueKey('share'),
                              onTap: _shareResult,
                            ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _goHome,
                        icon: const Icon(Icons.home_rounded,
                            color: AppColors.textSecondary, size: 18),
                        label: const Text('Back to Home',
                            style:
                                TextStyle(color: AppColors.textSecondary)),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: AppColors.divider),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Handlers ───────────────────────────────────────────────────────────────

  void _goHome() {
    if (_navigating) return;
    _navigating = true;
    Navigator.of(context).pop();
  }

  // ── SPEND SURFACE 3: Try Again with cooldown reset (40 AC) ────────────────
  //
  // Cooldowns are stored in SharedPreferences (not Firestore) by HomePage,
  // using each anime title as the key. Removing the key here is enough to
  // clear the lock — HomePage re-reads prefs on its next initState call.
  //
  // This retry is NOT a Daily Challenge session — it is purely a cooldown
  // reset. The new quiz will launch with isDailyChallenge: false.
  Future<void> _tryAgainWithCoins() async {
    if (_navigating) return;

    final userData = context.read<UserDataProvider>();

    // Balance check before showing the dialog.
    if (userData.animeCoins < _kRetryCost) {
      if (mounted) await showInsufficientCoinsSheet(context, needed: _kRetryCost);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Try Again?',
          style: TextStyle(
            color:      AppColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: const Text(
          'Spend 40🪙 to reset today\'s cooldown and replay the '
          'same anime immediately?',
          style: TextStyle(
            color:    AppColors.textSecondary,
            fontSize: 14,
            height:   1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              '🔄 Try Again  −40🪙',
              style: TextStyle(
                color:      AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      // 1. Deduct coins (throws InsufficientCoinsException on race condition).
      await userData.spendCoins(_kRetryCost, 'spend_retry');

      // 2. Clear the SharedPreferences cooldown entry for every title played.
      //    Keys are namespaced by UID (matching home_page's _prefKey helper).
      final uid   = FirebaseAuth.instance.currentUser?.uid ?? '';
      final prefs = await SharedPreferences.getInstance();
      for (final title in widget.selectedTitles) {
        await prefs.remove(uid.isEmpty ? title : '${uid}_$title');
      }

      // 3. Notify the HomePage to clear its in-memory _locks map for these
      //    titles. Without this the tiles stay visually locked for the rest
      //    of the session even though the user just paid to unlock them.
      widget.onRetryLockCleared?.call();

      if (!mounted) return;

      // 4. Navigate directly into a fresh quiz — no DC, no interstitial on
      //    paid retry.
      _navigating = true;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: QuestionsPage(
              selectedTitles:     widget.selectedTitles,
              isDailyChallenge:   false,                   // ← explicit: not DC
              onRetryLockCleared: widget.onRetryLockCleared, // ← carry forward
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } on InsufficientCoinsException {
      // Balance dropped between the pre-check and the Firestore transaction.
      if (mounted) await showInsufficientCoinsSheet(context, needed: _kRetryCost);
    } catch (e) {
      // Network error, prefs failure, etc. — do NOT show "not enough coins".
      debugPrint('[SoloSummaryPage] _tryAgainWithCoins error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Something went wrong — please try again.')),
        );
      }
    }
  }
}

// ── Share button widgets ───────────────────────────────────────────────────

class _ShareButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ShareButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width:  double.infinity,
          height: 52,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF5B2D8E), Color(0xFF7B4FBB)],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color:      const Color(0xFF7B4FBB).withOpacity(0.35),
                blurRadius: 16,
                offset:     const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.ios_share_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(
                'Share Result',
                style: TextStyle(
                  color:      Colors.white,
                  fontSize:   15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      );
}

class _ShareLoadingIndicator extends StatelessWidget {
  const _ShareLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width:  double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: const Color(0xFF5B2D8E).withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: const Color(0xFF7B4FBB).withOpacity(0.3)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 15, height: 15,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF9B6FDB)),
            ),
            SizedBox(width: 10),
            Text(
              'Creating share card…',
              style: TextStyle(
                color:      Color(0xFF9B6FDB),
                fontSize:   14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
}

// ── Performance Tiers ──────────────────────────────────────────────────────

enum _Tier { perfect, great, good, keepPracticing }

extension _TierProps on _Tier {
  String get emoji {
    switch (this) {
      case _Tier.perfect:        return '🏆';
      case _Tier.great:          return '🔥';
      case _Tier.good:           return '⚔️';
      case _Tier.keepPracticing: return '📖';
    }
  }

  String get title {
    switch (this) {
      case _Tier.perfect:        return 'Perfect Score!';
      case _Tier.great:          return 'You\'re on Fire!';
      case _Tier.good:           return 'Good Fight!';
      case _Tier.keepPracticing: return 'Keep Training!';
    }
  }

  String get subtitle {
    switch (this) {
      case _Tier.perfect:
        return 'Flawless. You know your anime.';
      case _Tier.great:
        return 'Strong performance — leaderboard material.';
      case _Tier.good:
        return 'Decent run. One more session and you\'re climbing.';
      case _Tier.keepPracticing:
        return 'Every legend starts somewhere. Keep going.';
    }
  }

  Color get color {
    switch (this) {
      case _Tier.perfect:        return AppColors.accent;
      case _Tier.great:          return AppColors.correct;
      case _Tier.good:           return AppColors.secondary;
      case _Tier.keepPracticing: return AppColors.textMuted;
    }
  }
}