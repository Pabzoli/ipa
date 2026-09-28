import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

/// Player-policy-safe website reference: renders the shop URL as plain,
/// non-interactive text. The only tappable element is the [TextButton.icon]
/// "Copy" button, which copies the URL string and never launches a browser.
/// Do not wrap the URL [Text] in a gesture detector or call `url_launcher`
/// from this widget — the in-app UI must not navigate users to the checkout.
class ShopLinkNote extends StatelessWidget {
  const ShopLinkNote({super.key, this.compact = false});

  /// Uses a denser layout for bottom sheets / position cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // The website shop is web-only (Play Billing policy: the Play-distributed
    // Android app must not expose any external purchase path). On non-web
    // platforms this widget renders nothing so no shop reference is visible.
    if (!kIsWeb) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 12.r,
        vertical: compact ? 8.r : 10.r,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Icon(Icons.language_rounded,
              size: 16.r, color: AppColors.textMuted),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              kShopUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textMuted,
                fontFamily: 'Nunito',
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => _copy(context),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
            icon: Icon(Icons.content_copy_rounded,
                size: 14.r, color: AppColors.primary),
            label: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context) {
    Clipboard.setData(const ClipboardData(text: kShopUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Website link copied — open it in your browser.',
          style: TextStyle(fontFamily: 'Nunito'),
        ),
      ),
    );
  }
}