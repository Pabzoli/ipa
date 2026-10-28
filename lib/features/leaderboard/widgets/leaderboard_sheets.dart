import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers/user_data_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../auth/auth_service.dart';
import 'leaderboard_pool_card.dart';

// ═══════════════════════════════════════════════════════════════════════════
// WEB PURCHASE SHEET
// ═══════════════════════════════════════════════════════════════════════════

/// Opens the inline Flutterwave purchase sheet.
///
/// Web-only by construction: the Android/iOS builds reach the hosted shop
/// through [LeaderboardEntryCta] instead, so no external-payment URL is ever
/// requested from a Play-distributed build. Both the guard here and the branch
/// in the CTA are driven by the same platform check.
Future<void> showLeaderboardPurchaseSheet(BuildContext context) async {
  if (!kIsWeb) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Purchases are only available on our website.',
          style: TextStyle(fontFamily: 'Nunito'),
        ),
      ),
    );
    return;
  }

  await showAppSheet<void>(
    context,
    builder: (_) => const _LeaderboardPurchaseSheet(),
  );
}

class _LeaderboardPurchaseSheet extends StatefulWidget {
  const _LeaderboardPurchaseSheet();

  @override
  State<_LeaderboardPurchaseSheet> createState() =>
      _LeaderboardPurchaseSheetState();
}

class _LeaderboardPurchaseSheetState extends State<_LeaderboardPurchaseSheet> {
  static const _paymentEndpoint =
      'https://us-central1-anime-quiz-1ab1b.cloudfunctions.net/requestPaymentLink';

  bool _opening = false;
  bool _autoDismissed = false;

  Future<void> _buy() async {
    if (_opening) return;

    // Defence in depth: the CTA already routes mobile to the website, but a
    // payment endpoint must never be reachable from a Play-distributed build
    // regardless of how it was reached.
    if (!kIsWeb) {
      if (mounted) _snack('Purchases are only available on our website.');
      return;
    }

    final user = AuthService.instance.currentUser;
    if (user == null || (user.email ?? '').isEmpty) {
      _snack('Sign in to purchase a leaderboard entry.');
      return;
    }

    setState(() => _opening = true);
    HttpClient? client;
    try {
      // Purchases are account-bound server-side: the ID token decides who the
      // code belongs to, and no email is sent in the body.
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) {
        if (mounted) _snack('Your session expired. Sign in again.');
        return;
      }

      client = HttpClient();
      final request = await client.postUrl(Uri.parse(_paymentEndpoint));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.write(jsonEncode({'productId': 'AQ_LB_WEEK'}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      final decoded = jsonDecode(body);
      if (response.statusCode == 401) {
        if (mounted) _snack('Your session expired. Sign in again.');
        return;
      }
      if (response.statusCode != 200 ||
          decoded is! Map<String, dynamic> ||
          decoded['success'] != true) {
        if (mounted) _snack('Payment setup failed. Please try again.');
        return;
      }

      final link = decoded['link'] as String?;
      if (link == null || link.isEmpty) {
        if (mounted) _snack('Payment setup failed. Please try again.');
        return;
      }

      final uri = Uri.parse(link);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          _snack(
            'The code is tied to this account. Redeem it under '
            'Profile → Redeem Code.',
          );
        }
      } else if (mounted) {
        _snack('Could not open the payment page.');
      }
    } catch (e) {
      debugPrint('[LeaderboardPurchase] error: $e');
      if (mounted) _snack('Something went wrong. Please try again.');
    } finally {
      client?.close(force: true);
      if (mounted) setState(() => _opening = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontFamily: 'Nunito')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Once the entry activates, the sheet has served its purpose. Captured
    // before popping so the confirmation still has a messenger to use.
    if (context.watch<UserDataProvider>().isLeaderboardEligible &&
        !_autoDismissed &&
        !_opening) {
      _autoDismissed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Entry active — good luck!',
              style: TextStyle(fontFamily: 'Nunito'),
            ),
          ),
        );
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 44.r,
              height: 44.r,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: LeaderboardPalette.gold.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Icon(Icons.emoji_events_rounded,
                  color: AppColors.readable(LeaderboardPalette.gold), size: 22.r),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Compete for prizes',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                      height: 1.1,
                    ),
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    '₦500 · one week',
                    style: TextStyle(
                      color: AppColors.secondary,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 18.h),

        Text(
          "A leaderboard entry activates your already-earned points for this "
          "week's paid rank & prize pool (top ranks split 70% of this week's "
          "entry revenue). One entry covers this week only.",
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13.sp,
            height: 1.5,
          ),
        ),
        SizedBox(height: 14.h),

        Container(
          width: double.infinity,
          padding: EdgeInsets.all(12.r),
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.24),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded,
                  color: AppColors.secondary, size: 16.r),
              SizedBox(width: 10.w),
              Expanded(
                child: Text(
                  "Pay securely via Flutterwave. The one-time code is tied to "
                  'this account — redeem it under Profile → Redeem Code to '
                  'activate your entry.',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.sp,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 20.h),

        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _opening ? null : _buy,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
            ),
            child: _opening
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Continue to payment',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
          ),
        ),
        SizedBox(height: 6.h),

        Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              "I'll redeem my code later",
              style: TextStyle(
                color: AppColors.textMuted,
                fontFamily: 'Nunito',
                fontSize: 13.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
