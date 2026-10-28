import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';
import '../theme/app_theme.dart';

/// Full-screen blocking wall shown when the installed Android build is below
/// the server's minimum supported build.
///
/// There is no dismiss affordance by design: [PopScope] refuses to pop, the
/// Android back gesture is consumed, and the widget deliberately offers no
/// "later" / "skip" control. The only way out is downloading the new build.
///
/// Account deletion lives in Settings only
/// (Profile → Account → Danger zone → Delete account). It is intentionally
/// not offered here.
///
/// It is rendered from `MaterialApp.builder`, i.e. ABOVE the Navigator, so the
/// screen underneath is never torn down and never receives touches.
class UpdateRequiredScreen extends StatefulWidget {
  const UpdateRequiredScreen({super.key, required this.state});

  final AppUpdateState state;

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  bool _working = false;
  String? _error;

  AppUpdateState get _s => widget.state;

  @override
  Widget build(BuildContext context) {
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
                        child: _body(context),
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

  Widget _body(BuildContext context) {
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
        Text(
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
          style: TextStyle(
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
            onPressed: _working ? null : _openApk,
            icon: _working
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
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.45,
                fontFamily: 'Nunito',
              ),
            ),
          ),

        if (_error != null) ...[
          SizedBox(height: 20.r),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.errorText,
              fontSize: 13,
              height: 1.45,
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _openApk() async {
    final url = _s.apkUrl;
    if (url == null) return;
    setState(() {
      _working = true;
      _error = null;
    });
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
    setState(() => _working = false);
    if (!ok) {
      // A failed launch is usually "no browser installed to handle the
      // intent". Show the raw URL so the user can still get the file.
      setState(() => _error =
          'Could not open the download automatically.\n\n$url');
    }
  }
}
