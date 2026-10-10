import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers/user_data_provider.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/no_refunds_note.dart';
import '../../auth/auth_service.dart';
import '../../multiplayer/rivalry_page.dart';
import '../leaderboard_models.dart';
import 'leaderboard_pool_card.dart';

/// Opens the rival sheet for [rival].
///
/// [parentContext] must be the context of the *caller*, not the sheet's. The
/// rivalry button dismisses the sheet and immediately pushes a route, and
/// doing that on the sheet's own context means pushing on a widget that is
/// mid-teardown.
void showRivalSheet(
  BuildContext parentContext,
  BoardEntry rival,
) {
  final currentUid = FirestoreService.instance.currentUid;
  if (currentUid == null) return;

  showAppSheet<void>(
    parentContext,
    builder: (_) => _RivalSheet(
      rival: rival,
      currentUid: currentUid,
      // Captured now, used after the sheet is gone. Sparring is always
      // available, so this button never gates on cooldown — duel
      // availability lives on the rivalry page.
      pushChallenge: () => Navigator.of(parentContext).push(
        MaterialPageRoute<void>(
          builder: (_) => RivalryPage(
            rivalUid: rival.uid,
            rivalUsername: rival.username,
          ),
        ),
      ),
    ),
  );
}

class _RivalSheet extends StatefulWidget {
  final BoardEntry rival;
  final String currentUid;
  final VoidCallback pushChallenge;

  const _RivalSheet({
    required this.rival,
    required this.currentUid,
    required this.pushChallenge,
  });

  @override
  State<_RivalSheet> createState() => _RivalSheetState();
}

class _RivalSheetState extends State<_RivalSheet> {
  static const _rivalColour = LeaderboardPalette.rival;

  Map<String, int>? _h2h;
  bool _loadingH2H = true;

  @override
  void initState() {
    super.initState();
    _loadH2H();
  }

  Future<void> _loadH2H() async {
    try {
      final result = await FirestoreService.instance
          .getHeadToHeadRecord(widget.currentUid, widget.rival.uid);
      if (!mounted) return;
      setState(() {
        _h2h = result;
        _loadingH2H = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingH2H = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rival = widget.rival;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Header: avatar, name, status ─────────────────────────────
        Row(
          children: [
            Container(
              width: 54.w,
              height: 54.h,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _rivalColour.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16.r),
              ),
              child: Text(
                rival.initial,
                style: TextStyle(
                  color: _rivalColour,
                  fontSize: 24.sp,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          rival.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 17.sp,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.2,
                            height: 1.15,
                          ),
                        ),
                      ),
                      SizedBox(width: 6.w),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.r, vertical: 2.r),
                        decoration: BoxDecoration(
                          color: _rivalColour.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(5.r),
                        ),
                        child: Text(
                          'RIVAL',
                          style: TextStyle(
                            color: _rivalColour,
                            fontSize: 8.sp,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4.h),
                  Text(
                    [
                      if (rival.rank != null) '#${rival.rank}',
                      if (rival.university.isNotEmpty) rival.university,
                      '${rival.weeklyPoints} pts',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 18.h),

        // ── Head to head ─────────────────────────────────────────────
        Container(
          padding: EdgeInsets.symmetric(vertical: 14.r),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(14.r),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _H2HStat(
                label: 'Wins',
                value: _h2h?['wins'] ?? 0,
                color: AppColors.correct,
                loading: _loadingH2H,
              ),
              Container(width: 1, height: 32, color: AppColors.divider),
              _H2HStat(
                label: 'Draws',
                value: _h2h?['draws'] ?? 0,
                color: AppColors.secondary,
                loading: _loadingH2H,
              ),
              Container(width: 1, height: 32, color: AppColors.divider),
              _H2HStat(
                label: 'Losses',
                value: _h2h?['losses'] ?? 0,
                color: AppColors.wrong,
                loading: _loadingH2H,
              ),
            ],
          ),
        ),
        SizedBox(height: 16.h),

        // ── Rivalry ────────────────────────────────────────────────
        // Sparring is always open, so this never gates on the ranked
        // rematch cooldown — duel availability is previewed on the
        // rivalry page instead.
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: EdgeInsets.symmetric(vertical: 14.r),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13.r),
              ),
            ),
            onPressed: () {
              // Dismiss first, then push on the caller's context.
              Navigator.of(context).pop();
              widget.pushChallenge();
            },
            child: Text(
              'Open rivalry',
              style: TextStyle(
                fontSize: 15.sp,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _H2HStat extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final bool loading;

  const _H2HStat({
    required this.label,
    required this.value,
    required this.color,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (loading)
          SizedBox(
            width: 18.w,
            height: 18.h,
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.textMuted,
            ),
          )
        else
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: 22.sp,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
        SizedBox(height: 4.h),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.sp,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

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

    final email = AuthService.instance.currentUser?.email;
    if (email == null || email.isEmpty) {
      _snack('Sign in to purchase a leaderboard entry.');
      return;
    }

    setState(() => _opening = true);
    HttpClient? client;
    try {
      client = HttpClient();
      final request = await client.postUrl(Uri.parse(_paymentEndpoint));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'productId': 'AQ_LB_WEEK', 'email': email}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      final decoded = jsonDecode(body);
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
            'After paying, redeem the code you receive under '
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
                borderRadius: BorderRadius.circular(12.r),
              ),
              child: Icon(Icons.emoji_events_rounded,
                  color: LeaderboardPalette.gold, size: 22.r),
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
          "entry revenue). One entry covers this week only, and once it is "
          "activated it cannot be withdrawn.",
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
            borderRadius: BorderRadius.circular(12.r),
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
                  "Pay securely via Flutterwave. After payment you'll receive "
                  "a one-time code on the success page — redeem it under "
                  'Profile → Redeem Code to activate your entry.',
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
        SizedBox(height: 12.h),

        // Final-sale notice sits directly above the pay button: once an entry
        // is activated it is applied to the pool and cannot be withdrawn, so
        // this has to be read before "Continue to payment", not after.
        const NoRefundsNote(compact: true, showPolicyLink: true),
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
                borderRadius: BorderRadius.circular(12.r),
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