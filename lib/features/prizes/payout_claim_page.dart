// lib/features/prizes/payout_claim_page.dart
//
// Winner payout-claim screen (Phase 3).
//
// The winner selects a verified bank (server-provided list only — no
// free-form bank codes), enters their 10-digit account number and beneficiary
// name, and submits via the `submitPayoutDetails` callable. The server
// resolves the account via Flutterwave and determines the verified name.
//
// The server is authoritative for eligibility, prize amount, verification,
// approval, payout status, and `paid`. This page only submits details and
// renders the server's claim state. It never calculates or displays a prize
// amount.
//
// States: loading-claim / idle-form / submitting / verification-result /
// pending-approval (submitted) / approved-awaiting-completion /
// already-submitted / expired (re-claim allowed) / already-paid / error.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import 'bank_selector_sheet.dart';

/// Claim states driven entirely by the server (`leaderboardCycles` ranked
/// entry + own `pendingClaim` doc).
enum _ClaimView {
  loading,
  form,
  submittedPending,
  approvedAwaiting,
  paid,
  notWinner,
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
  String? _claimStatus;
  String? _maskedAccount;

  // Form state.
  NigerianBank? _bank;
  final _accountCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  String? _formError;
  bool _submitting = false;

  // Last submission result (verification display).
  bool? _resolvedNameMatch;
  String _resultMessage = '';
  bool _wasAlreadySubmitted = false;

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

    final cycle = await FirestoreService.instance
        .getLeaderboardCycle(widget.weekId);
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
    final claim =
        await FirestoreService.instance.getPendingClaim(widget.weekId);
    if (!mounted) return;

    final status = claim?['status'] as String?;
    final storedAccount = claim?['accountNumber'] as String?;

