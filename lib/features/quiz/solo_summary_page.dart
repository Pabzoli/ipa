// lib/features/quiz/solo_summary_page.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_chip.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_page_route.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/ad_service.dart';
import '../../core/providers/user_data_provider.dart';
import 'questions_page.dart';
import 'quiz_controller.dart' show kGauntletTiers;

// Solo cooldown-retry (non-Gauntlet) flat cost. Kept for the legacy
// "Try Again 40 AC" replay that clears local cooldown locks only.
const int _kRetryCost = 40;

class SoloSummaryPage extends StatefulWidget {
  final int correctCount;
  final int totalQuestions;
  final List<String> selectedTitles;
  final String soloDifficulty;
  final int coinsEarned;
  final int wpEarned;

  /// Coins granted from crossed achievement tiers (`achievementAC` from the
  /// CF). Rendered with a distinct trophy/purple UI from base [coinsEarned]
  /// and logged as a separate `earn_achievement` ledger entry server-side.
  final int achievementCoins;
  final bool isDailyChallenge;
  final bool isGauntlet;
  final int gauntletStreak;
  final List<int> gauntletPerQuestionWP;
  final VoidCallback? onRetryLockCleared;

  const SoloSummaryPage({
    super.key,
    required this.correctCount,
    required this.totalQuestions,
    required this.selectedTitles,
    this.soloDifficulty = 'easy',
    this.coinsEarned = 0,
    this.wpEarned = 0,
    this.achievementCoins = 0,
    this.isDailyChallenge = false,
    this.isGauntlet = false,
    this.gauntletStreak = 0,
    this.gauntletPerQuestionWP = const [],
    this.onRetryLockCleared,
  });

  @override
  State<SoloSummaryPage> createState() => _SoloSummaryPageState();
}

