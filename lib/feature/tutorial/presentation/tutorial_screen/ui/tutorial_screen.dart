import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/widgets/app_button.dart';
import '../../../tutorial_service.dart';
import 'widgets/tutorial_step_card.dart';

class _TutorialStep {
  final IconData icon;
  final Color accent;
  final String title;
  final String body;
  final List<String> bullets;

  const _TutorialStep({
    required this.icon,
    required this.accent,
    required this.title,
    required this.body,
    required this.bullets,
  });
}

/// First-run tutorial carousel: lineup → solo → battle → earn → invite → redeem.
///
/// Shown once after sign-in (see `_AppShellState`) and replayable from
/// Settings → App tutorial. Plain `StatefulWidget` + `PageController` — no
/// provider, no router, no overlay keys.
class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  static const List<_TutorialStep> _steps = [
    _TutorialStep(
      icon: Icons.grid_view_rounded,
      accent: AppColors.primary,
      title: 'Pick your lineup',
      body: 'Every run starts on Home. Choose the anime you want to play.',
      bullets: [
        'Tap 2 or more anime to build today\'s lineup.',
        'Surprise me picks two for you when you cannot decide.',
        'Set difficulty in Profile → Settings. Harder pays more.',
      ],
    ),
    _TutorialStep(
      icon: Icons.play_circle_outline_rounded,
      accent: AppColors.correct,
      title: 'Play a solo quiz',
      body: 'Answer 10 questions, then bank your rewards.',
      bullets: [
        'Tap Start quiz — played titles go on cooldown.',
        'Correct answers earn Anime Coins and Weekly Points.',
        'Check Rankings to see your points climb each week.',
      ],
    ),
    _TutorialStep(
      icon: Icons.sports_esports_rounded,
      accent: AppColors.amber,
      title: 'Blitz on Home, duels on Battle',
      body: 'Gauntlet Blitz lives on Home. Head-to-head lives on Battle.',
      bullets: [
        'Home → Gauntlet Blitz: 90 seconds, up to 30 questions. First attempt is free, retries cost AC.',
        'No hints or pauses in Blitz — quitting a paid entry forfeits it.',
        'Battle → Create a duel, Join with a code, or Quick Match vs a ghost (5 daily tokens, 8 with Premium).',
        'Recent rivalry tracks your win series against each rival.',
      ],
    ),
    _TutorialStep(
      icon: Icons.emoji_events_rounded,
      accent: AppColors.secondary,
      title: 'Earn coins, climb, win prizes',
      body: 'Coins unlock play. Weekly Points unlock prizes.',
      bullets: [
        'Anime Coins pay for retries, skips and unlocks.',
        'Weekly Points decide your rank on the Rankings tab.',
        'Top ranks split the weekly prize pool — claim from My Prizes.',
      ],
    ),
    _TutorialStep(
      icon: Icons.group_add_rounded,
      accent: AppColors.primary,
      title: 'Invite friends, earn cash',
      body:
          'Share your code from Profile → Referrals. You earn +100 AC and your friend earns +50 AC once they play.',
      bullets: [
        'Track every invite as Pending, Rewarded or Expired.',
        'The cash bar fills only when an invitee activates a leaderboard entry on their own account (Profile → Redeem Code).',
        'When the bar is full you can claim ₦5,000 — the full conditions are in the Terms of Service.',
      ],
    ),
    _TutorialStep(
      icon: Icons.confirmation_number_rounded,
      accent: AppColors.gold,
      title: 'Redeem codes and the website shop',
      body:
          'Codes turn into AC, Premium or a weekly entry. Paid items start on our website.',
      bullets: [
        'Profile → Redeem Code accepts codes like XXXX-XXXX-XXXX. One code works on one account only.',
        'Buy on the website with this same account, pay securely via Flutterwave, then redeem the one-time code in the app.',
        'Lost a code? Find every website purchase under Settings → Account → Purchases.',
        'Rankings entry is ₦500 for one week. On mobile tap Get entry on the website, then redeem it under Profile → Redeem Code.',
      ],
    ),
  ];

  @override
  void dispose() {
    // Any exit counts as seen — Skip, Start playing, system back gesture,
    // browser back, tab close. Previously only the two buttons marked it,
    // so web users who left any other way were shown it on every launch.
    // Fire-and-forget: persistence must never block route disposal.
    unawaited(TutorialService.markSeen());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await TutorialService.markSeen();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _goTo(int page) {
    _controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _steps.length - 1;
    final step = _steps[_page];

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: DecoratedBox(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(8.r, 6.r, 16.r, 0),
                child: Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: _finish,
                      child: Text(
                        'Skip',
                        style: AppTypography.labelLarge.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20.r, 4.r, 20.r, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'How AnimeQuiz works',
                    style: AppTypography.heading2.copyWith(
                      fontSize: 26.sp,
                      letterSpacing: -0.5,
                      height: 1.05,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 4.h),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.r),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Step ${_page + 1} of ${_steps.length}',
                    style: AppTypography.bodySmall,
                  ),
                ),
              ),
              SizedBox(height: AppSpacing.md),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _steps.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) {
                    final s = _steps[i];
                    return SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(20.r, 4.r, 20.r, 12.r),
                      child: TutorialStepCard(
                        icon: s.icon,
                        accent: s.accent,
                        title: s.title,
                        body: s.body,
                        bullets: s.bullets,
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20.r, 0, 20.r, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _steps.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: EdgeInsets.symmetric(horizontal: 3.w),
                        width: i == _page ? 22.w : 7.w,
                        height: 7.h,
                        decoration: BoxDecoration(
                          color: i == _page ? step.accent : AppColors.divider,
                          borderRadius: BorderRadius.circular(AppRadii.full),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: AppSpacing.lg),
              Padding(
                padding: EdgeInsets.fromLTRB(20.r, 0, 20.r, 24.r),
                child: Row(
                  children: [
                    if (_page > 0)
                      Expanded(
                        child: AppButton(
                          label: 'Back',
                          variant: AppButtonVariant.text,
                          onPressed: () => _goTo(_page - 1),
                        ),
                      ),
                    if (_page > 0) SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: AppButton(
                        label: isLast ? 'Start playing' : 'Next',
                        variant: AppButtonVariant.primary,
                        size: AppButtonSize.large,
                        color: isLast ? null : step.accent,
                        onPressed: isLast ? _finish : () => _goTo(_page + 1),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
