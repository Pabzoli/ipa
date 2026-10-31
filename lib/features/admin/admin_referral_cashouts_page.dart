import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_form_field.dart';
import 'admin_payout_service.dart';
import 'widgets/admin_shared.dart';

/// Referral cashout queue — manual NGN 5,000 payouts.
///
/// Deliberately a separate screen from the weekly prize queue:
///   * its money lives in `referralCashoutReserve/ledger`, not the prize pool;
///   * a submitted claim is fully earmarked, so several claimants at once never
///     reduce what a leaderboard winner is owed;
///   * "Top up budget" is the only way to add money, and it only moves the
///     cashout ledger.
///
/// Every callable is ADMIN_UIDS-gated server-side. [isAdminUid] here is a UX
/// gate only.
class AdminReferralCashoutsPage extends StatefulWidget {
  /// When true, renders only the tab body (no Scaffold/AppBar) so the admin
  /// console can host it under its own navigation.
  final bool embedded;
  const AdminReferralCashoutsPage({super.key, this.embedded = false});

  @override
  State<AdminReferralCashoutsPage> createState() =>
      _AdminReferralCashoutsPageState();
}

enum _LoadState { loading, denied, error, ready }

class _AdminReferralCashoutsPageState extends State<AdminReferralCashoutsPage> {
  _LoadState _state = _LoadState.loading;
  String _message = '';
  AdminReferralCashoutSnapshot? _snapshot;
  String _filter = 'Pending';
  bool _refreshing = false;

