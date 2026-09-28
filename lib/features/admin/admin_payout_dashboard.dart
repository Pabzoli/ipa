// lib/features/admin/admin_payout_dashboard.dart
//
// Admin Payout Dashboard — manual review + approval of weekly leaderboard
// payout claims.
//
// WHAT THIS IS: a thin administrative UI around the EXISTING backend. The
// only money-movement path is the existing `approveLeaderboardPayout`
// callable (server-derived amounts, server-side reservation/idempotency,
// Flutterwave transfer, webhook-confirmed paid). This page never calls
// Flutterwave, never writes payoutLedger / payouts / paid=true, never sends
// an amount, and never displays full bank account numbers (server-masked
// ****last4 only).
//
// Paid is displayed ONLY when the backend says ranked[].paid == true. A
// successful approval shows "Transfer submitted / awaiting Flutterwave
// confirmation" — never "Paid".

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import 'admin_payout_service.dart';

/// Formats whole/kobo naira with thousands separators, e.g. ₦12,500.
/// Amounts always come from the server — this only renders them.
String formatNaira(double amount) {
  final fixed = amount.toStringAsFixed(2);
  final parts = fixed.split('.');
  final digits = parts[0].split('').reversed.toList();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && i % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  final intPart = buf.toString().split('').reversed.join();
  final frac = parts[1] == '00' ? '' : '.${parts[1]}';
  return '₦$intPart$frac';
}

String _shortUid(String uid) =>
    uid.length <= 8 ? uid : '${uid.substring(0, 6)}…';

String _formatTime(DateTime? t) {
  if (t == null) return '—';
  final l = t.toLocal();
  final m = l.month.toString().padLeft(2, '0');
  final d = l.day.toString().padLeft(2, '0');
  final h = l.hour.toString().padLeft(2, '0');
  final min = l.minute.toString().padLeft(2, '0');
  return '${l.year}-$m-$d $h:$min';
}

// ─── Dashboard ──────────────────────────────────────────────────────────────

class AdminPayoutDashboard extends StatefulWidget {
  const AdminPayoutDashboard({super.key});

  @override
  State<AdminPayoutDashboard> createState() => _AdminPayoutDashboardState();
}

enum _LoadState { loading, denied, error, ready }

class _AdminPayoutDashboardState extends State<AdminPayoutDashboard> {
  _LoadState _state = _LoadState.loading;
  String _message = '';
  List<AdminPayoutCycle> _cycles = [];
  Map<String, String> _bankNames = {};
  String? _selectedWeekId;
  String _filter = 'Needs approval';
  bool _refreshing = false;
  bool _exporting = false;
  bool _scoring = false;

  static const _filters = <String>[
    'Needs approval',
    'All',
    'Approved',
    'Paid',
    'Attention',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  AdminPayoutCycle? get _selected {
    if (_cycles.isEmpty) return null;
    return _cycles.where((c) => c.weekId == _selectedWeekId).firstOrNull ??
        _cycles.first;
  }

  Future<void> _load() async {
    setState(() {
      _state = _LoadState.loading;
      _message = '';
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _state = _LoadState.denied;
          _message = 'Sign in with the admin account to open this dashboard.';
        });
      }
      return;
    }
    // UX gate only — every callable below re-checks admin server-side.
    if (!isAdminUid(user.uid)) {
      if (mounted) {
        setState(() {
          _state = _LoadState.denied;
          _message =
              'This account is not authorized for payout administration.';
        });
      }
      return;
    }

