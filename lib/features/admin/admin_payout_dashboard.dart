// lib/features/admin/admin_payout_dashboard.dart
//
// Admin Payout Dashboard — manual payment of weekly leaderboard prizes.
//
// PAYOUTS ARE MANUAL. The app never moves money. The admin transfers from
// their own bank app using the details shown here, then taps "Mark as paid"
// to record it. This page's entire job is: who needs paying, what are their
// exact bank details, and tick them off.
//
// The only state-changing call is `markLeaderboardPayout`, which sends just
// {weekId, uid, paid} — never an amount. The backend derives the amount from
// ranked[].share.
//
// Account numbers are shown UNMASKED here because the admin has to type them
// into a banking app. This is the one meaningful widening of exposure versus
// a masked feed, so it must never happen outside the admin-gated callable.
//
// Paid is displayed ONLY when the backend says ranked[].paid == true.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_back_button.dart';
import 'admin_console_page.dart';
import 'admin_payout_service.dart';
import 'widgets/admin_shared.dart';

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
  /// When true, renders only the tab body (no Scaffold/AppBar) so the admin
  /// console can host it under its own navigation.
  final bool embedded;
  const AdminPayoutDashboard({super.key, this.embedded = false});

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
  String _filter = 'Awaiting payment';
  bool _refreshing = false;
  bool _exporting = false;
  bool _scoring = false;

  /// Live prize-pool state for the CURRENT week (independent of which cycle
  /// is selected in the list below — a pool can only be set for the live week).
  PrizePoolStatus? _pool;
  bool _poolSaving = false;
  bool _poolLoading = true;

  static const _filters = <String>[
    'Awaiting payment',
    'Paid',
    'Expired',
    'All',
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
      // Pool state is independent of the cycle list and must not fail the
      // whole dashboard — a non-admin already returned above.
      await _loadPool();
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

  /// Loads the live prize-pool card. Failures degrade to a retry banner rather
  /// than blocking the payout queue, which is the part that must always work.
  Future<void> _loadPool() async {
    try {
      final pool = await AdminPayoutService.instance.getPrizePoolStatus();
      if (!mounted) return;
      setState(() {
        _pool = pool;
        _poolLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _poolLoading = false);
    }
  }

  Future<void> _savePool(int amount) async {
    if (_poolSaving) return;
    setState(() => _poolSaving = true);
    try {
      final pool = await AdminPayoutService.instance.setPrizePool(amount);
      if (!mounted) return;
      setState(() => _pool = pool);
      _snack('Prize pool for ${pool.weekId} fixed at '
          '${adminNaira(amount.toDouble())}.');
    } on AdminPayoutException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Could not set the pool. Check your connection.');
    } finally {
      if (mounted) setState(() => _poolSaving = false);
    }
  }

  Future<void> _clearPool() async {
    if (_poolSaving) return;
    setState(() => _poolSaving = true);
    try {
      final pool = await AdminPayoutService.instance.clearPrizePool();
      if (!mounted) return;
      setState(() => _pool = pool);
      _snack('Fixed amount removed. Pool is now unset.');
    } on AdminPayoutException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Could not revert the pool.');
    } finally {
      if (mounted) setState(() => _poolSaving = false);
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await _loadPool();
    try {
      final results = await Future.wait([
        AdminPayoutService.instance.listPayoutClaims(weekId: _selectedWeekId),
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
  /// the fresh advisory scores render inline. Marking paid is never gated on
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
          'Scores are advisory — check them before sending money.');
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
      // Bookkeeping CSV scoped to the cycle. Contains no account numbers.
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
      case 'Awaiting payment':
        return claims.where((c) => c.needsPayment).toList();
      case 'Paid':
        return claims
            .where((c) => c.queueState == AdminQueueState.paid)
            .toList();
      case 'Expired':
        return claims
            .where((c) => c.queueState == AdminQueueState.expired)
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
      builder: (_) => _PaymentDialog(
        weekId: cycle.weekId,
        claim: claim,
        bankDisplay: _bankDisplay(claim.bankCode),
        onChanged: _refresh,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = switch (_state) {
      _LoadState.loading => const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      _LoadState.denied => _DeniedView(
          message: _message,
          onRetry: _load,
        ),
      _LoadState.error => _ErrorView(message: _message, onRetry: _load),
      _LoadState.ready => _readyBody(),
    };
    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: const AppBackButton(),
        title: Text(
          'Payout admin',
          style: TextStyle(
            fontSize: 17.sp,
            fontWeight: FontWeight.w900,
            fontFamily: 'Nunito',
          ),
        ),
        actions: [
          // Always available (even if the cycle list failed): the referral
          // cashout queue is independent of weekly leaderboard cycles.
          // Standalone entry now routes into the unified console.
          IconButton(
            tooltip: 'Open admin console · referrals',
            onPressed: () => AdminConsolePage.open(context, tab: 2),
            icon: const Icon(Icons.savings_outlined),
          ),
          IconButton(
            tooltip: 'Open admin console · house',
            onPressed: () => AdminConsolePage.open(context, tab: 3),
            icon: const Icon(Icons.shield_outlined),
          ),
          if (_state == _LoadState.ready)
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refreshing ? null : _refresh,
              icon: _refreshing
                  ? SizedBox(
                      width: 18.r,
                      height: 18.r,
                      child: CircularProgressIndicator(
                        color: AppColors.readable(AppColors.primary),
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
                      child: CircularProgressIndicator(
                        color: AppColors.readable(AppColors.primary),
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
                      child: CircularProgressIndicator(
                        color: AppColors.readable(AppColors.primary),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.download_rounded),
            ),
        ],
      ),
      body: SafeArea(child: content),
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
      color: AppColors.readable(AppColors.primary),
      onRefresh: _refresh,
      child: ListView(
        padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
        children: [
          _PrizePoolCard(
            pool: _pool,
            loading: _poolLoading,
            saving: _poolSaving,
            onSave: _savePool,
            onClear: _clearPool,
          ),
          SizedBox(height: 12.h),
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

// ─── Prize pool card ─────────────────────────────────────────────────────────
//
// Sets the CURRENT week's prize pool to one fixed naira amount. The amount
// is the pool for the week — one number you control, not a total you have to
// predict.
//
// Only the current week is editable. Once weeklyReset has snapshotted the
// cycle, winners' shares are already derived from the pool, so the server
// refuses further changes. The card says so instead of silently failing.
class _PrizePoolCard extends StatefulWidget {
  final PrizePoolStatus? pool;
  final bool loading;
  final bool saving;
  final ValueChanged<int> onSave;
  final VoidCallback onClear;

  const _PrizePoolCard({
    required this.pool,
    required this.loading,
    required this.saving,
    required this.onSave,
    required this.onClear,
  });

  @override
  State<_PrizePoolCard> createState() => _PrizePoolCardState();
}

class _PrizePoolCardState extends State<_PrizePoolCard> {
  final _ctrl = TextEditingController();
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _syncFromServer();
  }

  @override
  void didUpdateWidget(covariant _PrizePoolCard old) {
    super.didUpdateWidget(old);
    // Reflect a server-side change, but never clobber what the admin is typing.
    if (!_dirty) _syncFromServer();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _syncFromServer() {
    final amount = widget.pool?.adminPoolNaira;
    final text = amount == null
        ? ''
        : (amount == amount.roundToDouble()
            ? amount.round().toString()
            : amount.toStringAsFixed(2));
    if (_ctrl.text != text) _ctrl.text = text;
  }

  Future<void> _confirmSave() async {
    final raw = _ctrl.text.trim().replaceAll(RegExp(r'[^0-9.]'), '');
    final value = double.tryParse(raw);
    if (value == null || value <= 0) {
      _snackPool('Enter an amount greater than zero.');
      return;
    }
    if (value != value.roundToDouble()) {
      _snackPool('Use whole naira — no kobo.');
      return;
    }
    final pool = widget.pool;
    if (pool != null && value > pool.maxPoolNaira.toDouble()) {
      _snackPool('That is above the '
          '${adminNaira(pool.maxPoolNaira.toDouble())} limit.');
      return;
    }

    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.r),
        ),
        title: Text(
          'Fix the pool at ${adminNaira(value)}?',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16.sp,
            fontWeight: FontWeight.w900,
          ),
        ),
        content: Text(
          'This sets the pool for week ${pool?.weekId ?? ''}.\n\n'
          'When the week closes, this is the amount the winning shares are '
          'calculated from, and it becomes a real payout obligation you pay by '
          'hand.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.sp,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Set pool',
              style: TextStyle(color: AppColors.readable(AppColors.primary)),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    widget.onSave(value.round());
    if (mounted) setState(() => _dirty = false);
  }

  Future<void> _confirmClear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.r),
        ),
        title: Text(
          'Remove fixed amount?',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16.sp,
            fontWeight: FontWeight.w900,
          ),
        ),
        content: Text(
          'The fixed amount is removed. This week has no pool until you set a new amount.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.sp,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Revert',
              style: TextStyle(color: AppColors.readable(AppColors.wrong)),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    widget.onClear();
    if (mounted) setState(() => _dirty = false);
  }

  void _snackPool(String m) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pool = widget.pool;

    if (widget.loading) {
      return Container(
        padding: EdgeInsets.all(18.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Center(
          child: SizedBox(
            width: 18.r,
            height: 18.r,
            child: CircularProgressIndicator(
              color: AppColors.readable(AppColors.primary),
              strokeWidth: 2,
            ),
          ),
        ),
      );
    }

    if (pool == null) {
      return Container(
        padding: EdgeInsets.all(14.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded,
                color: AppColors.textMuted, size: 18.r),
            SizedBox(width: 10.w),
            Expanded(
              child: Text(
                'Prize pool unavailable — pull to refresh.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(
          color: pool.isFixed
              ? AppColors.primary.withValues(alpha: 0.5)
              : AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Prize pool · week of ${pool.weekId}',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
                decoration: BoxDecoration(
                  color:
                      (pool.isFixed ? AppColors.primary : AppColors.textMuted)
                          .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(
                    color:
                        (pool.isFixed ? AppColors.primary : AppColors.textMuted)
                            .withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  pool.isFixed ? 'FIXED' : 'NOT SET',
                  style: TextStyle(
                    color:
                        pool.isFixed ? AppColors.primary : AppColors.textMuted,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10.h),
          Text(
            pool.isFixed ? adminNaira(pool.effectivePool) : 'No pool set',
            style: TextStyle(
              color: pool.isFixed
                  ? AppColors.readable(AppColors.correct)
                  : AppColors.textSecondary,
              fontSize: 26.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          Text(
            pool.isFixed
                ? 'Fixed by you for this week'
                : 'Set an amount below — nothing is funded automatically',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 12.h),
          if (pool.weekClosed)
            Container(
              padding: EdgeInsets.all(10.r),
              decoration: BoxDecoration(
                color: AppColors.textMuted.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(
                  color: AppColors.textMuted.withValues(alpha: 0.25),
                ),
              ),
              child: Text(
                'This week has closed. Its pool is fixed and the winners\' '
                'shares are already calculated.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.sp,
                  height: 1.45,
                ),
              ),
            )
          else ...[
            Text(
              'SET A FIXED AMOUNT (₦)',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.0,
              ),
            ),
            SizedBox(height: 6.h),
            TextField(
              controller: _ctrl,
              enabled: !widget.saving,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
              onChanged: (_) => setState(() => _dirty = true),
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16.sp,
                fontWeight: FontWeight.w900,
              ),
              decoration: InputDecoration(
                hintText: 'e.g. 10000',
                hintStyle: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 14.sp,
                  fontWeight: FontWeight.w700,
                ),
                filled: true,
                fillColor: AppColors.surfaceAlt,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(11.r),
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(11.r),
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(11.r),
                  borderSide:
                      const BorderSide(color: AppColors.primary, width: 1.5),
                ),
              ),
            ),
            SizedBox(height: 10.h),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: widget.saving ? 'Saving…' : 'Set pool',
                    variant: AppButtonVariant.primary,
                    size: AppButtonSize.small,
                    loading: widget.saving,
                    onPressed: widget.saving ? null : _confirmSave,
                  ),
                ),
                if (pool.isFixed) ...[
                  SizedBox(width: 10.w),
                  AppButton(
                    label: 'Revert',
                    variant: AppButtonVariant.outline,
                    size: AppButtonSize.small,
                    onPressed: widget.saving ? null : _confirmClear,
                  ),
                ],
              ],
            ),
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
                      color:
                          active ? AppColors.primary : AppColors.textSecondary,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (c.pendingCount > 0) ...[
                    SizedBox(width: 7.w),
                    Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 7.r, vertical: 2.r),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(10.r),
                      ),
                      child: Text(
                        '${c.pendingCount}',
                        style: TextStyle(
                          color: AppColors.readable(AppColors.accent),
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
            'Prize pool ${adminNaira(cycle.prizePool)}',
            style: TextStyle(
              color: AppColors.readable(AppColors.correct),
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
      ('Revenue', adminNaira(cycle.totalCodeRevenue)),
      ('Winners', '${cycle.eligibleCount}'),
      ('Submitted', '${cycle.claimsSubmitted}'),
      ('Paid', '${cycle.paidCount}'),
      ('Awaiting', '${cycle.pendingCount}'),
      ('To send', adminNaira(cycle.pendingAmount)),
    ];
    return Wrap(
      spacing: 8.r,
      runSpacing: 8.r,
      children: [
        for (final s in stats)
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 7.r),
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
                    style: TextStyle(
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
      case 'Awaiting payment':
        return cycle.pendingCount;
      case 'Paid':
        return cycle.paidCount;
      case 'Expired':
        return cycle.expiredCount;
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
              padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 7.r),
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
                  color:
                      f == active ? AppColors.primary : AppColors.textSecondary,
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
                      color: AppColors.readable(AppColors.gold),
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
                  adminNaira(claim.share),
                  style: TextStyle(
                    color: AppColors.readable(AppColors.correct),
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
                _FraudChip(claim: claim),
                _EnforcementChip(claim: claim),
              ],
            ),
            SizedBox(height: 10.h),
            _ClaimLine(
              icon: Icons.account_balance_rounded,
              text: '$bankDisplay · ${claim.accountNumber ?? '—'}',
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
            if (claim.markedAt != null) ...[
              SizedBox(height: 4.h),
              _ClaimLine(
                icon: Icons.check_circle_outline_rounded,
                text: 'Sent ${_formatTime(claim.markedAt)}'
                    '${(claim.payoutReference ?? '').isEmpty ? '' : ' · ref ${claim.payoutReference}'}',
                color: AppColors.readable(AppColors.correct),
              ),
            ],
            // ── Fraud advisory (display-only, never gates marking paid)
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
            // ── Enforcement hold (silent auto-ban ladder — review before paying)
            if (claim.hasEnforcementHold) ...[
              SizedBox(height: 8.h),
              _ClaimLine(
                icon: Icons.gavel_rounded,
                text:
                    '${claim.enforcementLabel}${claim.enforcementLevel != null ? ' · ${claim.enforcementLevel}' : ''} — check enforcement before sending money.',
                color: AppColors.readable(AppColors.wrong),
              ),
            ],
            if (claim.payoutAccountShared) ...[
              SizedBox(height: 4.h),
              _ClaimLine(
                icon: Icons.account_balance_wallet_outlined,
                text:
                    'Payout account reused${claim.payoutAccountUidCount != null ? ' across ${claim.payoutAccountUidCount} account(s)' : ''} — confirm the owner before sending.',
                color: AppColors.readable(AppColors.wrong),
              ),
            ],
            if (state == AdminQueueState.expired) ...[
              SizedBox(height: 4.h),
              _ClaimLine(
                icon: Icons.timer_off_outlined,
                text:
                    'Claim window closed — this prize was forfeited. Nothing to send.',
                color: AppColors.textMuted,
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
      AdminQueueState.pending => ('AWAITING PAYMENT', AppColors.accent),
      AdminQueueState.paid => ('PAID', AppColors.correct),
      AdminQueueState.expired => ('EXPIRED', AppColors.textMuted),
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

/// Fraud advisory chip — display-only. Renders the server-computed suspicion
/// band + score next to each winner. Unscored (scoreFraudForWeek not yet run)
/// shows a muted placeholder. Never gates marking paid.
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
          border:
              Border.all(color: AppColors.textMuted.withValues(alpha: 0.30)),
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

/// Enforcement chip — display-only. Renders the silent auto-ban ladder
/// state next to each winner. No hold shows a muted placeholder.
/// Never gates marking paid server-side; the admin must check before sending.
class _EnforcementChip extends StatelessWidget {
  final AdminClaimInfo claim;
  const _EnforcementChip({required this.claim});

  @override
  Widget build(BuildContext context) {
    final label = claim.enforcementLabel;
    if (label == null) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
        decoration: BoxDecoration(
          color: AppColors.textMuted.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8.r),
          border:
              Border.all(color: AppColors.textMuted.withValues(alpha: 0.30)),
        ),
        child: Text(
          'HOLD: NONE',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      );
    }
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: AppColors.wrong.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: AppColors.wrong.withValues(alpha: 0.30)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.wrong,
          fontSize: 10.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─── Payment dialog ─────────────────────────────────────────────────────────

class _PaymentDialog extends StatefulWidget {
  final String weekId;
  final AdminClaimInfo claim;
  final String bankDisplay;
  final VoidCallback onChanged;

  const _PaymentDialog({
    required this.weekId,
    required this.claim,
    required this.bankDisplay,
    required this.onChanged,
  });

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  // Guards both buttons: while true no second call can be issued (buttons
  // disabled + early return). Never auto-retries on failure.
  bool _busy = false;
  String? _outcome;
  bool _outcomeOk = false;

  final _referenceCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final existing = widget.claim.payoutReference;
    if (existing != null && existing.isNotEmpty) {
      _referenceCtrl.text = existing;
    }
  }

  @override
  void dispose() {
    _referenceCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmSent() async {
    // Double-tap / double-fire guard.
    if (_busy) return;

    // Explicit confirmation. "Paid" is a claim about what a human did that
    // the app cannot verify, and it also permanently protects the prize from
    // the 3-day expiry — so it must never be a single tap.
    final hold = widget.claim.hasEnforcementHold
        ? 'ENFORCEMENT ${widget.claim.enforcementLabel}'
            '${widget.claim.enforcementLevel != null ? ' (${widget.claim.enforcementLevel})' : ''}: check the ladder before sending — '
        : widget.claim.payoutAccountShared
            ? 'SHARED PAYOUT ACCOUNT${widget.claim.payoutAccountUidCount != null ? ' (${widget.claim.payoutAccountUidCount} accounts)' : ''}: confirm the owner before sending — '
            : '';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.r),
        ),
        title: Text(
          'Confirm you sent this',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16.sp,
            fontWeight: FontWeight.w900,
          ),
        ),
        content: Text(
          '${hold}Only continue if you have ALREADY transferred '
          '${adminNaira(widget.claim.share)} to ${widget.claim.beneficiaryName} '
          'at ${widget.bankDisplay}.\n\n'
          'This app cannot send or verify the money — it only records that you '
          'did. Marking paid is blocked once the 3-day claim window closes.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.sp,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              widget.claim.hasEnforcementHold ||
                      widget.claim.payoutAccountShared
                  ? 'Still record as sent'
                  : 'Yes, I sent it',
              style: TextStyle(color: AppColors.readable(AppColors.correct)),
            ),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;

    setState(() {
      _busy = true;
      _outcome = null;
    });
    try {
      final result = await AdminPayoutService.instance.markPaid(
        weekId: widget.weekId,
        uid: widget.claim.uid,
        payoutReference: _referenceCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _outcomeOk = result.ok;
        _outcome = result.ok
            ? (result.allPaid
                ? 'Recorded. Every winner in this week is now marked paid.'
                : 'Recorded as sent.')
            : result.message;
      });
      widget.onChanged();
    } on AdminPayoutException catch (e) {
      // Backend rejections (no claim / expired / share invalid / not
      // authorized / ...) surface here. No automatic retry — ever.
      if (!mounted) return;
      setState(() {
        _outcomeOk = false;
        _outcome = '${e.message} Nothing was retried automatically.';
      });
      widget.onChanged();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _outcomeOk = false;
        _outcome =
            'Network error. The backend state is unknown — refresh and verify before trying again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRevert() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.r),
        ),
        title: Text(
          'Undo the payment mark?',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16.sp,
            fontWeight: FontWeight.w900,
          ),
        ),
        content: Text(
          'This winner goes back into the payment queue. Only use it if you '
          'tapped Mark as paid by mistake — if you already sent the money, '
          'leave it marked.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.sp,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Undo',
              style: TextStyle(color: AppColors.readable(AppColors.wrong)),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _outcome = null;
    });
    try {
      final result = await AdminPayoutService.instance.markUnpaid(
        weekId: widget.weekId,
        uid: widget.claim.uid,
      );
      if (!mounted) return;
      setState(() {
        _outcomeOk = result.ok;
        _outcome = result.ok ? result.message : result.message;
      });
      widget.onChanged();
    } on AdminPayoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _outcomeOk = false;
        _outcome = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _outcomeOk = false;
        _outcome = 'Network error. Refresh and check the current state.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final claim = widget.claim;
    final canMark = claim.needsPayment && !_busy;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18.r),
      ),
      title: Text(
        'Pay this winner',
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
                color: AppColors.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: AppColors.accent.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: AppColors.readable(AppColors.accent), size: 18.r),
                  SizedBox(width: 9.w),
                  Expanded(
                    child: Text(
                      claim.needsPayment
                          ? 'Send this from your own bank app first. Then mark '
                              'it as paid so the winner sees it as settled.'
                          : 'This claim is not awaiting payment. Details below '
                              'are read-only.',
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
              value: adminNaira(claim.share),
              highlight: true,
            ),
            _ReviewRow(label: 'Winner', value: claim.username),
            _ReviewRow(label: 'Bank', value: widget.bankDisplay),
            _ReviewRow(
              label: 'Account',
              value: claim.accountNumber ?? '—',
            ),
            _ReviewRow(
              label: 'Beneficiary',
              value: claim.beneficiaryName ?? '—',
            ),
            _ReviewRow(
              label: 'Claim',
              value: (claim.claimStatus ?? 'none').toUpperCase(),
            ),
            _ReviewRow(
              label: 'Hold',
              value: claim.enforcementLabel ??
                  (claim.payoutAccountShared
                      ? 'SHARED ACCOUNT${claim.payoutAccountUidCount != null ? ' ×${claim.payoutAccountUidCount}' : ''}'
                      : 'NONE'),
              highlight: claim.hasEnforcementHold || claim.payoutAccountShared,
            ),
            if (claim.markedAt != null)
              _ReviewRow(
                label: 'Sent',
                value: _formatTime(claim.markedAt),
                highlight: true,
              ),
            if (claim.needsPayment) ...[
              SizedBox(height: 12.h),
              Text(
                'Your bank reference (optional)',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11.sp,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              SizedBox(height: 5.h),
              TextField(
                controller: _referenceCtrl,
                enabled: !_busy,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  hintText: 'e.g. NIP/2026-0917-00123',
                  hintStyle: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w600,
                  ),
                  filled: true,
                  fillColor: AppColors.surfaceAlt,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10.r),
                    borderSide: BorderSide(color: AppColors.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10.r),
                    borderSide: const BorderSide(color: AppColors.primary),
                  ),
                ),
              ),
            ],
            if (_outcome != null) ...[
              SizedBox(height: 10.h),
              Container(
                padding: EdgeInsets.all(11.r),
                decoration: BoxDecoration(
                  color: (_outcomeOk ? AppColors.secondary : AppColors.accent)
                      .withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10.r),
                  border: Border.all(
                    color: (_outcomeOk ? AppColors.secondary : AppColors.accent)
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
        if (claim.paid)
          TextButton(
            onPressed: _busy ? null : _confirmRevert,
            child: Text(
              'Undo',
              style: TextStyle(color: AppColors.readable(AppColors.wrong)),
            ),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (claim.needsPayment)
          AppButton(
            // The amount shown comes from server claim data — the admin can
            // never type an arbitrary transfer amount. The call sends no
            // amount at all.
            label: _busy
                ? 'Recording…'
                : 'Mark as paid ${adminNaira(claim.share)}',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.small,
            loading: _busy,
            onPressed: canMark ? _confirmSent : null,
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
                color: highlight ? AppColors.correct : AppColors.textPrimary,
                fontSize: 13.sp,
                fontWeight: highlight ? FontWeight.w900 : FontWeight.w700,
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
                  color: AppColors.readable(AppColors.wrong), size: 30.r),
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
          Icon(Icons.inbox_outlined, color: AppColors.textMuted, size: 32.r),
          SizedBox(height: 10.h),
          Text(
            filter == 'Awaiting payment'
                ? 'Nothing awaiting payment.'
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
            onTap: () => AdminConsolePage.open(context),
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
                      color: AppColors.wrong.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10.r),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.admin_panel_settings_outlined,
                      color: AppColors.readable(AppColors.wrong),
                      size: 20.r,
                    ),
                  ),
                  SizedBox(width: 12.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Admin console',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          'Payouts · referrals · house engine',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11.sp,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
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
        );
      },
    );
  }
}

/// Copies [text] to the clipboard (export fallback / debugging aid).
///
/// Never used for account numbers — copying one onto the system clipboard
/// would leave full bank details readable by any other app.
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