  static const _filters = ['Pending', 'Paid', 'Rejected', 'All'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _state = _LoadState.loading;
      _message = '';
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.denied;
        _message = 'Sign in with the admin account to open this queue.';
      });
      return;
    }
    if (!isAdminUid(user.uid)) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.denied;
        _message = 'This account is not authorized for payout administration.';
      });
      return;
    }

    try {
      final snapshot = await AdminPayoutService.instance.listReferralCashouts();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
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
        _message = 'Could not load referral cashouts. Check your connection.';
      });
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await _load();
    if (mounted) setState(() => _refreshing = false);
  }

  List<AdminReferralCashoutClaim> _visible() {
    final all = _snapshot?.claims ?? const <AdminReferralCashoutClaim>[];
    return switch (_filter) {
      'Pending' => all.where((c) => c.isPending).toList(),
      'Paid' => all.where((c) => c.isPaid).toList(),
      'Rejected' => all.where((c) => c.isRejected).toList(),
      _ => all,
    };
  }

  Future<void> _topUp() async {
    final reserve =
        _snapshot?.reserve ?? const AdminReferralCashoutReserve.empty();
    final amount = await showAppDialog<int>(
      context,
      builder: (_) => _TopUpDialog(reserve: reserve),
    );
    if (amount == null || !mounted) return;

    try {
      await AdminPayoutService.instance.fundReferralCashoutReserve(amount);
      if (!mounted) return;
      _snack('${adminNaira(amount)} added to the cashout budget.');
      await _refresh();
    } on AdminPayoutException catch (e) {
      if (mounted) _snack(e.message);
    } catch (_) {
      if (mounted) _snack('Could not top up the budget.');
    }
  }

  Future<void> _openReview(AdminReferralCashoutClaim claim) async {
    final changed = await showAppDialog<bool>(
      context,
      barrierDismissible: false,
      builder: (_) => _ReviewDialog(claim: claim),
    );
    if (changed == true && mounted) await _refresh();
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = switch (_state) {
      _LoadState.loading => const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      _LoadState.denied => _CenteredMessage(
          icon: Icons.lock_outline_rounded,
          title: 'Not authorized',
          message: _message,
          onRetry: _load,
        ),
      _LoadState.error => _CenteredMessage(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load',
          message: _message,
          onRetry: _load,
        ),
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
          'Referral cashouts',
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
                      child: CircularProgressIndicator(
                        color: AppColors.readable(AppColors.primary),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: SafeArea(child: content),
    );
  }

  Widget _readyBody() {
    final snapshot = _snapshot;
    if (snapshot == null) return const SizedBox.shrink();
    final visible = _visible();

    return RefreshIndicator(
      color: AppColors.readable(AppColors.primary),
      onRefresh: _refresh,
      child: ListView(
        padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
        children: [
          _ReserveCard(reserve: snapshot.reserve, onTopUp: _topUp),
          SizedBox(height: 12.h),
          Row(
            children: [
              Text('Claims', style: AppTypography.labelLarge),
              const Spacer(),
              Text(
                '${snapshot.pending.length} pending · '
                '${adminNaira(snapshot.pendingAmount)}',
                style: AppTypography.bodySmall,
              ),
            ],
          ),
          SizedBox(height: 8.h),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in _filters)
                _FilterPill(
                  label: f,
                  active: _filter == f,
                  onTap: () => setState(() => _filter = f),
                ),
            ],
          ),
          SizedBox(height: 10.h),
          if (visible.isEmpty)
            Padding(
              padding: EdgeInsets.only(top: 40.h),
              child: Column(
                children: [
                  Icon(
                    Icons.inbox_rounded,
                    color: AppColors.textMuted,
                    size: 40.r,
                  ),
                  SizedBox(height: 12.h),
                  Text(
                    _filter == 'Pending'
                        ? 'No cashout claims are waiting.'
                        : 'Nothing in this view.',
                    style: AppTypography.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          else
            for (final claim in visible) ...[
              _ClaimCard(claim: claim, onTap: () => _openReview(claim)),
              SizedBox(height: 10.h),
            ],
        ],
      ),
    );
  }
}

// ─── Budget card ────────────────────────────────────────────────────────────

class _ReserveCard extends StatelessWidget {
  final AdminReferralCashoutReserve reserve;
  final VoidCallback onTopUp;

  const _ReserveCard({required this.reserve, required this.onTopUp});

  @override
  Widget build(BuildContext context) {
    final shortfall = reserve.shortfall;
    return AppCard(
      accentColor: shortfall > 0 ? AppColors.wrong : AppColors.correct,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_rounded,
                color: AppColors.readable(AppColors.primary),
                size: 18.r,
              ),
              SizedBox(width: AppSpacing.sm),
              Text('Cashout budget', style: AppTypography.titleMedium),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(AppRadii.full),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Text(
                  'SEPARATE FROM PRIZE POOL',
                  style: AppTypography.labelSmall.copyWith(
                    color: AppColors.textMuted,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _MoneyTile(
                label: 'Available',
                value: adminNaira(reserve.available),
                color: reserve.available < 0
                    ? AppColors.readable(AppColors.wrong)
                    : AppColors.textPrimary,
              ),
              _MoneyTile(
                label: 'Earmarked',
                value: adminNaira(reserve.encumbered),
                color: AppColors.readable(AppColors.amber),
              ),
              _MoneyTile(
                label: 'Paid',
                value: adminNaira(reserve.paidTotal),
                color: AppColors.readable(AppColors.correct),
              ),
            ],
          ),
          if (shortfall > 0) ...[
            SizedBox(height: AppSpacing.md),
            Container(
              padding: EdgeInsets.all(10.r),
              decoration: BoxDecoration(
                color: AppColors.wrong.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: AppColors.wrong.withValues(alpha: 0.30),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: AppColors.readable(AppColors.wrong),
                    size: 16.r,
                  ),
                  SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Top up ${adminNaira(shortfall)} so every earmarked claim is '
                      'covered. This never draws from the prize pool.',
                      style: AppTypography.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Top up budget',
            variant: AppButtonVariant.secondary,
            icon: Icon(Icons.add_rounded, size: 17.r),
            onPressed: onTopUp,
          ),
        ],
      ),
    );
  }
}

class _MoneyTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MoneyTile({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppTypography.titleMedium.copyWith(
                color: color,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(height: 2.h),
          Text(label, style: AppTypography.bodySmall),
        ],
      ),
    );
  }
}

// ─── Claim card ─────────────────────────────────────────────────────────────

class _ClaimCard extends StatelessWidget {
  final AdminReferralCashoutClaim claim;
  final VoidCallback onTap;

