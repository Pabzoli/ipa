import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_back_button.dart';
import '../../core/widgets/app_card.dart';

/// In-app summaries of the Terms of Service and Privacy Policy. The hosted
/// documents are the full, authoritative text; these pages exist so the
/// sign-up checkbox can link to something readable inside the app.
class TermsOfServicePage extends StatelessWidget {
  const TermsOfServicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: 'Terms of Service',
      fullUrl: '$kShopUrl/terms.html',
      intro: 'A short summary of how AnimeQuiz works. The full Terms are the '
          'binding document.',
      sections: const [
        _LegalSection(
          heading: 'The service',
          body: 'AnimeQuiz is a quiz game with solo play, challenges against '
              'other players and a weekly leaderboard. Some features use coins '
              'and points that you earn or buy.',
        ),
        _LegalSection(
          heading: 'Your account',
          body: 'You need an account with a working email address. You must '
              'verify that address before you can use the app. Keep your '
              'password private; you are responsible for activity on your '
              'account.',
        ),
        _LegalSection(
          heading: 'Fair play',
          body: 'Cheating, multi-accounting, automated play and abuse of '
              'referrals or promotions can lead to lost rewards, forfeited '
              'matches or suspension.',
        ),
        _LegalSection(
          heading: 'Prizes and payouts',
          body: 'Weekly prizes depend on the rules in force for that week. '
              'See the full Terms for eligibility and claim details.',
        ),
        _LegalSection(
          heading: 'Purchases',
          body: 'Paid items are described at the point of purchase. Refund '
              'and code rules are set out in the full Terms.',
        ),
        _LegalSection(
          heading: 'Changes and termination',
          body: 'We may update these Terms and will show the current version '
              'in the app. You can stop using AnimeQuiz and delete your account '
              'at any time from Settings.',
        ),
      ],
    );
  }
}

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: 'Privacy Policy',
      fullUrl: kPrivacyPolicyUrl,
      intro: 'A short summary of the personal data AnimeQuiz uses. The full '
          'policy is the binding document.',
      sections: const [
        _LegalSection(
          heading: 'What we collect',
          body: 'Your email address and username, your university if you pick '
              'one, gameplay results, coin and point history, and the '
              'details you choose to give us for prizes. We also keep '
              'security signals such as a hashed device identifier and hashed '
              'network address to stop abuse.',
        ),
        _LegalSection(
          heading: 'Why we use it',
          body: 'To run your account, match you with other players, show the '
              'leaderboard, deliver prizes and keep the game fair.',
        ),
        _LegalSection(
          heading: 'Who else sees it',
          body: 'Our service providers (for example hosting, authentication, '
              'analytics and payment processors) handle data on our behalf. '
              'Other players see your username and leaderboard results, not '
              'your email address.',
        ),
        _LegalSection(
          heading: 'How long we keep it',
          body: 'Accounts that never verify their email are deleted after 7 '
              'days. Other data is kept while your account exists, except '
              'records we must keep for legal or accounting reasons.',
        ),
        _LegalSection(
          heading: 'Your rights',
          body: 'You can view and correct your profile in the app and delete '
              'your account from Settings. To ask about your data, contact us '
              'using the address in the full policy.',
        ),
      ],
    );
  }
}

class _LegalSection {
  final String heading;
  final String body;
  const _LegalSection({required this.heading, required this.body});
}

class _LegalScaffold extends StatelessWidget {
  final String title;
  final String intro;
  final String fullUrl;
  final List<_LegalSection> sections;

  const _LegalScaffold({
    required this.title,
    required this.intro,
    required this.fullUrl,
    required this.sections,
  });

  Future<void> _openFull(BuildContext context) async {
    final ok = await launchUrl(
      Uri.parse(fullUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the full document.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: AppColors.surfaceDim,
        leading: const AppBackButton(),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(AppSpacing.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(intro, style: AppTypography.bodyMedium),
              SizedBox(height: AppSpacing.lg),
              for (final section in sections) ...[
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(section.heading, style: AppTypography.titleMedium),
                      SizedBox(height: AppSpacing.xs),
                      Text(section.body, style: AppTypography.bodyMedium),
                    ],
                  ),
                ),
                SizedBox(height: AppSpacing.md),
              ],
              SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Read the full document',
                variant: AppButtonVariant.outline,
                icon: Icon(Icons.open_in_new_rounded, size: 18.r),
                onPressed: () => _openFull(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
