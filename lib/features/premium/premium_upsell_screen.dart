import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/shop_link_note.dart';

/// Premium Pass upsell screen. Premium is currently sold on the website as a
/// one-time 31-day code (₦2,000) redeemed under Profile → Redeem Code; the
/// Play Billing path below is dormant and kept for re-enable.
class PremiumUpsellScreen extends StatefulWidget {
  const PremiumUpsellScreen({super.key});

  @override
  State<PremiumUpsellScreen> createState() => _PremiumUpsellScreenState();
}

class _PremiumUpsellScreenState extends State<PremiumUpsellScreen> {
  // Fallback price shown across the premium UI (website shop price, ₦2,000/31d).
  static const String _kPriceFallback = '₦2,000';

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<UserDataProvider>().premiumActive;

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
                    onPressed: () => Navigator.pop(context),
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
                      'Premium Pass',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 26.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                        height: 1.05,
                      ),
                    ),
                  ),
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
                    // ── Hero: crown + price ─────────────────────────
                    const _HeroCard(price: _kPriceFallback),

                    SizedBox(height: 26.h),

                    // ── Perks section ───────────────────────────────
                    const _SectionHeader(
                      icon: Icons.auto_awesome_rounded,
                      title: 'What you get',
                      color: AppColors.secondary,
                    ),
                    SizedBox(height: 12.h),
                    const _PerksList(),

                    SizedBox(height: 26.h),

                    // ── Already premium / how to get it ────────────
                    if (premium)
                      const _AlreadyPremiumCard()
                    else
                      const _ShopPremiumCard(),

                    SizedBox(height: 12.h),

                    Text(
                      '31 days of Premium, activated once. Renew anytime from '
                      'the website.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                        height: 1.5,
                      ),
                    ),
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

// ─── Section header (matches Home / Battle / Rankings) ─────────────────────
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 28.r,
          height: 28.r,
          decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(9.r),
          ),
          child: Icon(icon, color: color, size: 15.r),
        ),
        SizedBox(width: 10.w),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Hero: crown + price ───────────────────────────────────────────────────
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.price});
  final String price;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 24.r, horizontal: 18.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.accent.withOpacity(0.18),
            AppColors.secondary.withOpacity(0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22.r),
        border: Border.all(color: AppColors.accent.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          // Crown icon tile
          Container(
            width: 68.r,
            height: 68.r,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.20),
              borderRadius: BorderRadius.circular(20.r),
              border: Border.all(color: AppColors.accent.withOpacity(0.40)),
            ),
            child: Center(
              child: Text('👑', style: TextStyle(fontSize: 34.sp)),
            ),
          ),
          SizedBox(height: 14.h),

          Text(
            'Premium Pass',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),
          SizedBox(height: 6.h),

          // Price hero
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                price,
                style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 34.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                  height: 1.05,
                ),
              ),
            ],
          ),
          SizedBox(height: 3.h),
          Text(
            'per 31 days',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Perks list ───────────────────────────────────────────────────────────
/// Mirror of the actual premium branches in the code (v4.8):
///   - ad_service.dart:            Premium users see no interstitials/app-open ads
///   - stake_screen.dart:          maxStake 3000 (vs 1000), WP max 100 (vs 50),
///                                 dailyCap 300 (vs 150)
///   - user_data_provider.dart:    rival rematch cooldown 12h (vs 24h)
///   - submitDailyGauntlet:        Premium first retry FREE, then 40/60/90/…
///   - awardPremiumMonday/Monthly: +75 WP Mondays + 100 WP monthly (flat grants)
///   - challenge/WP settlement:    1.20× eligible WP (flat grants excluded)
const List<({IconData icon, String title, String detail})> _kPerks = [
  (
    icon: Icons.visibility_off_rounded,
    title: 'No ads at all',
    detail: 'Interstitials, app-open and result ads — all gone.',
  ),
  (
    icon: Icons.trending_up_rounded,
    title: 'Bigger stakes',
    detail: '5,000 AC per stake (vs 2,000) · 200 WP per stake (vs 100) · '
        '300 WP staked/day (vs 150).',
  ),
  (
    icon: Icons.percent_rounded,
    title: '1.20× eligible WP',
    detail: 'Eligible weekly-points awards earn 20% more. '
        'Flat grants (+75 Monday, +100 monthly) are not multiplied.',
  ),
  (
    icon: Icons.sports_martial_arts_rounded,
    title: 'Gauntlet first retry FREE',
    detail:
        'Premium first retry each day costs 0 AC, then 40 · 60 · 90 · 135 · 203 AC.',
  ),
  (
    icon: Icons.bolt_rounded,
    title: 'Faster rival rematches',
    detail: 'Re-match the same rival in 12h instead of 24h.',
  ),
  (
    icon: Icons.flash_on_rounded,
    title: 'More Quick Match access',
    detail: 'Extra QM availability to find opponents faster.',
  ),
  (
    icon: Icons.calendar_today_rounded,
    title: '+75 WP Mondays \u00b7 +100 WP monthly',
    detail:
        'Flat weekly and anniversary grants for active Premium members — not multiplied.',
  ),
];

class _PerksList extends StatelessWidget {
  const _PerksList();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          for (int i = 0; i < _kPerks.length; i++) ...[
            _PerkRow(perk: _kPerks[i]),
            if (i != _kPerks.length - 1)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 6.r),
                child:
                    Divider(height: 1, thickness: 1, color: AppColors.divider),
              ),
          ],
        ],
      ),
    );
  }
}