    setState(() {
      _rank = ((mine?['rank'] as num?)?.toInt()) ?? 0;
      _claimStatus = status;
      _maskedAccount =
          storedAccount != null && storedAccount.isNotEmpty
              ? _mask(storedAccount)
              : null;
      // Only "Paid" when the backend says paid == true.
      if (paid) {
        _view = _ClaimView.paid;
      } else if (status == 'approved') {
        _view = _ClaimView.approvedAwaiting;
      } else if (status == 'pending') {
        _view = _ClaimView.submittedPending;
      } else {
        // No claim yet, or expired (re-claim allowed) — show the form.
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

    setState(() {
      _submitting = true;
      _formError = null;
    });

    try {
      final result = await FirestoreService.instance.submitPayoutDetails(
        weekId: widget.weekId,
        accountNumber: account,
        bankCode: _bank!.code,
        beneficiaryName: name,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _resolvedNameMatch = result.resolvedNameMatch;
        _resultMessage = result.message;
        _wasAlreadySubmitted = result.alreadySubmitted;
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

  void _handleClaimError(PayoutClaimException e) {
    final msg = e.message.toLowerCase();
    if (e.code == 'failed-precondition' && msg.contains('already been paid')) {
      setState(() => _view = _ClaimView.paid);
      return;
    }
    if (e.code == 'failed-precondition' &&
        (msg.contains('already been approved') ||
            msg.contains('approved while you were submitting'))) {
      setState(() => _view = _ClaimView.approvedAwaiting);
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
    setState(() => _formError = e.message);
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
                    expiredBefore: _claimStatus == 'expired',
                    resolvedNameMatch: _resolvedNameMatch,
                    resultMessage: _resultMessage,
                    wasAlreadySubmitted: _wasAlreadySubmitted,
                    onPickBank: _pickBank,
                    onSubmit: _submit,
                  ),
                _ClaimView.submittedPending => _StatusCard(
                    icon: Icons.hourglass_top_rounded,
                    color: AppColors.accent,
                    title: 'Claim submitted',
                    body:
                        'Your details are with the admin for approval. '
                        'Submitting does NOT mean you have been paid.',
                    maskedAccount: _maskedAccount,
                    resolvedNameMatch: _resolvedNameMatch,
                    resultMessage: _resultMessage,
                    onRefresh: _loadClaimState,
                  ),
                _ClaimView.approvedAwaiting => _StatusCard(
                    icon: Icons.send_rounded,
                    color: AppColors.secondary,
                    title: 'Transfer submitted',
                    body:
                        'Your payout was approved and the bank transfer has '
                        'been submitted. It will show as Paid only after the '
                        'backend confirms completion.',
                    maskedAccount: _maskedAccount,
                    onRefresh: _loadClaimState,
                  ),
                _ClaimView.paid => _StatusCard(
                    icon: Icons.check_circle_rounded,
                    color: AppColors.correct,
                    title: 'Paid',
                    body:
                        'Your prize has been paid. Bank details are purged '
                        'after payout — only a masked reference is kept.',
                    maskedAccount: _maskedAccount,
                    onRefresh: _loadClaimState,
                  ),
                _ClaimView.notWinner => const _StatusCard(
                    icon: Icons.info_outline_rounded,
                    color: AppColors.textMuted,
                    title: 'Not a winner',
                    body:
                        'This account is not in the winning list for that week.',
                  ),
                _ClaimView.error => _StatusCard(
                    icon: Icons.error_outline_rounded,
                    color: AppColors.wrong,
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
              color: const Color(0xFFFFD700).withOpacity(0.14),
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
                  rank > 0 ? 'Week of $weekId · Rank #$rank' : 'Week of $weekId',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  'Prize amount is confirmed by the server.',
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
  final bool expiredBefore;
  final bool? resolvedNameMatch;
  final String resultMessage;
  final bool wasAlreadySubmitted;
  final VoidCallback onPickBank;
  final VoidCallback onSubmit;

  const _ClaimForm({
    required this.bank,
    required this.accountCtrl,
    required this.nameCtrl,
    required this.formError,
    required this.submitting,
    required this.expiredBefore,
    required this.resolvedNameMatch,
    required this.resultMessage,
    required this.wasAlreadySubmitted,
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
          if (expiredBefore) ...[
            _NoticeRow(
              icon: Icons.history_rounded,
              color: AppColors.accent,
              text:
                  'Your previous claim expired unclaimed. You can submit fresh details below.',
            ),
            SizedBox(height: 12.h),
          ],
          if (wasAlreadySubmitted && resultMessage.isNotEmpty) ...[
            _NoticeRow(
              icon: Icons.info_outline_rounded,
              color: AppColors.secondary,
              text: resultMessage,
            ),
            SizedBox(height: 12.h),
          ],
          if (!wasAlreadySubmitted &&
              resolvedNameMatch != null &&
              resultMessage.isNotEmpty) ...[
            _VerificationNotice(
              match: resolvedNameMatch!,
              message: resultMessage,
            ),
            SizedBox(height: 12.h),
          ],
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
              padding:
                  EdgeInsets.symmetric(horizontal: 12.r, vertical: 13.r),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(11.r),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_rounded,
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
                  const Icon(Icons.expand_more_rounded,
                      color: AppColors.textMuted),
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
              hintStyle:
                  TextStyle(color: AppColors.textMuted, fontSize: 15.sp),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              contentPadding:
                  EdgeInsets.symmetric(vertical: 13.r, horizontal: 12.r),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11.r),
                borderSide: const BorderSide(color: AppColors.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11.r),
                borderSide: const BorderSide(color: AppColors.divider),
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
              hintStyle:
                  TextStyle(color: AppColors.textMuted, fontSize: 13.sp),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              contentPadding:
                  EdgeInsets.symmetric(vertical: 13.r, horizontal: 12.r),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11.r),
                borderSide: const BorderSide(color: AppColors.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11.r),
                borderSide: const BorderSide(color: AppColors.divider),
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
                    color: AppColors.wrong, size: 15.r),
                SizedBox(width: 7.w),
                Expanded(
                  child: Text(
                    formError!,
                    style: TextStyle(
                      color: AppColors.wrong,
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

// ─── Server verification notice ─────────────────────────────────────────────
class _VerificationNotice extends StatelessWidget {
  final bool match;
  final String message;

  const _VerificationNotice({required this.match, required this.message});

  @override
  Widget build(BuildContext context) {
    final color = match ? AppColors.correct : AppColors.accent;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: color.withOpacity(0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            match
                ? Icons.verified_rounded
                : Icons.warning_amber_rounded,
            color: color,
            size: 18.r,
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  match
                      ? 'Account name verified'
                      : 'Name needs admin review',
                  style: TextStyle(
                    color: color,
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  match
                      ? 'The account name matches this bank account.'
                      : 'The name does not clearly match the verified account '
                        'name. An admin will review before approval.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.sp,
                    height: 1.45,
                  ),
                ),
                if (message.isNotEmpty) ...[
                  SizedBox(height: 3.h),
                  Text(
                    message,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.sp,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _NoticeRow({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: color.withOpacity(0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 17.r),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              text,
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

// ─── Status card (pending / approved / paid / not-winner / error) ───────────
class _StatusCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final String? maskedAccount;
  final bool? resolvedNameMatch;
  final String? resultMessage;
  final VoidCallback? onRefresh;

  const _StatusCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.maskedAccount,
    this.resolvedNameMatch,
    this.resultMessage,
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
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          Container(
            width: 60.r,
            height: 60.r,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(color: color.withOpacity(0.35)),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: color, size: 28.r),
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
              padding:
                  EdgeInsets.symmetric(horizontal: 12.r, vertical: 7.r),
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
          if (resolvedNameMatch != null && (resultMessage ?? '').isNotEmpty) ...[
            SizedBox(height: 10.h),
            _VerificationNotice(
              match: resolvedNameMatch!,
              message: resultMessage!,
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
        color: AppColors.secondary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12.r),
        border:
            Border.all(color: AppColors.secondary.withOpacity(0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded,
              color: AppColors.secondary, size: 16.r),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              'The account must belong to you, the winner. Submitting details '
              'does not mean you have been paid — admin approval is required, '
              'and Paid appears only after the backend confirms the transfer.',
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
