// lib/features/multiplayer/quick_match_result_page.dart

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/widgets/shared_widgets.dart';
import 'multiplayer_hub_page.dart';

/// Quick Match result screen.
///
/// Important layout design:
/// - The whole page scrolls vertically.
/// - No Expanded/Flexible is used in the vertical page layout.
/// - Expanded is used only inside the horizontal VS row.
/// - This prevents:
///   "RenderFlex children have non-zero flex but incoming height constraints
///   are unbounded."
class QuickMatchResultPage extends StatefulWidget {
  final int localCorrect;
  final int opponentScore;
  final int totalQuestions;

  final String opponentName;
  final int coinsEarned;
  final int wpEarned;
  final bool isGhost;

  // Ghost-pool replenishment.
  final String animeTitle;
  final List<String> questionIds;
  final List<int> answers;

  const QuickMatchResultPage({
    super.key,
    required this.localCorrect,
    required this.opponentScore,
    required this.totalQuestions,
    this.opponentName = 'Opponent',
    this.coinsEarned = 0,
    this.wpEarned = 0,
    this.isGhost = false,
    required this.animeTitle,
    required this.questionIds,
    required this.answers,
  });

  @override
  State<QuickMatchResultPage> createState() => _QuickMatchResultPageState();
}

class _QuickMatchResultPageState extends State<QuickMatchResultPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  bool _navigating = false;
  bool _ghostSessionSaved = false;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();

    _scaleAnim = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.elasticOut,
    );

    _fadeAnim = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeIn,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // Completion coin animation.
      if (widget.coinsEarned > 0) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;

          CoinEarnAnimation.show(
            context,
            amount: widget.coinsEarned,
          );
        });
      }

      // Ads + result tally.
      _runAdSequence();

      // Save completed match to ghost pool.
      _saveGhostSession();
    });
  }

  // ---------------------------------------------------------------------------
  // Ads
  // ---------------------------------------------------------------------------

  Future<void> _runAdSequence() async {
    if (!mounted) return;

    final userData = context.read<UserDataProvider>();

    // Let the result screen settle first.
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    try {
      await AdService.instance.recordResultAndMaybeShowInterstitial(
        isPremium: userData.premiumActive,
      );
    } catch (e) {
      // Ads must never break the result page.
      debugPrint(
        '[QuickMatchResultPage] Ad sequence failed (non-fatal): $e',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Ghost pool
  // ---------------------------------------------------------------------------

  Future<void> _saveGhostSession() async {
    if (_ghostSessionSaved) return;

    _ghostSessionSaved = true;

    try {
      if (!mounted) return;

      final username =
          FirebaseAuth.instance.currentUser?.displayName ?? 'Anonymous';

      await FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('saveGhostSession').call<Map<String, dynamic>>({
        'animeTitle': widget.animeTitle,
        'questionIds': widget.questionIds,
        'answers': widget.answers,
        'score': widget.localCorrect,
        'username': username,
      });

      debugPrint(
        '[QuickMatchResultPage] saveGhostSession ✓ '
        'anime=${widget.animeTitle} '
        'score=${widget.localCorrect}/10',
      );
    } catch (e) {
      // Non-fatal.
      debugPrint(
        '[QuickMatchResultPage] '
        'saveGhostSession failed (non-fatal): $e',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Derived state
  // ---------------------------------------------------------------------------

  _MatchOutcome get _outcome {
    if (widget.localCorrect > widget.opponentScore) {
      return _MatchOutcome.win;
    }

    if (widget.localCorrect < widget.opponentScore) {
      return _MatchOutcome.loss;
    }

    return _MatchOutcome.draw;
  }

  _Tier get _tier {
    if (widget.totalQuestions <= 0) {
      return _Tier.keepPracticing;
    }

    final ratio =
        widget.localCorrect / widget.totalQuestions;

    if (ratio >= 1.0) {
      return _Tier.perfect;
    }

    if (ratio >= 0.8) {
      return _Tier.great;
    }

    if (ratio >= 0.5) {
      return _Tier.good;
    }

    return _Tier.keepPracticing;
  }

  double get _accuracy {
    if (widget.totalQuestions <= 0) {
      return 0;
    }

    final value =
        widget.localCorrect / widget.totalQuestions;

    return value.clamp(0.0, 1.0);
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _goHome() {
    if (_navigating) return;

    _navigating = true;

    Navigator.of(context).popUntil(
      (route) => route.isFirst,
    );
  }

  void _playAgain() {
    if (_navigating) return;

    _navigating = true;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const MultiplayerHubPage(),
      ),
      (route) => route.isFirst,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      20.r,
                      24.r,
                      20.r,
                      28.r,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 52,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: 8.h),

                          // ====================================================
                          // OUTCOME HEADER
                          // ====================================================

                          ScaleTransition(
                            scale: _scaleAnim,
                            child: _buildOutcomeHeader(),
                          ),

                          SizedBox(height: 28.h),

                          // ====================================================
                          // SCORE CARD
                          // ====================================================

                          _buildScoreCard(),

                          SizedBox(height: 16.h),

                          // ====================================================
                          // PERFORMANCE NUDGE
                          // ====================================================

                          if (widget.totalQuestions > 0 &&
                              widget.localCorrect <
                                  (widget.totalQuestions ~/ 2))
                            _buildPerformanceNudge(),

                          SizedBox(height: 28.h),

                          // ====================================================
                          // ACTIONS
                          // ====================================================

                          _buildActions(),

                          SizedBox(height: 4.h),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Outcome header
  // ---------------------------------------------------------------------------

  Widget _buildOutcomeHeader() {
    if (!widget.isGhost) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '⏳',
            style: TextStyle(fontSize: 64.sp),
          ),
          SizedBox(height: 10.h),
          Text(
            'Match in Progress',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 28.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 8.h),
          Text(
            'Waiting for your opponent to finish.\n'
            'Rewards land automatically when they\'re done.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14.sp,
              height: 1.5,
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _outcome.emoji,
          style: TextStyle(
            fontSize: 68.sp,
          ),
        ),
        SizedBox(height: 10.h),
        Text(
          _outcome.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 28.sp,
            fontWeight: FontWeight.w900,
          ),
        ),
        SizedBox(height: 8.h),
        Text(
          _outcome.subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14.sp,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Score card
  // ---------------------------------------------------------------------------

  Widget _buildScoreCard() {
    return GlassCard(
      borderColor: _outcome.accentColor.withOpacity(0.4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---------------------------------------------------------------
          // Head-to-head scores
          // ---------------------------------------------------------------

          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: _PlayerScore(
                  label: 'You',
                  score: widget.localCorrect,
                  total: widget.totalQuestions,
                  color: _outcome.accentColor,
                  isLeft: true,
                ),
              ),

              SizedBox(width: 8.w),

              Expanded(
                child: Center(
                  child: Text(
                    'VS',
                    style: TextStyle(
                      color: AppColors.textMuted.withOpacity(0.5),
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),

              SizedBox(width: 8.w),

              Flexible(
                fit: FlexFit.loose,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _PlayerScore(
                      label: widget.opponentName,
                      score: widget.opponentScore,
                      total: widget.totalQuestions,
                      color: AppColors.textMuted,
                      isLeft: false,
                    ),

                    if (widget.isGhost) ...[
                      SizedBox(height: 6.h),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8.r,
                          vertical: 3.r,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.textMuted.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8.r),
                          border: Border.all(
                            color: AppColors.textMuted.withOpacity(0.25),
                          ),
                        ),
                        child: Text(
                          'Recorded match',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10.sp,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),

          SizedBox(height: 20.h),

          // ---------------------------------------------------------------
          // Accuracy
          // ---------------------------------------------------------------

          ClipRRect(
            borderRadius: BorderRadius.circular(6.r),
            child: LinearProgressIndicator(
              value: _accuracy,
              backgroundColor: AppColors.divider,
              valueColor: AlwaysStoppedAnimation<Color>(
                _outcome.accentColor,
              ),
              minHeight: 10.h,
            ),
          ),

          SizedBox(height: 8.h),

          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${widget.localCorrect}/${widget.totalQuestions} correct',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.sp,
              ),
            ),
          ),

          SizedBox(height: 20.h),

          // ---------------------------------------------------------------
          // Rewards
          // ---------------------------------------------------------------

          if (widget.isGhost && widget.wpEarned > 0)
            _buildRewardPill(
              icon: Icons.stars_rounded,
              iconColor: AppColors.accent,
              text: '+${widget.wpEarned} pts added to your balance',
              textColor: AppColors.accent,
              backgroundColor:
                  AppColors.accent.withOpacity(0.1),
              borderColor:
                  AppColors.accent.withOpacity(0.3),
            )
          else if (!widget.isGhost)
            _buildRewardPill(
              icon: Icons.hourglass_top_rounded,
              iconColor: AppColors.textMuted,
              text: 'Rewards pending opponent\'s result',
              textColor: AppColors.textMuted,
              backgroundColor:
                  AppColors.textMuted.withOpacity(0.08),
              borderColor:
                  AppColors.textMuted.withOpacity(0.2),
            ),

          if (widget.wpEarned > 0) ...[
            SizedBox(height: 10.h),
            _buildRewardPill(
              icon: Icons.trending_up_rounded,
              iconColor: const Color(0xFF818CF8),
              text: '+${widget.wpEarned} WP earned!',
              textColor: const Color(0xFF818CF8),
              backgroundColor:
                  const Color(0xFF6366F1).withOpacity(0.1),
              borderColor:
                  const Color(0xFF6366F1).withOpacity(0.35),
            ),
          ],

          if (widget.coinsEarned > 0) ...[
            SizedBox(height: 10.h),
            _buildRewardPill(
              icon: Icons.monetization_on_rounded,
              iconColor: const Color(0xFFFBBF24),
              text: '+${widget.coinsEarned} coins earned!',
              textColor: const Color(0xFFFBBF24),
              backgroundColor:
                  const Color(0xFFFBBF24).withOpacity(0.1),
              borderColor:
                  const Color(0xFFFBBF24).withOpacity(0.35),
              leadingText: '🪙',
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Reward pill
  // ---------------------------------------------------------------------------

  Widget _buildRewardPill({
    required IconData icon,
    required Color iconColor,
    required String text,
    required Color textColor,
    required Color backgroundColor,
    required Color borderColor,
    String? leadingText,
  }) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 14.r,
        vertical: 12.r,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: borderColor,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leadingText != null) ...[
            Text(
              leadingText,
              style: TextStyle(
                fontSize: 18.sp,
              ),
            ),
          ] else
            Icon(
              icon,
              color: iconColor,
              size: 20.r,
            ),

          SizedBox(width: 8.w),

          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor,
                fontSize: 13.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Performance nudge
  // ---------------------------------------------------------------------------

  Widget _buildPerformanceNudge() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(
          color: AppColors.divider,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: AppColors.textMuted,
            size: 20.r,
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              _tier.nudge,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13.sp,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Widget _buildActions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Play again
        GestureDetector(
          onTap: _playAgain,
          child: Container(
            width: double.infinity,
            height: 54.h,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF5B2D8E),
                  Color(0xFF7B4FBB),
                ],
              ),
              borderRadius: BorderRadius.circular(16.r),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7B4FBB)
                      .withOpacity(0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.replay_rounded,
                  color: Colors.white,
                  size: 18.r,
                ),
                SizedBox(width: 8.w),
                Text(
                  'Play Again',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: 12.h),

        // Back home
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _goHome,
            icon: Icon(
              Icons.home_rounded,
              color: AppColors.textSecondary,
              size: 18.r,
            ),
            label: const Text(
              'Back to Home',
              style: TextStyle(
                color: AppColors.textSecondary,
              ),
            ),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.symmetric(
                vertical: 14.r,
              ),
              side: const BorderSide(
                color: AppColors.divider,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16.r),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Player score
// ============================================================================

class _PlayerScore extends StatelessWidget {
  final String label;
  final int score;
  final int total;
  final Color color;
  final bool isLeft;

  const _PlayerScore({
    required this.label,
    required this.score,
    required this.total,
    required this.color,
    required this.isLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          isLeft
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 110.w,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign:
                isLeft
                    ? TextAlign.left
                    : TextAlign.right,
            style: TextStyle(
              color: color,
              fontSize: 13.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),

        SizedBox(height: 6.h),

        Text(
          '$score',
          style: TextStyle(
            color: color,
            fontSize: 48.sp,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),

        SizedBox(height: 2.h),

        Text(
          '/ $total',
          style: TextStyle(
            color: AppColors.textMuted.withOpacity(0.6),
            fontSize: 13.sp,
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Match outcome
// ============================================================================

enum _MatchOutcome {
  win,
  loss,
  draw,
}

extension _MatchOutcomeProps on _MatchOutcome {
  String get emoji {
    switch (this) {
      case _MatchOutcome.win:
        return '🏆';
      case _MatchOutcome.loss:
        return '💀';
      case _MatchOutcome.draw:
        return '🤝';
    }
  }

  String get title {
    switch (this) {
      case _MatchOutcome.win:
        return 'You Won!';
      case _MatchOutcome.loss:
        return 'Defeated!';
      case _MatchOutcome.draw:
        return 'It\'s a Draw!';
    }
  }

  String get subtitle {
    switch (this) {
      case _MatchOutcome.win:
        return 'Dominant performance. The crown is yours.';
      case _MatchOutcome.loss:
        return 'Close fight. One more match and the tables turn.';
      case _MatchOutcome.draw:
        return 'Evenly matched — rematch to break the tie?';
    }
  }

  Color get accentColor {
    switch (this) {
      case _MatchOutcome.win:
        return AppColors.correct;
      case _MatchOutcome.loss:
        return AppColors.wrong;
      case _MatchOutcome.draw:
        return AppColors.secondary;
    }
  }
}

// ============================================================================
// Performance tier
// ============================================================================

enum _Tier {
  perfect,
  great,
  good,
  keepPracticing,
}

extension _TierProps on _Tier {
  String get nudge {
    switch (this) {
      case _Tier.perfect:
      case _Tier.great:
        return 'Great accuracy — keep it up!';

      case _Tier.good:
        return 'Decent run. One more match and you\'re climbing the ranks.';

      case _Tier.keepPracticing:
        return 'Struggling? Solo mode is great for drilling weak spots.';
    }
  }
}