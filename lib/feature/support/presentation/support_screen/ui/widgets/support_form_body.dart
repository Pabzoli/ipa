import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../../../core/constants/app_constants.dart';
import '../../../../../../core/theme/app_theme.dart';
import '../../../../../../core/widgets/app_button.dart';
import '../../../../../../core/widgets/app_card.dart';
import '../../../../../../core/widgets/app_form_field.dart';
import '../../../../data/model/feedback_category.dart';

/// The write-a-message form: category, subject, message and a plain-email
/// fallback.
class SupportFormBody extends StatelessWidget {
  const SupportFormBody({
    super.key,
    required this.formKey,
    required this.subjectController,
    required this.messageController,
    required this.category,
    required this.onCategoryChanged,
    required this.sending,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController subjectController;
  final TextEditingController messageController;
  final FeedbackCategory category;
  final ValueChanged<FeedbackCategory> onCategoryChanged;
  final bool sending;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionLabel('What is it about?'),
            SizedBox(height: 10.h),
            _CategoryPicker(
              category: category,
              enabled: !sending,
              onChanged: onCategoryChanged,
            ),
            SizedBox(height: 10.h),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: Text(
                category.hint,
                key: ValueKey(category),
                style: AppTypography.bodySmall.copyWith(height: 1.4),
              ),
            ),
            SizedBox(height: 22.h),
            const _SectionLabel('Your message'),
            SizedBox(height: 10.h),
            AppFormField(
              controller: subjectController,
              enabled: !sending,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              labelText: 'Subject',
              hintText: 'A short summary (optional)',
            ),
            SizedBox(height: 12.h),
            AppFormField(
              controller: messageController,
              enabled: !sending,
              maxLines: 7,
              maxLength: 1500,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textCapitalization: TextCapitalization.sentences,
              labelText: 'Message',
              hintText: 'What happened, and what did you expect?',
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return 'Please write a message.';
                if (text.length < 10) {
                  return 'Add a little more detail (at least 10 characters).';
                }
                return null;
              },
            ),
            SizedBox(height: 20.h),
            AppButton(
              label: 'Send message',
              icon: const Icon(Icons.send_rounded),
              size: AppButtonSize.large,
              loading: sending,
              onPressed: onSubmit,
            ),
            SizedBox(height: 14.h),
            const _EmailFallbackCard(),
          ],
        ),
      ),
    );
  }
}

// ─── Category picker ────────────────────────────────────────────────────────
class _CategoryPicker extends StatelessWidget {
  const _CategoryPicker({
    required this.category,
    required this.enabled,
    required this.onChanged,
  });

  final FeedbackCategory category;
  final bool enabled;
  final ValueChanged<FeedbackCategory> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final option in FeedbackCategory.values) ...[
          if (option != FeedbackCategory.values.first) SizedBox(width: 8.w),
          Expanded(
            child: _CategoryTile(
              option: option,
              selected: option == category,
              onTap: enabled ? () => onChanged(option) : null,
            ),
          ),
        ],
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final FeedbackCategory option;
  final bool selected;
  final VoidCallback? onTap;

  static const Map<FeedbackCategory, String> _shortLabels = {
    FeedbackCategory.bug: 'Bug',
    FeedbackCategory.suggestion: 'Idea',
    FeedbackCategory.other: 'Other',
  };

  static const Map<FeedbackCategory, IconData> _icons = {
    FeedbackCategory.bug: Icons.bug_report_rounded,
    FeedbackCategory.suggestion: Icons.lightbulb_rounded,
    FeedbackCategory.other: Icons.chat_bubble_outline_rounded,
  };

  static const Map<FeedbackCategory, Color> _colors = {
    FeedbackCategory.bug: AppColors.wrong,
    FeedbackCategory.suggestion: AppColors.gold,
    FeedbackCategory.other: AppColors.secondary,
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[option]!;

    return Semantics(
      button: true,
      selected: selected,
      label: option.label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(vertical: 12.h, horizontal: 6.w),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.14) : AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color:
                  selected ? color.withValues(alpha: 0.5) : AppColors.divider,
            ),
          ),
          child: Column(
            children: [
              Container(
                width: 34.r,
                height: 34.r,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: selected ? 0.18 : 0.10),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Icon(
                  _icons[option],
                  color: selected
                      ? AppColors.readable(color)
                      : AppColors.textMuted,
                  size: 18.r,
                ),
              ),
              SizedBox(height: 7.h),
              Text(
                _shortLabels[option]!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppTypography.fontFamily,
                  color: selected
                      ? AppColors.readable(color)
                      : AppColors.textSecondary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Plain email fallback ────────────────────────────────────────────────────
class _EmailFallbackCard extends StatelessWidget {
  const _EmailFallbackCard();

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final opened = await launchUrl(
        Uri(scheme: 'mailto', path: kSupportEmail),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open your email app. Write to $kSupportEmail.',
            ),
          ),
        );
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open your email app. Write to $kSupportEmail.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
      onTap: () => _open(context),
      child: Row(
        children: [
          Container(
            width: 34.r,
            height: 34.r,
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10.r),
            ),
            child: Icon(
              Icons.mail_outline_rounded,
              color: AppColors.secondary,
              size: 17.r,
            ),
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Prefer email?',
                  style: AppTypography.labelLarge,
                ),
                SizedBox(height: 2.h),
                Text(kSupportEmail, style: AppTypography.bodySmall),
              ],
            ),
          ),
          Icon(
            Icons.open_in_new_rounded,
            color: AppColors.textMuted,
            size: 16.r,
          ),
        ],
      ),
    );
  }
}

// ─── Small section label ─────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: AppTypography.labelSmall.copyWith(
        color: AppColors.textSecondary,
        letterSpacing: 1.1,
      ),
    );
  }
}
