// lib/features/prizes/payout_claim_page.dart
//
// Winner payout-claim screen.
//
// The winner selects a verified bank (server-provided list only — no
// free-form bank codes), enters their 10-digit account number and beneficiary
// name, and submits via the `submitPayoutDetails` callable.
//
// Claim details are submitted for review. This page makes no claims about
// account validation.
//
// The server is authoritative for eligibility, prize amount, payout status,
// and `paid`. This page only submits details and renders the server's claim
// state. It never calculates or displays a prize amount.
//
// States: loading-claim / idle-form / submitting / submitted (awaiting
// payment) / already-submitted / expired-forfeited (no re-claim) / paid / error.
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_back_button.dart';
import 'bank_selector_sheet.dart';

/// Claim states driven entirely by the server (`leaderboardCycles` ranked
/// entry + own `pendingClaim` doc).
enum _ClaimView {
  loading,
  form,
  submittedPending,
  paid,
  notWinner,
  noPrize,
  forfeited,
  error,
}

class PayoutClaimPage extends StatefulWidget {
  final String weekId;

  const PayoutClaimPage({super.key, required this.weekId});

  @override
  State<PayoutClaimPage> createState() => _PayoutClaimPageState();
}

class _PayoutClaimPageState extends State<PayoutClaimPage> {
  _ClaimView _view = _ClaimView.loading;
  String _errorMessage = '';

  // Server-derived context (never trusted from local input).
  // Paid-ness is captured by [_ClaimView.paid] — the ONLY "Paid" source.
  int _rank = 0;
  String? _maskedAccount;