class _PerkRow extends StatelessWidget {
  final ({IconData icon, String title, String detail}) perk;
  const _PerkRow({required this.perk});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6.r, horizontal: 4.r),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38.r,
            height: 38.r,
            decoration: BoxDecoration(
              color: AppColors.secondary.withOpacity(0.14),
              borderRadius: BorderRadius.circular(11.r),
            ),
            child: Icon(perk.icon, color: AppColors.secondary, size: 19.r),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  perk.title,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                    height: 1.2,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  perk.detail,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
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

// ─── How to get it card ───────────────────────────────────────────────────
class _ShopPremiumCard extends StatelessWidget {
  const _ShopPremiumCard();

  @override
  Widget build(BuildContext context) {
    // Premium is sold on the website shop only (Play Billing policy: no
    // external-payment path reachable from the Play-distributed Android app).
    // On non-web platforms we show a neutral "unavailable" note instead of
    // the website shop link.
    if (!kIsWeb) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(16.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded,
                size: 18.r, color: AppColors.textMuted),
            SizedBox(width: 10.w),
            Expanded(
              child: Text(
                'Premium is available to purchase on our website. '
                'Open AnimeQuiz on the web to get it.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w600,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28.r,
                height: 28.r,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(9.r),
                ),
                child: Icon(Icons.shopping_bag_rounded,
                    color: AppColors.accent, size: 15.r),
              ),
              SizedBox(width: 10.w),
              Text(
                'How to get it',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
          SizedBox(height: 12.h),
          Text(
            "Get Premium on the website — it costs ₦2,000 for 31 days. "
            "You'll receive a one-time code on the payment page, then redeem "
            "it under Profile → Redeem Code and Premium is live on your "
            "account.",
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.sp,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          SizedBox(height: 14.h),
          const ShopLinkNote(),
        ],
      ),
    );
  }
}

// ─── Already Premium card ────────────────────────────────────────────────
class _AlreadyPremiumCard extends StatelessWidget {
  const _AlreadyPremiumCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 22.r, horizontal: 18.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.accent.withOpacity(0.16),
            AppColors.secondary.withOpacity(0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: AppColors.accent.withOpacity(0.40)),
      ),
      child: Column(
        children: [
          Container(
            width: 56.r,
            height: 56.r,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.20),
              borderRadius: BorderRadius.circular(16.r),
            ),
            child: Center(
              child: Text('👑', style: TextStyle(fontSize: 28.sp)),
            ),
          ),
          SizedBox(height: 12.h),
          Text(
            "You're Premium",
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            'All Premium benefits are active on this account.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.sp,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

