import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../data/data_source/referral_remote_data_source.dart';
import '../../../data/model/referral_entry.dart';
import 'widgets/referral_body.dart';

/// Referral tracking screen: the referral code, totals and the pending /
/// rewarded / expired referral sections.
class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key});

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  static const _dataSource = ReferralRemoteDataSource();

  late Future<List<ReferralEntry>> _entriesFuture;
  late Future<String> _codeFuture;

  @override
  void initState() {
    super.initState();
    _entriesFuture = _dataSource.getReferralEntries();
    _codeFuture = _dataSource.getReferralCode();
  }

  Future<void> _reload() async {
    final future = _dataSource.getReferralEntries();
    // The code is refetched too: a mint that failed while offline would
    // otherwise leave the page codeless until the screen is reopened.
    final code = _dataSource.getReferralCode();
    setState(() {
      _entriesFuture = future;
      _codeFuture = code;
    });
    try {
      await future;
    } catch (_) {
      // Rendered by ReferralBody's error state.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Header (matches Earn Coins / Premium) ────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(8.r, 10.r, 16.r, 4.r),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: AppColors.textPrimary,
                      size: 19.r,
                    ),
                    splashRadius: 22,
                  ),
                  SizedBox(width: 2.w),
                  Expanded(
                    child: Text(
                      'Referrals',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.heading2.copyWith(
                        fontSize: 26.sp,
                        letterSpacing: -0.5,
                        height: 1.05,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Body ─────────────────────────────────────────────────
            Expanded(
              child: ReferralBody(
                entriesFuture: _entriesFuture,
                codeFuture: _codeFuture,
                onRefresh: _reload,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
