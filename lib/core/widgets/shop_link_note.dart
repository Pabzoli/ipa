import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

/// Website shop reference: shows the shop URL with an "Open" button that
/// launches the website in the external browser (works on Android and web).
/// If no browser is available the URL is copied to the clipboard instead.
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
      padding: EdgeInsets.all(compact ? 10.r : 14.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withValues(alpha: 0.12),
            AppColors.primary.withValues(alpha: 0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Container(
            width: compact ? 34.r : 40.r,
            height: compact ? 34.r : 40.r,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.30),
              ),
            ),
            child: Icon(
              Icons.language_rounded,
              size: (compact ? 17 : 20).r,
              color: AppColors.primary,
            ),
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Visit our website',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontFamily: 'Nunito',
                    fontSize: (compact ? 12 : 13).sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
                SizedBox(height: 2.h),
                GestureDetector(
                  onTap: () => _open(context),
                  child: Text(
                    kShopUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.primary,
                      fontFamily: 'Nunito',
                      fontSize: (compact ? 11 : 12).sp,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                    ),
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