    try {
      final results = await Future.wait([
        AdminPayoutService.instance.listPayoutClaims(),
        AdminPayoutService.instance.bankCodeToName(),
      ]);
      if (!mounted) return;
      final cycles = results[0] as List<AdminPayoutCycle>;
      setState(() {
        _cycles = cycles;
        _bankNames = results[1] as Map<String, String>;
        _selectedWeekId ??= cycles.isNotEmpty ? cycles.first.weekId : null;
        _state = _LoadState.ready;
      });
    } on AdminPayoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = e.code == 'permission-denied'
            ? _LoadState.denied
            : _LoadState.error;
        _message = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.error;
        _message = 'Could not load payout data. Check your connection.';
      });
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final results = await Future.wait([
        AdminPayoutService.instance
            .listPayoutClaims(weekId: _selectedWeekId),
        AdminPayoutService.instance.bankCodeToName(),
      ]);
      if (!mounted) return;
      final fresh = results[0] as List<AdminPayoutCycle>;
      setState(() {
        _bankNames = results[1] as Map<String, String>;
        // Merge fresh cycle(s) into the cached list without fabricating any.
        for (final f in fresh) {
          final i = _cycles.indexWhere((c) => c.weekId == f.weekId);
          if (i >= 0) {
            _cycles[i] = f;
          } else {
            _cycles.add(f);
          }
        }
        _cycles.sort((a, b) => b.weekId.compareTo(a.weekId));
      });
    } on AdminPayoutException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Refresh failed. Check your connection.');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Runs server-side fraud scoring for the selected week, then reloads so
  /// the fresh advisory scores render inline. Approval is never gated on
  /// this — scores are display-only.
  Future<void> _scoreFraud() async {
    if (_scoring) return;
    final week = _selectedWeekId;
    if (week == null) return;
    setState(() => _scoring = true);
    try {
      final result =
          await AdminPayoutService.instance.scoreFraudForWeek(weekId: week);
      if (!mounted) return;
      _snack('Fraud scoring complete: ${result.scored} account(s) scored. '
          'Scores are advisory — review before approving.');
      await _refresh();
    } on AdminPayoutException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Fraud scoring failed. Check your connection.');
    } finally {
      if (mounted) setState(() => _scoring = false);
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    final week = _selectedWeekId;
    if (week == null) return;
    setState(() => _exporting = true);
    try {
      // Existing exportPayoutLog callable, unchanged — scoped to the cycle.
      final result = await AdminPayoutService.instance.exportPayoutLog(
        fromWeekId: week,
        toWeekId: week,
      );
      if (!mounted) return;
      if (result.csv.isEmpty) {
        _snack('No payout rows for week $week yet.');
        return;
      }
      _snack('Export ready — ${result.rowCount} row(s) for week $week.');
      await Share.share(
        result.csv,
        subject: 'Payout audit log — week $week',
      );
    } on AdminPayoutException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Export failed. Check your connection.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  String _bankDisplay(String? code) {
    if (code == null || code.isEmpty) return '—';
    return _bankNames[code] ?? code;
  }

  List<AdminClaimInfo> _visibleClaims(AdminPayoutCycle cycle) {
    final claims = cycle.claims;
    switch (_filter) {
      case 'Needs approval':
        return claims.where((c) => c.needsApproval).toList();
      case 'Approved':
        return claims
            .where((c) =>
                c.queueState == AdminQueueState.approvedAwaiting)
            .toList();
      case 'Paid':
        return claims
            .where((c) => c.queueState == AdminQueueState.paid)
            .toList();
      case 'Attention':
        return claims
            .where((c) =>
                c.queueState == AdminQueueState.failed ||
                c.queueState == AdminQueueState.reservedNeedsReview ||
                c.queueState == AdminQueueState.expired)
            .toList();
      case 'All':
      default:
        return claims;
    }
  }

  Future<void> _openReview(AdminClaimInfo claim) async {
    final cycle = _selected;
    if (cycle == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReviewDialog(
        weekId: cycle.weekId,
        claim: claim,
        bankDisplay: _bankDisplay(claim.bankCode),
        onApproved: _refresh,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text(
          'Payout admin',
          style: TextStyle(
            fontSize: 17.sp,
            fontWeight: FontWeight.w900,
            fontFamily: 'Nunito',
          ),
        ),
        actions: [
          if (_state == _LoadState.ready)
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refreshing ? null : _refresh,
              icon: _refreshing
                  ? SizedBox(
                      width: 18.r,
                      height: 18.r,
                      child: const CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          if (_state == _LoadState.ready)
            IconButton(
              tooltip: 'Run fraud scoring (advisory)',
              onPressed: _scoring ? null : _scoreFraud,
              icon: _scoring
                  ? SizedBox(
                      width: 18.r,
                      height: 18.r,
                      child: const CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.shield_outlined),
            ),
          if (_state == _LoadState.ready)
            IconButton(
              tooltip: 'Export payout log (CSV)',
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? SizedBox(
                      width: 18.r,
                      height: 18.r,
                      child: const CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.download_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: switch (_state) {
          _LoadState.loading => const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          _LoadState.denied => _DeniedView(
              message: _message,
              onRetry: _load,
            ),
          _LoadState.error => _ErrorView(message: _message, onRetry: _load),
          _LoadState.ready => _readyBody(),
        },
      ),
    );
  }

  Widget _readyBody() {
    final cycle = _selected;
    if (cycle == null || _cycles.isEmpty) {
      return _ErrorView(
        message: 'No leaderboard cycles exist yet.',
        onRetry: _load,
      );
    }
    final visible = _visibleClaims(cycle);
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _refresh,
      child: ListView(
        padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
        children: [
          _CycleSelector(
            cycles: _cycles,
            selectedWeekId: cycle.weekId,
            onSelect: (w) => setState(() => _selectedWeekId = w),
          ),
          SizedBox(height: 12.h),
          _CycleSummaryCard(cycle: cycle),
          SizedBox(height: 14.h),
          _FilterRow(
            filters: _filters,
            active: _filter,
            cycle: cycle,
            onSelect: (f) => setState(() => _filter = f),
          ),
          SizedBox(height: 10.h),
          if (visible.isEmpty)
            _EmptyQueue(filter: _filter)
          else
            for (final claim in visible) ...[
              _ClaimCard(
                claim: claim,
                bankDisplay: _bankDisplay(claim.bankCode),
                onTap: () => _openReview(claim),
              ),
              SizedBox(height: 10.h),
            ],
        ],
      ),
    );
  }
}

// ─── Cycle selector ─────────────────────────────────────────────────────────

class _CycleSelector extends StatelessWidget {
  final List<AdminPayoutCycle> cycles;
  final String selectedWeekId;
  final ValueChanged<String> onSelect;

  const _CycleSelector({
    required this.cycles,
    required this.selectedWeekId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44.h,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cycles.length,
        separatorBuilder: (_, __) => SizedBox(width: 8.w),
        itemBuilder: (context, i) {
          final c = cycles[i];
          final active = c.weekId == selectedWeekId;
          return GestureDetector(
            onTap: () => onSelect(c.weekId),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 8.r),
              decoration: BoxDecoration(
                color: active
                    ? AppColors.primary.withValues(alpha: 0.14)
                    : AppColors.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: active
                      ? AppColors.primary.withValues(alpha: 0.5)
                      : AppColors.divider,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    c.weekId,
                    style: TextStyle(
                      color: active
                          ? AppColors.primary
                          : AppColors.textSecondary,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (c.pendingCount > 0) ...[
                    SizedBox(width: 7.w),
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: 7.r, vertical: 2.r),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(10.r),
                      ),
                      child: Text(
                        '${c.pendingCount}',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 11.sp,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Cycle summary ──────────────────────────────────────────────────────────

class _CycleSummaryCard extends StatelessWidget {
  final AdminPayoutCycle cycle;
  const _CycleSummaryCard({required this.cycle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Week of ${cycle.weekId}',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _CycleStatusChip(status: cycle.status),
            ],
          ),
          SizedBox(height: 4.h),
          Text(
            'Prize pool ${formatNaira(cycle.prizePool)}',
            style: TextStyle(
              color: AppColors.correct,
              fontSize: 20.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
            ),
          ),
          SizedBox(height: 12.h),
          _StatGrid(cycle: cycle),
          if (cycle.notes.isNotEmpty) ...[
            SizedBox(height: 10.h),
            Text(
              cycle.notes,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11.sp,
                fontStyle: FontStyle.italic,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CycleStatusChip extends StatelessWidget {
  final String? status;
  const _CycleStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final s = (status ?? 'unknown').toLowerCase();
    final color = s == 'paid' ? AppColors.correct : AppColors.secondary;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        s.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 10.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  final AdminPayoutCycle cycle;
  const _StatGrid({required this.cycle});

  @override
  Widget build(BuildContext context) {
    final stats = <(String, String)>[
      ('Revenue', formatNaira(cycle.totalCodeRevenue)),
      ('House cut', formatNaira(cycle.houseCut)),
      ('Floor', formatNaira(cycle.guaranteedFloor)),
      ('Winners', '${cycle.eligibleCount}'),
      ('Submitted', '${cycle.claimsSubmitted}'),
      ('Approved', '${cycle.claimsApproved}'),
      ('Paid', '${cycle.paidCount}'),
      ('Pending', '${cycle.pendingCount}'),
    ];
    return Wrap(
      spacing: 8.r,
      runSpacing: 8.r,
      children: [
        for (final s in stats)
          Container(
            padding:
                EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(9.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 11.sp,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w700,
                ),
                children: [
                  TextSpan(text: '${s.$1} '),
                  TextSpan(
                    text: s.$2,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Filter row ─────────────────────────────────────────────────────────────

class _FilterRow extends StatelessWidget {
  final List<String> filters;
  final String active;
  final AdminPayoutCycle cycle;
  final ValueChanged<String> onSelect;

  const _FilterRow({
    required this.filters,
    required this.active,
    required this.cycle,
    required this.onSelect,
  });

  int _countFor(String f) {
    switch (f) {
      case 'Needs approval':
        return cycle.pendingCount;
      case 'Approved':
        return cycle.claims
            .where((c) =>
                c.queueState == AdminQueueState.approvedAwaiting)
            .length;
      case 'Paid':
        return cycle.paidCount;
      case 'Attention':
        return cycle.failedCount +
            cycle.claims
                .where((c) =>
                    c.queueState == AdminQueueState.expired)
                .length;
      case 'All':
      default:
        return cycle.claims.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8.r,
      runSpacing: 8.r,
      children: [
        for (final f in filters)
          GestureDetector(
            onTap: () => onSelect(f),
            child: Container(
              padding:
                  EdgeInsets.symmetric(horizontal: 12.r, vertical: 7.r),
              decoration: BoxDecoration(
                color: f == active
                    ? AppColors.primary.withValues(alpha: 0.14)
                    : AppColors.surface,
                borderRadius: BorderRadius.circular(20.r),
                border: Border.all(
                  color: f == active
                      ? AppColors.primary.withValues(alpha: 0.5)
                      : AppColors.divider,
                ),
              ),
              child: Text(
                '$f · ${_countFor(f)}',
                style: TextStyle(
                  color: f == active
                      ? AppColors.primary
                      : AppColors.textSecondary,
                  fontSize: 11.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Claim card ─────────────────────────────────────────────────────────────

class _ClaimCard extends StatelessWidget {
  final AdminClaimInfo claim;
  final String bankDisplay;
  final VoidCallback onTap;

  const _ClaimCard({
    required this.claim,
    required this.bankDisplay,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final state = claim.queueState;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.all(14.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(
            color: state == AdminQueueState.pending
                ? AppColors.accent.withValues(alpha: 0.45)
                : AppColors.divider,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38.r,
                  height: 38.r,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10.r),
                  ),
                  child: Text(
                    '#${claim.rank}',
                    style: TextStyle(
                      color: AppColors.gold,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        claim.username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        'uid ${_shortUid(claim.uid)}',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  formatNaira(claim.share),
                  style: TextStyle(
                    color: AppColors.correct,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            SizedBox(height: 10.h),
            Wrap(
              spacing: 7.r,
              runSpacing: 7.r,
              children: [
                _StateChip(state: state),
                _ResolutionChip(match: claim.resolvedNameMatch),
                _FraudChip(claim: claim),
              ],
            ),
            SizedBox(height: 10.h),
            _ClaimLine(
              icon: Icons.account_balance_rounded,
              text:
                  '$bankDisplay · ${claim.maskedAccount ?? '—'}',
            ),
            SizedBox(height: 4.h),
            _ClaimLine(
              icon: Icons.person_outline_rounded,
              text: claim.beneficiaryName ?? '—',
            ),
            if (claim.submittedAt != null) ...[
              SizedBox(height: 4.h),
              _ClaimLine(
                icon: Icons.schedule_rounded,
                text: 'Claimed ${_formatTime(claim.submittedAt)}',
              ),
            ],
            // ── Phase 3 fraud advisory (display-only, never gates approval)
            if (claim.fraudReasons.isNotEmpty) ...[
              SizedBox(height: 8.h),
              Text(
                'Fraud signals (advisory, scored${claim.fraudScoredAt != null ? ' ${_formatTime(claim.fraudScoredAt)}' : ''}):',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11.sp,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 4.h),
              for (final reason in claim.fraudReasons)
                Padding(
                  padding: EdgeInsets.only(bottom: 4.h),
                  child: _ClaimLine(
                    icon: Icons.flag_outlined,
                    text: reason,
                  ),
                ),
            ],
            if (state == AdminQueueState.failed &&
                (claim.failedReason ?? '').isNotEmpty) ...[
              SizedBox(height: 4.h),
              _ClaimLine(
                icon: Icons.warning_amber_rounded,
                text: 'Failed: ${claim.failedReason}',
                color: AppColors.wrong,
              ),
            ],
            if (state == AdminQueueState.reservedNeedsReview) ...[
              SizedBox(height: 4.h),
              const _ClaimLine(
                icon: Icons.help_outline_rounded,
                text:
                    'Reserved with unknown outcome — reconcile on the Flutterwave dashboard before any retry.',
                color: AppColors.accent,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ClaimLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const _ClaimLine({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondary;
    return Row(
      children: [
        Icon(icon, color: AppColors.textMuted, size: 14.r),
        SizedBox(width: 7.w),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c,
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _StateChip extends StatelessWidget {
  final AdminQueueState state;
  const _StateChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      AdminQueueState.pending => ('AWAITING APPROVAL', AppColors.accent),
      AdminQueueState.approvedAwaiting =>
        ('TRANSFER SUBMITTED', AppColors.secondary),
      AdminQueueState.paid => ('PAID', AppColors.correct),
      AdminQueueState.failed => ('FAILED', AppColors.wrong),
      AdminQueueState.expired => ('EXPIRED', AppColors.textMuted),
      AdminQueueState.reservedNeedsReview =>
        ('NEEDS RECONCILIATION', AppColors.accent),
      AdminQueueState.notSubmitted => ('NO CLAIM', AppColors.textMuted),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Phase 3 fraud advisory chip — display-only. Renders the server-computed
/// suspicion band + score next to each payout-eligible player. Unscored
/// (scoreFraudForWeek not yet run) shows a muted placeholder. Never gates
/// approval; the approve path does not read this widget.
class _FraudChip extends StatelessWidget {
  final AdminClaimInfo claim;
  const _FraudChip({required this.claim});

  @override
  Widget build(BuildContext context) {
    final label = claim.fraudBandLabel;
    if (label == null || claim.fraudScore == null) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
        decoration: BoxDecoration(
          color: AppColors.textMuted.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
              color: AppColors.textMuted.withValues(alpha: 0.30)),
        ),
        child: Text(
          'RISK: NOT SCORED',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      );
    }
    final color = switch (claim.fraudBand) {
      'high' => AppColors.wrong,
      'moderate' => AppColors.accent,
      _ => AppColors.correct,
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Text(
        '$label · ${claim.fraudScore}',
        style: TextStyle(
          color: color,
          fontSize: 10.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ResolutionChip extends StatelessWidget {  final bool? match;
  const _ResolutionChip({required this.match});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (match) {
      true => ('NAME MATCH', AppColors.correct),
      false => ('REVIEW REQUIRED', AppColors.accent),
      null => ('RESOLUTION UNAVAILABLE', AppColors.textMuted),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─── Review dialog ──────────────────────────────────────────────────────────

class _ReviewDialog extends StatefulWidget {
  final String weekId;
  final AdminClaimInfo claim;
  final String bankDisplay;
  final VoidCallback onApproved;

  const _ReviewDialog({
    required this.weekId,
    required this.claim,
    required this.bankDisplay,
    required this.onApproved,
  });

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  // Guards the Approve button: while true no second call can be issued
  // (button disabled + early return). Never auto-retries on failure.
  bool _approving = false;
  String? _outcome;
  bool _outcomeOk = false;

  String get _resolutionText => switch (widget.claim.resolvedNameMatch) {
        true => 'MATCH',
        false => 'REVIEW REQUIRED',
        null => 'UNAVAILABLE',
      };

  Future<void> _approve() async {
    // Double-tap / double-fire guard.
    if (_approving) return;
    setState(() {
      _approving = true;
      _outcome = null;
    });
    try {
      // The ONLY money-movement call in the entire dashboard.
      final result = await AdminPayoutService.instance.approvePayout(
        weekId: widget.weekId,
        uid: widget.claim.uid,
      );
      if (!mounted) return;
      setState(() {
        _outcomeOk = result.ok;
        _outcome = result.duplicate
            ? 'Already handled: ${result.message} Refresh to see the current state.'
            : result.ok
                ? 'Transfer submitted / awaiting Flutterwave confirmation. '
                    'This winner will show Paid only after the backend confirms completion.'
                : result.message;
      });
      if (result.ok) widget.onApproved();
    } on AdminPayoutException catch (e) {
      // Backend rejections (already submitted / reserved / expired / not
      // authorized / ...) surface here. No automatic retry — ever.
      if (!mounted) return;
      setState(() {
        _outcomeOk = false;
        _outcome = '${e.message} Nothing was retried automatically.';
      });
      widget.onApproved();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _outcomeOk = false;
        _outcome =
            'Network error. The backend state is unknown — refresh and verify before trying again.';
      });
    } finally {
      if (mounted) setState(() => _approving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final claim = widget.claim;
    final canApprove = claim.needsApproval && !_approving;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18.r),
      ),
      title: Text(
        'Review payout',
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 17.sp,
          fontWeight: FontWeight.w900,
          fontFamily: 'Nunito',
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: EdgeInsets.all(12.r),
              decoration: BoxDecoration(
                color: AppColors.wrong.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: AppColors.wrong.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: AppColors.wrong, size: 18.r),
                  SizedBox(width: 9.w),
                  Expanded(
                    child: Text(
                      claim.needsApproval
                          ? "You're about to submit a real payout. Approval submits a real Flutterwave transfer."
                          : 'This claim is not awaiting approval. Details below are read-only.',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w800,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 12.h),
            _ReviewRow(label: 'Week', value: widget.weekId),
            _ReviewRow(label: 'Rank', value: '#${claim.rank}'),
            _ReviewRow(
              label: 'Prize',
              value: formatNaira(claim.share),
              highlight: true,
            ),
            _ReviewRow(label: 'Winner', value: claim.username),
            _ReviewRow(label: 'Bank', value: widget.bankDisplay),
            _ReviewRow(
              label: 'Account',
              value: claim.maskedAccount ?? '—',
            ),
            _ReviewRow(
              label: 'Beneficiary',
              value: claim.beneficiaryName ?? '—',
            ),
            _ReviewRow(label: 'Resolution', value: _resolutionText),
            _ReviewRow(
              label: 'Claim',
              value: (claim.claimStatus ?? 'none').toUpperCase(),
            ),
            if ((claim.failedReason ?? '').isNotEmpty)
              _ReviewRow(label: 'Failed', value: claim.failedReason!),
            if (_outcome != null) ...[
              SizedBox(height: 10.h),
              Container(
                padding: EdgeInsets.all(11.r),
                decoration: BoxDecoration(
                  color: (_outcomeOk ? AppColors.secondary : AppColors.accent)
                      .withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10.r),
                  border: Border.all(
                    color: (_outcomeOk
                            ? AppColors.secondary
                            : AppColors.accent)
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  _outcome!,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.sp,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _approving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (claim.needsApproval)
          AppButton(
            // Button amount comes from the actual claim data — the admin
            // can never type an arbitrary transfer amount.
            label: _approving
                ? 'Submitting…'
                : 'Approve ${formatNaira(claim.share)}',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.small,
            loading: _approving,
            onPressed: canApprove ? _approve : null,
          ),
      ],
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _ReviewRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92.w,
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11.sp,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: highlight
                    ? AppColors.correct
                    : AppColors.textPrimary,
                fontSize: 13.sp,
                fontWeight:
                    highlight ? FontWeight.w900 : FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Misc states ────────────────────────────────────────────────────────────

class _DeniedView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _DeniedView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72.r,
              height: 72.r,
              decoration: BoxDecoration(
                color: AppColors.wrong.withValues(alpha: 0.10),
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.wrong.withValues(alpha: 0.30),
                ),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.lock_outline_rounded,
                  color: AppColors.wrong, size: 30.r),
            ),
            SizedBox(height: 16.h),
            Text(
              'Not authorized',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6.h),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13.sp,
                height: 1.5,
              ),
            ),
            SizedBox(height: 16.h),
            AppButton(
              label: 'Retry',
              variant: AppButtonVariant.outline,
              size: AppButtonSize.small,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                color: AppColors.textMuted, size: 40.r),
            SizedBox(height: 12.h),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13.sp,
                height: 1.5,
              ),
            ),
            SizedBox(height: 16.h),
            AppButton(
              label: 'Retry',
              variant: AppButtonVariant.outline,
              size: AppButtonSize.small,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  final String filter;
  const _EmptyQueue({required this.filter});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 36.h, horizontal: 20.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined,
              color: AppColors.textMuted, size: 32.r),
          SizedBox(height: 10.h),
          Text(
            filter == 'Needs approval'
                ? 'Nothing awaiting approval.'
                : 'No payouts in this view.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Admin-only entry point ─────────────────────────────────────────────────
// Renders nothing for non-admin users. Mount this anywhere in the normal UI;
// the dashboard itself re-checks authorization and every callable enforces
// the server-side admin gate.

class AdminPayoutEntry extends StatelessWidget {
  const AdminPayoutEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!isAdminUid(snapshot.data?.uid)) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(20.r, 10.r, 20.r, 0.r),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminPayoutDashboard(),
              ),
            ),
            child: Container(
              padding: EdgeInsets.all(14.r),
              decoration: BoxDecoration(
                color: AppColors.wrong.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(14.r),
                border: Border.all(
                  color: AppColors.wrong.withValues(alpha: 0.30),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38.r,
                    height: 38.r,
                    decoration: BoxDecoration(
                      color:
                          AppColors.wrong.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10.r),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.admin_panel_settings_outlined,
                      color: AppColors.wrong,
                      size: 20.r,
                    ),
                  ),
                  SizedBox(width: 12.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Payout admin',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          'Review & approve winner payouts',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11.sp,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Copies [text] to the clipboard (export fallback / debugging aid only —
/// never used for account numbers, which are masked server-side).
Future<void> copyAdminText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
