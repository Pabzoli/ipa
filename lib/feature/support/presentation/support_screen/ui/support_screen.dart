import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../data/data_source/support_remote_data_source.dart';
import '../../../data/model/feedback_category.dart';
import 'widgets/support_form_body.dart';
import 'widgets/support_sent_view.dart';

/// Contact / bug report / suggestion page.
///
/// Messages are sent through the [SupportRemoteDataSource] callable; nothing
/// is written to Firestore directly, so a report cannot be spoofed, edited or
/// deleted from a patched client.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  static const _dataSource = SupportRemoteDataSource();

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _subjectController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();

  FeedbackCategory _category = FeedbackCategory.bug;
  bool _sending = false;
  bool _sent = false;

  String get _replyEmail =>
      FirebaseAuth.instance.currentUser?.email?.trim() ?? '';

  @override
  void dispose() {
    _subjectController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _sending = true);
    try {
      await _dataSource.submitFeedback(
        category: _category.wireValue,
        subject: _subjectController.text.trim(),
        message: _messageController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sent = true;
      });
    } on SupportSubmissionException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(e.message, style: const TextStyle(fontFamily: 'Nunito')),
          backgroundColor: AppColors.wrong,
        ),
      );
    }
  }

  void _sendAnother() {
    _subjectController.clear();
    _messageController.clear();
    setState(() {
      _category = FeedbackCategory.bug;
      _sent = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Header (matches Referrals / Earn Coins) ─────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(8.r, 10.r, 16.r, 4.r),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: AppColors.textPrimary,
                      size: 19.r,
                    ),
                    splashRadius: 22,
                  ),
                  SizedBox(width: 2.w),
                  Expanded(
                    child: Text(
                      'Help & Support',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.heading2.copyWith(
                        fontSize: 26.sp,
                        letterSpacing: -0.5,
                        height: 1.05,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Body: form ↔ success ────────────────────────────────────
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                // The default Stack centres its child, which pushed the form
                // down and left a gap above it whenever the content was
                // shorter than the viewport. Keep both states pinned to the top.
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.topCenter,
                  fit: StackFit.expand,
                  children: [
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                ),
                child: _sent
                    ? SupportSentView(
                        key: const ValueKey('support-sent'),
                        replyEmail: _replyEmail,
                        onSendAnother: _sendAnother,
                      )
                    : SupportFormBody(
                        key: const ValueKey('support-form'),
                        formKey: _formKey,
                        subjectController: _subjectController,
                        messageController: _messageController,
                        category: _category,
                        onCategoryChanged: (category) =>
                            setState(() => _category = category),
                        sending: _sending,
                        onSubmit: _submit,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
