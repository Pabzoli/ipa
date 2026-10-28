import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../providers/user_data_provider.dart';
import '../theme/app_theme.dart';
import '../../features/coins/earn_coins_screen.dart';
import 'app_page_route.dart';

/// Compact pill: 🪙 + live animeCoins balance.
///
/// Tap pushes [EarnCoinsScreen] (built in P-04).
/// Drop it anywhere in the widget tree that is inside a [UserDataProvider].
class CoinBalanceWidget extends StatelessWidget {
  const CoinBalanceWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final coins = context.watch<UserDataProvider>().animeCoins;

    return Ink(
      decoration: BoxDecoration(
        color:        AppColors.accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border:       Border.all(
          color: AppColors.accent.withValues(alpha: 0.38),
          width: 1.2,
        ),
      ),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            AppPageRoute(builder: (_) => const EarnCoinsScreen()),
          );
        },
        borderRadius: BorderRadius.circular(AppRadii.xl),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 6.r),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('🪙', style: TextStyle(fontSize: 14.sp)),
              const SizedBox(width: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _formatCoins(coins),
                  style: TextStyle(
                    color: AppColors.readable(AppColors.accent),
                    fontWeight: FontWeight.w800,
                    fontSize:   14.sp,
                    fontFamily: AppTypography.fontFamily,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Formats large coin values compactly: 1 500 → 1.5K
  static String _formatCoins(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}