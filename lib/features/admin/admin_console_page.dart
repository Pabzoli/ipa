// lib/features/admin/admin_console_page.dart
//
// Redesigned admin entry point: one shell, four destinations.
//
// Before: three disconnected pages (payout dashboard, referral cashouts,
// house top-3) reached through AppBar icons on the payout page. After: a
// single [AdminConsolePage] with bottom navigation (phone) / rail (tablet)
// hosting Overview, Payouts, Referrals and House as tabs.
//
// All money movement stays manual and server-gated exactly as before. This
// file only changes navigation and presentation; every callable still goes
// through AdminPayoutService / AdminHouseService with the ADMIN_UIDS gate.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_page_route.dart';
import 'admin_house_service.dart';
import 'admin_payout_service.dart';
import 'admin_tabs.dart';
import 'widgets/admin_shared.dart';

class AdminConsolePage extends StatefulWidget {
  final int initialTab;
  const AdminConsolePage({super.key, this.initialTab = 0});

  /// Push helper used by the home-page entry card and any deep link.
  static Future<void> open(BuildContext context, {int tab = 0}) {
    return Navigator.of(context).push(
      AppPageRoute(builder: (_) => AdminConsolePage(initialTab: tab)),
    );
  }

  @override
  State<AdminConsolePage> createState() => _AdminConsolePageState();
}

class _AdminConsolePageState extends State<AdminConsolePage> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialTab.clamp(0, 3);
  }

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 720;
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: const AppBackButton(),
        title: Text('Admin console', style: AppTypography.heading3),
        actions: [
          Container(
            margin: EdgeInsets.only(right: 16.w),
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 5.h),
            decoration: BoxDecoration(
              color: AppColors.wrong.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadii.full.r),
              border: Border.all(
                color: AppColors.wrong.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.verified_user_rounded,
                  size: 13.r,
                  color: AppColors.readable(AppColors.wrong),
                ),
                SizedBox(width: 5.w),
                Text(
                  'ADMIN',
                  style: AppTypography.labelSmall.copyWith(
                    color: AppColors.readable(AppColors.wrong),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              NavigationRail(
                backgroundColor: AppColors.surfaceDim,
                selectedIndex: _index,
                onDestinationSelected: _go,
                labelType: NavigationRailLabelType.all,
                selectedLabelTextStyle: AppTypography.labelSmall.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w900,
                ),
                unselectedLabelTextStyle: AppTypography.labelSmall,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard_rounded),
                    label: Text('Overview'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.payments_outlined),
                    selectedIcon: Icon(Icons.payments_rounded),
                    label: Text('Payouts'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.savings_outlined),
                    selectedIcon: Icon(Icons.savings_rounded),
                    label: Text('Referrals'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.shield_outlined),
                    selectedIcon: Icon(Icons.shield_rounded),
                    label: Text('House'),
                  ),
                ],
              ),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: [
                  _OverviewTab(onGo: _go),
                  const AdminPayoutsTab(),
                  const AdminReferralsTab(),
                  const AdminHouseTab(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              backgroundColor: AppColors.surface,
              indicatorColor: AppColors.primary.withValues(alpha: 0.14),
              selectedIndex: _index,
              onDestinationSelected: _go,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard_rounded),
                  label: 'Overview',
                ),
                NavigationDestination(
                  icon: Icon(Icons.payments_outlined),
                  selectedIcon: Icon(Icons.payments_rounded),
                  label: 'Payouts',
                ),
                NavigationDestination(
                  icon: Icon(Icons.savings_outlined),
                  selectedIcon: Icon(Icons.savings_rounded),
                  label: 'Referrals',
                ),
                NavigationDestination(
                  icon: Icon(Icons.shield_outlined),
                  selectedIcon: Icon(Icons.shield_rounded),
                  label: 'House',
                ),
              ],
            ),
    );
  }
}

// ─── Overview ────────────────────────────────────────────────────────────────

enum _OverviewState { loading, denied, error, ready }

