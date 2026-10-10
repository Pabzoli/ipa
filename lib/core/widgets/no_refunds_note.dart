import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

/// Pre-baked alpha tints for [AppColors.warning], matching the convention of the
/// other stable tints in app_theme.dart.
const Color _warningSoft = Color(0x14F4A261); // warning @ ~8%
const Color _warningBorder = Color(0x52F4A261); // warning @ ~32%

/// Blunt "purchases are final sale, no refunds" notice for in-app purchase
/// surfaces (coin packs, Premium, leaderboard entry).
///
/// Shows [kNoRefundsNotice] verbatim so the copy is identical everywhere, and
/// optionally links through to the hosted policy. It is a notice, not a
/// confirmation gate — there is deliberately no tappable "I understand" step,
/// because requiring consent to a term you have already published is friction
/// without protection and costs conversions.
///
/// Deliberately NOT for the in-game stake refunds on expired multiplayer
/// challenges. Those return in-game credit between players and are not refunds
/// of money paid to us; showing this widget there would be a false statement.
class NoRefundsNote extends StatelessWidget {
  const NoRefundsNote({super.key, this.showPolicyLink = false, this.compact = false});

  /// Appends a tappable link to the hosted No Refunds Policy.
  final bool showPolicyLink;

  /// Denser layout for bottom sheets.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final heading = Text(
      'No refunds',
      style: TextStyle(
        color: AppColors.warning,
        fontFamily: 'Nunito',
        fontSize: (compact ? 11 : 12).sp,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.4,
      ),
    );

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 12.r,
        vertical: compact ? 8.r : 10.r,
      ),
      decoration: BoxDecoration(
        color: _warningSoft,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: _warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded,
              size: (compact ? 14 : 16).r, color: AppColors.warning),
          SizedBox(width: 8.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                SizedBox(height: 2.h),
                Text(
                  kNoRefundsNotice,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontFamily: 'Nunito',
                    fontSize: (compact ? 11 : 12).sp,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                if (showPolicyLink)
                  GestureDetector(
                    onTap: () => _openPolicy(context),
                    child: Padding(
                      padding: EdgeInsets.only(top: 4.h),
                      child: Text(
                        'Read the full policy',
                        style: TextStyle(
                          color: AppColors.warning,
                          fontFamily: 'Nunito',
                          fontSize: (compact ? 11 : 12).sp,
                          fontWeight: FontWeight.w900,
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.warning,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openPolicy(BuildContext context) async {
    final uri = Uri.parse(kNoRefundsPolicyUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Couldn\'t open the browser. Policy: $kNoRefundsPolicyUrl',
            style: const TextStyle(fontFamily: 'Nunito'),
          ),
        ),
      );
    }
  }
}