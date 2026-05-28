// lib/features/quiz/solo_summary_page.dart
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart'; // ← NEW (spend_retry)

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/widgets/insufficient_coins_sheet.dart'; // ← NEW (spend_retry)
import '../../core/services/firestore_service.dart';       // for InsufficientCoinsException
import '../../core/services/ad_service.dart';              // ← P-05
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
  /// Passed from [QuestionsPage] so we can show [CoinEarnAnimation]
  /// and the inline badge without a second Firestore round-trip.
  final int          coinsEarned;

  const SoloSummaryPage({
    super.key,
    required this.correctCount,
    required this.totalQuestions,
    required this.selectedTitles,
    this.coinsEarned = 0,
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
      // Fires at 400ms so the score UI has settled before the overlay appears.
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

  /// P-05: Runs the full result-screen ad sequence.
  ///
  /// Step 1 — increment the in-memory session quiz counter.
  /// Step 2 — wait 500ms so the player sees their score first.
  /// Step 3 — show rewarded interstitial (all users, including Premium).
  ///           If the user watches the full ad: award +5 AC and show animation.
  ///           If the user skips: no penalty, continue normally.
  /// Step 4 — once the rewarded interstitial is fully dismissed, show the
  ///           regular interstitial if this is the 3rd quiz in the session
  ///           and the user is not Premium.
  ///
  /// Both ads run sequentially — never simultaneously.
  Future<void> _runAdSequence() async {
    if (!mounted) return;

    final userData = context.read<UserDataProvider>();

    // Step 1: increment session quiz count BEFORE the interstitial check so
    // the count is already updated when showInterstitialIfDue reads it.
    userData.incrementSessionQuizCount();

    // Step 2: let the player see their result.
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    // Step 3: rewarded interstitial — fires for all users, including Premium.
    await AdService.instance.showRewardedInterstitial(
      context,
      onRewarded: () {
        if (!mounted) return;
        // Award +5 AC via Provider → FirestoreService (fire-and-forget is fine;
        // the Firestore transaction is atomic regardless of awaiting here).
        userData.updateAnimeCoins(5, 'earn_rewarded_interstitial').catchError((e) {
          debugPrint('[SoloSummaryPage] rewarded interstitial coin award error: $e');
        });
        // Show the coin animation overlay.
        CoinEarnAnimation.show(context, amount: 5);
      },
    );

    // Step 4: regular interstitial — non-Premium users, every 3rd session quiz.
    // The future above already completed, so this never overlaps with Step 3.
    if (!mounted) return;
    AdService.instance.showInterstitialIfDue(
      isPremium:       userData.premiumActive,
      sessionQuizCount: userData.sessionQuizCount,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int   get _pointsEarned => widget.correctCount * 10;
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
              totalScore:     userData.score,
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

                    const SizedBox(height: 36),

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
                          // ── Points earned ───────────────────────────────
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 12),
                            decoration: BoxDecoration(
                              color:        AppColors.accent.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: AppColors.accent.withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.stars_rounded,
                                    color: AppColors.accent, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  '+$_pointsEarned pts added to your balance',
                                  style: const TextStyle(
                                    color:      AppColors.accent,
                                    fontSize:   14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // ── Coins earned badge (shown when > 0) ─────────
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
                    // Resets the daily cooldown for every anime played so the
                    // user can immediately replay the same selection.
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
      await userData.updateAnimeCoins(-_kRetryCost, 'spend_retry');

      // 2. Clear the SharedPreferences cooldown entry for every title played.
      //    Keys are namespaced by UID (matching home_page's _prefKey helper).
      final uid   = FirebaseAuth.instance.currentUser?.uid ?? '';
      final prefs = await SharedPreferences.getInstance();
      for (final title in widget.selectedTitles) {
        await prefs.remove(uid.isEmpty ? title : '${uid}_$title');
      }

      if (!mounted) return;

      // 3. Navigate directly into a fresh quiz — no interstitial on paid retry.
      _navigating = true;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: QuestionsPage(selectedTitles: widget.selectedTitles),
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
          const SnackBar(content: Text('Something went wrong — please try again.')),
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