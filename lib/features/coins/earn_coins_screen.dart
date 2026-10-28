import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/widgets/shop_link_note.dart';

/// Rewarded-ad rate and daily cap. Kept in sync with `AdService` (`_dailyMax`)
/// and the `recordAdWatch` Cloud Function (+15 AC per verified view).
const int _kCoinsPerAd = 15;
const int _kDailyAdCap = 10;

class EarnCoinsScreen extends StatefulWidget {
  const EarnCoinsScreen({super.key});

  @override
  State<EarnCoinsScreen> createState() => _EarnCoinsScreenState();
}

class _EarnCoinsScreenState extends State<EarnCoinsScreen> {
  Timer? _cooldownTimer;
  Timer? _midnightTimer;
  int _cooldownSecsLeft = 0;
  bool _adLoading = false;

  @override
  void initState() {
    super.initState();
    AdService.instance.loadRewardedAd();
    _startCooldownTimer();
    _scheduleMidnightRefresh();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _midnightTimer?.cancel();
    super.dispose();
  }

  void _startCooldownTimer() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final secs = AdService.instance.cooldownSecondsRemaining();
      if (mounted) setState(() => _cooldownSecsLeft = secs);
    });
  }

  void _scheduleMidnightRefresh() {
    final nowWAT   = DateTime.now().toUtc().add(const Duration(hours: 1));
    final midnight = DateTime(nowWAT.year, nowWAT.month, nowWAT.day + 1);
    final msUntil  = midnight.difference(nowWAT).inMilliseconds;
    _midnightTimer = Timer(Duration(milliseconds: msUntil), () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _onWatchAdTapped() async {
    final provider = context.read<UserDataProvider>();

    if (provider.adsRemainingToday <= 0) return;
    if (_cooldownSecsLeft > 0) return;

    if (!AdService.instance.isRewardedAdReady) {
      setState(() => _adLoading = true);
      AdService.instance.loadRewardedAd();
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (AdService.instance.isRewardedAdReady) break;
      }
      if (!mounted) return;
      setState(() => _adLoading = false);

      if (!AdService.instance.isRewardedAdReady) {
        _showSnack('Ad not available right now. Try again in a moment.');
        return;
      }
    }

    setState(() => _adLoading = true);

    final shown = await AdService.instance.showRewardedAd(
      context: context,
      onComplete: (int coinsAwarded) {
        if (!mounted) return;
        setState(() => _cooldownSecsLeft = 30);
        try {
          CoinEarnAnimation.show(context, amount: coinsAwarded);
        } catch (e) {
          debugPrint('[Ad] animation skipped: $e');
        }
      },
    );

    if (mounted) setState(() => _adLoading = false);

    if (!shown && mounted && _cooldownSecsLeft == 0) {
      _showSnack('Ad not available right now. Try again in a moment.');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _midnightCountdown() {
    final nowWAT   = DateTime.now().toUtc().add(const Duration(hours: 1));
    final midnight = DateTime(nowWAT.year, nowWAT.month, nowWAT.day + 1);
    final secs     = midnight.difference(nowWAT).inSeconds;
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final provider   = context.watch<UserDataProvider>();
    final ac         = provider.animeCoins;
    final watched    = provider.dailyAdWatched;
    final remaining  = provider.adsRemainingToday;
    final dailyLimit = remaining <= 0;
    final onCooldown = _cooldownSecsLeft > 0;

    final buttonEnabled = !dailyLimit && !onCooldown && !_adLoading;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ───────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(8.r, 10.r, 16.r, 8.r),
              child: Row(
                children: [
                  AppBackButton(
                    onPressed:
                        _adLoading ? null : () => Navigator.pop(context),
                  ),
                  SizedBox(width: 2.w),
                  Expanded(
                    child: Text(
                      'Earn Coins',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.heading2.copyWith(
                        fontSize: 26.sp,
                        letterSpacing: -0.5,
                        height: 1.05,
                      ),
                    ),
                  ),
                  _CoinPill(animeCoins: ac),
                ],
              ),
            ),

            // ── Body ─────────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Hero: Watch Ad card ──────────────────────────
                    _WatchAdHero(
                      enabled:      buttonEnabled,
                      loading:      _adLoading,
                      dailyLimit:   dailyLimit,
                      onCooldown:   onCooldown,
                      cooldownSecs: _cooldownSecsLeft,
                      watched:      watched,
                      resetsIn:     _midnightCountdown(),
                      onTap:        _onWatchAdTapped,
                    ),

                    SizedBox(height: 28.h),

                    // ── Coin Packs (website shop) ────────────────────
                    const _CoinPacksSection(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Header coin pill — mirrors CoinBalanceWidget, but non-tappable here (we're
// already on the earn screen) and formatted compactly.
// ═══════════════════════════════════════════════════════════════════════════
class _CoinPill extends StatelessWidget {
  final int animeCoins;
  const _CoinPill({required this.animeCoins});

  static String _format(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}K' : '$n';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.38),
          width: 1.2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🪙', style: TextStyle(fontSize: 14.sp)),
          SizedBox(width: 5.w),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _format(animeCoins),
              style: TextStyle(
                color: AppColors.readable(AppColors.accent),
                fontFamily: AppTypography.fontFamily,
                fontWeight: FontWeight.w800,
                fontSize: 14.sp,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Hero: Watch Ad card — the app's signature gradient hero card.
// ═══════════════════════════════════════════════════════════════════════════
class _WatchAdHero extends StatelessWidget {
  final bool         enabled;
  final bool         loading;
  final bool         dailyLimit;
  final bool         onCooldown;
  final int          cooldownSecs;
  final int          watched;
  final String       resetsIn;
  final VoidCallback onTap;

  const _WatchAdHero({
    required this.enabled,
    required this.loading,
    required this.dailyLimit,
    required this.onCooldown,
    required this.cooldownSecs,
    required this.watched,
    required this.resetsIn,
    required this.onTap,
  });

  String get _buttonLabel {
    if (loading) return 'Loading ad…';
    if (dailyLimit) return 'Come back tomorrow 🌙';
    if (onCooldown) {
      final m = (cooldownSecs ~/ 60).toString().padLeft(2, '0');
      final s = (cooldownSecs % 60).toString().padLeft(2, '0');
      return 'Next ad in $m:$s';
    }
    return 'Watch Ad';
  }

  @override
  Widget build(BuildContext context) {
    final progress     = (watched / _kDailyAdCap).clamp(0.0, 1.0);
    final full         = watched >= _kDailyAdCap;
    final rewardActive = enabled || loading;

    // Muted once the daily cap is hit; accent-highlighted while watchable.
    final Color tileColor = dailyLimit ? AppColors.textMuted : AppColors.accent;
    final Color borderColor = dailyLimit
        ? AppColors.divider
        : AppColors.accent.withValues(alpha: rewardActive ? 0.45 : 0.22);

    return Container(
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.accent.withValues(alpha: dailyLimit ? 0.06 : 0.18),
            AppColors.primary.withValues(alpha: dailyLimit ? 0.03 : 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22.r),
        border: Border.all(color: borderColor, width: rewardActive ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Top row: icon tile + title / subtitle + reward badge ──
          Row(
            children: [
              Container(
                width: 60.r,
                height: 60.r,
                decoration: BoxDecoration(
                  color: tileColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(17.r),
                  border: Border.all(
                    color: tileColor.withValues(alpha: 0.34),
                  ),
                ),
                child: Center(
                  child: Text('📺', style: TextStyle(fontSize: 26.sp)),
                ),
              ),
              SizedBox(width: 14.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      dailyLimit ? 'No ads left today' : 'Watch an ad',
                      style: AppTypography.heading3.copyWith(
                        fontSize: 18.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                        height: 1.15,
                      ),
                    ),
                    SizedBox(height: 4.h),
                    if (!dailyLimit)
                      Text(
                        '30s cooldown',
                        style: AppTypography.bodySmall,
                      ),
                  ],
                ),
              ),
              if (!dailyLimit) ...[
                SizedBox(width: 8.w),
                _RewardBadge(color: tileColor),
              ],
            ],
          ),
          SizedBox(height: 18.h),

          // ── Divider ──────────────────────────────────────────────
          Container(height: 1, color: AppColors.divider),
          SizedBox(height: 14.h),

          // ── Daily progress ───────────────────────────────────────
          Row(
            children: [
              Text(
                'TODAY\'S ADS',
                style: AppTypography.labelSmall.copyWith(
                  letterSpacing: 0.9,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                '$watched / $_kDailyAdCap',
                style: AppTypography.labelLarge.copyWith(
                  color: full
                      ? AppColors.readable(AppColors.accent)
                      : AppColors.textPrimary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(6.r),
            child: LinearProgressIndicator(
              value:           progress,
              minHeight:       8,
              backgroundColor: AppColors.divider,
              color:           full ? AppColors.accent : AppColors.primary,
            ),
          ),
          SizedBox(height: 18.h),

          // ── Action button ────────────────────────────────────────
          AppButton(
            label:   _buttonLabel,
            size:    AppButtonSize.large,
            loading: loading,
            icon:    dailyLimit ? null : const Icon(Icons.play_circle_fill_rounded),
            onPressed: enabled ? onTap : null,
          ),

          // ── Footer: reset countdown when daily limit hit ─────────
          if (dailyLimit) ...[
            SizedBox(height: 12.h),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.schedule_rounded,
                    size: 12.r, color: AppColors.textMuted),
                SizedBox(width: 5.w),
                Text(
                  'Resets in $resetsIn',
                  style: AppTypography.bodySmall.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Reward badge: the per-ad AC amount ────────────────────────────────────
class _RewardBadge extends StatelessWidget {
  final Color color;
  const _RewardBadge({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.36)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🪙', style: TextStyle(fontSize: 12.sp)),
          SizedBox(width: 4.w),
          Text(
            '+$_kCoinsPerAd',
            style: AppTypography.labelLarge.copyWith(
              color: color,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Coin Packs (website shop)
// ═══════════════════════════════════════════════════════════════════════════
({int ac, String bonus, bool bestValue, String price, String blurb}) _coinPackMeta(
    String id) {
  switch (id) {
    case 'animequiz_coins_300':
      return (
        ac: 500,
        bonus: '',
        bestValue: false,
        price: '₦500',
        blurb: 'Fast top-up for hints, cooldown skips and a few small stakes.',
      );
    case 'animequiz_coins_1100':
      return (
        ac: 1650,
        bonus: 'Includes a 10% bonus',
        bestValue: false,
        price: '₦1,500',
        blurb:
            'A solid session of boss battles and rival rematches.',
      );
    case 'animequiz_coins_3600':
      return (
        ac: 4800,
        bonus: 'Includes a 20% bonus',
        bestValue: true,
        price: '₦4,000',
        blurb: 'A week of battling in one shot.',
      );
    default:
      return (
        ac: 0,
        bonus: '',
        bestValue: false,
        price: '—',
        blurb: '',
      );
  }
}

class _CoinPacksSection extends StatelessWidget {
  const _CoinPacksSection();

  static const List<String> _kShopPackIds = [
    'animequiz_coins_300',
    'animequiz_coins_1100',
    'animequiz_coins_3600',
  ];

  @override
  Widget build(BuildContext context) {
    // Coin packs are sold on the website shop; the section below always shows
    // the shop link (Android included).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Section header (matches Premium / Home) ──────────────
        Row(
          children: [
            Container(
              width: 28.r,
              height: 28.r,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9.r),
              ),
              child: Icon(
                Icons.shopping_bag_rounded,
                color: AppColors.readable(AppColors.accent),
                size: 15.r,
              ),
            ),
            SizedBox(width: 10.w),
            Text(
              'Coin packs',
              style: AppTypography.titleMedium.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
        SizedBox(height: 14.h),

        // ── Shop link ────────────────────────────────────────────
        const ShopLinkNote(),
        SizedBox(height: 10.h),

        // ── Pack cards ───────────────────────────────────────────
        for (final id in _kShopPackIds)
          _CoinPackCard(meta: _coinPackMeta(id)),
      ],
    );
  }
}

class _CoinPackCard extends StatelessWidget {
  const _CoinPackCard({required this.meta});

  final ({int ac, String bonus, bool bestValue, String price, String blurb}) meta;

  @override
  Widget build(BuildContext context) {
    final isBest = meta.bestValue;
    final accent = isBest ? AppColors.accent : AppColors.primary;

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 10.r),
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(
          color: isBest
              ? AppColors.accent.withValues(alpha: 0.40)
              : AppColors.divider,
          width: isBest ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Icon tile ────────────────────────────────────────────
          Container(
            width: 42.r,
            height: 42.r,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Center(
              child: Text(
                isBest ? '👑' : '🪙',
                style: TextStyle(fontSize: 18.sp),
              ),
            ),
          ),
          SizedBox(width: 12.w),

          // ── Middle: AC amount + bonus + blurb ────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '${meta.ac}',
                      style: AppTypography.titleLarge.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                      ),
                    ),
                    SizedBox(width: 4.w),
                    Text(
                      'AC',
                      style: AppTypography.labelMedium.copyWith(
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (isBest) ...[
                      SizedBox(width: 8.w),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.r, vertical: 2.r),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.32),
                          ),
                        ),
                        child: Text(
                          'BEST VALUE',
                          style: AppTypography.labelSmall.copyWith(
                            color: AppColors.readable(AppColors.accent),
                            fontSize: 8.sp,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (meta.bonus.isNotEmpty) ...[
                  SizedBox(height: 3.h),
                  Text(
                    meta.bonus,
                    style: AppTypography.labelMedium.copyWith(
                      color: isBest
                          ? AppColors.accent
                          : AppColors.textSecondary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                SizedBox(height: 4.h),
                Text(
                  meta.blurb,
                  style: AppTypography.bodySmall.copyWith(
                    fontSize: 10.sp,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 12.w),

          // ── Price pill ───────────────────────────────────────────
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
            decoration: BoxDecoration(
              color: isBest
                  ? AppColors.accent.withValues(alpha: 0.14)
                  : AppColors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10.r),
              border: Border.all(
                color: isBest
                    ? AppColors.accent.withValues(alpha: 0.40)
                    : AppColors.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Text(
              meta.price,
              style: AppTypography.labelLarge.copyWith(
                color: isBest ? AppColors.accent : AppColors.primary,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
