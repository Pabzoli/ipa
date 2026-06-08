import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/user_data_provider.dart';
import '../theme/app_theme.dart';

// ─── Public helper ────────────────────────────────────────────────────────────
/// Show the "not enough coins" bottom sheet.
///
/// [needed]    is the cost of the action the user tried to perform.
/// [available] is the server-authoritative balance from [InsufficientCoinsException].
///             Pass it whenever you catch that exception so the shortfall shown
///             is the real server value, not the (potentially stale) local cache.
///             Falls back to `UserDataProvider.animeCoins` when omitted.
Future<void> showInsufficientCoinsSheet(
  BuildContext context, {
  required int needed,
  int?         available, // ← authoritative balance from InsufficientCoinsException
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _InsufficientCoinsSheet(needed: needed, available: available),
  );
}

// ─── Sheet widget ─────────────────────────────────────────────────────────────
class _InsufficientCoinsSheet extends StatelessWidget {
  final int  needed;
  final int? available; // server-authoritative; null → fall back to provider
  const _InsufficientCoinsSheet({required this.needed, this.available});

  @override
  Widget build(BuildContext context) {
    // Prefer the server-authoritative balance passed in from InsufficientCoinsException.
    // If not provided (legacy call sites), fall back to the live provider value.
    final balance   = available ?? context.watch<UserDataProvider>().animeCoins;
    final shortfall = (needed - balance).clamp(1, 999999);

    return Container(
      decoration: const BoxDecoration(
        color:        AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
        24, 16, 24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── drag handle ────────────────────────────────────────────────────
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color:        AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // ── icon ───────────────────────────────────────────────────────────
          Container(
            width:  76,
            height: 76,
            decoration: BoxDecoration(
              color:  AppColors.accent.withOpacity(0.12),
              shape:  BoxShape.circle,
              border: Border.all(
                color: AppColors.accent.withOpacity(0.35),
                width: 2,
              ),
            ),
            child: const Center(
              child: Text('🪙', style: TextStyle(fontSize: 34)),
            ),
          ),
          const SizedBox(height: 16),

          // ── title ──────────────────────────────────────────────────────────
          const Text(
            'Not enough Anime Coins',
            style: TextStyle(
              color:      AppColors.textPrimary,
              fontSize:   20,
              fontWeight: FontWeight.w900,
              fontFamily: 'Nunito',
            ),
          ),
          const SizedBox(height: 10),

          // ── balance / shortfall info ───────────────────────────────────────
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: const TextStyle(
                color:      AppColors.textSecondary,
                fontSize:   14,
                height:     1.55,
                fontFamily: 'Nunito',
              ),
              children: [
                const TextSpan(text: 'You have '),
                TextSpan(
                  text: '$balance 🪙',
                  style: const TextStyle(
                    color:      AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const TextSpan(text: ' but need '),
                TextSpan(
                  text: '$needed 🪙',
                  style: const TextStyle(
                    color:      AppColors.accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: '.\nYou\'re $shortfall coin${shortfall == 1 ? '' : 's'} short.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // ── Watch Ad button (+10 AC) ───────────────────────────────────────
          SizedBox(
            width:  double.infinity,
            height: 52,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              onPressed: () {
                Navigator.pop(context);
                // TODO(P-04): push EarnCoinsScreen
                // Navigator.push(context,
                //   MaterialPageRoute(builder: (_) => const EarnCoinsScreen()));
              },
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('📺', style: TextStyle(fontSize: 18)),
                  SizedBox(width: 8),
                  Text(
                    'Watch Ad  +10🪙',
                    style: TextStyle(
                      fontSize:   16,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Nunito',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // ── Buy Coins button ───────────────────────────────────────────────
          SizedBox(
            width:  double.infinity,
            height: 52,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side:  BorderSide(color: AppColors.accent.withOpacity(0.7)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () {
                Navigator.pop(context);
                // TODO(P-11): push BuyCoinsScreen
                // Navigator.push(context,
                //   MaterialPageRoute(builder: (_) => const BuyCoinsScreen()));
              },
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('💎', style: TextStyle(fontSize: 18)),
                  SizedBox(width: 8),
                  Text(
                    'Buy Coins',
                    style: TextStyle(
                      fontSize:   16,
                      fontWeight: FontWeight.w700,
                      color:      AppColors.accent,
                      fontFamily: 'Nunito',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}