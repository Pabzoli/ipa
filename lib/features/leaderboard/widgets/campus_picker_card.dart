// lib/features/leaderboard/widgets/campus_picker_card.dart
//
// Campus picker, shared by two surfaces:
//   • the Rankings campus chip (via [openCampusPickerSheet]),
//   • Profile > Stats tab top (via [CampusPickerCard]).
//
// Unlimited changes (locked decision): a bare users/{uid} update of the
// `university` field. No cooldown, no history.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/services/firestore_service.dart';
import '../../../core/theme/app_theme.dart';

/// Opens the picker as a bottom sheet. Returns after save or dismiss.
Future<void> openCampusPickerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20.r)),
    ),
    builder: (_) => const Padding(
      padding: EdgeInsets.only(bottom: 24),
      child: CampusPickerCard(inSheet: true),
    ),
  );
}

class CampusPickerCard extends StatefulWidget {
  final bool inSheet;
  const CampusPickerCard({super.key, this.inSheet = false});

  @override
  State<CampusPickerCard> createState() => _CampusPickerCardState();
}

class _CampusPickerCardState extends State<CampusPickerCard> {
  String? _current;
  String? _picked;
  bool _loading = true;
  bool _saving = false;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uni =
          await FirestoreService.instance.getCurrentUserUniversity();
      if (!mounted) return;
      setState(() {
        _current = uni;
        _picked = uni;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final picked = _picked;
    if (picked == null || _saving) return;
    setState(() => _saving = true);
    try {
      await FirestoreService.instance.updateUniversity(picked);
      if (!mounted) return;
      setState(() {
        _current = picked;
        _saving = false;
        _editing = false;
      });
      if (widget.inSheet && mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Campus saved.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save campus - please try again.'),
          backgroundColor: AppColors.wrong,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        padding: EdgeInsets.all(16.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(color: AppColors.divider),
        ),
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }

    final current = _current;
    if (current != null && current.isNotEmpty && !_editing) {
      return Container(
        padding: EdgeInsets.all(16.r),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 44.w,
              height: 44.h,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.secondary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12.r),
              ),
              child: Icon(Icons.school_rounded,
                  color: AppColors.secondary, size: 22.r),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'YOUR CAMPUS',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 9.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.9,
                    ),
                  ),
                  SizedBox(height: 3.h),
                  Text(
                    current,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: () => setState(() {
                _editing = true;
                _picked = current;
              }),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: 8.r, vertical: 6.r),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Change',
                      style: TextStyle(
                        color: AppColors.secondary,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(width: 2.w),
                    Icon(Icons.edit_rounded,
                        color: AppColors.secondary, size: 12.r),
                  ],
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
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _editing ? 'Change your campus' : 'Pick your campus',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            'Choose your university. Changing campus moves your chip and '
            'suggestions immediately.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.sp,
              height: 1.45,
            ),
          ),
          SizedBox(height: 12.h),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14.r),
            decoration: BoxDecoration(
              color: AppColors.surfaceDim.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value:
                    kNigerianUniversities.contains(_picked) ? _picked : null,
                isExpanded: true,
                dropdownColor: AppColors.surface,
                icon: Icon(Icons.expand_more_rounded,
                    color: AppColors.textMuted, size: 20.r),
                hint: Text(
                  'Select your university',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: 14.sp),
                ),
                style: TextStyle(
                    color: AppColors.textPrimary, fontSize: 14.sp),
                items: kNigerianUniversities
                    .map((u) => DropdownMenuItem(
                          value: u,
                          child: Text(u,
                              style: const TextStyle(
                                  color: AppColors.textPrimary)),
                        ))
                    .toList(),
                onChanged: _saving ? null : (v) => setState(() => _picked = v),
              ),
            ),
          ),
          SizedBox(height: 12.h),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 42,
                  child: ElevatedButton(
                    onPressed:
                        (_picked == null || _saving) ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppRadii.md),
                      ),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Save campus'),
                  ),
                ),
              ),
              if (_editing) ...[
                SizedBox(width: 8.w),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _editing = false),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
