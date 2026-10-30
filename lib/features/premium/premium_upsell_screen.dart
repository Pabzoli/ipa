import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_badge.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/shop_link_note.dart';

/// Premium Pass upsell screen. Premium is currently sold on the website as a
/// one-time 28-day code (₦2,000) redeemed under Profile → Redeem Code; the
/// Play Billing path below is dormant and kept for re-enable.
class PremiumUpsellScreen extends StatefulWidget {
  const PremiumUpsellScreen({super.key});

  @override
  State<PremiumUpsellScreen> createState() => _PremiumUpsellScreenState();
}

class _PremiumUpsellScreenState extends State<PremiumUpsellScreen> {
  // Fallback price shown across the premium UI (website shop price, ₦2,000/28d).
  static const String _kPriceFallback = '₦2,000';

  /// Hands off to the website shop, which is where the 28-day code is sold.
  /// Mirrors [ShopLinkNote]'s fallback: if no browser can take the URL, copy
  /// it instead of leaving the tap dead.
  Future<void> _openShop(BuildContext context) async {
    final uri = Uri.parse(kShopUrl);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (opened) return;

    await Clipboard.setData(const ClipboardData(text: kShopUrl));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Couldn\'t open the browser — shop link copied instead.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final premium = context.watch<UserDataProvider>().premiumActive;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header (matches Earn Coins / Referrals) ──────────────
            Padding(
              padding: EdgeInsets.fromLTRB(8.r, 10.r, 16.r, 8.r),
              child: Row(
                children: [
                  const AppBackButton(),
                  SizedBox(width: 2.w),
                  Expanded(
                    child: Text(
                      'Premium Pass',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.heading2.copyWith(
                        fontSize: 26.sp,
                        letterSpacing: -0.5,
                        height: 1.05,
                      ),
                    ),
                  ),
                  if (premium) ...[
                    SizedBox(width: 8.w),
                    AppBadge(
                      label: 'Active',
                      color: AppColors.readable(AppColors.correct),
                      icon: Icons.workspace_premium_rounded,
                      dot: false,
                    ),
                  ],
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
                    // ── Hero: plan, price and the headline numbers ──
                    _PremiumHero(
                      premium: premium,
                      price: _kPriceFallback,
                      onGetPremium: () => _openShop(context),
                    ),

                    SizedBox(height: 28.h),

                    // ── Perks section ───────────────────────────────
                    _SectionHeader(
                      icon: Icons.auto_awesome_rounded,
                      title: 'What you get',
                      color: AppColors.readable(AppColors.accent),
                    ),
                    SizedBox(height: AppSpacing.md),
                    const _PerksList(),

                    SizedBox(height: AppSpacing.xl),

                    // ── How to get it (buying only) ─────────────────
                    if (!premium) const _ShopPremiumCard(),
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

// ─── Section header (matches Home / Battle / Earn Coins) ───────────────────
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 28.r,
              height: 28.r,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(9.r),
              ),
              child: Icon(icon, color: AppColors.readable(color), size: 15.r),
            ),
            SizedBox(width: 10.w),
            Expanded(
              child: Text(
                title,
                style: AppTypography.titleMedium.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Hero: plan, price and headline numbers ────────────────────────────────
class _PremiumHero extends StatelessWidget {
  final bool premium;
  final String price;
  final VoidCallback onGetPremium;

  const _PremiumHero({
    required this.premium,
    required this.price,
    required this.onGetPremium,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.accent.withValues(alpha: premium ? 0.14 : 0.20),
            AppColors.secondary.withValues(alpha: 0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22.r),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Top row: crown tile + plan + price ───────────────────
          Row(
            children: [
              Container(
                width: 56.r,
                height: 56.r,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(17.r),
                  border: Border.all(
                    color: AppColors.accent.withValues(alpha: 0.36),
                  ),
                ),
                child: Center(
                  child: Text('👑', style: TextStyle(fontSize: 24.sp)),
                ),
              ),
              SizedBox(width: 14.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      premium
                          ? '28 days from activation'
                          : '28 days · one-time',
                      style: AppTypography.bodySmall,
                    ),
                  ],
                ),
              ),
              if (!premium) ...[
                SizedBox(width: 10.w),
                _PricePill(price: price),
              ],
            ],
          ),
          SizedBox(height: 16.h),

          // ── Divider ──────────────────────────────────────────────
          Container(height: 1, color: AppColors.divider),
          SizedBox(height: 14.h),

          // ── At-a-glance numbers ──────────────────────────────────
          Row(
            children: [
              const _HeroStat(value: '1.20×', label: 'WP boost'),
              const _StatDivider(),
              const _HeroStat(value: '5,000', label: 'AC max stake'),
              const _StatDivider(),
              const _HeroStat(value: '8/day', label: 'Quick Match'),
            ],
          ),
          SizedBox(height: 18.h),

          // ── Action ───────────────────────────────────────────────
          if (premium)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.readable(AppColors.correct),
                  size: 15.r,
                ),
                SizedBox(width: 6.w),
                Flexible(
                  child: Text(
                    'All Premium benefits are active on this account.',
                    style: AppTypography.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            )
          else ...[
            AppButton(
              label: 'Get Premium Pass',
              size: AppButtonSize.large,
              icon: const Icon(Icons.workspace_premium_rounded),
              onPressed: onGetPremium,
            ),
          ],
        ],
      ),
    );
  }
}

