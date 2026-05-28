import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/user_data_provider.dart';
import '../theme/app_theme.dart';
import '../../features/coins/earn_coins_screen.dart';

/// Compact pill: 🪙 + live animeCoins balance.
///
/// Tap pushes [EarnCoinsScreen] (built in P-04).
/// Drop it anywhere in the widget tree that is inside a [UserDataProvider].
class CoinBalanceWidget extends StatelessWidget {
  const CoinBalanceWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final coins = context.watch<UserDataProvider>().animeCoins;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const EarnCoinsScreen()),
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color:        AppColors.accent.withOpacity(0.13),
          borderRadius: BorderRadius.circular(20),
          border:       Border.all(
            color: AppColors.accent.withOpacity(0.38),
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🪙', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 5),
            Text(
              _formatCoins(coins),
              style: const TextStyle(
                color:      AppColors.accent,
                fontWeight: FontWeight.w800,
                fontSize:   14,
                fontFamily: 'Nunito',
              ),
            ),
          ],
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