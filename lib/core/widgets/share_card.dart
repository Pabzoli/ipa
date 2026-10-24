// lib/core/widgets/share_card.dart
//
// The picture a player actually shares.
//
// This widget is rendered OFF-SCREEN by `ShareService.shareCard`, never mounted
// in a screen. That is why every size below is a plain logical pixel value
// instead of `.w`/`.h`/`.sp`: the card is captured at a fixed target size and
// pixel ratio, so responsive scaling would only make the text grow on large
// phones and overflow the fixed frame.
//
// Visual direction: brand gradient only, no anime artwork. A user-shared image
// carrying a licensed cover is an IP problem for both the player and the app;
// a clean gradient with a huge, legible code travels just as well and cannot be
// reported. No QR code either — nobody scans the screen of the phone that is
// holding the share, they use the link or the code.

import 'package:flutter/material.dart';

import '../constants/referral_economy.dart';
import '../constants/share_links.dart';
import '../theme/app_theme.dart';

/// Logical size of a share card. Captured at 3× → 1080×1350 (4:5 portrait).
const Size kShareCardSize = Size(360, 450);

class ShareCard extends StatelessWidget {
  final String eyebrow;
  final String headline;
  final String codeLabel;
  final String code;
  final String footnote;

  const ShareCard({
    super.key,
    required this.eyebrow,
    required this.headline,
    required this.codeLabel,
    required this.code,
    required this.footnote,
  });

  /// Invite card for a referral code (the inviter's uid).
  factory ShareCard.forReferral(String code) => ShareCard(
        eyebrow: 'REFERRAL INVITE',
        headline: 'Join me on AnimeQuiz',
        codeLabel: 'YOUR REFERRAL CODE',
        code: code,
        footnote: 'You earn +$kReferralRefereeReward AC. '
            'I earn +$kReferralReferrerReward AC.',
      );

  /// Invite card for a challenge code. Short code, so it renders large.
  factory ShareCard.forChallenge(String code) => ShareCard(
        eyebrow: 'CHALLENGE INVITE',
        headline: 'Think you can beat me?',
        codeLabel: 'CHALLENGE CODE',
        code: code,
        footnote: 'Open AnimeQuiz, tap Join Challenge and enter this code.',
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kShareCardSize.width,
      height: kShareCardSize.height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.heroGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          // Soft brand glows. Gradients only — nothing here is artwork.
          Positioned(
            top: -70,
            right: -60,
            child: _Glow(size: 240, color: AppColors.primary),
          ),
          Positioned(
            bottom: -80,
            left: -70,
            child: _Glow(size: 220, color: AppColors.secondary),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              // spaceBetween, not Spacer/Expanded: the screenshot package
              // documents that flex children break off-screen capture.
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _TopBar(eyebrow: eyebrow),
                _CodeBlock(
                  headline: headline,
                  codeLabel: codeLabel,
                  code: code,
                ),
                _Footer(footnote: footnote),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Header ─────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final String eyebrow;

  const _TopBar({required this.eyebrow});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎌', style: TextStyle(fontSize: 18)),
            const SizedBox(width: AppSpacing.sm),
            Text(
              'AnimeQuiz',
              style: AppTypography.titleMedium.copyWith(
                fontSize: 16,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadii.full),
            border: Border.all(color: AppColors.primaryBorder),
          ),
          child: Text(
            eyebrow,
            style: AppTypography.labelSmall.copyWith(
              fontSize: 9,
              letterSpacing: 1.2,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Headline + code ────────────────────────────────────────────────────────

class _CodeBlock extends StatelessWidget {
  final String headline;
  final String codeLabel;
  final String code;

  const _CodeBlock({
    required this.headline,
    required this.codeLabel,
    required this.code,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          headline,
          style: AppTypography.heading1.copyWith(fontSize: 30, height: 1.08),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: AppSpacing.lg,
          ),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(color: AppColors.primaryBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                codeLabel,
                style: AppTypography.labelSmall.copyWith(
                  fontSize: 9,
                  letterSpacing: 1.4,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                code,
                // A referral code is a 28-character uid, a challenge code is
                // 6. Wrap rather than ellipsize — a truncated code is useless.
                maxLines: 4,
                style: AppTypography.heading1.copyWith(
                  fontSize: _codeFontSize(code.length),
                  height: 1.15,
                  letterSpacing: 1.5,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Keeps a short challenge code huge and a long referral uid readable inside
/// the card's fixed 312 px content width.
double _codeFontSize(int length) {
  if (length <= 8) return 40;
  if (length <= 16) return 30;
  return 22;
}

// ─── Footer ─────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  final String footnote;

  const _Footer({required this.footnote});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          footnote,
          style: AppTypography.bodySmall.copyWith(
            fontSize: 12,
            height: 1.4,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          kShareLinkHost,
          style: AppTypography.labelSmall.copyWith(
            fontSize: 10,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

// ─── Decorative glow ────────────────────────────────────────────────────────

class _Glow extends StatelessWidget {
  final double size;
  final Color color;

  const _Glow({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: 0.28),
            color.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}
