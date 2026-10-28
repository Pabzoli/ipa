// lib/features/prizes/bank_selector_sheet.dart
//
// Verified bank-name → bank-code selector for the winner payout claim flow.
//
// The list comes ONLY from the `listNigerianBanks` callable (proposed Cloud
// Function — server-side Flutterwave `GET /v3/banks/NG`, secret never leaves
// the server). There is deliberately:
//   • no hardcoded bank catalogue,
//   • no free-form bank-code text entry — submission is blocked until a valid
//     bank is selected from the server-provided list.
//
// States: loading / loaded + search-filter / empty / error + retry.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';

/// Shows the verified-bank selector bottom sheet. Returns the selected bank,
/// or `null` when dismissed without a selection.
Future<NigerianBank?> showBankSelectorSheet(
  BuildContext context, {
  NigerianBank? selected,
}) {
  return showModalBottomSheet<NigerianBank>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _BankSelectorSheet(selected: selected),
  );
}

class _BankSelectorSheet extends StatefulWidget {
  final NigerianBank? selected;

  const _BankSelectorSheet({this.selected});

  @override
  State<_BankSelectorSheet> createState() => _BankSelectorSheetState();
}

class _BankSelectorSheetState extends State<_BankSelectorSheet> {
  late Future<List<NigerianBank>> _banksFuture;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _banksFuture = FirestoreService.instance.listNigerianBanks();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _retry() {
    setState(() {
      FirestoreService.instance.invalidateBankCache();
      _banksFuture = FirestoreService.instance.listNigerianBanks();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24.r)),
        ),
        padding: EdgeInsets.fromLTRB(24.r, 16.r, 24.r, 28.r),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44.w,
                height: 4.h,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2.r),
                ),
              ),
            ),
            SizedBox(height: 20.h),
            Text(
              'Select your bank',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.3,
                height: 1.1,
              ),
            ),
            SizedBox(height: 4.h),
            Text(
              'Verified banks only',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 14.h),
            Flexible(
              child: FutureBuilder<List<NigerianBank>>(
                future: _banksFuture,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const _BankLoading();
                  }
                  if (snap.hasError) {
                    return _BankError(
                      error: snap.error,
                      onRetry: _retry,
                    );
                  }
                  final banks = snap.data ?? const <NigerianBank>[];
                  if (banks.isEmpty) {
                    return _BankError(
                      error: null,
                      empty: true,
                      onRetry: _retry,
                    );
                  }
                  return _BankList(
                    banks: banks,
                    query: _query,
                    searchCtrl: _searchCtrl,
                    selected: widget.selected,
                    onQueryChanged: (q) =>
                        setState(() => _query = q.trim().toLowerCase()),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BankLoading extends StatelessWidget {
  const _BankLoading();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 36.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppColors.primary),
          SizedBox(height: 14.h),
          Text(
            'Loading verified banks…',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _BankError extends StatelessWidget {
  final Object? error;
  final bool empty;
  final VoidCallback onRetry;

  const _BankError({
    required this.error,
    required this.onRetry,
    this.empty = false,
  });

  String _message() {
    if (empty) return 'No banks were returned. Please try again.';
    if (error is FirebaseFunctionsException) {
      final code = (error as FirebaseFunctionsException).code;
      if (code == 'unavailable' || code == 'deadline-exceeded') {
        return 'Could not reach the bank list. Check your connection and retry.';
      }
      if (code == 'not-found') {
        return 'Bank list is not available yet. Please try again later.';
      }
    }
    return 'Could not load the bank list. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 28.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64.r,
            height: 64.r,
            decoration: BoxDecoration(
              color: AppColors.wrong.withValues(alpha: 0.10),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.wrong.withValues(alpha: 0.28)),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.account_balance_outlined,
              color: AppColors.readable(AppColors.wrong),
              size: 28.r,
            ),
          ),
          SizedBox(height: 14.h),
          Text(
            _message(),
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
            variant: AppButtonVariant.primary,
            size: AppButtonSize.small,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _BankList extends StatelessWidget {
  final List<NigerianBank> banks;
  final String query;
  final TextEditingController searchCtrl;
  final NigerianBank? selected;
  final ValueChanged<String> onQueryChanged;

  const _BankList({
    required this.banks,
    required this.query,
    required this.searchCtrl,
    required this.onQueryChanged,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final filtered = query.isEmpty
        ? banks
        : banks
            .where((b) =>
                b.name.toLowerCase().contains(query) ||
                b.code.contains(query))
            .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: searchCtrl,
          onChanged: onQueryChanged,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14.sp,
            fontWeight: FontWeight.w600,
          ),
          decoration: InputDecoration(
            hintText: 'Search banks…',
            hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 13.sp),
            prefixIcon:
                Icon(Icons.search_rounded, color: AppColors.textMuted),
            filled: true,
            fillColor: AppColors.surfaceAlt,
            contentPadding:
                EdgeInsets.symmetric(vertical: 12.r, horizontal: 12.r),
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
        Flexible(
          child: filtered.isEmpty
              ? Padding(
                  padding: EdgeInsets.symmetric(vertical: 24.h),
                  child: Text(
                    'No banks match "$query".',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13.sp,
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => SizedBox(height: 8.h),
                  itemBuilder: (_, i) {
                    final bank = filtered[i];
                    final isSelected = selected?.code == bank.code;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).pop(bank),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 14.r, vertical: 12.r),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primary.withValues(alpha: 0.08)
                              : AppColors.surfaceAlt.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12.r),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.primary.withValues(alpha: 0.45)
                                : AppColors.divider,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 38.r,
                              height: 38.r,
                              decoration: BoxDecoration(
                                color: AppColors.primary.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(10.r),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                bank.name.isNotEmpty
                                    ? bank.name[0].toUpperCase()
                                    : '?',
                                style: TextStyle(
                                  color: AppColors.readable(AppColors.primary),
                                  fontSize: 17.sp,
                                  fontWeight: FontWeight.w900,
                                  height: 1,
                                ),
                              ),
                            ),
                            SizedBox(width: 12.w),
                            Expanded(
                              child: Text(
                                bank.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 14.sp,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Icon(Icons.check_circle_rounded,
                                  color: AppColors.readable(AppColors.primary), size: 20.r),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
