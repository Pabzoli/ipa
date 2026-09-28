import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_constants.dart';
import '../services/app_update_service.dart';
import '../theme/app_theme.dart';
import '../../features/auth/auth_service.dart';
import '../../features/auth/delete_account_flow.dart';

/// Full-screen blocking wall shown when the installed Android build is below
/// the server's minimum supported build.
///
/// There is no dismiss affordance by design: [PopScope] refuses to pop, the
/// Android back gesture is consumed, and the widget deliberately offers no
/// "later" / "skip" control. The only ways out are downloading the new build
/// or deleting the account — the second is not a way past the wall, it is a
/// privacy right (NDPA/GDPR) that must survive being outdated, and it is
/// scoped to deletion only.
///
/// It is rendered from `MaterialApp.builder`, i.e. ABOVE the Navigator, so the
/// screen underneath is never torn down and never receives touches. A
/// consequence worth knowing: anything pushed as a Navigator route (including
/// showDialog) renders UNDERNEATH this wall and would be invisible. That is why
/// the deletion flow below is rendered inline instead of in dialogs.
class UpdateRequiredScreen extends StatefulWidget {
  const UpdateRequiredScreen({super.key, required this.state});

  final AppUpdateState state;

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

enum _Stage { idle, working, done }

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  _Stage _stage = _Stage.idle;
  bool _confirming = false;
  String? _error;

  AppUpdateState get _s => widget.state;