  const _ClaimCard({required this.claim, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final statusColor = claim.isPaid
        ? AppColors.correct
        : claim.isRejected
            ? AppColors.wrong
            : AppColors.amber;
    final statusLabel = claim.isPaid
        ? 'PAID'
        : claim.isRejected
            ? 'REJECTED'
            : 'PENDING';

    return AppCard(
      padding: EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      accentColor: statusColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  claim.username?.isNotEmpty == true
                      ? claim.username!
                      : claim.uid,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.titleMedium,
                ),
              ),
              Text(
                adminNaira(claim.amount),
                style: AppTypography.titleMedium.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          SizedBox(height: 4.h),
          Row(
            children: [
              _StatusChip(label: statusLabel, color: statusColor),
              SizedBox(width: 6.w),
              Text(
                '${claim.qualifiedCount} qualifying · '
                '${claim.maskedAccount}',
                style: AppTypography.bodySmall,
              ),
            ],
          ),
          if (claim.riskFlags.isNotEmpty) ...[
            SizedBox(height: 8.h),
            for (final flag in claim.riskFlags)
              Padding(
                padding: EdgeInsets.only(bottom: 2.h),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.flag_outlined,
                      size: 12.r,
                      color: AppColors.readable(AppColors.wrong),
                    ),
                    SizedBox(width: 4.w),
                    Expanded(
                      child: Text(
                        flag,
                        style: AppTypography.bodySmall.copyWith(
                          color: AppColors.readable(AppColors.wrong),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (claim.payoutAccountShared) ...[
            SizedBox(height: 8.h),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 12.r,
                  color: AppColors.readable(AppColors.wrong),
                ),
                SizedBox(width: 4.w),
                Expanded(
                  child: Text(
                    'Shared payout account'
                    '${claim.payoutAccountUidCount != null ? ' · ${claim.payoutAccountUidCount} account(s)' : ''} — confirm the owner before paying.',
                    style: AppTypography.bodySmall.copyWith(
                      color: AppColors.readable(AppColors.wrong),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7.w, vertical: 2.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.full),
      ),
      child: Text(
        label,
        style: AppTypography.labelSmall.copyWith(
          color: AppColors.readable(color),
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
        decoration: BoxDecoration(
          color: active
              ? AppColors.primary.withValues(alpha: 0.14)
              : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(AppRadii.full),
          border: Border.all(
            color: active ? AppColors.primary : AppColors.divider,
          ),
        ),
        child: Text(
          label,
          style: AppTypography.labelMedium.copyWith(
            color: active
                ? AppColors.readable(AppColors.primary)
                : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ─── Review dialog ──────────────────────────────────────────────────────────

class _ReviewDialog extends StatefulWidget {
  final AdminReferralCashoutClaim claim;

  const _ReviewDialog({required this.claim});

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  final _referenceCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _referenceCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _apply(String status) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AdminPayoutService.instance.markReferralCashout(
        claimId: widget.claim.claimId,
        status: status,
        payoutReference: status == 'paid' ? _referenceCtrl.text : null,
        reason: status == 'rejected' ? _reasonCtrl.text : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AdminPayoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not update the claim.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final claim = widget.claim;

    return AppDialog(
      title: '${claim.username ?? claim.uid} · ${adminNaira(claim.amount)}',
      contentWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row('Status', claim.status.toUpperCase()),
          _Row('Qualifying referrals', '${claim.qualifiedCount}'),
          _Row('Account number', claim.accountNumber ?? '—'),
          _Row('Bank code', claim.bankCode ?? '—'),
          _Row('Beneficiary', claim.beneficiaryName ?? '—'),
          _Row('Submitted', adminTime(claim.submittedAt)),
          if (claim.payoutReference != null)
            _Row('Reference', claim.payoutReference!),
          if (claim.rejectionReason != null)
            _Row('Rejection reason', claim.rejectionReason!),
          if (claim.riskFlags.isNotEmpty) ...[
            SizedBox(height: AppSpacing.sm),
            Text(
              'Risk flags (advisory)',
              style: AppTypography.labelMedium.copyWith(
                color: AppColors.readable(AppColors.wrong),
              ),
            ),
            SizedBox(height: 4.h),
            for (final f in claim.riskFlags)
              Text('• $f', style: AppTypography.bodySmall),
          ],
          if (claim.payoutAccountShared) ...[
            SizedBox(height: AppSpacing.sm),
            Text(
              'Shared payout account'
              '${claim.payoutAccountUidCount != null ? ' · ${claim.payoutAccountUidCount} account(s)' : ''}',
              style: AppTypography.labelMedium.copyWith(
                color: AppColors.readable(AppColors.wrong),
              ),
            ),
            SizedBox(height: 4.h),
            Text(
              'This bank account is used by more than one account. '
              'Confirm the owner before sending money.',
              style: AppTypography.bodySmall,
            ),
          ],
          if (claim.isPending) ...[
            SizedBox(height: AppSpacing.md),
            AppFormField(
              controller: _referenceCtrl,
              labelText: 'Transfer reference (optional)',
              hintText: 'From your bank statement',
              maxLength: 120,
              enabled: !_busy,
            ),
            SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Mark as paid ${adminNaira(claim.amount)}',
              loading: _busy,
              onPressed: _busy ? null : () => _apply('paid'),
            ),
            SizedBox(height: AppSpacing.sm),
            AppFormField(
              controller: _reasonCtrl,
              labelText: 'Rejection reason (only if rejecting)',
              maxLength: 200,
              enabled: !_busy,
            ),
            SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Reject claim',
              variant: AppButtonVariant.outline,
              loading: _busy,
              onPressed: _busy ? null : () => _apply('rejected'),
            ),
          ] else ...[
            SizedBox(height: AppSpacing.md),
            AppButton(
              label: 'Re-open claim',
              variant: AppButtonVariant.secondary,
              loading: _busy,
              onPressed: _busy ? null : () => _apply('pending'),
            ),
          ],
          if (_error != null) ...[
            SizedBox(height: AppSpacing.sm),
            Text(
              _error!,
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.readable(AppColors.wrong),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 6.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130.w,
            child: Text(label, style: AppTypography.bodySmall),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Top-up dialog ──────────────────────────────────────────────────────────

class _TopUpDialog extends StatefulWidget {
  final AdminReferralCashoutReserve reserve;

  const _TopUpDialog({required this.reserve});

  @override
  State<_TopUpDialog> createState() => _TopUpDialogState();
}

class _TopUpDialogState extends State<_TopUpDialog> {
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = int.tryParse(
      _amountCtrl.text.replaceAll(RegExp(r'\D'), ''),
    );
    if (amount == null || amount < 1) {
      setState(() => _error = 'Enter the amount you are setting aside.');
      return;
    }
    Navigator.of(context).pop(amount);
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Top up cashout budget',
      content:
          'This only records money you have set aside for referral cashouts. '
          'It never touches the weekly prize pool.',
      contentWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row('Available', adminNaira(widget.reserve.available)),
          _Row('Earmarked', adminNaira(widget.reserve.encumbered)),
          if (widget.reserve.shortfall > 0)
            _Row('Shortfall', adminNaira(widget.reserve.shortfall)),
          SizedBox(height: AppSpacing.md),
          AppFormField(
            controller: _amountCtrl,
            labelText: 'Amount to add (₦)',
            hintText: 'e.g. 20000',
            keyboardType: TextInputType.number,
            maxLength: 9,
          ),
          SizedBox(height: AppSpacing.sm),
          AppFormField(
            controller: _noteCtrl,
            labelText: 'Note (optional)',
            maxLength: 200,
          ),
          if (_error != null) ...[
            SizedBox(height: AppSpacing.sm),
            Text(
              _error!,
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.readable(AppColors.wrong),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        AppButton(
          label: 'Add to budget',
          onPressed: _submit,
        ),
      ],
    );
  }
}

// ─── Small shared bits ──────────────────────────────────────────────────────

class _CenteredMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onRetry;

  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.textMuted, size: 42.r),
            SizedBox(height: AppSpacing.md),
            Text(title, style: AppTypography.titleMedium),
            SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall,
            ),
            SizedBox(height: AppSpacing.lg),
            AppButton(label: 'Try again', onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