class _SoloSummaryPageState extends State<SoloSummaryPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fadeAnim;
  late Animation<double> _slideAnim;
  late Animation<double> _medallionScale;

  bool _navigating = false;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..forward();

    _fadeAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slideAnim = Tween<double>(begin: 18, end: 0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    _medallionScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.6, end: 1.08), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.08, end: 1.0), weight: 40),
    ]).animate(CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.1, 0.75, curve: Curves.easeOut)));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.coinsEarned > 0) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted)
            CoinEarnAnimation.show(context, amount: widget.coinsEarned);
        });
      }
      // Achievement coins get their own distinct (purple/trophy) animation so
      // they are visually separable from base quiz earnings. Staggered after
      // the base animation when both fire.
      if (widget.achievementCoins > 0) {
        Future.delayed(
          Duration(milliseconds: widget.coinsEarned > 0 ? 1700 : 500),
          () {
            if (mounted) {
              CoinEarnAnimation.showAchievement(
                context,
                amount: widget.achievementCoins,
              );
            }
          },
        );
      }
      _runAdSequence();
    });
  }

  Future<void> _runAdSequence() async {
    if (!mounted) return;
    final userData = context.read<UserDataProvider>();
    userData.incrementSessionQuizCount();
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

  double get _accuracy => widget.correctCount / widget.totalQuestions;

  void _goHome() {
    if (_navigating) return;
    _navigating = true;
    Navigator.of(context).pop();
  }

  Future<void> _tryAgainWithCoins() async {
    if (_navigating) return;

    if (widget.isGauntlet) return;

    final userData = context.read<UserDataProvider>();
    if (userData.animeCoins < _kRetryCost) {
      if (mounted)
        await showInsufficientCoinsSheet(context, needed: _kRetryCost);
      return;
    }

    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => AppDialog(
        title: 'Try Again?',
        contentWidget: Text(
          'Spend 40🪙 to reset today\'s cooldown and replay the same anime immediately?',
          style: AppTypography.bodyMedium,
        ),
        actions: [
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.text,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            label: '🔄 Try Again  −40🪙',
            variant: AppButtonVariant.text,
            color: AppColors.accent,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await userData.spendCoins(_kRetryCost, 'spend_retry');

      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final prefs = await SharedPreferences.getInstance();
      for (final title in widget.selectedTitles) {
        await prefs.remove(uid.isEmpty ? title : '${uid}_$title');
      }
      widget.onRetryLockCleared?.call();

      if (!mounted) return;
      _navigating = true;
      Navigator.of(context).pushReplacement(
        AppPageRoute(
          builder: (_) => QuestionsPage(
            selectedTitles: widget.selectedTitles,
            soloDifficulty: widget.soloDifficulty,
            isDailyChallenge: false,
            onRetryLockCleared: widget.onRetryLockCleared,
          ),
        ),
      );
    } on InsufficientCoinsException {
      if (mounted)
        await showInsufficientCoinsSheet(context, needed: _kRetryCost);
    } catch (e) {
      debugPrint('[SoloSummaryPage] _tryAgainWithCoins error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Something went wrong — please try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tier = _tier;
    final pct = (_accuracy * 100).round();
    final currentCoins = context.watch<UserDataProvider>().animeCoins;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, __) => _goHome(),
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: AnimatedBuilder(
              animation: _slideAnim,
              builder: (_, child) => Transform.translate(
                offset: Offset(0, _slideAnim.value),
                child: child,
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 32.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Header ────────────────────────────────────────
                    _HeaderRow(coins: currentCoins),
                    SizedBox(height: 20.h),

                    // ── Result hero ───────────────────────────────────
                    ScaleTransition(
                      scale: _medallionScale,
                      child: _ResultHero(
                        tier: tier,
                        correct: widget.correctCount,
                        total: widget.totalQuestions,
                      ),
                    ),
                    SizedBox(height: 20.h),

                    // ── Stats ─────────────────────────────────────────
                    _StatsCard(
                      tier: tier,
                      accuracy: _accuracy,
                      pct: pct,
                      coinsEarned: widget.coinsEarned,
                      wpEarned: widget.wpEarned,
                      achievementCoins: widget.achievementCoins,
                      isGauntlet: widget.isGauntlet,
                      isDailyChallenge: widget.isDailyChallenge,
                      titles: widget.selectedTitles,
                      soloDifficulty: widget.soloDifficulty,
                    ),

                    // ── Achievement bonus (distinct UI) ───────────────
                    if (widget.achievementCoins > 0) ...[
                      SizedBox(height: 12.h),
                      const _AchievementBonusBanner(),
                    ],

                    // ── Gauntlet panel ────────────────────────────────
                    if (widget.isGauntlet) ...[
                      SizedBox(height: 12.h),
                      _GauntletResultPanel(
                        streak: widget.gauntletStreak,
                        perQuestionWP: widget.gauntletPerQuestionWP,
                      ),
                    ],

                    // ── Hint ──────────────────────────────────────────
                    if (widget.correctCount < 5) ...[
                      SizedBox(height: 12.h),
                      const _HintCard(),
                    ],

                    SizedBox(height: 24.h),

                    // ── Actions ───────────────────────────────────────
                    SizedBox(
                      width: double.infinity,
                      height: 54.h,
                      child: AppButton(
                        label: 'Back to Home',
                        icon: Icon(Icons.home_rounded,
                            color: Colors.white, size: 18.r),
                        variant: AppButtonVariant.primary,
                        size: AppButtonSize.large,
                        height: 54.h,
                        onPressed: _goHome,
                      ),
                    ),
                    if (!widget.isDailyChallenge && !widget.isGauntlet) ...[
                      SizedBox(height: 10.h),
                      SizedBox(
                        width: double.infinity,
                        height: 44.h,
                        child: AppButton(
                          label: 'Try Again  —  40🪙',
                          icon: Text('🔄', style: TextStyle(fontSize: 13.sp)),
                          variant: AppButtonVariant.outline,
                          color: AppColors.accent,
                          size: AppButtonSize.small,
                          height: 44.h,
                          onPressed: _tryAgainWithCoins,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Header row
// ═══════════════════════════════════════════════════════════════════════════
class _HeaderRow extends StatelessWidget {
  final int coins;
  const _HeaderRow({required this.coins});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'QUIZ COMPLETE',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
        const Spacer(),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 5.r),
          decoration: BoxDecoration(
            color: AppColors.accent.withOpacity(0.13),
            borderRadius: BorderRadius.circular(20.r),
            border: Border.all(color: AppColors.accent.withOpacity(0.32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('🪙', style: TextStyle(fontSize: 12.sp)),
              SizedBox(width: 5.w),
              Text(
                '$coins',
                style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Result hero — medallion + score + tier feedback, all in one card
// ═══════════════════════════════════════════════════════════════════════════
class _ResultHero extends StatelessWidget {
  final _Tier tier;
  final int correct;
  final int total;

  const _ResultHero({
    required this.tier,
    required this.correct,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 30.r, horizontal: 24.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            tier.color.withOpacity(0.14),
            tier.color.withOpacity(0.04),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(24.r),
        border: Border.all(color: tier.color.withOpacity(0.25), width: 1.2),
      ),
      child: Column(
        children: [
          // ── Emoji medallion ─────────────────────────────────────
          Container(
            width: 72.r,
            height: 72.r,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tier.color.withOpacity(0.16),
              border:
                  Border.all(color: tier.color.withOpacity(0.4), width: 1.5),
            ),
            child: Center(
              child: Text(tier.emoji, style: TextStyle(fontSize: 34.sp)),
            ),
          ),
          SizedBox(height: 18.h),

          // ── Score ───────────────────────────────────────────────
          RichText(
            text: TextSpan(
              style: const TextStyle(fontFamily: 'Nunito'),
              children: [
                TextSpan(
                  text: '$correct',
                  style: TextStyle(
                    color: tier.color,
                    fontSize: 64.sp,
                    fontWeight: FontWeight.w900,
                    height: 1,
                    letterSpacing: -2,
                  ),
                ),
                TextSpan(
                  text: '/$total',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 22.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 14.h),

          // ── Tier badge ──────────────────────────────────────────
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 6.r),
            decoration: BoxDecoration(
              color: tier.color.withOpacity(0.14),
              borderRadius: BorderRadius.circular(20.r),
              border: Border.all(color: tier.color.withOpacity(0.35)),
            ),
            child: Text(
              tier.title.toUpperCase(),
              style: TextStyle(
                color: tier.color,
                fontSize: 11.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.3,
              ),
            ),
          ),
          SizedBox(height: 12.h),

          // ── Subtitle ────────────────────────────────────────────
          Text(
            tier.subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.sp,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Stats card — accuracy + rewards + topics
// ═══════════════════════════════════════════════════════════════════════════
class _StatsCard extends StatelessWidget {
  final _Tier tier;
  final double accuracy;
  final int pct;
  final int coinsEarned;
  final int wpEarned;
  final int achievementCoins;
  final bool isGauntlet;
  final bool isDailyChallenge;
  final List<String> titles;
  final String soloDifficulty;

  const _StatsCard({
    required this.tier,
    required this.accuracy,
    required this.pct,
    required this.coinsEarned,
    required this.wpEarned,
    this.achievementCoins = 0,
    required this.isGauntlet,
    required this.isDailyChallenge,
    required this.titles,
    this.soloDifficulty = 'easy',
  });

  @override
  Widget build(BuildContext context) {
    final hasRewards =
        coinsEarned > 0 || wpEarned > 0 || achievementCoins > 0;

    return Container(
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Difficulty badge (solo only) ────────────────────────
          if (!isGauntlet)
            _DifficultyPill(difficulty: soloDifficulty),
          if (!isGauntlet) SizedBox(height: 14.h),
          // ── Accuracy ────────────────────────────────────────────
          Row(
            children: [
              Text(
                'ACCURACY',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              Text(
                '$pct%',
                style: TextStyle(
                  color: tier.color,
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
          SizedBox(height: 10.h),
          ClipRRect(
            borderRadius: BorderRadius.circular(6.r),
            child: LinearProgressIndicator(
              value: accuracy,
              backgroundColor: AppColors.divider,
              valueColor: AlwaysStoppedAnimation(tier.color),
              minHeight: 8,
            ),
          ),

          // ── Rewards ─────────────────────────────────────────────
          // Base coins (gold/🪙) and achievement coins (purple/🏆) are
          // visually distinct by color, icon, and label — achievement coins
          // come from a separate `earn_achievement` ledger entry.
          if (hasRewards) ...[
            SizedBox(height: 18.h),
            Container(height: 1, color: AppColors.divider),
            SizedBox(height: 16.h),
            Row(
              children: [
                if (coinsEarned > 0)
                  Expanded(
                    child: _RewardBlock(
                      emoji: '🪙',
                      value: '+$coinsEarned',
                      label: 'coins this round',
                      color: AppColors.coinGold,
                    ),
                  ),
                if (coinsEarned > 0 && wpEarned > 0) SizedBox(width: 12.w),
                if (wpEarned > 0)
                  Expanded(
                    child: _RewardBlock(
                      icon: Icons.leaderboard_rounded,
                      value: '+$wpEarned',
                      label: isGauntlet
                          ? 'weekly pts'
                          : isDailyChallenge
                              ? 'weekly pts ⚡'
                              : 'weekly pts',
                      color: AppColors.skyBright,
                    ),
                  ),
              ],
            ),
            if (achievementCoins > 0) ...[
              SizedBox(height: 12.h),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 12.r, vertical: 10.r),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(0.10),
                  borderRadius: BorderRadius.circular(14.r),
                  border: Border.all(
                    color: const Color(0xFF8B5CF6).withOpacity(0.45),
                  ),
                ),
                child: _RewardBlock(
                  emoji: '🏆',
                  value: '+$achievementCoins',
                  label: 'achievement bonus',
                  color: const Color(0xFF8B5CF6),
                ),
              ),
            ],
          ],

          // ── Topics ──────────────────────────────────────────────
          if (titles.isNotEmpty) ...[
            SizedBox(height: 18.h),
            Container(height: 1, color: AppColors.divider),
            SizedBox(height: 16.h),
            Text(
              'TOPICS',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
            SizedBox(height: 10.h),
            Wrap(
              spacing: 6.w,
              runSpacing: 6.w,
              children: titles.map((t) {
                final display = t
                    .split(' ')
                    .map((w) =>
                        w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
                    .join(' ');
                return AppChip(
                  label: display,
                  color: AppColors.textMuted,
                  selected: false,
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Difficulty pill — shows which homepage tier this solo run was played on
// ═══════════════════════════════════════════════════════════════════════════
class _DifficultyPill extends StatelessWidget {
  final String difficulty;
  const _DifficultyPill({required this.difficulty});

  @override
  Widget build(BuildContext context) {
    final d = difficulty.trim().toLowerCase();
    final (emoji, label, color) = switch (d) {
      'hard' => ('🔥', 'HARD', const Color(0xFFEF4444)),
      'medium' => ('⚔️', 'MEDIUM', const Color(0xFFF59E0B)),
      _ => ('🌱', 'EASY', const Color(0xFF34D399)),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: TextStyle(fontSize: 14.sp)),
          SizedBox(width: 8.w),
          Text(
            '$label MODE',
            style: TextStyle(
              color: color,
              fontSize: 11.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Reward block — icon + big value + small label
// ═══════════════════════════════════════════════════════════════════════════
class _RewardBlock extends StatelessWidget {
  final String? emoji;
  final IconData? icon;
  final String value;
  final String label;
  final Color color;

  const _RewardBlock({
    required this.value,
    required this.label,
    required this.color,
    this.emoji,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (emoji != null) Text(emoji!, style: TextStyle(fontSize: 18.sp)),
        if (icon != null) Icon(icon, color: color, size: 18.r),
        SizedBox(width: 8.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 17.sp,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  letterSpacing: -0.3,
                ),
              ),
              SizedBox(height: 2.h),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Achievement bonus banner — distinct purple/trophy styling separate from
// base gold/coin rewards. Explains that these coins came from achievements.
// ═══════════════════════════════════════════════════════════════════════════
class _AchievementBonusBanner extends StatelessWidget {
  const _AchievementBonusBanner();

  static const _purple = Color(0xFF8B5CF6);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _purple.withOpacity(0.16),
            _purple.withOpacity(0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: _purple.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          Container(
            width: 36.r,
            height: 36.r,
            decoration: BoxDecoration(
              color: _purple.withOpacity(0.18),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: _purple.withOpacity(0.40)),
            ),
            child: Center(
              child: Text('🏆', style: TextStyle(fontSize: 18.sp)),
            ),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ACHIEVEMENT REWARD',
                  style: TextStyle(
                    color: _purple,
                    fontSize: 9.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.0,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  'Bonus coins from crossed achievement tiers — tracked separately in your ledger.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5.sp,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Hint card
// ═══════════════════════════════════════════════════════════════════════════
class _HintCard extends StatelessWidget {
  const _HintCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 32.r,
            height: 32.r,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.14),
              borderRadius: BorderRadius.circular(10.r),
            ),
            child: Icon(
              Icons.lightbulb_outline_rounded,
              color: AppColors.accent,
              size: 17.r,
            ),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Text(
              'Use a hint next round to eliminate wrong answers before guessing.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.sp,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tier enum + extension (unchanged)
// ═══════════════════════════════════════════════════════════════════════════
enum _Tier { perfect, great, good, keepPracticing }

extension _TierProps on _Tier {
  String get emoji {
    switch (this) {
      case _Tier.perfect:
        return '🏆';
      case _Tier.great:
        return '🔥';
      case _Tier.good:
        return '⚔️';
      case _Tier.keepPracticing:
        return '📖';
    }
  }

  String get title {
    switch (this) {
      case _Tier.perfect:
        return 'Perfect Score';
      case _Tier.great:
        return 'You\'re on Fire';
      case _Tier.good:
        return 'Good Fight';
      case _Tier.keepPracticing:
        return 'Keep Training';
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
      case _Tier.perfect:
        return AppColors.accent;
      case _Tier.great:
        return AppColors.correct;
      case _Tier.good:
        return AppColors.secondary;
      case _Tier.keepPracticing:
        return AppColors.textMuted;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Gauntlet result panel (unchanged)
// ═══════════════════════════════════════════════════════════════════════════
class _GauntletResultPanel extends StatelessWidget {
  final int streak;
  final List<int> perQuestionWP;

  const _GauntletResultPanel({
    required this.streak,
    required this.perQuestionWP,
  });

  static const Map<int, String> _milestones = {
    3: '40🪙',
    7: '100🪙 + 50 WP',
    14: '200🪙 + 100 WP + 🖼️ Frame',
    30: '500🪙 + 7d Premium',
  };

  int? get _nextMilestoneDay {
    for (final day in _milestones.keys) {
      if (streak < day) return day;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final nextDay = _nextMilestoneDay;
    final tiers = kGauntletTiers;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md + 2),
      tier: AppCardTier.standard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('🔥', style: TextStyle(fontSize: 16.sp)),
              SizedBox(width: 7.w),
              Text(
                '$streak day streak',
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 14.sp,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  nextDay != null
                      ? '${nextDay - streak}d → ${_milestones[nextDay]}'
                      : 'All milestones claimed',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 12.h),
          Row(
            children: [
              for (int i = 0; i < tiers.length; i++) ...[
                if (i > 0) SizedBox(width: 5.w),
                Expanded(child: _tierChip(i, tiers[i])),
              ],
            ],
          ),
          SizedBox(height: 8.h),
          Text(
            'WP per question — tiers climb as you survive',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tierChip(int index, int tier) {
    final correct = index < perQuestionWP.length && perQuestionWP[index] > 0;
    final isTopTier = tier == kGauntletTiers.last;
    return Container(
      padding: EdgeInsets.symmetric(vertical: 7.r),
      decoration: BoxDecoration(
        color: correct
            ? AppColors.amber.withValues(alpha: 0.22)
            : AppColors.surfaceAlt.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(
          color: correct
              ? AppColors.amber.withValues(alpha: 0.55)
              : AppColors.divider.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Q${index + 1}',
            style: TextStyle(
              color: correct ? AppColors.amber : AppColors.textMuted,
              fontSize: 9.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 2.h),
          Text(
            correct ? '+$tier' : '$tier',
            style: TextStyle(
              color: correct
                  ? AppColors.amber
                  : (isTopTier ? AppColors.textSecondary : AppColors.textMuted),
              fontSize: 12.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}