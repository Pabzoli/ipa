import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/ad_service.dart';
import 'challenge_model.dart';

// ─── Challenge Result — Revamped ─────────────────────────────────────────────
// Fixes applied:
// [FIX-1] Background: Positioned.fill inside a Stack so the heroBg gradient
//         covers the ENTIRE screen, including below SafeArea. The Scaffold is
//         now backgroundColor: Colors.transparent so nothing bleeds through.
// [FIX-2] Full-screen coverage: ConstrainedBox(minHeight: screenHeight) inside
//         the SingleChildScrollView prevents the dark scaffold from peeking
//         through when content is shorter than the viewport.
// [FIX-3] Navigation: onBack now calls Navigator.pop() — one hop back to
//         MultiplayerHub — instead of popUntil(isFirst) which dumped the user
//         on the home screen.
// Design overhaul:
// - Custom header row with styled back button.
// - Confetti now renders full-screen via Positioned.fill (IgnorePointer).
// - Result banner gets a layered glow ring with animated shimmer.
// - VS card redesigned with large isolated score bubbles.
// - Stake outcome card uses a coloured icon badge + cleaner layout.
// - Coin badge is visually separated as its own widget.
// - CTA button label changed to "Back to Multiplayer".
class ChallengeResultPage extends StatelessWidget {
  final String challengeId;
  const ChallengeResultPage({super.key, required this.challengeId});

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return PopScope(
      canPop: false,
      child: Scaffold(
        // [FIX-1] Transparent so the Positioned.fill background shows everywhere.
        backgroundColor: Colors.transparent,
        extendBody: true,
        extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            // ── Full-screen background — no gaps ──────────────────────────
            Positioned.fill(
              child: Container(decoration: AppDecorations.heroBg),
            ),
            // ── Safe-area content ─────────────────────────────────────────
            SafeArea(
              bottom: true,
              child: StreamBuilder<ChallengeModel?>(
                stream:
                    FirestoreService.instance.challengeStream(challengeId),
                builder: (context, snap) {
                  if (!snap.hasData &&
                      snap.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                          color: AppColors.primary),
                    );
                  }
                  final c = snap.data;
                  if (c == null) {
                    return _NotFound(
                      // [FIX-3] pop → MultiplayerHub
                      onBack: () => Navigator.of(context).pop(),
                    );
                  }
                  return _ResultBody(
                    challenge: c,
                    currentUid: currentUid,
                    // [FIX-3] pop → MultiplayerHub
                    onBack: () => Navigator.of(context).pop(),
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

// ── Body ──────────────────────────────────────────────────────────────────────
class _ResultBody extends StatefulWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final VoidCallback onBack;

  const _ResultBody({
    required this.challenge,
    required this.currentUid,
    required this.onBack,
  });

  @override
  State<_ResultBody> createState() => _ResultBodyState();
}

class _ResultBodyState extends State<_ResultBody>
    with TickerProviderStateMixin {
  late AnimationController _bannerCtrl;
  late Animation<double> _bannerScale;
  late Animation<double> _bannerFade;
  late AnimationController _confettiCtrl;

  /// Guards the win-payout animation so it fires at most once per page session.
  bool _winAnimationShown = false;

  /// Coin balance captured at the moment the win result first arrives.
  int? _coinsAtResultTime;

  /// Listener registered on [UserDataProvider] to detect the CF payout.
  VoidCallback? _payoutListener;

  /// Cached provider reference for safe listener removal in dispose().
  UserDataProvider? _cachedUserDataProvider;

  // ── P-05: Ad sequence guard ───────────────────────────────────────────────
  bool _adSequenceFired = false;

  @override
  void initState() {
    super.initState();

    _bannerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _bannerScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _bannerCtrl, curve: Curves.elasticOut),
    );
    _bannerFade =
        CurvedAnimation(parent: _bannerCtrl, curve: Curves.easeOut);

    _confettiCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );

    if (widget.challenge.isCompleted && widget.challenge.outcome != null) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) {
          _bannerCtrl.forward();
          if (widget.challenge.didCurrentUserWin(widget.currentUid)) {
            _confettiCtrl.forward();
          }
          _listenForPayoutAndAnimate();
        }
      });

      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _runAdSequence();
      });
    }
  }

  @override
  void didUpdateWidget(_ResultBody old) {
    super.didUpdateWidget(old);
    if (!old.challenge.isCompleted && widget.challenge.isCompleted) {
      _bannerCtrl.forward();
      if (widget.challenge.didCurrentUserWin(widget.currentUid)) {
        _confettiCtrl.forward();
      }
      _listenForPayoutAndAnimate();

      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _runAdSequence();
      });
    }
  }

  void _listenForPayoutAndAnimate() {
    if (_winAnimationShown) return;
    if (!widget.challenge.isCompleted) return;
    if (!widget.challenge.didCurrentUserWin(widget.currentUid)) return;

    final userData = context.read<UserDataProvider>();
    _cachedUserDataProvider = userData;
    _coinsAtResultTime ??= userData.animeCoins;

    final int baseline = _coinsAtResultTime!;
    final int payout =
        ChallengeModel.payoutWin(widget.challenge.stakeAmount);

    void onBalanceChange() {
      if (!mounted || _winAnimationShown) return;
      if (userData.animeCoins > baseline) {
        _winAnimationShown = true;
        setState(() {});
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) CoinEarnAnimation.show(context, amount: payout);
        });
        userData.removeListener(_payoutListener!);
        _payoutListener = null;
      }
    }

    _payoutListener = onBalanceChange;
    userData.addListener(_payoutListener!);
  }

  Future<void> _runAdSequence() async {
    if (_adSequenceFired) return;
    _adSequenceFired = true;
    if (!mounted) return;
    final userData = context.read<UserDataProvider>();
    userData.incrementSessionQuizCount();
    await AdService.instance.recordResultAndMaybeShowInterstitial(
      isPremium: userData.premiumActive,
    );
  }

  @override
  void dispose() {
    _bannerCtrl.dispose();
    _confettiCtrl.dispose();
    if (_payoutListener != null) {
      _cachedUserDataProvider?.removeListener(_payoutListener!);
      _payoutListener = null;
    }
    super.dispose();
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        children: [
          // Back to Multiplayer button
          GestureDetector(
            onTap: widget.onBack,
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.surface.withOpacity(0.55),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: AppColors.textMuted,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Multiplayer',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          Text(
            'Result',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          // Invisible spacer to balance the back button
          const SizedBox(width: 90),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.challenge;
    final isResolved = c.isCompleted && c.outcome != null;
    final iWon = c.didCurrentUserWin(widget.currentUid);
    final isDraw = c.isDraw;

    // [FIX-2] Constrain to at least the screen height so the background
    // never peeks through when content is shorter than the viewport.
    final screenHeight = MediaQuery.of(context).size.height;

    return Stack(
      children: [
        // ── Full-screen confetti (win only) ──────────────────────────────
        // IgnorePointer so confetti never blocks taps on cards / buttons.
        if (isResolved && iWon)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _confettiCtrl,
                builder: (_, __) => CustomPaint(
                  painter:
                      _ConfettiPainter(progress: _confettiCtrl.value),
                ),
              ),
            ),
          ),

        // ── Scrollable content ───────────────────────────────────────────
        SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: screenHeight),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Header row ───────────────────────────────────────
                  _buildHeader(),
                  const SizedBox(height: 28),

                  // ── Calculating state ────────────────────────────────
                  if (!isResolved) ...[
                    const _CalculatingState(),
                    const SizedBox(height: 28),
                  ],

                  // ── Result banner ────────────────────────────────────
                  if (isResolved) ...[
                    ScaleTransition(
                      scale: _bannerScale,
                      child: FadeTransition(
                        opacity: _bannerFade,
                        child: _ResultBanner(
                          iWon: iWon,
                          isDraw: isDraw,
                          stakeAmount: c.stakeAmount,
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],

                  // ── VS score card ────────────────────────────────────
                  _VsCard(
                    challenge: c,
                    currentUid: widget.currentUid,
                    isResolved: isResolved,
                  ),
                  const SizedBox(height: 16),

                  // ── Stake outcome card ───────────────────────────────
                  if (isResolved) ...[
                    _StakeOutcomeCard(
                      iWon: iWon,
                      isDraw: isDraw,
                      stakeAmount: c.stakeAmount,
                    ),
                  ],

                  // ── Win coins badge ──────────────────────────────────
                  if (isResolved && iWon && _winAnimationShown) ...[
                    const SizedBox(height: 12),
                    _CoinBadge(
                        amount:
                            ChallengeModel.payoutWin(c.stakeAmount)),
                  ],

                  const Spacer(),
                  const SizedBox(height: 32),

                  // ── CTA — back to MultiplayerHub ─────────────────────
                  GradientButton(
                    label: 'Back to Multiplayer',
                    icon: Icons.sports_esports_rounded,
                    onTap: widget.onBack,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Calculating state ──────────────────────────────────────────────────────────
class _CalculatingState extends StatefulWidget {
  const _CalculatingState();

  @override
  State<_CalculatingState> createState() => _CalculatingStateState();
}

class _CalculatingStateState extends State<_CalculatingState>
    with SingleTickerProviderStateMixin {
  late AnimationController _dotCtrl;

  @override
  void initState() {
    super.initState();
    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.6),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          // Animated dots
          AnimatedBuilder(
            animation: _dotCtrl,
            builder: (_, __) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (i) {
                  final t = (_dotCtrl.value * 3 - i).clamp(0.0, 1.0);
                  final opacity = (math.sin(t * math.pi)).clamp(0.3, 1.0);
                  final scale = 0.7 + (opacity - 0.3) * 0.43;
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 5),
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primary.withOpacity(opacity),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(
                                opacity * 0.4),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              );
            },
          ),
          const SizedBox(height: 20),
          const Text(
            'Calculating result…',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'This happens automatically — sit tight!',
            style: TextStyle(
              color: AppColors.textMuted.withOpacity(0.8),
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Result banner ──────────────────────────────────────────────────────────────
class _ResultBanner extends StatelessWidget {
  final bool iWon;
  final bool isDraw;
  final int stakeAmount;

  const _ResultBanner({
    required this.iWon,
    required this.isDraw,
    required this.stakeAmount,
  });

  @override
  Widget build(BuildContext context) {
    final color = iWon
        ? AppColors.correct
        : isDraw
            ? AppColors.secondary
            : AppColors.wrong;
    final emoji = iWon ? '🏆' : isDraw ? '🤝' : '😔';
    final title = iWon ? 'You Won!' : isDraw ? "It's a Draw!" : 'You Lost';
    final subtitle = iWon
        ? 'Outstanding performance!'
        : isDraw
            ? 'Evenly matched!'
            : 'Better luck next time!';

    return Column(
      children: [
        // ── Glow ring + emoji ──────────────────────────────────────────
        Stack(
          alignment: Alignment.center,
          children: [
            // Outer glow ring
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    color.withOpacity(0.25),
                    color.withOpacity(0.0),
                  ],
                ),
              ),
            ),
            // Inner circle with border
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withOpacity(0.1),
                border: Border.all(color: color.withOpacity(0.5), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.3),
                    blurRadius: 24,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  emoji,
                  style: const TextStyle(fontSize: 46),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // ── Title ──────────────────────────────────────────────────────
        ShaderMask(
          shaderCallback: (r) => LinearGradient(
            colors: iWon
                ? [AppColors.correct, const Color(0xFF34D399)]
                : isDraw
                    ? [AppColors.secondary, const Color(0xFFFBBF24)]
                    : [AppColors.wrong, const Color(0xFFF87171)],
          ).createShader(r),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 40,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.5,
              height: 1,
            ),
          ),
        ),
        const SizedBox(height: 8),

        // ── Subtitle chip ──────────────────────────────────────────────
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.25)),
          ),
          child: Text(
            subtitle,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// ── VS score card ──────────────────────────────────────────────────────────────
class _VsCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final bool isResolved;

  const _VsCard({
    required this.challenge,
    required this.currentUid,
    required this.isResolved,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Row(
        children: [
          Expanded(
            child: _PlayerColumn(
              name: challenge.creatorUsername,
              score: challenge.creatorScore,
              isCurrentUser: currentUid == challenge.creatorUid,
              isWinner: isResolved && challenge.outcome == 'creator_wins',
              alignRight: false,
            ),
          ),
          // ── VS pill ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppColors.primary.withOpacity(0.2),
                        AppColors.primary.withOpacity(0.05),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: AppColors.primary.withOpacity(0.35)),
                  ),
                  child: const Text(
                    'VS',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                      letterSpacing: 3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _PlayerColumn(
              name: challenge.opponentUsername ?? 'Opponent',
              score: challenge.opponentScore,
              isCurrentUser: currentUid == challenge.opponentUid,
              isWinner:
                  isResolved && challenge.outcome == 'opponent_wins',
              alignRight: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerColumn extends StatelessWidget {
  final String name;
  final int? score;
  final bool isCurrentUser;
  final bool isWinner;
  final bool alignRight;

  const _PlayerColumn({
    required this.name,
    required this.score,
    required this.isCurrentUser,
    required this.isWinner,
    required this.alignRight,
  });

  @override
  Widget build(BuildContext context) {
    final scoreColor =
        isWinner ? AppColors.correct : AppColors.textPrimary;

    return Column(
      crossAxisAlignment: alignRight
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        // Crown
        if (isWinner) ...[
          Text(
            '👑',
            textAlign: alignRight ? TextAlign.right : TextAlign.left,
            style: const TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 4),
        ],

        // Player name chip
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isCurrentUser
                ? AppColors.primary.withOpacity(0.12)
                : AppColors.surface.withOpacity(0.4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isCurrentUser
                  ? AppColors.primary.withOpacity(0.3)
                  : Colors.transparent,
            ),
          ),
          child: Text(
            isCurrentUser ? 'You' : name,
            style: TextStyle(
              color: isCurrentUser
                  ? AppColors.primary
                  : AppColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 10),

        // Big score number
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child: Text(
            score != null ? '$score' : '…',
            key: ValueKey(score),
            textAlign:
                alignRight ? TextAlign.right : TextAlign.left,
            style: TextStyle(
              color: scoreColor,
              fontSize: 52,
              fontWeight: FontWeight.w900,
              height: 1,
              shadows: isWinner
                  ? [
                      Shadow(
                          color: AppColors.correct.withOpacity(0.4),
                          blurRadius: 12)
                    ]
                  : null,
            ),
          ),
        ),
        Text(
          '/ 10',
          textAlign: alignRight ? TextAlign.right : TextAlign.left,
          style: TextStyle(
            color: AppColors.textMuted.withOpacity(0.5),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ── Stake outcome card ─────────────────────────────────────────────────────────
class _StakeOutcomeCard extends StatelessWidget {
  final bool iWon;
  final bool isDraw;
  final int stakeAmount;

  const _StakeOutcomeCard({
    required this.iWon,
    required this.isDraw,
    required this.stakeAmount,
  });

  @override
  Widget build(BuildContext context) {
    final color = iWon
        ? AppColors.correct
        : isDraw
            ? AppColors.secondary
            : AppColors.wrong;

    final sign = iWon ? '+' : isDraw ? '±' : '-';
    final points = iWon
        ? ChallengeModel.payoutWin(stakeAmount)
        : isDraw
            ? ChallengeModel.payoutDraw(stakeAmount)
            : stakeAmount;
    final title = iWon
        ? 'Points Earned'
        : isDraw
            ? 'Points Refunded'
            : 'Points Lost';
    final sub = iWon
        ? 'You won both stakes! 🎉'
        : isDraw
            ? 'Stake returned minus 5% house fee'
            : 'Your opponent takes the pot';

    final iconData = iWon
        ? Icons.emoji_events_rounded
        : isDraw
            ? Icons.handshake_rounded
            : Icons.sentiment_dissatisfied_rounded;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withOpacity(0.25), width: 1.5),
      ),
      child: Row(
        children: [
          // Icon badge
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Icon(iconData, color: color, size: 24),
          ),
          const SizedBox(width: 14),

          // Labels
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  sub,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Big delta number
          Text(
            '$sign$points',
            style: TextStyle(
              color: color,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
              shadows: [
                Shadow(
                    color: color.withOpacity(0.35), blurRadius: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Coin badge ─────────────────────────────────────────────────────────────────
class _CoinBadge extends StatelessWidget {
  final int amount;
  const _CoinBadge({required this.amount});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFBBF24).withOpacity(0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: const Color(0xFFFBBF24).withOpacity(0.35), width: 1.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🪙', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Text(
            '+$amount AC coins deposited!',
            style: const TextStyle(
              color: Color(0xFFFBBF24),
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Confetti painter (win only) ────────────────────────────────────────────────
class _ConfettiPainter extends CustomPainter {
  final double progress;
  static final _rand = math.Random(42);
  static final _particles = List.generate(
    50,
    (i) => _Particle(
      x: _rand.nextDouble(),
      startY: -0.05 - _rand.nextDouble() * 0.4,
      speed: 0.35 + _rand.nextDouble() * 0.65,
      size: 4 + _rand.nextDouble() * 7,
      color: _colors[i % _colors.length],
      rotation: _rand.nextDouble() * math.pi * 2,
      isCircle: i % 4 == 0,
    ),
  );

  static const _colors = [
    Color(0xFF7C3AED),
    Color(0xFF60A5FA),
    Color(0xFF34D399),
    Color(0xFFFBBF24),
    Color(0xFFF472B6),
    Color(0xFFA78BFA),
    Color(0xFFFF6B6B),
  ];

  const _ConfettiPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in _particles) {
      final y = (p.startY + progress * p.speed) % 1.2;
      if (y < 0 || y > 1.1) continue;
      final x = p.x * size.width;
      final py = y * size.height;
      final opacity = (1.0 - y * 0.8).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = p.color.withOpacity(opacity * 0.9);

      canvas.save();
      canvas.translate(x, py);
      canvas.rotate(p.rotation + progress * math.pi * 3);

      if (p.isCircle) {
        canvas.drawCircle(Offset.zero, p.size * 0.4, paint);
      } else {
        canvas.drawRect(
          Rect.fromCenter(
              center: Offset.zero,
              width: p.size,
              height: p.size * 0.45),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.progress != progress;
}

class _Particle {
  final double x;
  final double startY;
  final double speed;
  final double size;
  final Color color;
  final double rotation;
  final bool isCircle;

  const _Particle({
    required this.x,
    required this.startY,
    required this.speed,
    required this.size,
    required this.color,
    required this.rotation,
    required this.isCircle,
  });
}

// ── Not found ──────────────────────────────────────────────────────────────────
class _NotFound extends StatelessWidget {
  final VoidCallback onBack;
  const _NotFound({required this.onBack});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.surface.withOpacity(0.5),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.divider),
                ),
                child:
                    const Center(child: Text('🔍', style: TextStyle(fontSize: 36))),
              ),
              const SizedBox(height: 20),
              const Text(
                'Challenge not found',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'It may have been deleted or already expired.',
                style:
                    TextStyle(color: AppColors.textMuted, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              GradientButton(
                label: 'Back to Multiplayer',
                icon: Icons.sports_esports_rounded,
                onTap: onBack,
              ),
            ],
          ),
        ),
      );
}