class _OverviewTab extends StatefulWidget {
  final ValueChanged<int> onGo;
  const _OverviewTab({required this.onGo});

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  _OverviewState _state = _OverviewState.loading;
  String _message = '';
  List<AdminPayoutCycle> _cycles = const [];
  AdminReferralCashoutSnapshot? _referrals;
  PrizePoolStatus? _pool;
  HouseSnapshot? _house;
  bool _partialData = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _state = _OverviewState.loading;
      _message = '';
      _partialData = false;
    });
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _state = _OverviewState.denied;
          _message = 'Sign in with the admin account to open this console.';
        });
      }
      return;
    }
    if (!isAdminUid(user.uid)) {
      if (mounted) {
        setState(() {
          _state = _OverviewState.denied;
          _message = 'This account is not authorized for administration.';
        });
      }
      return;
    }
    try {
      final cycles = await AdminPayoutService.instance.listPayoutClaims();
      AdminReferralCashoutSnapshot? refs;
      PrizePoolStatus? pool;
      HouseSnapshot? house;
      var partial = false;
      try {
        refs = await AdminPayoutService.instance.listReferralCashouts();
      } catch (_) {
        partial = true;
      }
      try {
        pool = await AdminPayoutService.instance.getPrizePoolStatus();
      } catch (_) {
        partial = true;
      }
      try {
        house = await AdminHouseService.instance.fetch();
      } catch (_) {
        partial = true;
      }
      if (!mounted) return;
      setState(() {
        _cycles = cycles;
        _referrals = refs;
        _pool = pool;
        _house = house;
        _partialData = partial;
        _state = _OverviewState.ready;
      });
    } on AdminPayoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = e.code == 'permission-denied'
            ? _OverviewState.denied
            : _OverviewState.error;
        _message = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _OverviewState.error;
        _message = 'Could not load admin overview. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (_state) {
      _OverviewState.loading => const AdminLoading(),
      _OverviewState.denied => AdminStateView(
          icon: Icons.lock_outline_rounded,
          title: 'Not authorized',
          message: _message,
          onRetry: _load,
        ),
      _OverviewState.error => AdminStateView(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load',
          message: _message,
          onRetry: _load,
        ),
      _OverviewState.ready => _body(),
    };
  }

  Widget _body() {
    final pendingCycles = _cycles.fold<int>(0, (n, c) => n + c.pendingCount);
    final pendingAmount =
        _cycles.fold<double>(0, (s, c) => s + c.pendingAmount);
    final pendingRefs = _referrals?.pending.length ?? 0;
    final refAmount = _referrals?.pendingAmount ?? 0;
    final shortfall = _referrals?.reserve.shortfall ?? 0;
    final pool = _pool;
    final house = _house;
    final houseEnabled = (house?.global['enabled'] as bool?) ?? true;

    // Next actions: top pending winners + pending referrals, capped.
    final actions = <_Action>[];
    for (final c in _cycles) {
      for (final claim in c.claims.where((e) => e.needsPayment)) {
        actions.add(
          _Action(
            icon: Icons.payments_outlined,
            title:
                '#${claim.rank} ${claim.username} · ${adminNaira(claim.share)}',
            subtitle: 'Week ${c.weekId} · tap to pay',
            tab: 1,
          ),
        );
        if (actions.length >= 4) break;
      }
      if (actions.length >= 4) break;
    }
    if (actions.length < 5 && _referrals != null) {
      for (final r in _referrals!.pending.take(5 - actions.length)) {
        actions.add(
          _Action(
            icon: Icons.savings_outlined,
            title: '${r.username ?? r.uid} · ${adminNaira(r.amount)}',
            subtitle: 'Referral cashout · tap to review',
            tab: 2,
          ),
        );
      }
    }

    return RefreshIndicator(
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 24.h),
        children: [
          AdminHero(
            title: 'Good day, admin',
            subtitle: pendingCycles == 0 && pendingRefs == 0
                ? 'Every queue is clear. Nothing needs money movement.'
                : '$pendingCycles weekly prize(s) + $pendingRefs referral(s) need you.',
            icon: Icons.admin_panel_settings_outlined,
            trailing: IconButton(
              tooltip: 'Refresh',
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
          SizedBox(height: AppSpacing.md.h),
          if (_partialData)
            Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm.h),
              child: AppCard(
                accentColor: AppColors.amber,
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      color: AppColors.readable(AppColors.amber),
                      size: 18.r,
                    ),
                    SizedBox(width: AppSpacing.sm.w),
                    Expanded(
                      child: Text(
                        'Some sections failed to load — figures may be incomplete. Pull to refresh.',
                        style: AppTypography.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: AppSpacing.sm.r,
            crossAxisSpacing: AppSpacing.sm.r,
            childAspectRatio: 1.35,
            children: [
              AdminStat(
                label: 'Awaiting prizes',
                value: adminNaira(pendingAmount),
                icon: Icons.payments_outlined,
                color: AppColors.accent,
                onTap: () => widget.onGo(1),
              ),
              AdminStat(
                label: 'Referral queue',
                value: pendingRefs == 0
                    ? 'Clear'
                    : '$pendingRefs · ${adminNaira(refAmount)}',
                icon: Icons.savings_outlined,
                color: AppColors.amber,
                onTap: () => widget.onGo(2),
              ),
              AdminStat(
                label: pool == null ? 'Prize pool' : 'Pool · ${pool.weekId}',
                value: pool == null ? '—' : adminNaira(pool.effectivePool),
                icon: Icons.account_balance_wallet_outlined,
                color: AppColors.correct,
                onTap: () => widget.onGo(1),
              ),
              AdminStat(
                label: 'House engine',
                value: house == null ? '—' : (houseEnabled ? 'ON' : 'PAUSED'),
                icon: Icons.shield_outlined,
                color: houseEnabled ? AppColors.correct : AppColors.wrong,
                onTap: () => widget.onGo(3),
              ),
            ],
          ),
          if (shortfall > 0) ...[
            SizedBox(height: AppSpacing.md.h),
            AppCard(
              accentColor: AppColors.wrong,
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: AppColors.readable(AppColors.wrong),
                    size: 18.r,
                  ),
                  SizedBox(width: AppSpacing.sm.w),
                  Expanded(
                    child: Text(
                      'Referral budget is short by ${adminNaira(shortfall)}. Top up before paying.',
                      style: AppTypography.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: AppSpacing.lg.h),
          AdminSectionTitle(
            title: 'Needs your action',
            trailing: actions.isEmpty ? null : '${actions.length} open',
          ),
          SizedBox(height: AppSpacing.sm.h),
          if (actions.isEmpty)
            AppCard(
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline_rounded,
                    color: AppColors.readable(AppColors.correct),
                    size: 20.r,
                  ),
                  SizedBox(width: AppSpacing.sm.w),
                  Expanded(
                    child: Text(
                      'Nothing awaiting payment. Check back after the next cycle closes.',
                      style: AppTypography.bodyMedium,
                    ),
                  ),
                ],
              ),
            )
          else
            for (final a in actions)
              Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.sm.h),
                child: AppCard(
                  onTap: () => widget.onGo(a.tab),
                  child: Row(
                    children: [
                      Icon(a.icon, color: AppColors.textMuted, size: 20.r),
                      SizedBox(width: AppSpacing.sm.w),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              a.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.labelLarge,
                            ),
                            Text(a.subtitle, style: AppTypography.bodySmall),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
          SizedBox(height: AppSpacing.lg.h),
          const AdminSectionTitle(title: 'Jump to'),
          SizedBox(height: AppSpacing.sm.h),
          Wrap(
            spacing: AppSpacing.sm.r,
            runSpacing: AppSpacing.sm.r,
            children: [
              _Jump(
                label: 'Pay winners',
                icon: Icons.payments_outlined,
                onTap: () => widget.onGo(1),
              ),
              _Jump(
                label: 'Referrals',
                icon: Icons.savings_outlined,
                onTap: () => widget.onGo(2),
              ),
              _Jump(
                label: 'House top 3',
                icon: Icons.shield_outlined,
                onTap: () => widget.onGo(3),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Action {
  final IconData icon;
  final String title;
  final String subtitle;
  final int tab;
  const _Action({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tab,
  });
}

class _Jump extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _Jump({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.full.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15.r, color: AppColors.primary),
            SizedBox(width: 6.w),
            Text(
              label,
              style: AppTypography.labelMedium.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