class _PricePill extends StatelessWidget {
  final String price;
  const _PricePill({required this.price});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.36)),
      ),
      child: Text(
        price,
        style: AppTypography.titleLarge.copyWith(
          color: AppColors.readable(AppColors.accent),
          fontWeight: FontWeight.w900,
          letterSpacing: -0.3,
        ),
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  final String value;
  final String label;
  const _HeroStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: AppTypography.heading3.copyWith(
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.3,
              ),
            ),
          ),
          SizedBox(height: 2.h),
          Text(
            label.toUpperCase(),
            textAlign: TextAlign.center,
            style: AppTypography.labelSmall.copyWith(letterSpacing: 0.5),
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 26.r,
      margin: EdgeInsets.symmetric(horizontal: 6.w),
      color: AppColors.divider,
    );
  }
}

// ─── Perks list ───────────────────────────────────────────────────────────
/// Mirror of the actual premium branches in the code:
///   - ad_service.dart:            Premium users see no interstitials/app-open ads
///   - stake_screen.dart:          maxStake 5000 (vs 2000), WP max 400 (vs 200),
///                                 dailyCap 500 (vs 300), 8 creates+joins/day (vs 5)
///   - rival rematches:            same-rival WP-staked cooldown 6h (vs 12h);
///                                 spars have no cooldown for anyone
///   - submitDailyGauntlet (Blitz): Premium first retry FREE, then 40/60/90/…
///   - solo_summary_page.dart:     instant solo retry (80 AC) is Premium-only
///   - awardPremiumMonday/Monthly: +75 WP Mondays + 100 WP monthly (flat grants)
///   - challenge/WP settlement:    1.20× eligible WP (flat grants excluded)
///   - Quick Match:                8 daily battles (vs 5), open 24/7
const List<({IconData icon, String title, String detail})> _kPerks = [
  (
    icon: Icons.visibility_off_rounded,
    title: 'No ads at all',
    detail: 'Interstitials, app-open and result ads — all gone.',
  ),
  (
    icon: Icons.trending_up_rounded,
    title: 'Bigger stakes',
    detail: '5,000 AC per stake (vs 2,000) · 400 WP per stake (vs 200) · '
        '500 WP staked/day (vs 300).',
  ),
  (
    icon: Icons.percent_rounded,
    title: '1.20× eligible WP',
    detail: 'Eligible weekly-points awards earn 20% more. '
        'Flat grants (+75 Monday, +100 monthly) are not multiplied.',
  ),
  (
    icon: Icons.sports_martial_arts_rounded,
    title: 'Blitz first retry FREE',
    detail:
        'Premium first Gauntlet Blitz retry each day costs 0 AC, then 40 · 60 · 90 · 135 · 203 AC.',
  ),
  (
    icon: Icons.replay_rounded,
    title: 'Instant solo retry',
    detail: 'Replay a finished solo lineup right away — 80 AC clears the '
        'cooldown. Free players can\'t retry.',
  ),
  (
    icon: Icons.bolt_rounded,
    title: 'Faster rival rematches',
    detail: 'Re-match the same rival in 6h instead of 12h. Spars never wait.',
  ),
  (
    icon: Icons.flash_on_rounded,
    title: 'More Quick Match access',
    detail: '8 battles daily (vs 5), open 24/7.',
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
    return AppCard(
      tier: AppCardTier.elevated,
      padding: EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          for (int i = 0; i < _kPerks.length; i++) ...[
            _PerkRow(perk: _kPerks[i]),
            if (i != _kPerks.length - 1)
              Divider(
                height: AppSpacing.lg,
                thickness: 1,
                color: AppColors.divider,
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
              color: AppColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(11.r),
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.22),
              ),
            ),
            child: Icon(perk.icon,
                color: AppColors.readable(AppColors.accent), size: 19.r),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  perk.title,
                  style: AppTypography.labelLarge.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                    height: 1.2,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(perk.detail, style: AppTypography.bodySmall),
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

  static const List<String> _steps = [
    'Pay ₦2,000 — you get a one-time code on the payment page.',
    'Redeem it under Profile → Redeem Code and Premium goes live on your '
        'account.',
  ];

  @override
  Widget build(BuildContext context) {
    // Premium is sold on the website shop; the card below always shows the
    // shop link (Android included).
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.shopping_bag_rounded,
            title: 'How to get it',
          ),
          SizedBox(height: AppSpacing.lg),
          for (final (index, step) in _steps.indexed) ...[
            if (index > 0) SizedBox(height: AppSpacing.md),
            _NumberedStep(index: index, text: step),
          ],
          SizedBox(height: AppSpacing.lg),
          Container(height: 1, color: AppColors.divider),
          SizedBox(height: AppSpacing.md),
          const ShopLinkNote(),
        ],
      ),
    );
  }
}

// ─── Card title (matches the shop / coin-pack card headers) ───────────────
class _CardTitle extends StatelessWidget {
  final IconData icon;
  final String title;

  const _CardTitle({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 28.r,
          height: 28.r,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(9.r),
          ),
          child: Icon(icon,
              color: AppColors.readable(AppColors.accent), size: 15.r),
        ),
        SizedBox(width: 10.w),
        Expanded(
          child: Text(
            title,
            style: AppTypography.titleMedium.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Numbered step row (matches Referrals explainer) ──────────────────────
class _NumberedStep extends StatelessWidget {
  final int index;
  final String text;

  const _NumberedStep({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22.r,
          height: 22.r,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.30),
            ),
          ),
          child: Text(
            '${index + 1}',
            style: AppTypography.labelMedium.copyWith(
              color: AppColors.readable(AppColors.primary),
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(text, style: AppTypography.bodyMedium),
        ),
      ],
    );
  }
}
