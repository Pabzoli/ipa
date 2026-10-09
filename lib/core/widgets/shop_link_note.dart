import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

/// Website shop reference: shows the shop URL with an "Open" button that
/// launches the website in the external browser (works on Android and web).
/// If no browser is available the URL is copied to the clipboard instead.
class ShopLinkNote extends StatelessWidget {
  const ShopLinkNote({super.key, this.compact = false});

  /// Uses a denser layout for bottom sheets / position cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
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
            child: GestureDetector(
              onTap: () => _open(context),
              child: Text(
                kShopUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.primary,
                  fontFamily: 'Nunito',
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => _open(context),
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
            icon: Icon(Icons.open_in_new_rounded,
                size: 14.r, color: AppColors.primary),
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
          SnackBar(
            content: Text(
              'Couldn\'t open the browser — website link copied instead.',
              style: const TextStyle(fontFamily: 'Nunito'),
            ),
          ),
        );
      }
    }
  }
}
