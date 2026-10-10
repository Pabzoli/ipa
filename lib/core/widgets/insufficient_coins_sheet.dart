import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../providers/user_data_provider.dart';
import '../theme/app_theme.dart';
import '../../features/coins/earn_coins_screen.dart';
import 'app_button.dart';
import 'app_page_route.dart';
import 'app_sheet.dart';
import 'no_refunds_note.dart';

Future<void> showInsufficientCoinsSheet(
  BuildContext context, {
  required int needed,
  int? available,
}) {
  return showAppSheet<void>(
    context,
    builder: (_) =>
        _InsufficientCoinsSheet(needed: needed, available: available),
  );
}

class _InsufficientCoinsSheet extends StatelessWidget {
  final int needed;
  final int? available;

  const _InsufficientCoinsSheet({required this.needed, this.available});

  @override
  Widget build(BuildContext context) {
    final balance = available ?? context.watch<UserDataProvider>().animeCoins;
    final shortfall = (needed - balance).clamp(1, 999999);

    return AppSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.10),
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.25),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text('🪙', style: TextStyle(fontSize: 32.sp)),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'Not enough Anime Coins',
              style: AppTypography.heading3,
            ),
          ),
          const SizedBox(height: 10),

          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: AppTypography.bodyMedium.copyWith(height: 1.55),
              children: [
                const TextSpan(text: 'You have '),
                TextSpan(
                  text: '$balance 🪙',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: ' but need '),
                TextSpan(
                  text: '$needed 🪙',
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text:
                      '.\nYou\'re $shortfall coin${shortfall == 1 ? '' : 's'} short.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: 'Watch Ad  +15 AC',
              icon: Text(' \u{1F4FA}', style: TextStyle(fontSize: 18.sp)),
              variant: AppButtonVariant.primary,
              size: AppButtonSize.large,
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  AppPageRoute(
                    builder: (_) => const EarnCoinsScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),

          // Shop is website-only (see ShopLinkNote / EarnCoinsScreen).
          // This CTA promotes the web shop rather than a dead in-app flow.
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: 'Coin Packs on Website',
              icon: Text('\ud83d\uded2', style: TextStyle(fontSize: 18.sp)),
              variant: AppButtonVariant.outline,
              color: AppColors.accent,
              size: AppButtonSize.large,
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  AppPageRoute(builder: (_) => const EarnCoinsScreen()),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          const NoRefundsNote(compact: true, showPolicyLink: true),
        ],
      ),
    );
  }
}
