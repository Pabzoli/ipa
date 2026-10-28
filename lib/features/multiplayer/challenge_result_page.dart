import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/weekly_points_pill.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/ad_service.dart';
import 'challenge_model.dart';

// ═══════════════════════════════════════════════════════════════════════════
// ChallengeResultPage — the destination for every multiplayer match, all modes.
//
// Opened by QuestionsPage after the user submits, and by ChallengeLobbyPage
// when a challenge resolves while the user is watching it. Exits via
// popUntil(isFirst) on both the back gesture and the CTA.
//
// The layout mirrors the solo summary page: a mode/currency header, one
// outcome hero (medallion → headline → scoreline → story), then a single
// summary card that carries the rewards and the match facts.
//
// Only information the user acts on is shown:
//   • not settled → a waiting card and live scores (no payout is decided yet)
//   • settled     → outcome, final scores, what was credited or lost
// ═══════════════════════════════════════════════════════════════════════════

const int _seriesPrizeAc = 100;

class ChallengeResultPage extends StatelessWidget {
  final String challengeId;

  const ChallengeResultPage({
    super.key,
    required this.challengeId,
  });

  void _goHome(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goHome(context);
      },
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: SafeArea(
          child: StreamBuilder<ChallengeModel?>(
            stream: FirestoreService.instance.challengeStream(challengeId),
            builder: (context, snap) {
              if (!snap.hasData &&
                  snap.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                );
              }

              final challenge = snap.data;

              if (challenge == null) {
                return _NotFound(onBack: () => _goHome(context));
              }

              return _ResultBody(
                challenge: challenge,
                currentUid: currentUid,
                onExit: () => _goHome(context),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ─── Outcome ────────────────────────────────────────────────────────────────

enum ResultOutcome { win, draw, loss }

@immutable
class _ResultFx {
  final ResultOutcome outcome;
  final ChallengeKind kind;

  const _ResultFx({required this.outcome, required this.kind});

  factory _ResultFx.resolve(ChallengeModel c, String uid) {
    final outcome = c.isDraw
        ? ResultOutcome.draw
        : (c.didCurrentUserWin(uid) ? ResultOutcome.win : ResultOutcome.loss);
    return _ResultFx(outcome: outcome, kind: c.kind);
  }

  Color get accent => switch (outcome) {
        ResultOutcome.win => AppColors.correct,
        ResultOutcome.draw => AppColors.secondary,
        ResultOutcome.loss => AppColors.wrong,
      };

  String get glyph => switch (kind) {
        ChallengeKind.rival => switch (outcome) {
            ResultOutcome.win => '🏆',
            ResultOutcome.draw => '⚔️',
            ResultOutcome.loss => '💀',
          },
        ChallengeKind.code => switch (outcome) {
            ResultOutcome.win => '📤',
            ResultOutcome.draw => '🤝',
            ResultOutcome.loss => '📉',
          },
        ChallengeKind.quick => switch (outcome) {
            ResultOutcome.win => '⚡',
            ResultOutcome.draw => '🤝',
            ResultOutcome.loss => '🪫',
          },
        ChallengeKind.spar => switch (outcome) {
            ResultOutcome.win => '🤝',
            ResultOutcome.draw => '🤝',
            ResultOutcome.loss => '💪',
          },
      };

  String get headline => switch (outcome) {
        ResultOutcome.win => 'You Won',
        ResultOutcome.draw => 'Draw',
        ResultOutcome.loss => 'You Lost',
      };
}

// ─── Body ───────────────────────────────────────────────────────────────────

class _ResultBody extends StatefulWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final VoidCallback onExit;

  const _ResultBody({
    required this.challenge,
    required this.currentUid,
    required this.onExit,
  });

  @override
  State<_ResultBody> createState() => _ResultBodyState();
}

class _ResultBodyState extends State<_ResultBody>
    with TickerProviderStateMixin {
  late final AnimationController _pageCtrl;
  late final AnimationController _scoreCtrl;
  late final Animation<double> _pageFade;
  late final Animation<Offset> _pageSlide;
  late final Animation<double> _medallionScale;
  late final Animation<double> _scoreAnim;

  Timer? _adTimer;
  bool _adSequenceFired = false;
  bool _disposed = false;

  ChallengeModel get c => widget.challenge;
  String get uid => widget.currentUid;
  bool get _isSpectator => !c.isParticipant(uid);
  bool get _showOutcome => c.isSettled && !_isSpectator;

  @override
  void initState() {
    super.initState();

    _pageCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _scoreCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _pageFade = CurvedAnimation(parent: _pageCtrl, curve: Curves.easeOut);
    _pageSlide = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _pageCtrl, curve: Curves.easeOutCubic),
    );
    _medallionScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.6, end: 1.08), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.08, end: 1.0), weight: 40),
    ]).animate(
      CurvedAnimation(
        parent: _pageCtrl,
        curve: const Interval(0.1, 0.75, curve: Curves.easeOut),
      ),
    );
    _scoreAnim = CurvedAnimation(parent: _scoreCtrl, curve: Curves.easeOutCubic);

    _pageCtrl.forward();
    if (c.isSettled) _playOutcome();
  }

  @override
  void didUpdateWidget(_ResultBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.challenge.isSettled && c.isSettled) _playOutcome();
  }

  void _playOutcome() {
    if (_disposed) return;
    _scoreCtrl.forward(from: 0);
    _adTimer?.cancel();
    _adTimer = Timer(const Duration(milliseconds: 700), _runAdSequence);
  }

  Future<void> _runAdSequence() async {
    if (_adSequenceFired || !mounted || _disposed) return;

    _adSequenceFired = true;

    final userData = context.read<UserDataProvider>();

    try {
      await AdService.instance.recordResultAndMaybeShowInterstitial(
        isPremium: userData.premiumActive,
      );
    } catch (e) {
      debugPrint('[ChallengeResultPage] ad sequence failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _adTimer?.cancel();
    _pageCtrl.dispose();
    _scoreCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showOutcome = _showOutcome;

    return FadeTransition(
      opacity: _pageFade,
      child: SlideTransition(
        position: _pageSlide,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 32.r),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeaderRow(kind: c.kind),
              SizedBox(height: 20.h),

              // ── Outcome hero / waiting card ───────────────────────────
              ScaleTransition(
                scale: _medallionScale,
                child: showOutcome
                    ? _OutcomeHero(
                        fx: _ResultFx.resolve(c, uid),
                        challenge: c,
                        currentUid: uid,
                        scoreAnimation: _scoreAnim,
                      )
                    : _StatusCard(
                        challenge: c,
                        currentUid: uid,
                        isSpectator: _isSpectator,
                      ),
              ),
              SizedBox(height: 14.h),

              // ── Live / final scores (only when the hero doesn't carry them)
              if (!showOutcome)
                _ScoreboardCard(
                  challenge: c,
                  currentUid: uid,
                  live: !c.isSettled,
                  scoreAnimation: kAlwaysCompleteAnimation,
                ),

              // ── Rewards + match facts ─────────────────────────────────
              if (showOutcome)
                _MatchSummaryCard(challenge: c, currentUid: uid),

              SizedBox(height: 24.h),

              // ── Actions ───────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 54.h,
                child: AppButton(
                  label: 'Back to Multiplayer',
                  icon: const Icon(Icons.sports_esports_rounded),
                  variant: AppButtonVariant.gradient,
                  size: AppButtonSize.large,
                  height: 54.h,
                  onPressed: widget.onExit,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Header — the mode, plus the two currencies
// ═══════════════════════════════════════════════════════════════════════════

class _HeaderRow extends StatelessWidget {
  final ChallengeKind kind;

  const _HeaderRow({required this.kind});

  @override
  Widget build(BuildContext context) {
    final color = kind.accentColor;

    return Row(
      children: [
        Text(
          'MATCH RESULT',
          style: AppTypography.labelSmall.copyWith(
            fontSize: 10.sp,
            letterSpacing: 1.2,
          ),
        ),
        const Spacer(),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 5.r),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(20.r),
            border: Border.all(color: color.withValues(alpha: 0.32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(kind.icon,
                  color: AppColors.readable(color), size: 13.r),
              SizedBox(width: 6.w),
              Text(
                kind.shortLabel,
                style: AppTypography.labelMedium.copyWith(
                  color: AppColors.readable(color),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: 8.w),
        const WeeklyPointsPill(),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Outcome hero — medallion, headline, animated scoreline, one-line story
// ═══════════════════════════════════════════════════════════════════════════

class _OutcomeHero extends StatelessWidget {
  final _ResultFx fx;
  final ChallengeModel challenge;
  final String currentUid;
  final Animation<double> scoreAnimation;

  const _OutcomeHero({
    required this.fx,
    required this.challenge,
    required this.currentUid,
    required this.scoreAnimation,
  });

  @override
  Widget build(BuildContext context) {
    final color = fx.accent;

    return Container(
      padding: EdgeInsets.symmetric(vertical: 30.r, horizontal: 24.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0.14),
            color.withValues(alpha: 0.04),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(24.r),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1.2),
      ),
      child: Column(
        children: [
          _Medallion(emoji: fx.glyph, color: color, size: 72.r, glyphSize: 34.sp),
          SizedBox(height: 18.h),
          Text(
            fx.headline,
            textAlign: TextAlign.center,
            style: AppTypography.heading1
                .copyWith(color: AppColors.readable(color)),
          ),
          SizedBox(height: 22.h),
          _ScoreLine(
            challenge: challenge,
            currentUid: currentUid,
            animation: scoreAnimation,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Status card — waiting, declined, expired, or spectating
// ═══════════════════════════════════════════════════════════════════════════

class _StatusCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final bool isSpectator;

  const _StatusCard({
    required this.challenge,
    required this.currentUid,
    required this.isSpectator,
  });

  @override
  Widget build(BuildContext context) {
    final opponentName = challenge.opponentNameFor(currentUid);
    final myScore = challenge.scoreFor(currentUid);

    final String title;
    final String body;
    final IconData icon;

    if (isSpectator) {
      icon = Icons.visibility_rounded;
      title = 'You are not in this match';
      body = 'Nothing is staked or credited to you.';
    } else if (challenge.isDeclined) {
      icon = Icons.block_rounded;
      title = 'Challenge declined';
      body = '$opponentName turned this challenge down. Nothing was staked.';
    } else if (challenge.isGhostMatch && challenge.creatorScore == null) {
      icon = Icons.bolt_rounded;
      title = 'Quick Match ready';
      body = 'Play the quiz to settle the result.';
    } else if (challenge.isAwaitingOpponent(currentUid)) {
      icon = Icons.hourglass_top_rounded;
      title = 'Waiting for $opponentName';
      body = myScore == null
          ? 'Finish the quiz to settle this challenge.'
          : 'This page updates the moment $opponentName finishes.';
    } else if (challenge.isExpired) {
      icon = Icons.timer_off_rounded;
      title = 'Challenge expired';
      body = 'Any stake was refunded.';
    } else {
      icon = Icons.hourglass_bottom_rounded;
      title = 'Settling the result';
      body = 'Both scores are in. The result will appear here once confirmed.';
    }

    return Container(
      padding: EdgeInsets.symmetric(vertical: 30.r, horizontal: 24.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withValues(alpha: 0.10),
            AppColors.primary.withValues(alpha: 0.03),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(24.r),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.22),
          width: 1.2,
        ),
      ),
      child: Column(
        children: [
          _Medallion(
            icon: icon,
            color: AppColors.readable(AppColors.primary),
            size: 72.r,
            glyphSize: 32.r,
          ),
          SizedBox(height: 18.h),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.heading3,
          ),
          SizedBox(height: 8.h),
          Text(
            body,
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Scoreboard — both scores, used for live and spectated matches
// ═══════════════════════════════════════════════════════════════════════════

class _ScoreboardCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final bool live;
  final Animation<double> scoreAnimation;

  const _ScoreboardCard({
    required this.challenge,
    required this.currentUid,
    required this.live,
    required this.scoreAnimation,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionLabel(live ? 'LIVE SCORES' : 'FINAL SCORES'),
          SizedBox(height: 16.h),
          _ScoreLine(
            challenge: challenge,
            currentUid: currentUid,
            animation: scoreAnimation,
          ),
        ],
      ),
    );
  }
}

class _ScoreLine extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final Animation<double> animation;

  const _ScoreLine({
    required this.challenge,
    required this.currentUid,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    final settled = challenge.isSettled;
    final total = challenge.questionIds.length;
    final creatorWon = settled && challenge.outcome == 'creator_wins';
    final opponentWon = settled && challenge.outcome == 'opponent_wins';

    return Row(
      children: [
        Expanded(
          child: _PlayerScore(
            name: challenge.creatorUsername,
            score: challenge.creatorScore,
            total: total,
            isMe: currentUid == challenge.creatorUid,
            isWinner: creatorWon,
            animation: animation,
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 8.w),
          child: Text(
            'VS',
            style: AppTypography.labelSmall.copyWith(
              fontSize: 11.sp,
              letterSpacing: 1.5,
            ),
          ),
        ),
        Expanded(
          child: _PlayerScore(
            name: challenge.opponentUsername ?? 'Opponent',
            score: challenge.opponentScore,
            total: total,
            isMe: currentUid == challenge.opponentUid,
            isWinner: opponentWon,
            animation: animation,
          ),
        ),
      ],
    );
  }
}

class _PlayerScore extends StatelessWidget {
  final String name;
  final int? score;
  final int total;
  final bool isMe;
  final bool isWinner;
  final Animation<double> animation;

  const _PlayerScore({
    required this.name,
    required this.score,
    required this.total,
    required this.isMe,
    required this.isWinner,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, __) {
        final value = score;
        final shown = value == null
            ? '—'
            : '${(value * animation.value).round()}';

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isMe ? 'You' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppTypography.labelMedium.copyWith(
                color: isMe ? AppColors.primary : AppColors.textMuted,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 8.h),
            Text(
              shown,
              textAlign: TextAlign.center,
              style: AppTypography.heading1.copyWith(
                fontSize: 40.sp,
                height: 1,
                letterSpacing: -1.5,
                color: isWinner
                    ? AppColors.readable(AppColors.correct)
                    : AppColors.textPrimary,
              ),
            ),
            if (total > 0) ...[
              SizedBox(height: 2.h),
              Text(
                '/ $total',
                textAlign: TextAlign.center,
                style: AppTypography.bodySmall,
              ),
            ],
          ],
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Summary card — only what this user received or lost, plus the match facts
// ═══════════════════════════════════════════════════════════════════════════

class _MatchSummaryCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const _MatchSummaryCard({
    required this.challenge,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    final won = challenge.didCurrentUserWin(currentUid);
    final isDraw = challenge.isDraw;

    final ac = challenge.acSettlementFor(won: won, isDraw: isDraw);
    final wp = challenge.wpTotalFor(won: won, isDraw: isDraw);
    final bounty =
        challenge.bountyWinnerUid == currentUid ? challenge.bountyWP : 0;
    final seriesPrize = challenge.seriesWinnerUid == currentUid &&
            challenge.seriesPrizePaid
        ? _seriesPrizeAc
        : 0;

    final hasRewards = ac > 0 || wp > 0 || bounty > 0 || seriesPrize > 0;
    final caption = _caption(won: won, isDraw: isDraw);

    return Container(
      padding: EdgeInsets.all(18.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('REWARDS'),
          SizedBox(height: 12.h),
          if (hasRewards) ...[
            Row(
              children: [
                if (ac > 0)
                  Expanded(
                    child: _RewardBlock(
                      emoji: '🪙',
                      value: '+$ac',
                      label: 'anime coins',
                      color: AppColors.readable(AppColors.coinGold),
                    ),
                  ),
                if (ac > 0 && wp > 0) SizedBox(width: 12.w),
                if (wp > 0)
                  Expanded(
                    child: _RewardBlock(
                      icon: Icons.leaderboard_rounded,
                      value: '+$wp',
                      label: 'weekly pts',
                      color: AppColors.readable(AppColors.skyBright),
                    ),
                  ),
              ],
            ),
            if (bounty > 0) ...[
              SizedBox(height: 12.h),
              _RewardLine(
                emoji: '🎯',
                label: 'Upset bounty',
                value: '+$bounty WP',
                color: AppColors.readable(AppColors.amber),
              ),
            ],
            if (seriesPrize > 0) ...[
              SizedBox(height: 10.h),
              _RewardLine(
                emoji: '🏆',
                label: 'Series prize',
                value: '+$seriesPrize AC',
                color: AppColors.readable(AppColors.coinGold),
              ),
            ],
          ] else
            Text('No rewards this match.', style: AppTypography.bodyMedium),

          // Only explains a stake that was lost or refunded. A win needs none.
          if (caption != null) ...[
            SizedBox(height: 16.h),
            Container(height: 1, color: AppColors.divider),
            SizedBox(height: 12.h),
            Text(caption, style: AppTypography.bodySmall),
          ],

          if (challenge.animeTitle.isNotEmpty) ...[
            SizedBox(height: 18.h),
            Container(height: 1, color: AppColors.divider),
            SizedBox(height: 16.h),
            const _SectionLabel('MATCH'),
            SizedBox(height: 12.h),
            _InfoRow(
              icon: Icons.movie_filter_rounded,
              label: 'Anime',
              value: challenge.animeTitle,
            ),
            if (challenge.kind.isStaked) ...[
              SizedBox(height: 10.h),
              _InfoRow(
                icon: Icons.sports_martial_arts_rounded,
                label: 'Stake',
                value: _stakeText,
              ),
            ],
          ],
        ],
      ),
    );
  }

  String get _stakeText {
    final wpStake = challenge.wpStake ?? 0;
    final buffer = StringBuffer('${challenge.stakeAmount} AC');
    if (wpStake > 0) buffer.write(' · $wpStake WP');
    return buffer.toString();
  }

  String? _caption({required bool won, required bool isDraw}) {
    if (!challenge.kind.isStaked) return null;
    if (won) return null;
    if (isDraw) {
      return 'Your stake was refunded, minus the house fee.';
    }
    return 'Your stake went to ${challenge.opponentNameFor(currentUid)}.';
  }
}

// ─── Small shared pieces ────────────────────────────────────────────────────

class _Medallion extends StatelessWidget {
  final String? emoji;
  final IconData? icon;
  final Color color;
  final double size;
  final double glyphSize;

  const _Medallion({
    this.emoji,
    this.icon,
    required this.color,
    required this.size,
    required this.glyphSize,
  });

  @override
  Widget build(BuildContext context) {
    final glyph = AppColors.readable(color);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Center(
        child: emoji != null
            ? Text(emoji!, style: TextStyle(fontSize: glyphSize))
            : Icon(icon, color: glyph, size: glyphSize),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: AppTypography.labelSmall.copyWith(letterSpacing: 1));
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15.r, color: AppColors.textMuted),
        SizedBox(width: 8.w),
        Text(label, style: AppTypography.bodySmall),
        SizedBox(width: 12.w),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodyLarge.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

// ─── Reward block — icon + big value + small label ──────────────────────────

class _RewardBlock extends StatelessWidget {
  final String? emoji;
  final IconData? icon;
  final String value;
  final String label;
  final Color color;

  const _RewardBlock({
    required this.value,
    required this.label,
    required this.color,
    this.emoji,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final glyph = AppColors.readable(color);
    return Row(
      children: [
        if (emoji != null) Text(emoji!, style: TextStyle(fontSize: 18.sp)),
        if (icon != null) Icon(icon, color: glyph, size: 18.r),
        SizedBox(width: 8.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: AppTypography.titleLarge.copyWith(
                  fontSize: 17.sp,
                  color: glyph,
                  height: 1,
                  letterSpacing: -0.3,
                ),
              ),
              SizedBox(height: 2.h),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodySmall.copyWith(
                  fontSize: 10.sp,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RewardLine extends StatelessWidget {
  final String emoji;
  final String label;
  final String value;
  final Color color;

  const _RewardLine({
    required this.emoji,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final glyph = AppColors.readable(color);
    return Row(
      children: [
        Text(emoji, style: TextStyle(fontSize: 16.sp)),
        SizedBox(width: 10.w),
        Expanded(child: Text(label, style: AppTypography.bodyLarge)),
        Text(value, style: AppTypography.titleLarge.copyWith(color: glyph)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Not found
// ═══════════════════════════════════════════════════════════════════════════

class _NotFound extends StatelessWidget {
  final VoidCallback onBack;

  const _NotFound({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 82,
              height: 82,
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.55),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.divider),
              ),
              child: const Center(
                child: Text('🔍', style: TextStyle(fontSize: 36)),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Challenge not found',
              textAlign: TextAlign.center,
              style: AppTypography.heading3,
            ),
            const SizedBox(height: 8),
            Text(
              'It may have been deleted or already expired.',
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium,
            ),
            const SizedBox(height: 26),
            AppButton(
              variant: AppButtonVariant.gradient,
              label: 'Back to Multiplayer',
              icon: const Icon(Icons.sports_esports_rounded),
              onPressed: onBack,
            ),
          ],
        ),
      ),
    );
  }
}