  @override
  Widget build(BuildContext context) {
    final signedIn = AuthService.instance.currentUser != null;

    return PopScope(
      // Hard block: no back gesture, no programmatic pop escape.
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: DecoratedBox(
          decoration: AppDecorations.heroBg,
          child: SizedBox.expand(
            child: SafeArea(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: MediaQuery.of(context).size.height -
                        MediaQuery.of(context).padding.vertical,
                  ),
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 24.r,
                        vertical: 32.r,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: _body(context, signedIn),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, bool signedIn) {
    if (_stage == _Stage.done) return _done(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 96.r, height: 96.r,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.35),
                width: 2,
              ),
            ),
            child: Icon(
              Icons.system_update_alt_rounded,
              color: AppColors.primary,
              size: 46.r,
            ),
          ),
        ),
        SizedBox(height: 28.r),
        const Text(
          'Update required',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.3,
            fontFamily: 'Nunito',
          ),
        ),
        SizedBox(height: 12.r),
        Text(
          'You are on build ${_s.installedBuild}. '
          'Build ${_s.minBuild} or newer is required to keep using AnimeQuiz.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 15,
            height: 1.55,
            fontFamily: 'Nunito',
          ),
        ),
        SizedBox(height: 10.r),
        Text(
          'This usually takes under a minute.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 13,
            fontFamily: 'Nunito',
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: 32.r),

        if (_s.apkUrl != null) ...[
          FilledButton.icon(
            onPressed: _stage == _Stage.working ? null : _openApk,
            icon: _stage == _Stage.working
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download_rounded, size: 20),
            label: const Text('Download the update'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              minimumSize: Size.fromHeight(52.r),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14.r),
              ),
              textStyle: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(height: 10.r),
          Text(
            'Android will ask you to allow installs from your browser the '
            'first time.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              height: 1.4,
              fontFamily: 'Nunito',
            ),
          ),
        ] else
          // A missing apkUrl must not leave a dead-end screen: the gate is
          // armed but there is nothing to hand the user. Say so explicitly.
          Container(
            padding: EdgeInsets.all(14.r),
            decoration: BoxDecoration(
              color: AppColors.wrong.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(
                color: AppColors.wrong.withValues(alpha: 0.30),
              ),
            ),
            child: Text(
              'The download link is temporarily unavailable. '
              'Please try again in a few minutes.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.45,
                fontFamily: 'Nunito',
              ),
            ),
          ),

        SizedBox(height: 28.r),
        const Divider(color: AppColors.divider, height: 1),
        SizedBox(height: 20.r),
        _deleteAccountSection(context, signedIn),
      ],
    );
  }

  // ── Account deletion escape hatch ─────────────────────────────────────────

  /// Deliberately narrow: this opens the erasure flow and nothing else. It
  /// does not let an outdated build play, spend coins, or claim anything — it
  /// only reaches the one thing the privacy policy promises and that would
  /// otherwise be unreachable from a walled app.
  Widget _deleteAccountSection(BuildContext context, bool signedIn) {
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.wrong,
              fontSize: 13,
              height: 1.45,
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 12.r),
          TextButton(
            onPressed: () => setState(() {
              _error = null;
              _confirming = false;
            }),
            child: const Text('Back'),
          ),
        ],
      );
    }

    if (_stage == _Stage.working) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.primary),
          ),
        ),
      );
    }

    if (!_confirming) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            signedIn
                ? 'Need to leave for good? You can delete your account and '
                    'all your data without updating.'
                : 'Need to leave for good? You can request deletion of your '
                    'account and all your data without updating.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 13,
              height: 1.5,
              fontFamily: 'Nunito',
            ),
          ),
          SizedBox(height: 6.r),
          TextButton(
            onPressed: () => setState(() => _confirming = true),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.wrong,
              textStyle: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
            child: const Text('Delete my account'),
          ),
        ],
      );
    }

    // Confirmation, rendered inline because Navigator routes would be hidden
    // behind this wall.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          signedIn
              ? 'This permanently deletes your account, profile, match '
                  'history, bank details and gameplay data. It cannot be undone.'
              : 'We will permanently delete your account and personal data. '
                  'Records we are legally required to keep are retained with '
                  'your personal details removed.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            height: 1.5,
            fontFamily: 'Nunito',
          ),
        ),
        SizedBox(height: 14.r),
        if (signedIn) ...[
          OutlinedButton(
            onPressed: _startDeletion,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.wrong,
              side: BorderSide(color: AppColors.wrong.withValues(alpha: 0.6)),
              minimumSize: Size.fromHeight(46.r),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.r),
              ),
              textStyle: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
            child: const Text('Yes, delete my account'),
          ),
          SizedBox(height: 8.r),
          TextButton(
            onPressed: () => setState(() => _confirming = false),
            child: const Text('Cancel'),
          ),
        ] else
          // Signed out: there is no in-app flow to run, so route to the
          // published privacy policy's contact address. The mailto is
          // pre-filled so the user only has to supply their account email.
          OutlinedButton.icon(
            onPressed: _openDeletionEmail,
            icon: const Icon(Icons.mail_outline_rounded, size: 18),
            label: const Text('Email a deletion request'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.wrong,
              side: BorderSide(color: AppColors.wrong.withValues(alpha: 0.6)),
              minimumSize: Size.fromHeight(46.r),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.r),
              ),
              textStyle: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_rounded, color: AppColors.correct, size: 72.r),
        SizedBox(height: 20.r),
        const Text(
          'Account deleted',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w900,
            fontFamily: 'Nunito',
          ),
        ),
        SizedBox(height: 10.r),
        const Text(
          'Your account and personal data have been deleted.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            height: 1.5,
            fontFamily: 'Nunito',
          ),
        ),
        SizedBox(height: 20.r),
        TextButton(
          onPressed: () => setState(() {
            _stage = _Stage.idle;
            _confirming = false;
            _error = null;
          }),
          child: const Text('Close'),
        ),
      ],
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _openApk() async {
    final url = _s.apkUrl;
    if (url == null) return;
    setState(() => _stage = _Stage.working);
    var ok = false;
    try {
      ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _stage = _Stage.idle);
    if (!ok) {
      // A failed launch is usually "no browser installed to handle the
      // intent". Show the raw URL so the user can still get the file.
      setState(() => _error =
          'Could not open the download automatically.\n\n$url');
    }
  }

  Future<void> _startDeletion() async {
    setState(() => _stage = _Stage.working);
    final result = await performAccountDeletion(
      onBusy: (busy) {
        if (mounted && busy) setState(() => _stage = _Stage.working);
      },
    );
    if (!mounted) return;
    setState(() {
      if (result.success) {
        _stage = _Stage.done;
        _error = null;
      } else {
        _stage = _Stage.idle;
        _confirming = false;
        _error = result.error;
      }
    });
  }

  Future<void> _openDeletionEmail() async {
    var ok = false;
    try {
      ok = await launchUrl(
        Uri.parse(kDeleteRequestMailtoUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      ok = false;
    }
    if (!mounted || ok) return;
    setState(() => _error =
        'Could not open your email app.\n\nWrite to $kSupportEmail');
  }
}