  // Form state.
  NigerianBank? _bank;
  final _accountCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  String? _formError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadClaimState();
  }

  @override
  void dispose() {
    _accountCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  String? get _uid => FirestoreService.instance.currentUid;

  static String _mask(String account) {
    final digits = account.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 4) return '****';
    return '****${digits.substring(digits.length - 4)}';
  }

  Future<void> _loadClaimState() async {
    setState(() {
      _view = _ClaimView.loading;
      _errorMessage = '';
    });

    final uid = _uid;
    if (uid == null) {
      if (mounted) {
        setState(() {
          _view = _ClaimView.error;
          _errorMessage = 'Sign in to claim your prize.';
        });
      }
      return;
    }

    final cycle =
        await FirestoreService.instance.getLeaderboardCycle(widget.weekId);
    if (!mounted) return;

    if (cycle == null) {
      setState(() {
        _view = _ClaimView.error;
        _errorMessage =
            'No leaderboard record was found for that week. Please try again.';
      });
      return;
    }

    final ranked = (cycle['ranked'] as List?) ?? const [];
    Map<String, dynamic>? mine;
    for (final r in ranked) {
      final m = Map<String, dynamic>.from(r as Map);
      if (m['uid'] == uid) {
        mine = m;
        break;
      }
    }
    if (mine == null) {
      setState(() => _view = _ClaimView.notWinner);
      return;
    }

    final paid = mine['paid'] == true;
    final share = (mine['share'] as num?)?.toDouble() ?? 0;
    final claim =
        await FirestoreService.instance.getPendingClaim(widget.weekId);
    if (!mounted) return;

    // The server enforces the 3-day window against the cycle's calculatedAt;
    // mirror it here so a closed window shows the outcome instead of a form
    // that would only be rejected on submit.
    final calculatedAt = cycle['calculatedAt'];
    final windowClosed = calculatedAt is Timestamp &&
        DateTime.now().isAfter(
          calculatedAt.toDate().add(const Duration(days: 3)),
        );

    final status = claim?['status'] as String?;
    final storedAccount = claim?['accountNumber'] as String?;

    setState(() {
      _rank = ((mine?['rank'] as num?)?.toInt()) ?? 0;
      _maskedAccount = storedAccount != null && storedAccount.isNotEmpty
          ? _mask(storedAccount)
          : null;
      // Only "Paid" when the backend says paid == true.
      // After the 3-day window closes, any unpaid claim is automatically
      // forfeited — a submitted-but-unpaid claim is not kept alive waiting
      // for the sweep. 'marked' means the admin already recorded payment, so
      // it stays visible as awaiting settlement even past the window.
      if (paid) {
        _view = _ClaimView.paid;
      } else if (status == 'marked') {
        _view = _ClaimView.submittedPending;
      } else if (status == 'expired' || windowClosed) {
        _view = _ClaimView.forfeited;
      } else if (share <= 0) {
        _view = _ClaimView.noPrize;
      } else if (status == 'pending') {
        _view = _ClaimView.submittedPending;
      } else {
        // No claim yet and the window is still open — show the form.
        _view = _ClaimView.form;
      }
    });
  }

  Future<void> _pickBank() async {
    if (_submitting) return;
    final bank = await showBankSelectorSheet(context, selected: _bank);
    if (bank != null && mounted) {
      setState(() {
        _bank = bank;
        _formError = null;
      });
    }
  }

  Future<void> _submit() async {
    // Client-side UX guard only — the server re-validates everything.
    // Prevents rapid double-taps; the button stays disabled while running.
    if (_submitting) return;

    final account = _accountCtrl.text.trim();
    final name = _nameCtrl.text.trim();

    if (_bank == null) {
      setState(() => _formError = 'Select your bank from the verified list.');
      return;
    }
    if (!RegExp(r'^\d{10}$').hasMatch(account)) {
      setState(
        () => _formError = 'Enter the 10-digit account number.',
      );
      return;
    }
    if (name.length < 3) {
      setState(
        () => _formError = 'Enter the beneficiary name (at least 3 letters).',
      );
      return;
    }

    // Confirm before submitting. The account number is the destination,
    // and a typo here means the prize cannot be delivered. Submission also
    // locks the details until the admin marks it paid, so make it deliberate.
    final confirmed = await _confirmSubmission(
      bankName: _bank!.name,
      account: account,
      name: name,
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _submitting = true;
      _formError = null;
    });

    try {
      await FirestoreService.instance.submitPayoutDetails(
        weekId: widget.weekId,
        accountNumber: account,
        bankCode: _bank!.code,
        beneficiaryName: name,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _maskedAccount = _mask(account);
      });
      // Reflect the server's new claim state (pending) instead of guessing.
      await _loadClaimState();
      if (!mounted) return;
      // Keep the verification card visible above the refreshed state.
      setState(() {});
    } on PayoutClaimException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _handleClaimError(e);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _formError = 'Something went wrong. Check your connection and retry.';
      });
    }
  }

  /// Final confirmation before the details are submitted.
  ///
  /// Shows the destination back to the player because a wrong account number
  /// is unrecoverable — exactly what is stored here is used. Returns
  /// true only on explicit confirmation.
  Future<bool?> _confirmSubmission({
    required String bankName,
    required String account,
    required String name,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18.r),
        ),
        title: Text(
          'Confirm your bank details',
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Check this carefully. Your prize can only be sent to the '
                'account you confirm here.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13.sp,
                  height: 1.5,
                ),
              ),
              SizedBox(height: 14.h),
              _ConfirmRow(label: 'Bank', value: bankName),
              _ConfirmRow(label: 'Account', value: account),
              _ConfirmRow(label: 'Name', value: name),
              SizedBox(height: 12.h),
              Container(
                padding: EdgeInsets.all(11.r),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10.r),
                  border: Border.all(
                    color: AppColors.accent.withValues(alpha: 0.30),
                  ),
                ),
                child: Text(
                  'Submitting locks these details after you confirm, so '
                  'contact support if something is wrong afterwards.',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.sp,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Go back'),
          ),
          AppButton(
            label: 'Confirm',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
  }

  void _handleClaimError(PayoutClaimException e) {
    final msg = e.message.toLowerCase();
    if (e.code == 'failed-precondition' && msg.contains('already been paid')) {
      setState(() => _view = _ClaimView.paid);
      return;
    }
    if (e.code == 'failed-precondition' &&
        (msg.contains('marked as sent') ||
            msg.contains('marked as sent while you were submitting'))) {
      // The admin already recorded the payment — show the current state.
      setState(() => _view = _ClaimView.submittedPending);
      return;
    }
    if (e.code == 'not-found') {
      setState(() {
        _view = _ClaimView.error;
        _errorMessage = e.message;
      });
      return;
    }
    if (e.code == 'unauthenticated') {
      setState(() {
        _view = _ClaimView.error;
        _errorMessage = 'Your session expired. Sign in again and retry.';
      });
      return;
    }
    if (e.code == 'unavailable' ||
        e.code == 'deadline-exceeded' ||
        e.code == 'internal') {
      setState(
        () => _formError =
            'Network or server error. Your details were NOT submitted — please retry.',
      );
      return;
    }
    final lower = e.message.toLowerCase();
    if (e.code == 'failed-precondition' && lower.contains('no prize share')) {
      setState(() => _view = _ClaimView.noPrize);
      return;
    }
    if (e.code == 'failed-precondition' && lower.contains('claim window')) {
      setState(() => _view = _ClaimView.forfeited);
      return;
    }
    setState(() => _formError = e.message);
  }

  @override
  Widget build(BuildContext context) {
    return _buildGated(context);
  }

  Widget _buildGated(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: const AppBackButton(),
        title: Text(
          'Claim prize',
          style: TextStyle(
            fontSize: 17.sp,
            fontWeight: FontWeight.w900,
            fontFamily: 'Nunito',
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 32.r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _WeekHeader(weekId: widget.weekId, rank: _rank),
              SizedBox(height: 14.h),
              switch (_view) {
                _ClaimView.loading => const _LoadingCard(),
                _ClaimView.form => _ClaimForm(
                    bank: _bank,
                    accountCtrl: _accountCtrl,
                    nameCtrl: _nameCtrl,
                    formError: _formError,
                    submitting: _submitting,
                    onPickBank: _pickBank,
                    onSubmit: _submit,
                  ),
                _ClaimView.submittedPending => _StatusCard(
                    icon: Icons.hourglass_top_rounded,
                    color: AppColors.readable(AppColors.accent),
                    title: 'Awaiting payment',
                    body:
                        'Your details have been received and are under review. '
                        'Submitting does NOT mean you have been paid — check '
                        'your status after review.',
                    maskedAccount: _maskedAccount,
                    onRefresh: _loadClaimState,
                  ),
                _ClaimView.paid => _StatusCard(
                    icon: Icons.check_circle_rounded,
                    color: AppColors.readable(AppColors.correct),
                    title: 'Paid',
                    body: 'Your prize has been sent to your bank account. '
                        'Thanks for playing.',
                    maskedAccount: _maskedAccount,
                    onRefresh: _loadClaimState,
                  ),
                _ClaimView.notWinner => _StatusCard(
                    icon: Icons.info_outline_rounded,
                    color: AppColors.textMuted,
                    title: 'Not a winner',
                    body:
                        'This account is not in the winning list for that week.',
                  ),
                _ClaimView.noPrize => _StatusCard(
                    icon: Icons.info_outline_rounded,
                    color: AppColors.textMuted,
                    title: 'No prize this week',
                    body:
                        'Only the top 3 paid entrants win a prize. Your finishing '
                        'rank was outside those paid places.',
                  ),
                _ClaimView.forfeited => _StatusCard(
                    icon: Icons.event_busy_rounded,
                    color: AppColors.textMuted,
                    title: 'Claim window closed',
                    body:
                        'The 3-day window to claim this prize has passed, so this '
                        "week's share was forfeited. Prizes are not carried over "
                        'to a later week.',
                  ),
                _ClaimView.error => _StatusCard(
                    icon: Icons.error_outline_rounded,
                    color: AppColors.readable(AppColors.wrong),
                    title: 'Something went wrong',
                    body: _errorMessage,
                    onRefresh: _loadClaimState,
                  ),
              },
              SizedBox(height: 14.h),
              const _SecurityNote(),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Header ─────────────────────────────────────────────────────────────────
class _WeekHeader extends StatelessWidget {
  final String weekId;
  final int rank;

  const _WeekHeader({required this.weekId, required this.rank});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 44.r,
            height: 44.r,
            decoration: BoxDecoration(
              color: AppColors.gold.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12.r),
            ),
            alignment: Alignment.center,
            child: Text('🏆', style: TextStyle(fontSize: 22.sp)),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  rank > 0
                      ? 'Week of $weekId · Rank #$rank'
                      : 'Week of $weekId',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 48.h),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );
  }
}

