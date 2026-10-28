import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/widgets/app_back_button.dart';
import '../../../data/data_source/referral_remote_data_source.dart';
import '../../../data/model/referral_cashout.dart';
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
  late Future<ReferralCashoutClaim?> _cashoutFuture;

  @override
  void initState() {
    super.initState();
    _entriesFuture = _dataSource.getReferralEntries();
    _codeFuture = _dataSource.getReferralCode();
    _cashoutFuture = _dataSource.getCashoutClaim();
  }

  Future<void> _reload() async {
    final future = _dataSource.getReferralEntries();
    // The code is refetched too: a mint that failed while offline would
    // otherwise leave the page codeless until the screen is reopened.
    final code = _dataSource.getReferralCode();
    final cashout = _dataSource.getCashoutClaim();
    setState(() {
      _entriesFuture = future;
      _codeFuture = code;
      _cashoutFuture = cashout;
    });
    try {
      await future;
    } catch (_) {
      // Rendered by ReferralBody's error state.
    }
  }

  @override
  Widget build(BuildContext context) {
    return _buildGated(context);
  }

  Widget _buildGated(BuildContext context) {
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
                  const AppBackButton(),
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
                cashoutFuture: _cashoutFuture,
                onRefresh: _reload,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
