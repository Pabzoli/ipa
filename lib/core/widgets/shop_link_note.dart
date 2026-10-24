import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

/// Website shop reference: a compact action card that opens the shop in the
/// external browser (works on Android and web). If no browser is available the
/// URL is copied to the clipboard instead.
///
/// Styled to match the app's native cards (flat surface + accent shop icon
/// tile, matching the coin-pack and "How to get it" headers) instead of a
/// web-style gradient banner.
///
/// Contract (pinned by test/widget_test.dart): the full [kShopUrl] text must
/// be shown underlined inside a tappable GestureDetector, with exactly one
/// "Open" TextButton. Keep that contract when restyling.
class ShopLinkNote extends StatelessWidget {
  const ShopLinkNote({super.key, this.compact = false});

  /// Uses a denser layout for bottom sheets / position cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12.r : 14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Main row: shop icon + copy + Open button ─────────────
          Row(
            children: [
              Container(
                width: compact ? 34.r : 40.r,
                height: compact ? 34.r : 40.r,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12.r),
                  border: Border.all(
                    color: AppColors.accent.withValues(alpha: 0.32),
                  ),
                ),
                child: Icon(
                  Icons.storefront_rounded,
                  size: (compact ? 17 : 20).r,
                  color: AppColors.accent,
                ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Shop on our website',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontFamily: 'Nunito',
                        fontSize: (compact ? 12 : 13).sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8.w),
              TextButton.icon(
                onPressed: () => _open(context),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: AppColors.primary,
                  padding: EdgeInsets.symmetric(
                    horizontal: 12.r,
                    vertical: 8.r,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10.r),
                  ),
                  textStyle: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                icon: Icon(Icons.open_in_new_rounded,
                    size: 14.r, color: Colors.white),
                label: const Text('Open'),
              ),
            ],
          ),

          SizedBox(height: 12.h),

          // ── Divider ──────────────────────────────────────────────
          Container(height: 1, color: AppColors.divider),

          SizedBox(height: 10.h),

          // ── Footer: the shop URL as a tappable link ──────────────
          GestureDetector(
            onTap: () => _open(context),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Icon(Icons.language_rounded,
                    size: (compact ? 11 : 12).r, color: AppColors.textMuted),
                SizedBox(width: 6.w),
                Expanded(
                  child: Text(
                    kShopUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.primary,
                      fontFamily: 'Nunito',
                      fontSize: (compact ? 10 : 11).sp,
                      fontWeight: FontWeight.w800,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.primary,
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

  Future<void> _open(BuildContext context) async {
    final uri = Uri.parse(kShopUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      await Clipboard.setData(const ClipboardData(text: kShopUrl));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn\'t open the browser — website link copied instead.',
              style: TextStyle(fontFamily: 'Nunito'),
            ),
          ),
        );
      }
    }
  }
}