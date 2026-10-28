import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../../core/constants/referral_economy.dart';
import '../../../../../../core/services/firestore_service.dart';
import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_button.dart';
import '../../../../../../core/widgets/app_form_field.dart';
import '../../../../../../core/widgets/app_sheet.dart';
import '../../../../../../features/prizes/bank_selector_sheet.dart';
import '../../../../data/data_source/referral_remote_data_source.dart';
import '../../../../data/model/referral_cashout.dart';

/// Opens the bank-destination sheet for a referral cashout claim.
///
/// Pops `true` after the server accepts the claim, so the caller can refresh
/// the card. The destination is submitted to `claimReferralCashout`; the server
/// re-counts qualifying referrals and decides whether the claim is allowed.
Future<bool?> showReferralCashoutSheet(
  BuildContext context, {
  required ReferralCashoutState state,
}) {
  return showAppSheet<bool>(
    context,
    builder: (_) => _ReferralCashoutSheet(state: state),
  );
}

class _ReferralCashoutSheet extends StatefulWidget {
  final ReferralCashoutState state;

  const _ReferralCashoutSheet({required this.state});

  @override
  State<_ReferralCashoutSheet> createState() => _ReferralCashoutSheetState();
}

class _ReferralCashoutSheetState extends State<_ReferralCashoutSheet> {
  static const _dataSource = ReferralRemoteDataSource();

  NigerianBank? _bank;
  final _accountCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _accountCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickBank() async {
    final bank = await showBankSelectorSheet(
      context,
      selected: _bank,
    );
    if (bank == null || !mounted) return;
    setState(() => _bank = bank);
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final account = _accountCtrl.text.replaceAll(RegExp(r'\D'), '');
    final name = _nameCtrl.text.trim();
    final bank = _bank;

    if (bank == null) {
      setState(() => _error = 'Choose your bank.');
      return;
    }
    if (account.length != 10) {
      setState(() => _error = 'Enter a 10-digit account number.');
      return;
    }
    if (name.length < 3) {
      setState(() => _error = 'Enter the account holder name.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await _dataSource.submitCashoutClaim(
        bankCode: bank.code,
        accountNumber: account,
        beneficiaryName: name,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ReferralCashoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppSheet(
      title: 'Claim ₦${_formatNaira(kReferralCashoutAmountNaira)}',
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Double-check the details — they cannot be changed after submission.',
              style: AppTypography.bodySmall,
            ),
            SizedBox(height: AppSpacing.lg),

            // Bank selector
            InkWell(
              onTap: _submitting ? null : _pickBank,
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.account_balance_rounded,
                      size: 18.r,
                      color: AppColors.textSecondary,
                    ),
                    SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        _bank?.name ?? 'Choose your bank',
                        style: AppTypography.bodyMedium.copyWith(
                          color: _bank == null
                              ? AppColors.textMuted
                              : AppColors.textPrimary,
                        ),
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
            SizedBox(height: AppSpacing.md),

            AppFormField(
              controller: _accountCtrl,
              labelText: 'Account number',
              hintText: '10 digits',
              keyboardType: TextInputType.number,
              maxLength: 10,
              enabled: !_submitting,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (value) {
                final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
                if (digits.length != 10) {
                  return 'Enter a 10-digit account number';
                }
                return null;
              },
            ),
            SizedBox(height: AppSpacing.md),

            AppFormField(
              controller: _nameCtrl,
              labelText: 'Account holder name',
              hintText: 'As it appears on the account',
              textCapitalization: TextCapitalization.words,
              maxLength: 100,
              enabled: !_submitting,
              validator: (value) {
                if ((value ?? '').trim().length < 3) {
                  return 'Enter the account holder name';
                }
                return null;
              },
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

            SizedBox(height: AppSpacing.lg),
            AppButton(
              label: 'Submit claim',
              loading: _submitting,
              onPressed: _submitting ? null : _submit,
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              'Your claim will be reviewed after submission.',
              textAlign: TextAlign.center,
              style: AppTypography.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatNaira(int amount) {
  final digits = amount.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
