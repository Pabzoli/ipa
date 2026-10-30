// lib/features/admin/admin_tabs.dart
//
// Thin tab hosts for the admin console. Each tab is the existing admin page in
// embedded mode (no nested Scaffold/AppBar) wrapped with the new shared hero
// header so all four destinations read as one console.
//
// Business logic and service calls are unchanged — they live in the page
// State classes exactly as before.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'admin_house_page.dart';
import 'admin_payout_dashboard.dart';
import 'admin_referral_cashouts_page.dart';
import 'widgets/admin_shared.dart';

class AdminPayoutsTab extends StatelessWidget {
  const AdminPayoutsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 0),
          child: const AdminHero(
            title: 'Weekly payouts',
            subtitle:
                'Send from your bank app first, then mark paid. Amounts come from the server.',
            icon: Icons.payments_outlined,
          ),
        ),
        SizedBox(height: 12.h),
        const Expanded(child: AdminPayoutDashboard(embedded: true)),
      ],
    );
  }
}

class AdminReferralsTab extends StatelessWidget {
  const AdminReferralsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 0),
          child: const AdminHero(
            title: 'Referral cashouts',
            subtitle:
                'Separate budget from the prize pool. Fixed ₦5,000 per claim.',
            icon: Icons.savings_outlined,
          ),
        ),
        SizedBox(height: 12.h),
        const Expanded(child: AdminReferralCashoutsPage(embedded: true)),
      ],
    );
  }
}

class AdminHouseTab extends StatelessWidget {
  const AdminHouseTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 0),
          child: const AdminHero(
            title: 'House top 3',
            subtitle:
                'Ghost engine that keeps the leaderboard catchable. Pauses and gaps apply instantly.',
            icon: Icons.shield_outlined,
          ),
        ),
        SizedBox(height: 12.h),
        const Expanded(child: AdminHousePage(embedded: true)),
      ],
    );
  }
}
