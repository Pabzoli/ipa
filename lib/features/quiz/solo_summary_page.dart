// lib/features/quiz/solo_summary_page.dart
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

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
import '../premium/premium_upsell_screen.dart';
import 'questions_page.dart';
import '../../core/constants/blitz_economy.dart';
import '../../core/constants/solo_economy.dart';

// The replay cost lives in kSoloRetryCost (mirrors SOLO_RETRY_COST server-side).

/// Achievement purple: a fill hue that is too light for small text on white.
const Color _kPurple = Color(0xFF8B5CF6);
Color get _purpleText => AppColors.isDark ? _kPurple : const Color(0xFF6D28D9);

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
  final bool isGauntlet;

  /// Blitz questions attempted before the clock ran out (<= totalQuestions).
  /// Equals totalQuestions for solo runs.
  final int answeredCount;
  final List<int> gauntletPerQuestionWP;

  const SoloSummaryPage({
    super.key,
    required this.correctCount,
    required this.totalQuestions,
    required this.selectedTitles,
    this.soloDifficulty = 'easy',
    this.coinsEarned = 0,
    this.wpEarned = 0,
    this.achievementCoins = 0,
    this.isGauntlet = false,
    this.answeredCount = 0,
    this.gauntletPerQuestionWP = const [],
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

  /// True from the confirm tap until the retry charge resolves, so a second tap
  /// on a slow connection cannot pay the 80🪙 retry twice.
  bool _retrying = false;

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
          if (mounted) {
            CoinEarnAnimation.show(context, amount: widget.coinsEarned);
          }
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

  void _openPremiumUpsell() {
    Navigator.of(context).push(
      AppPageRoute(builder: (_) => const PremiumUpsellScreen()),
    );
  }

  Future<void> _tryAgainWithCoins() async {
    if (_navigating || _retrying) return;

    if (widget.isGauntlet) return;

    final userData = context.read<UserDataProvider>();

    // Retry is a Premium perk — free users are routed to the upsell instead.
    if (!userData.premiumActive) {
      _openPremiumUpsell();
      return;
    }

    if (userData.animeCoins < kSoloRetryCost) {
      if (mounted) {
        await showInsufficientCoinsSheet(context, needed: kSoloRetryCost);
      }
      return;
    }

    final confirmed = await showAppDialog<bool>(
      context,
      builder: (ctx) => AppDialog(
        title: 'Try Again?',
        contentWidget: Text(
          'Spend $kSoloRetryCost🪙 to reset today\'s cooldown and replay the same anime immediately?',
          style: AppTypography.bodyMedium,
        ),
        actions: [
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.text,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            label: '🔄 Try Again  −$kSoloRetryCost🪙',
            variant: AppButtonVariant.text,
            color: AppColors.readable(AppColors.accent),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Claim the retry before the charge. On a slow connection the button stayed
    // live, so a second tap fired a second 80🪙 spend before the
    // first one had navigated — the player paid twice for a single replay. Every
    // failure path below releases the claim again.
    setState(() {
      _navigating = true;
      _retrying = true;
    });

    try {
      // The server clears this lineup's cooldown locks and mints the replay
      // run's session (required by submitQuizAnswers) in one atomic spend.
      final spend = await userData.spendCoinsWithResult(
        kSoloRetryCost,
        'spend_retry',
        extra: {
          'titles': widget.selectedTitles,
          'runV2': true,
        },
      );
      final sessionId = (spend['sessionId'] as String?)?.trim() ?? '';

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        AppPageRoute(
          builder: (_) => QuestionsPage(
            selectedTitles: widget.selectedTitles,
            soloDifficulty: widget.soloDifficulty,
            soloSessionId: sessionId.isEmpty ? null : sessionId,
          ),
        ),
      );
    } on PremiumRequiredException {
      _releaseRetry();
      if (mounted) _openPremiumUpsell();
    } on InsufficientCoinsException {
      _releaseRetry();
      if (mounted) {
        await showInsufficientCoinsSheet(context, needed: kSoloRetryCost);
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('[SoloSummaryPage] _tryAgainWithCoins CF error: $e');
      _releaseRetry();
      if (!mounted) return;
      // A stale lock (e.g. a run left open elsewhere) blocks the replay
      // spend — name it instead of the generic message so the player knows
      // the Clear-run path on the home screen will fix it.
      final msg =
          e.code == 'failed-precondition' && e.message == 'run_in_progress'
              ? 'Finish your current run before starting another. '
                  'Clear it from the home screen, then try again.'
              : 'Something went wrong — please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    } catch (e) {
      debugPrint('[SoloSummaryPage] _tryAgainWithCoins error: $e');
      _releaseRetry();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Something went wrong — please try again.')),
        );
      }
    }
  }

  /// Re-arms the Try Again button after a failed retry charge.
  void _releaseRetry() {
    if (!mounted) return;
    setState(() {
      _navigating = false;
      _retrying = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tier = _tier;
    final pct = (_accuracy * 100).round();
    final userData = context.watch<UserDataProvider>();
    final currentCoins = userData.animeCoins;
    final isPremium = userData.premiumActive;

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
                      titles: widget.selectedTitles,
                      soloDifficulty: widget.soloDifficulty,
                    ),

                    // ── Achievement bonus (distinct UI) ───────────────
                    if (widget.achievementCoins > 0) ...[
                      SizedBox(height: 12.h),
                      const _AchievementBonusBanner(),
                    ],

                    // ── Blitz panel ───────────────────────────────────
                    if (widget.isGauntlet) ...[
                      SizedBox(height: 12.h),
                      _BlitzResultPanel(
                        correct: widget.correctCount,
                        answered: widget.answeredCount > 0
                            ? widget.answeredCount
                            : widget.totalQuestions,
                      ),
                    ],

                    // ── Hint ──────────────────────────────────────────
                    if (!widget.isGauntlet && widget.correctCount < 5) ...[
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
                    if (!widget.isGauntlet) ...[
                      SizedBox(height: 10.h),
                      SizedBox(
                        width: double.infinity,
                        height: 44.h,
                        child: AppButton(
                          label: isPremium
                              ? 'Try Again  —  $kSoloRetryCost🪙'
                              : 'Try Again  —  Premium only',
                          icon: isPremium
                              ? Text('🔄', style: TextStyle(fontSize: 13.sp))
                              : Icon(Icons.lock_rounded),
                          variant: AppButtonVariant.outline,
                          color: isPremium
                              ? AppColors.readable(AppColors.accent)
                              : AppColors.readable(AppColors.gold),
                          size: AppButtonSize.small,
                          height: 44.h,
                          loading: _retrying,
                          onPressed: isPremium
                              ? _tryAgainWithCoins
                              : _openPremiumUpsell,
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
            color: AppColors.accent.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(20.r),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('🪙', style: TextStyle(fontSize: 12.sp)),
              SizedBox(width: 5.w),
              Text(
                '$coins',
                style: TextStyle(
                  color: AppColors.readable(AppColors.accent),
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
            tier.color.withValues(alpha: 0.14),
            tier.color.withValues(alpha: 0.04),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(24.r),
        border:
            Border.all(color: tier.color.withValues(alpha: 0.25), width: 1.2),
      ),
      child: Column(
        children: [
          // ── Emoji medallion ─────────────────────────────────────
          Container(
            width: 72.r,
            height: 72.r,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tier.color.withValues(alpha: 0.16),
              border: Border.all(
                  color: tier.color.withValues(alpha: 0.4), width: 1.5),
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
                    color: AppColors.readable(tier.color),
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
              color: tier.color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20.r),
              border: Border.all(color: tier.color.withValues(alpha: 0.35)),
            ),
            child: Text(
              tier.title.toUpperCase(),
              style: TextStyle(
                color: AppColors.readable(tier.color),
                fontSize: 11.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.3,
              ),
            ),
          ),
          SizedBox(height: 12.h),
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
    required this.titles,
    this.soloDifficulty = 'easy',
  });

  @override
  Widget build(BuildContext context) {
    final hasRewards = coinsEarned > 0 || wpEarned > 0 || achievementCoins > 0;

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
          if (!isGauntlet) _DifficultyPill(difficulty: soloDifficulty),
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
                  color: AppColors.readable(tier.color),
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
                      label: 'weekly pts',
                      color: AppColors.skyBright,
                    ),
                  ),
              ],
            ),
            if (achievementCoins > 0) ...[
              SizedBox(height: 12.h),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14.r),
                  border: Border.all(
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.45),
                  ),
                ),
                child: _RewardBlock(
                  emoji: '🏆',
                  value: '+$achievementCoins',
                  label: 'achievement bonus',
                  color: _purpleText,
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
                    .map((w) => w.isEmpty
                        ? w
                        : '${w[0].toUpperCase()}${w.substring(1)}')
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
    // Vivid difficulty hues are fills; the label needs the darker light-mode
    // variant to stay legible on the 10% tint.
    final textColor = AppColors.isDark
        ? color
        : switch (d) {
            'hard' => const Color(0xFFB91C1C),
            'medium' => const Color(0xFFB45309),
            _ => const Color(0xFF047857),
          };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: TextStyle(fontSize: 14.sp)),
          SizedBox(width: 8.w),
          Text(
            '$label MODE',
            style: TextStyle(
              color: textColor,
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
        if (icon != null)
          Icon(icon, color: AppColors.readable(color), size: 18.r),
        SizedBox(width: 8.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: AppColors.readable(color),
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

  static const _purple = _kPurple;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _purple.withValues(alpha: 0.16),
            _purple.withValues(alpha: 0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: _purple.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Container(
            width: 36.r,
            height: 36.r,
            decoration: BoxDecoration(
              color: _purple.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: _purple.withValues(alpha: 0.40)),
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
                    color: _purpleText,
                    fontSize: 9.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.0,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  'Bonus coins from achievement tiers.',
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
              color: AppColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10.r),
            ),
            child: Icon(
              Icons.lightbulb_outline_rounded,
              color: AppColors.readable(AppColors.accent),
              size: 17.r,
            ),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Text(
              'Try a hint next round.',
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
// Blitz result panel: correct/answered plus the gamble payout ladder with
// the earned tier highlighted.
// ═══════════════════════════════════════════════════════════════════════════
class _BlitzResultPanel extends StatelessWidget {
  final int correct;
  final int answered;

  const _BlitzResultPanel({
    required this.correct,
    required this.answered,
  });

  @override
  Widget build(BuildContext context) {
    var earnedAc = 0;
    var earnedMin = 0;
    for (final tier in kBlitzAcTiers) {
      if (correct >= tier.minCorrect) {
        earnedAc = tier.ac;
        earnedMin = tier.minCorrect;
      }
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md + 2),
      tier: AppCardTier.standard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('⚡', style: TextStyle(fontSize: 16.sp)),
              SizedBox(width: 7.w),
              Text(
                '$correct/$answered correct',
                style: TextStyle(
                  color: AppColors.readable(AppColors.amber),
                  fontSize: 14.sp,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                '+$earnedAc AC',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(height: 12.h),
          Column(
            children: [
              for (final tier in kBlitzAcTiers)
                _payoutRow(
                  tier: tier,
                  earned: tier.minCorrect == earnedMin,
                ),
            ],
          ),
          SizedBox(height: 8.h),
          Text(
            'WP by difficulty (5/8/12) · capped daily',
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

  Widget _payoutRow({required BlitzAcTier tier, required bool earned}) {
    return Container(
      margin: EdgeInsets.only(bottom: 5.r),
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
      decoration: BoxDecoration(
        color: earned
            ? AppColors.amber.withValues(alpha: 0.22)
            : AppColors.surfaceAlt.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(
          color: earned
              ? AppColors.amber.withValues(alpha: 0.55)
              : AppColors.divider.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Text(
            '${tier.minCorrect}+ correct',
            style: TextStyle(
              color: earned
                  ? AppColors.readable(AppColors.amber)
                  : AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          Text(
            '+${tier.ac} AC',
            style: TextStyle(
              color: earned
                  ? AppColors.readable(AppColors.amber)
                  : AppColors.textSecondary,
              fontSize: 12.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
