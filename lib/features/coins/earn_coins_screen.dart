import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/widgets/shop_link_note.dart';
import '../../core/theme/app_theme.dart';

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
    final nowWAT    = DateTime.now().toUtc().add(const Duration(hours: 1));
    final midnight  = DateTime(nowWAT.year, nowWAT.month, nowWAT.day + 1);
    final msUntil   = midnight.difference(nowWAT).inMilliseconds;
    _midnightTimer  = Timer(Duration(milliseconds: msUntil), () {
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
        content: Text(message, style: const TextStyle(fontFamily: 'Nunito')),
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

    final bool buttonEnabled = !dailyLimit && !onCooldown && !_adLoading;

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
                  IconButton(
                    onPressed:
                        _adLoading ? null : () => Navigator.pop(context),
                    icon: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: AppColors.textPrimary,
                      size: 19.r,
                    ),
                    splashRadius: 22,
                  ),
                  SizedBox(width: 2.w),
                  Expanded(
                    child: Text(
                      'Earn Coins',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 26.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                        height: 1.05,
                      ),
                    ),
                  ),
                  _HeaderCoinPill(animeCoins: ac),
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
                      dailyCap:     10,
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
// Header coin pill — compact, matches the coin-balance chip used elsewhere
// ═══════════════════════════════════════════════════════════════════════════
class _HeaderCoinPill extends StatelessWidget {
  final int animeCoins;
  const _HeaderCoinPill({required this.animeCoins});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
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
            '$animeCoins',
            style: TextStyle(
              color: AppColors.accent,
              fontSize: 13.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Hero: Watch Ad card
// ═══════════════════════════════════════════════════════════════════════════
class _WatchAdHero extends StatelessWidget {
  final bool         enabled;
  final bool         loading;
  final bool         dailyLimit;
  final bool         onCooldown;
  final int          cooldownSecs;
  final int          watched;
  final int          dailyCap;
  final String       resetsIn;
  final VoidCallback onTap;

  const _WatchAdHero({
    required this.enabled,
    required this.loading,
    required this.dailyLimit,
    required this.onCooldown,
    required this.cooldownSecs,
    required this.watched,
    required this.dailyCap,
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
    return 'Watch Ad — Earn +15 🪙';
  }

  @override
  Widget build(BuildContext context) {
    final progress = (watched / dailyCap).clamp(0.0, 1.0);
    final full     = watched >= dailyCap;

    // Visual state of the card
    final bool isReady = enabled || loading;
    final Color accent  = dailyLimit
        ? AppColors.textMuted
        : (isReady ? AppColors.primary : AppColors.textMuted);
    final Color borderColor = isReady && !dailyLimit && !onCooldown
        ? AppColors.primary.withOpacity(0.35)
        : AppColors.divider;

    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(
          color: borderColor,
          width: isReady && !dailyLimit && !onCooldown ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Top row: icon tile + title / subtitle ────────────────
          Row(
            children: [
              Container(
                width: 56.r,
                height: 56.r,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(16.r),
                  border: Border.all(color: accent.withOpacity(0.32)),
                ),
                child: Center(
                  child: Text('📺', style: TextStyle(fontSize: 24.sp)),
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
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 17.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                        height: 1.15,
                      ),
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      dailyLimit
                          ? "You've watched all $dailyCap ads today"
                          : '+15 AC per view · 30s cooldown',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
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
                'DAILY PROGRESS',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 9.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.9,
                ),
              ),
              const Spacer(),
              Text(
                '$watched / $dailyCap',
                style: TextStyle(
                  color: full ? AppColors.wrong : AppColors.textPrimary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          ClipRRect(
            borderRadius: BorderRadius.circular(6.r),
            child: LinearProgressIndicator(
              value:           progress,
              minHeight:       8,
              backgroundColor: AppColors.divider,
              color:           full ? AppColors.wrong : AppColors.primary,
            ),
          ),
          SizedBox(height: 18.h),

          // ── Action button ────────────────────────────────────────
          SizedBox(
            width:  double.infinity,
            height: 52.h,
            child: ElevatedButton(
              onPressed: enabled ? onTap : null,
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    enabled ? AppColors.primary : AppColors.surfaceAlt,
                foregroundColor:
                    enabled ? Colors.white : AppColors.textMuted,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14.r),
                ),
                elevation: 0,
              ),
              child: loading
                  ? SizedBox(
                      width:  22.w,
                      height: 22.h,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      _buttonLabel,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize:   15.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.1,
                      ),
                    ),
            ),
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
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.sp,
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

// ═══════════════════════════════════════════════════════════════════════════
// Coin Packs (website shop)
// ═══════════════════════════════════════════════════════════════════════════
({int ac, String bonus, bool bestValue, String price, String blurb}) _coinPackMeta(
    String id) {
  switch (id) {
    case 'animequiz_coins_300':
      return (
        ac: 300,
        bonus: '',
        bestValue: false,
        price: '₦500',
        blurb: 'Fast top-up for hints, cooldown skips and a few small stakes.',
      );
    case 'animequiz_coins_1100':
      return (
        ac: 990,
        bonus: 'Includes a 10% bonus',
        bestValue: false,
        price: '₦1,500',
        blurb:
            '990 AC with a 10% bonus — a solid session of boss battles and '
            'rival rematches.',
      );
    case 'animequiz_coins_3600':
      return (
        ac: 2880,
        bonus: 'Includes a 20% bonus',
        bestValue: true,
        price: '₦4,000',
        blurb:
            'Best value — 20% bonus on the biggest top-up. A week of '
            'battling in one shot.',
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
        // ── Section header ───────────────────────────────────────
        Row(
          children: [
            Container(
              width: 28.r,
              height: 28.r,
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.14),
                borderRadius: BorderRadius.circular(9.r),
              ),
              child: Icon(
                Icons.shopping_bag_rounded,
                color: AppColors.accent,
                size: 15.r,
              ),
            ),
            SizedBox(width: 10.w),
            Text(
              'Coin packs',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
        SizedBox(height: 4.h),
        Padding(
          padding: EdgeInsets.only(left: 38.r),
          child: Text(
            'Top up from the shop on our website',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12.sp,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ),
        SizedBox(height: 14.h),

        // ── Shop link (moved above the packs) ────────────────────
        const ShopLinkNote(),
        SizedBox(height: 10.h),

        // ── Pack cards ──────────────────────────────────────────
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
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(
          color: isBest ? AppColors.accent.withOpacity(0.40) : AppColors.divider,
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
              color: accent.withOpacity(0.14),
              borderRadius: BorderRadius.circular(12.r),
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
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 17.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                      ),
                    ),
                    SizedBox(width: 4.w),
                    Text(
                      'AC',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (isBest) ...[
                      SizedBox(width: 8.w),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.r, vertical: 2.r),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withOpacity(0.16),
                          borderRadius: BorderRadius.circular(6.r),
                          border: Border.all(
                            color: AppColors.accent.withOpacity(0.32),
                          ),
                        ),
                        child: Text(
                          'BEST VALUE',
                          style: TextStyle(
                            color: AppColors.accent,
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
                    style: TextStyle(
                      color: isBest
                          ? AppColors.accent
                          : AppColors.textSecondary,
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                SizedBox(height: 4.h),
                Text(
                  meta.blurb,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 12.w),

          // ── Price pill ───────────────────────────────────────────
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: 10.r, vertical: 6.r),
            decoration: BoxDecoration(
              color: isBest
                  ? AppColors.accent.withOpacity(0.14)
                  : AppColors.primary.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10.r),
              border: Border.all(
                color: isBest
                    ? AppColors.accent.withOpacity(0.40)
                    : AppColors.primary.withOpacity(0.25),
              ),
            ),
            child: Text(
              meta.price,
              style: TextStyle(
                color: isBest ? AppColors.accent : AppColors.primary,
                fontSize: 12.sp,
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