// ─── Claim form ─────────────────────────────────────────────────────────────
class _ClaimForm extends StatelessWidget {
  final NigerianBank? bank;
  final TextEditingController accountCtrl;
  final TextEditingController nameCtrl;
  final String? formError;
  final bool submitting;
  final VoidCallback onPickBank;
  final VoidCallback onSubmit;

  const _ClaimForm({
    required this.bank,
    required this.accountCtrl,
    required this.nameCtrl,
    required this.formError,
    required this.submitting,
    required this.onPickBank,
    required this.onSubmit,
  });

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
          Text(
            'BANK',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
          SizedBox(height: 6.h),
          GestureDetector(
            onTap: submitting ? null : onPickBank,
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 13.r),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(11.r),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                children: [
                  Icon(Icons.account_balance_rounded,
                      color: AppColors.textMuted),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: Text(
                      bank?.name ?? 'Select your bank…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: bank == null
                            ? AppColors.textMuted
                            : AppColors.textPrimary,
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(Icons.expand_more_rounded, color: AppColors.textMuted),
                ],
              ),
            ),
          ),
          SizedBox(height: 12.h),
          Text(
            'ACCOUNT NUMBER',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
          SizedBox(height: 6.h),
          TextField(
            controller: accountCtrl,
            enabled: !submitting,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.0,
            ),
            decoration: InputDecoration(
              hintText: '0123456789',
              hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 15.sp),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              contentPadding:
                  EdgeInsets.symmetric(vertical: 13.r, horizontal: 12.r),
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
          SizedBox(height: 12.h),
          Text(
            'BENEFICIARY NAME',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
          SizedBox(height: 6.h),
          TextField(
            controller: nameCtrl,
            enabled: !submitting,
            textCapitalization: TextCapitalization.words,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14.sp,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              hintText: 'Name on the bank account',
              hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 13.sp),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              contentPadding:
                  EdgeInsets.symmetric(vertical: 13.r, horizontal: 12.r),
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
          if (formError != null) ...[
            SizedBox(height: 10.h),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded,
                    color: AppColors.readable(AppColors.wrong), size: 15.r),
                SizedBox(width: 7.w),
                Expanded(
                  child: Text(
                    formError!,
                    style: TextStyle(
                      color: AppColors.readable(AppColors.wrong),
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
          SizedBox(height: 16.h),
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: submitting ? 'Submitting…' : 'Submit payout details',
              variant: AppButtonVariant.primary,
              loading: submitting,
              onPressed: submitting ? null : onSubmit,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Confirmation dialog row ────────────────────────────────────────────────
class _ConfirmRow extends StatelessWidget {
  final String label;
  final String value;

  const _ConfirmRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82.w,
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
                color: AppColors.textPrimary,
                fontSize: 14.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Status card (pending / paid / not-winner / error) ──────────────────────
class _StatusCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final String? maskedAccount;
  final VoidCallback? onRefresh;

  const _StatusCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.maskedAccount,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Container(
            width: 60.r,
            height: 60.r,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: AppColors.readable(color), size: 28.r),
          ),
          SizedBox(height: 12.h),
          Text(
            title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 6.h),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.sp,
              height: 1.5,
            ),
          ),
          if (maskedAccount != null) ...[
            SizedBox(height: 10.h),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 7.r),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(9.r),
                border: Border.all(color: AppColors.divider),
              ),
              child: Text(
                'Destination: $maskedAccount',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
          if (onRefresh != null) ...[
            SizedBox(height: 14.h),
            AppButton(
              label: 'Refresh status',
              variant: AppButtonVariant.outline,
              size: AppButtonSize.small,
              onPressed: onRefresh,
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Security UX (always visible) ───────────────────────────────────────────
class _SecurityNote extends StatelessWidget {
  const _SecurityNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded,
              color: AppColors.secondary, size: 16.r),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              'The account must belong to you, the winner. Claim within 3 days '
              'of the week closing — after that your share is forfeited.',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12.sp,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
