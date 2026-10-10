import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/ad_service.dart';
import 'challenge_model.dart';

// ═══════════════════════════════════════════════════════════════════════════
// ChallengeResultPage — the single destination for every completed (and
// not-yet-completed) multiplayer match, for all three modes.
//
// Navigation contract
// ───────────────────
// Opened by:
//   • QuestionsPage.onChallengeComplete  — after ANY role finishes, ANY mode
//   • ChallengeLobbyPage                — auto-redirects here the instant the
//                                         challenge resolves while you watch
//   • MyChallengesPage                  — tapping a completed card
//
// Exits via Navigator.popUntil((r) => r.isFirst) on BOTH the system back
// button and the primary CTA. It previously used pop(), which meant the same
// "Back to Multiplayer" button sent the opponent to the root but sent a
// creator who had arrived via Navigator.push from the lobby straight back to
// that lobby — a result → lobby → result loop. popUntil removes the
// dependency on how the page was reached.
//
// Live / settled
// ──────────────
// The page is entered the moment *this* user submits, which is often before
// the opponent has finished. It therefore has two top-level states, chosen by
// ChallengeModel.isSettled:
//   • not settled  → a "waiting on {opponent}" card, a LIVE chip, and a "—"
//                    for the missing score. No payout is shown, because none
//                    has been decided yet.
//   • settled      → the full outcome reveal, driven by didUpdateWidget the
//                    instant the `outcome` field lands.
//
// Nothing here branches on challengeType directly; every visual and every
// payout routes through ChallengeModel.kind and the settlement getters, so all
// three modes stay in lockstep and none of them can relabel another's number.
// ═══════════════════════════════════════════════════════════════════════════

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

// ─── Outcome + effect variant ───────────────────────────────────────────────

enum ResultOutcome { win, draw, loss }

/// Everything that varies by (challenge type × outcome), resolved in exactly
/// one place. This is what guarantees that a Code Challenge can never fall
/// back to the Rival reveal, and that Quick Match can never reuse the Code
/// burst — previously all nine combinations collapsed into one win-only
/// stack, and draws and losses got no motion at all.
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

  bool get isWin => outcome == ResultOutcome.win;
  bool get isDraw => outcome == ResultOutcome.draw;
  bool get isLoss => outcome == ResultOutcome.loss;

  /// Full-strength confetti is reserved for wins. Draws get a calm ring
  /// pulse, losses get a slow descent — motion either way, celebration only
  /// where it is warranted.
  bool get celebrate => isWin;

  Color get accent => switch (outcome) {
        ResultOutcome.win => AppColors.correct,
        ResultOutcome.draw => AppColors.secondary,
        ResultOutcome.loss => AppColors.wrong,
      };

  /// The hero medallion glyph. Per type as well as per outcome, so a lost
  /// Quick Match never looks like a lost Rival duel.
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

  /// Which ambient effect plays behind the glyph. Three distinct win effects
  /// (duel rings / QR scan / lightning) plus a shared-per-tint draw pulse and
  /// a shared-per-tint loss descent.
  _AmbientFx get ambient => switch (kind) {
        ChallengeKind.rival => switch (outcome) {
            ResultOutcome.win => const _AmbientFxDuelRings(),
            ResultOutcome.draw => _AmbientFxTiePulse(kind.accentColor),
            ResultOutcome.loss => _AmbientFxDescent(kind.accentColor),
          },
        ChallengeKind.code => switch (outcome) {
            ResultOutcome.win => const _AmbientFxQrScan(),
            ResultOutcome.draw => _AmbientFxTiePulse(kind.accentColor),
            ResultOutcome.loss => _AmbientFxDescent(kind.accentColor),
          },
        ChallengeKind.quick => switch (outcome) {
            ResultOutcome.win => const _AmbientFxBolt(),
            ResultOutcome.draw => _AmbientFxTiePulse(kind.accentColor),
            ResultOutcome.loss => _AmbientFxDescent(kind.accentColor),
          },
        // Spar is friendly: even a win pulses, never rings or bolts.
        ChallengeKind.spar => switch (outcome) {
            ResultOutcome.win => _AmbientFxTiePulse(kind.accentColor),
            ResultOutcome.draw => _AmbientFxTiePulse(kind.accentColor),
            ResultOutcome.loss => _AmbientFxDescent(kind.accentColor),
          },
      };

  Duration get heroDuration => ambient.duration;
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
  // ── Controllers ────────────────────────────────────────────────────────
  late final AnimationController _pageCtrl;
  late final AnimationController _heroCtrl;
  late final AnimationController _fxCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _crownCtrl;
  late final AnimationController _confettiCtrl;

  // ── Animations ─────────────────────────────────────────────────────────
  late final Animation<double> _pageFade;
  late final Animation<Offset> _pageSlide;

  late final Animation<double> _glyphScale;
  late final Animation<double> _titleFade;
  late final Animation<Offset> _titleSlide;
  late final Animation<double> _subtitleFade;
  late final Animation<Offset> _subtitleSlide;
  late final Animation<double> _pillScale;
  late final Animation<double> _scoreReveal;

  late final Animation<double> _fxAnim;
  late final Animation<double> _pulse;
  late final Animation<double> _crownDrop;

  // ── State ──────────────────────────────────────────────────────────────
  bool _showConfetti = false;
  bool _settlementRevealed = false;

  Timer? _confettiHideTimer;
  Timer? _pulseStopTimer;
  Timer? _settleTimer;
  Timer? _adTimer;
  Timer? _payoutWatchdog;

  VoidCallback? _payoutListener;
  UserDataProvider? _payoutProvider;

  bool _adSequenceFired = false;
  bool _disposed = false;

  ChallengeModel get c => widget.challenge;
  String get uid => widget.currentUid;

  late _ResultFx _fx;
  bool get _isSettled => c.isSettled;
  bool get _isSpectator => !c.isParticipant(uid);

  bool get _wonSomething => c.didCurrentUserWin(uid);
  bool get _isDrawOutcome => c.isDraw;

  // ──────────────────────────────────────────────────────────────────────
  // init / lifecycle
  // ──────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _fx = _ResultFx.resolve(c, uid);

    _pageCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );

    _heroCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );

    _fxCtrl = AnimationController(vsync: this, duration: _fx.heroDuration);

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _crownCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _confettiCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );

    _pageFade = CurvedAnimation(
      parent: _pageCtrl,
      curve: Curves.easeOut,
    );

    _pageSlide = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _pageCtrl, curve: Curves.easeOutCubic),
    );

    _glyphScale = CurvedAnimation(
      parent: _heroCtrl,
      curve: const Interval(0.00, 0.55, curve: Curves.elasticOut),
    );

    _titleFade = CurvedAnimation(
      parent: _heroCtrl,
      curve: const Interval(0.25, 0.65, curve: Curves.easeOut),
    );

    _titleSlide = Tween<Offset>(
      begin: const Offset(0, 0.18),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _heroCtrl,
        curve: const Interval(0.25, 0.70, curve: Curves.easeOutCubic),
      ),
    );

    _subtitleFade = CurvedAnimation(
      parent: _heroCtrl,
      curve: const Interval(0.42, 0.80, curve: Curves.easeOut),
    );

    _subtitleSlide = Tween<Offset>(
      begin: const Offset(0, 0.25),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _heroCtrl,
        curve: const Interval(0.42, 0.85, curve: Curves.easeOutCubic),
      ),
    );

    _pillScale = CurvedAnimation(
      parent: _heroCtrl,
      curve: const Interval(0.60, 0.95, curve: Curves.easeOutBack),
    );

    _scoreReveal = CurvedAnimation(
      parent: _heroCtrl,
      curve: const Interval(0.35, 1.00, curve: Curves.easeOutExpo),
    );

    _fxAnim = CurvedAnimation(parent: _fxCtrl, curve: Curves.linear);

    _pulse = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _crownDrop = Tween<double>(begin: -1.0, end: 0.0).animate(
      CurvedAnimation(parent: _crownCtrl, curve: Curves.bounceOut),
    );

    _pageCtrl.forward();
    if (_isSettled) _playOutcome();
  }

  @override
  void didUpdateWidget(_ResultBody oldWidget) {
    super.didUpdateWidget(oldWidget);

    // The challenge type cannot change mid-doc, but be explicit about it so a
    // late-arriving `challengeType` field can never silently swap the
    // animation under the user.
    final nextFx = _ResultFx.resolve(c, uid);
    if (nextFx.kind != _fx.kind) {
      _fx = nextFx;
      _fxCtrl.duration = _fx.heroDuration;
      _fxCtrl.reset();
    }

    final becameSettled = !oldWidget.challenge.isSettled && c.isSettled;
    if (becameSettled) _playOutcome();
  }

  /// The full outcome reveal. Called once on mount for an already-settled
  /// challenge, and again the moment resolution lands for a live one.
  void _playOutcome() {
    if (_disposed) return;
    final fx = _ResultFx.resolve(c, uid);
    _fx = fx;

    Future.delayed(const Duration(milliseconds: 140), () {
      if (!mounted || _disposed) return;

      _heroCtrl.forward(from: 0);

      // Every outcome gets an effect; only a win celebrates.
      _fxCtrl.forward(from: 0);
      if (fx.isWin) {
        _startConfetti();
        _startWinnerGlow();
      }

      _listenForPayoutAndAnimate();

      Future.delayed(const Duration(milliseconds: 550), () {
        if (mounted && !_disposed) _runAdSequence();
      });
    });
  }

  void _startWinnerGlow() {
    _pulseCtrl.repeat(reverse: true);
    _pulseStopTimer?.cancel();
    _pulseStopTimer = Timer(const Duration(milliseconds: 5200), () {
      if (!mounted || _disposed) return;
      _pulseCtrl.stop();
      _pulseCtrl.value = 0.0;
    });

    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted || _disposed) return;
      _crownCtrl.forward(from: 0);
    });
  }

  void _startConfetti() {
    _confettiHideTimer?.cancel();

    setState(() {
      _showConfetti = true;
    });

    _confettiCtrl.forward(from: 0).whenComplete(() {
      if (!mounted || _disposed) return;

      _confettiHideTimer = Timer(const Duration(milliseconds: 160), () {
        if (!mounted || _disposed) return;
        setState(() {
          _showConfetti = false;
        });
      });
    });
  }

  // ──────────────────────────────────────────────────────────────────────
  // Payout settle detection
  // ──────────────────────────────────────────────────────────────────────
  //
  // Fires the "+N AC / +N WP" credit popup once the balance actually moves.
  // Two things changed here versus the previous implementation:
  //
  //  1. It now runs for draws and for Quick Match losses too, not only wins.
  //     A Quick Match loss still credits 5 WP, and a Rival/Code draw credits
  //     a real stake refund — previously both were silently swallowed because
  //     the listener bailed on `didCurrentUserWin`.
  //  2. A watchdog bounds the wait. The old listener required BOTH balances
  //     to increase and never removed itself otherwise, so if the server-side
  //     credit ever landed at zero (soft cap, achievement rounding) the
  //     listener leaked on the provider for the life of the page and the
  //     popup never appeared.

  void _listenForPayoutAndAnimate() {
    if (_settlementRevealed || _isSpectator) return;
    if (!_isSettled) return;

    final won = _wonSomething;
    final draw = _isDrawOutcome;
    final acPayout = c.acSettlementFor(won: won, isDraw: draw);
    final wpPayout = c.wpTotalFor(won: won, isDraw: draw);

    if (acPayout <= 0 && wpPayout <= 0) return;

    final userData = context.read<UserDataProvider>();
    _payoutProvider = userData;

    final acBaseline = userData.animeCoins;
    final wpBaseline = userData.weeklyPoints;

    final expectsAc = acPayout > 0;
    final expectsWp = wpPayout > 0;

    void reveal() {
      if (!mounted || _disposed || _settlementRevealed) return;
      _settlementRevealed = true;
      setState(() {});

      _settleTimer?.cancel();
      _settleTimer = Timer(const Duration(milliseconds: 450), () {
        if (!mounted || _disposed) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          barrierColor: Colors.transparent,
          builder: (_) => _CreditDialog(
            acAmount: expectsAc ? acPayout : null,
            wpAmount: expectsWp ? wpPayout : null,
            label: _creditHeadline(won: won, isDraw: draw),
          ),
        );
      });

      userData.removeListener(_payoutListener!);
      _payoutListener = null;
      _payoutWatchdog?.cancel();
      _payoutWatchdog = null;
    }

    void onBalanceChange() {
      if (!mounted || _disposed || _settlementRevealed) return;
      final acCredited = !expectsAc || userData.animeCoins > acBaseline;
      final wpCredited = !expectsWp || userData.weeklyPoints > wpBaseline;
      if (acCredited && wpCredited) reveal();
    }

    _payoutListener = onBalanceChange;
    userData.addListener(_payoutListener!);

    // If the credit never lands (rounding, soft cap, offline), still reveal
    // so the page is never left waiting on an event that will not come.
    _payoutWatchdog?.cancel();
    _payoutWatchdog = Timer(const Duration(milliseconds: 6000), () {
      if (!mounted || _disposed || _settlementRevealed) return;
      reveal();
    });
  }

  String _creditHeadline({required bool won, required bool isDraw}) {
    if (won) return 'Credited to your balance';
    if (isDraw) return 'Refunded to your balance';
    return 'Credited to your balance';
  }

  Future<void> _runAdSequence() async {
    if (_adSequenceFired || !mounted || _disposed) return;

    _adSequenceFired = true;

    final userData = context.read<UserDataProvider>();
    userData.incrementSessionQuizCount();

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

    _confettiHideTimer?.cancel();
    _pulseStopTimer?.cancel();
    _settleTimer?.cancel();
    _adTimer?.cancel();
    _payoutWatchdog?.cancel();

    _pageCtrl.dispose();
    _heroCtrl.dispose();
    _fxCtrl.dispose();
    _pulseCtrl.dispose();
    _crownCtrl.dispose();
    _confettiCtrl.dispose();

    if (_payoutListener != null) {
      _payoutProvider?.removeListener(_payoutListener!);
      _payoutListener = null;
    }

    super.dispose();
  }

  // ──────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final kind = c.kind;
    final showOutcome = _isSettled && !_isSpectator;

    return Stack(
      children: [
        // ── Confetti overlay — wins only ──────────────────────────────
        if (showOutcome && _fx.isWin && _showConfetti)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _confettiCtrl,
                builder: (_, __) {
                  final progress = _confettiCtrl.value;
                  final fade = progress > 0.78 ? (1.0 - progress) / 0.22 : 1.0;
                  return Opacity(
                    opacity: fade.clamp(0.0, 1.0),
                    child: CustomPaint(
                      painter: _ConfettiPainter(progress: progress),
                    ),
                  );
                },
              ),
            ),
          ),

        // ── Main content ─────────────────────────────────────────────
        FadeTransition(
          opacity: _pageFade,
          child: SlideTransition(
            position: _pageSlide,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _staggered(
                    index: 0,
                    child: _ResultHeader(
                      kind: kind,
                      isSettled: _isSettled,
                      isSpectator: _isSpectator,
                    ),
                  ),
                  SizedBox(height: 16.h),

                  if (_isSpectator)
                    _staggered(index: 1, child: const _SpectatorCard())
                  else if (showOutcome) ...[
                    _staggered(
                      index: 1,
                      child: _HeroResult(
                        fx: _ResultFx.resolve(c, uid),
                        glyphScale: _glyphScale,
                        titleFade: _titleFade,
                        titleSlide: _titleSlide,
                        subtitleFade: _subtitleFade,
                        subtitleSlide: _subtitleSlide,
                        pillScale: _pillScale,
                        pulse: _pulse,
                        pulseCtrl: _pulseCtrl,
                        crownDrop: _crownDrop,
                        fxAnim: _fxAnim,
                        fxCtrl: _fxCtrl,
                        opponentName: c.opponentNameFor(uid),
                        stakeAmount: c.stakeAmount,
                        wpStake: c.wpStake ?? 0,
                      ),
                    ),
                    SizedBox(height: 18.h),
                  ] else
                    _staggered(
                      index: 1,
                      child: _PendingState(
                        challenge: c,
                        currentUid: uid,
                      ),
                    ),

                  SizedBox(height: showOutcome ? 0 : 18.h),

                  _staggered(
                    index: 2,
                    child: _VsCard(
                      challenge: c,
                      currentUid: uid,
                      isSettled: _isSettled,
                      scoreAnimation: _scoreReveal,
                      isDraw: _isDrawOutcome,
                    ),
                  ),

                  // ── Payouts: only ever shown once settled, only ever to
                  //    a participant, and always split by currency. ──
                  if (showOutcome) ...[
                    // Bounty + series banners (ranked duels only; absent otherwise).
                    if (c.bountyWinnerUid == uid && c.bountyWP > 0) ...[
                      SizedBox(height: 14.h),
                      _staggered(
                        index: 3,
                        child: _BonusBanner(
                          emoji: '🎯',
                          title: 'UPSET BOUNTY +${c.bountyWP} WP',
                          subtitle:
                              'You beat a much stronger rival. Take their crown.',
                          color: const Color(0xFFF59E0B),
                        ),
                      ),
                    ],
                    if (c.seriesWinnerUid == uid) ...[
                      SizedBox(height: 14.h),
                      _staggered(
                        index: 3,
                        child: _BonusBanner(
                          emoji: '🏆',
                          title: 'SERIES WON · +100 AC',
                          subtitle:
                              'First to 3 — series prize added to your balance.',
                          color: const Color(0xFF8B5CF6),
                        ),
                      ),
                    ],
                    SizedBox(height: 14.h),
                    _staggered(
                      index: 3,
                      child: _SettlementSection(
                        challenge: c,
                        currentUid: uid,
                      ),
                    ),
                    SizedBox(height: 12.h),
                    _staggered(
                      index: 3,
                      child: _ReactionsBar(
                        challenge: c,
                        currentUid: uid,
                      ),
                    ),
                  ],

                  SizedBox(height: 24.h),

                  _staggered(
                    index: 4,
                    child: Column(
                      children: [
                        Text(
                          'Result saved to your match history',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 10.h),
                        AppButton(
                          variant: AppButtonVariant.gradient,
                          label: 'Back to Multiplayer',
                          icon: const Icon(Icons.sports_esports_rounded),
                          onPressed: widget.onExit,
                          height: 54,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static const int _staggerCount = 5;

  Widget _staggered({required int index, required Widget child}) {
    final start = (index / _staggerCount) * 0.55;
    final end = (start + 0.45).clamp(0.0, 1.0);
    final interval = Interval(start, end, curve: Curves.easeOutCubic);

    return FadeTransition(
      opacity: CurvedAnimation(parent: _pageCtrl, curve: interval),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.05),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _pageCtrl, curve: interval)),
        child: child,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Ambient effects — one distinct effect per (type × outcome)
// ═══════════════════════════════════════════════════════════════════════════

@immutable
sealed class _AmbientFx {
  const _AmbientFx();
}

/// Rival win — expanding duel rings. The original treatment, kept for the
/// mode whose whole identity is a head-to-head.
final class _AmbientFxDuelRings extends _AmbientFx {
  const _AmbientFxDuelRings();
}

/// Code win — a QR/scan burst, because a Code Challenge is defined by a
/// shareable code. Square brackets sweep out from the centre while a scan
/// line crosses the medallion.
final class _AmbientFxQrScan extends _AmbientFx {
  const _AmbientFxQrScan();
}

/// Quick Match win — a lightning bolt crack.
final class _AmbientFxBolt extends _AmbientFx {
  const _AmbientFxBolt();
}

/// Draw — a calm double ring pulse, tinted with the mode's accent.
final class _AmbientFxTiePulse extends _AmbientFx {
  final Color tint;
  const _AmbientFxTiePulse(this.tint);
}

/// Loss — a slow descending fade, tinted with the mode's accent.
final class _AmbientFxDescent extends _AmbientFx {
  final Color tint;
  const _AmbientFxDescent(this.tint);
}

extension _AmbientFxVariant on _AmbientFx {
  Duration get duration => switch (this) {
        _AmbientFxDuelRings() => const Duration(milliseconds: 1600),
        _AmbientFxQrScan() => const Duration(milliseconds: 1500),
        _AmbientFxBolt() => const Duration(milliseconds: 1300),
        _AmbientFxTiePulse() => const Duration(milliseconds: 2200),
        _AmbientFxDescent() => const Duration(milliseconds: 2000),
      };
}

Widget _buildAmbient(
  _AmbientFx fx,
  double progress,
  Color accent, {
  required double boxSize,
}) {
  return CustomPaint(
    size: Size.square(boxSize),
    painter: switch (fx) {
      _AmbientFxDuelRings() => _BurstRingsPainter(
          progress: progress,
          color: accent,
        ),
      _AmbientFxQrScan() => _QrScanPainter(
          progress: progress,
          color: accent,
        ),
      _AmbientFxBolt() => _BoltPainter(
          progress: progress,
          color: accent,
        ),
      _AmbientFxTiePulse(:final tint) => _TieRingsPainter(
          progress: progress,
          color: tint,
        ),
      _AmbientFxDescent(:final tint) => _DescentPainter(
          progress: progress,
          color: tint,
        ),
    },
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// Header
// ═══════════════════════════════════════════════════════════════════════════

class _ResultHeader extends StatelessWidget {
  final ChallengeKind kind;
  final bool isSettled;
  final bool isSpectator;

  const _ResultHeader({
    required this.kind,
    required this.isSettled,
    required this.isSpectator,
  });

  @override
  Widget build(BuildContext context) {
    final title = isSpectator
        ? 'Match Details'
        : isSettled
            ? 'Match Result'
            : 'Match In Progress';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MULTIPLAYER',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.7,
                    ),
                  ),
                  SizedBox(height: 3.h),
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 24.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.6,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            if (isSettled && !isSpectator)
              Container(
                width: 36.r,
                height: 36.r,
                decoration: BoxDecoration(
                  color: AppColors.correct.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11.r),
                  border: Border.all(
                    color: AppColors.correct.withValues(alpha: 0.3),
                  ),
                ),
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 18.r,
                  color: AppColors.correct,
                ),
              ),
          ],
        ),
        SizedBox(height: 12.h),
        _TypeBadge(kind: kind),
      ],
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final ChallengeKind kind;

  const _TypeBadge({required this.kind});

  @override
  Widget build(BuildContext context) {
    final color = kind.accentColor;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 6.r),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20.r),
          border: Border.all(color: color.withValues(alpha: 0.32)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 20.r,
              height: 20.r,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6.r),
              ),
              child: Icon(kind.icon, color: color, size: 12.r),
            ),
            SizedBox(width: 7.w),
            Text(
              kind.label,
              style: TextStyle(
                color: color,
                fontSize: 11.5.sp,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Hero result
// ═══════════════════════════════════════════════════════════════════════════

class _HeroResult extends StatelessWidget {
  final _ResultFx fx;
  final String opponentName;
  final int stakeAmount;
  final int wpStake;

  final Animation<double> glyphScale;
  final Animation<double> titleFade;
  final Animation<Offset> titleSlide;
  final Animation<double> subtitleFade;
  final Animation<Offset> subtitleSlide;
  final Animation<double> pillScale;
  final Animation<double> pulse;
  final AnimationController pulseCtrl;
  final Animation<double> crownDrop;
  final Animation<double> fxAnim;
  final AnimationController fxCtrl;

  const _HeroResult({
    required this.fx,
    required this.opponentName,
    required this.stakeAmount,
    required this.wpStake,
    required this.glyphScale,
    required this.titleFade,
    required this.titleSlide,
    required this.subtitleFade,
    required this.subtitleSlide,
    required this.pillScale,
    required this.pulse,
    required this.pulseCtrl,
    required this.crownDrop,
    required this.fxAnim,
    required this.fxCtrl,
  });

  /// A single sentence that says exactly what happened, in words, with the
  /// amounts already in them. No "MATCH COMPLETE", no "Points Earned".
  String get _narrative {
    final k = fx.kind;
    final stakes = <String>[];

    if (k.isStaked && stakeAmount > 0) {
      stakes.add('$stakeAmount AC');
    }
    if (k.stakesWeeklyPoints && wpStake > 0) {
      stakes.add('$wpStake WP');
    }

    final stakeClause = stakes.isEmpty ? '' : ' (stake: ${stakes.join(' + ')})';

    return switch (fx.outcome) {
      ResultOutcome.win => switch (k) {
          ChallengeKind.rival =>
            'You beat $opponentName$stakeClause. Their stake is now yours.',
          ChallengeKind.code =>
            'You outscored $opponentName$stakeClause and take the pot.',
          ChallengeKind.quick =>
            'You outscored $opponentName in a Quick Match. No stake was involved.',
          ChallengeKind.spar =>
            'You outscored $opponentName in a spar. Friendly — no stakes, just glory.',
        },
      ResultOutcome.draw => switch (k) {
          ChallengeKind.rival =>
            'You and $opponentName finished level$stakeClause. The stake is refunded to both of you, less the house fee.',
          ChallengeKind.code =>
            'You and $opponentName finished level$stakeClause. The stake is refunded to both of you, less the house fee.',
          ChallengeKind.quick =>
            'You and $opponentName finished level. Quick Match draws pay a flat reward with no stake involved.',
          ChallengeKind.spar =>
            'You and $opponentName finished level in a spar. No stakes either way.',
        },
      ResultOutcome.loss => switch (k) {
          ChallengeKind.rival =>
            '$opponentName outscored you$stakeClause. Your stake goes to them.',
          ChallengeKind.code =>
            '$opponentName outscored you$stakeClause. Your stake goes to them.',
          ChallengeKind.quick =>
            '$opponentName outscored you in a Quick Match. No stake was involved, so nothing was lost.',
          ChallengeKind.spar =>
            '$opponentName outscored you in a spar. Nothing lost — run it back.',
        },
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = fx.accent;
    const boxSize = 130.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(26.r),
      child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.85),
            radius: 1.2,
            colors: [
              color.withValues(alpha: 0.22),
              color.withValues(alpha: 0.06),
              AppColors.surface,
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
          borderRadius: BorderRadius.circular(26.r),
          border: Border.all(color: color.withValues(alpha: 0.28), width: 1.2),
        ),
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Positioned(
              top: 14,
              left: 16,
              child: _CornerAccent(color: color),
            ),
            Positioned(
              top: 14,
              right: 16,
              child: _CornerAccent(color: color, mirrored: true),
            ),
            Padding(
              padding: EdgeInsets.symmetric(vertical: 30.r, horizontal: 22.r),
              child: Column(
                children: [
                  // ── Medallion ─────────────────────────────────────────
                  SizedBox(
                    width: boxSize.r,
                    height: boxSize.r,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Per-(type × outcome) ambient effect. Every win
                        // variant is a different painter; draws and losses
                        // get their own effects tinted with the mode colour,
                        // so no two of the nine combinations look alike.
                        AnimatedBuilder(
                          animation: fxCtrl,
                          builder: (_, __) => _buildAmbient(
                            fx.ambient,
                            fxAnim.value,
                            color,
                            boxSize: boxSize,
                          ),
                        ),

                        // Breathing pulse — wins only
                        if (fx.isWin)
                          AnimatedBuilder(
                            animation: pulseCtrl,
                            builder: (_, __) {
                              final scale = 1.0 + pulse.value * 0.28;
                              final opacity = (1.0 - pulse.value) * 0.35;
                              return Transform.scale(
                                scale: scale,
                                child: Container(
                                  width: 96.r,
                                  height: 96.r,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: color.withValues(alpha: opacity),
                                  ),
                                ),
                              );
                            },
                          ),

                        // Glyph disc
                        ScaleTransition(
                          scale: glyphScale,
                          child: Container(
                            width: 96.r,
                            height: 96.r,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: color.withValues(alpha: 0.14),
                              border: Border.all(
                                color: color.withValues(alpha: 0.45),
                                width: 1.6,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.35),
                                  blurRadius: 34,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                fx.glyph,
                                style: TextStyle(fontSize: 42.sp),
                              ),
                            ),
                          ),
                        ),

                        // Crown — Rival wins only. The crown is the duel
                        // trophy; a Code Challenge is won by a shared code
                        // and a Quick Match by speed, so neither wears it.
                        if (fx.isWin && fx.kind == ChallengeKind.rival)
                          AnimatedBuilder(
                            animation: crownDrop,
                            builder: (_, __) => Transform.translate(
                              offset: Offset(0, crownDrop.value * 22),
                              child: Opacity(
                                opacity:
                                    (1.0 + crownDrop.value).clamp(0.0, 1.0),
                                child: Padding(
                                  padding: EdgeInsets.only(bottom: 96.r - 18.r),
                                  child: Text('👑',
                                      style: TextStyle(fontSize: 24.sp)),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(height: 20.h),

                  // ── Headline ─────────────────────────────────────
                  FadeTransition(
                    opacity: titleFade,
                    child: SlideTransition(
                      position: titleSlide,
                      child: Text(
                        fx.headline,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: color,
                          fontSize: 38.sp,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.6,
                          height: 1,
                          shadows: fx.isWin
                              ? [
                                  Shadow(
                                    color: color.withValues(alpha: 0.35),
                                    blurRadius: 20,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 10.h),

                  // ── Narrative: the whole story in one sentence ───
                  FadeTransition(
                    opacity: subtitleFade,
                    child: SlideTransition(
                      position: subtitleSlide,
                      child: Text(
                        _narrative,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13.sp,
                          height: 1.45,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 16.h),

                  // ── Outcome pill: names the outcome, never a generic
                  //    "MATCH COMPLETE". ────────────────────────────
                  ScaleTransition(
                    scale: pillScale,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 14.r,
                        vertical: 7.r,
                      ),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(20.r),
                        border:
                            Border.all(color: color.withValues(alpha: 0.30)),
                      ),
                      child: Text(
                        switch (fx.outcome) {
                          ResultOutcome.win => 'VICTORY',
                          ResultOutcome.draw => 'DRAWN',
                          ResultOutcome.loss => 'DEFEAT',
                        },
                        style: TextStyle(
                          color: color,
                          fontSize: 10.sp,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.3,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Pending state — shown while the opponent has not finished
// ═══════════════════════════════════════════════════════════════════════════

class _PendingState extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const _PendingState({
    required this.challenge,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    final uid = currentUid;
    final myScore = challenge.scoreFor(uid);
    final opponentName = challenge.opponentNameFor(uid);

    final String title;
    final String body;
    final IconData icon;

    if (challenge.isDeclined) {
      icon = Icons.block_rounded;
      title = 'Challenge Declined';
      body =
          '$opponentName turned down this challenge. Nothing was staked and nothing was charged.';
    } else if (challenge.isGhostMatch && challenge.creatorScore == null) {
      icon = Icons.bolt_rounded;
      title = 'Quick Match Ready';
      body =
          'You are matched against $opponentName. Play the quiz to settle the result.';
    } else if (challenge.isAwaitingOpponent(uid)) {
      icon = Icons.hourglass_top_rounded;
      title = 'Waiting for $opponentName';
      body = myScore == null
          ? 'Finish the quiz to settle this challenge.'
          : 'You scored $myScore out of ${challenge.questionIds.length}. '
              'This page updates the moment $opponentName finishes.';
    } else if (challenge.isExpired) {
      icon = Icons.timer_off_rounded;
      title = 'Challenge Expired';
      body =
          'This challenge ran out of time before it was settled. Any stake was refunded.';
    } else {
      icon = Icons.hourglass_bottom_rounded;
      title = 'Settling the Result';
      body =
          'Both scores are in. The result will appear here as soon as it is confirmed.';
    }

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        children: [
          Icon(icon, size: 34, color: AppColors.primary),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 19.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 13.sp,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SpectatorCard extends StatelessWidget {
  const _SpectatorCard();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        children: [
          const Icon(Icons.visibility_rounded,
              size: 32, color: AppColors.textMuted),
          const SizedBox(height: 12),
          const Text(
            'You are not in this match',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Scores are shown, but there is nothing staked or credited to you.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 13,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// VS card
// ═══════════════════════════════════════════════════════════════════════════

class _VsCard extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;
  final bool isSettled;
  final Animation<double> scoreAnimation;
  final bool isDraw;

  const _VsCard({
    required this.challenge,
    required this.currentUid,
    required this.isSettled,
    required this.scoreAnimation,
    required this.isDraw,
  });

  @override
  Widget build(BuildContext context) {
    final creatorIsWinner = isSettled && challenge.outcome == 'creator_wins';
    final opponentIsWinner = isSettled && challenge.outcome == 'opponent_wins';

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'FINAL SCORE',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 9.5.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.4,
                ),
              ),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
                decoration: BoxDecoration(
                  color: (isSettled ? AppColors.correct : AppColors.accent)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Text(
                  isSettled ? 'RESOLVED' : 'LIVE',
                  style: TextStyle(
                    color: isSettled ? AppColors.correct : AppColors.accent,
                    fontSize: 9.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.9,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 18.h),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _PlayerColumn(
                  name: challenge.creatorUsername,
                  score: challenge.creatorScore,
                  isCurrentUser: currentUid == challenge.creatorUid,
                  isWinner: creatorIsWinner,
                  isLoser: isSettled && !isDraw && !creatorIsWinner,
                  alignRight: false,
                  scoreAnimation: scoreAnimation,
                  isDraw: isDraw,
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.w),
                child: Container(
                  width: 46.r,
                  height: 46.r,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.primary.withValues(alpha: 0.15),
                        AppColors.primary.withValues(alpha: 0.05),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14.r),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.28),
                    ),
                  ),
                  child: Text(
                    'VS',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 12.sp,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _PlayerColumn(
                  name: challenge.opponentUsername ?? 'Opponent',
                  score: challenge.opponentScore,
                  isCurrentUser: currentUid == challenge.opponentUid,
                  isWinner: opponentIsWinner,
                  isLoser: isSettled && !isDraw && !opponentIsWinner,
                  alignRight: true,
                  scoreAnimation: scoreAnimation,
                  isDraw: isDraw,
                ),
              ),
            ],
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
  final bool isLoser;
  final bool alignRight;
  final Animation<double> scoreAnimation;
  final bool isDraw;

  const _PlayerColumn({
    required this.name,
    required this.score,
    required this.isCurrentUser,
    required this.isWinner,
    required this.isLoser,
    required this.alignRight,
    required this.scoreAnimation,
    required this.isDraw,
  });

  @override
  Widget build(BuildContext context) {
    final scoreColor = isWinner
        ? AppColors.correct
        : isDraw
            ? AppColors.secondary
            : isLoser
                ? AppColors.wrong
                : AppColors.textPrimary;

    return AnimatedBuilder(
      animation: scoreAnimation,
      builder: (_, __) {
        final revealed = score ?? 0;
        final animatedScore =
            (revealed * scoreAnimation.value).round().clamp(0, revealed);

        return Column(
          crossAxisAlignment:
              alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 110),
              padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 5.r),
              decoration: BoxDecoration(
                color: isCurrentUser
                    ? AppColors.primary.withValues(alpha: 0.12)
                    : AppColors.surfaceAlt.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(9.r),
                border: Border.all(
                  color: isCurrentUser
                      ? AppColors.primary.withValues(alpha: 0.25)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isWinner) ...[
                    Text('👑', style: TextStyle(fontSize: 12.sp)),
                    SizedBox(width: 4.w),
                  ],
                  Flexible(
                    child: Text(
                      isCurrentUser ? 'You' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: alignRight ? TextAlign.right : TextAlign.left,
                      style: TextStyle(
                        color: isCurrentUser
                            ? AppColors.primary
                            : AppColors.textMuted,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 10.h),
            Stack(
              alignment: Alignment.center,
              children: [
                if (isWinner && revealed > 0)
                  Container(
                    width: 90.r,
                    height: 90.r,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          AppColors.correct.withValues(alpha: 0.22),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                AnimatedScale(
                  scale: isWinner ? 1.03 : 1.0,
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOut,
                  child: Text(
                    score == null ? '—' : '$animatedScore',
                    textAlign: alignRight ? TextAlign.right : TextAlign.left,
                    style: TextStyle(
                      color: scoreColor,
                      fontSize: 46.sp,
                      fontWeight: FontWeight.w900,
                      height: 0.96,
                      letterSpacing: -2,
                      shadows: isWinner
                          ? [
                              Shadow(
                                color:
                                    AppColors.correct.withValues(alpha: 0.42),
                                blurRadius: 18,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 4.h),
            Text(
              '/ 10',
              textAlign: alignRight ? TextAlign.right : TextAlign.left,
              style: TextStyle(
                color: AppColors.textMuted.withValues(alpha: 0.55),
                fontSize: 11.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Bonus banner — upset bounty / series win. Distinct accent styling, shown
// above the settlement only when the current user earned it.
// ═══════════════════════════════════════════════════════════════════════════
class _BonusBanner extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Color color;

  const _BonusBanner({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0.16),
            color.withValues(alpha: 0.06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Text(emoji, style: TextStyle(fontSize: 26.sp)),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Settlement — the payout block
//
// Replaces the previous _StakesSection / _StakeOutcomeCard /
// _WpStakeOutcomeCard / _QuickMatchRewardSection / _RewardBadges /
// _CoinBadge / _WpBadge stack, which between them had four problems:
//
//   1. The card titled "Points Earned" was counting up an ANIME COINS value.
//      "Points" is the Weekly Points currency — the two were conflated.
//   2. A loss showed "−{stake}" under the AC row, even though that AC was
//      already spent when the challenge was created. The page was billing the
//      player twice for one loss.
//   3. A Code Challenge loss displayed "WP Earned" / "+0" with the subtitle
//      "Bonus Weekly Points earned." — asserting a reward that the server
//      never pays (a non-Quick-Match loss credits 0 WP).
//   4. Quick Match, Rival and Code each had their own payout widget with its
//      own labels, so a change to one silently drifted from the others.
//
// Now there is exactly one payout block. It renders the AC settlement and the
// WP settlement as two separate, explicitly-currency-labelled elements, and
// splits WP further into "Rival stake" and "participation reward" whenever a
// WP stake is actually in play. A draw or a Quick Match loss renders the same
// way a win does — the old code only rendered any of this on a win.
// ═══════════════════════════════════════════════════════════════════════════

/// Preset duel reactions: 4 fixed emoji, one per user per settled challenge.
///
/// Written CF-only to challenges/{id}.reactions.{uid} (rules deny client
/// challenge writes except own-score). Shows my reaction highlighted plus the
/// other side's pick, if any. No free text, no counts.
class _ReactionsBar extends StatefulWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const _ReactionsBar({
    required this.challenge,
    required this.currentUid,
  });

  @override
  State<_ReactionsBar> createState() => _ReactionsBarState();
}

class _ReactionsBarState extends State<_ReactionsBar> {
  static const _options = ['👏', '🔥', '😅', 'GG'];
  String? _sending;
  Map<String, String>? _override;

  Future<void> _react(String emoji) async {
    if (_sending != null) return;
    setState(() => _sending = emoji);
    try {
      await FirestoreService.instance.reactToChallenge(
        challengeId: widget.challenge.challengeId,
        emoji: emoji,
      );
      if (!mounted) return;
      setState(() {
        _override = {
          ...widget.challenge.reactions,
          widget.currentUid: emoji,
        };
        _sending = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not react — try again.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reactions = _override ?? widget.challenge.reactions;
    final mine = reactions[widget.currentUid];
    String? theirs;
    for (final e in reactions.entries) {
      if (e.key != widget.currentUid) {
        theirs = e.value;
        break;
      }
    }
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.r, vertical: 12.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REACT',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          SizedBox(height: 8.h),
          Row(
            children: [
              for (final emoji in _options) ...[
                GestureDetector(
                  onTap: _sending != null ? null : () => _react(emoji),
                  child: AnimatedOpacity(
                    opacity: _sending != null && _sending != emoji ? 0.4 : 1.0,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      width: 44.w,
                      height: 44.h,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: mine == emoji
                            ? AppColors.primary.withValues(alpha: 0.16)
                            : AppColors.surfaceAlt.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12.r),
                        border: Border.all(
                          color: mine == emoji
                              ? AppColors.primary.withValues(alpha: 0.5)
                              : AppColors.divider,
                        ),
                      ),
                      child: Text(emoji,
                          style: TextStyle(fontSize: 20.sp)),
                    ),
                  ),
                ),
                SizedBox(width: 8.w),
              ],
              const Spacer(),
              if (theirs != null)
                Text(
                  'Them: $theirs',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettlementSection extends StatelessWidget {
  final ChallengeModel challenge;
  final String currentUid;

  const _SettlementSection({
    required this.challenge,
    required this.currentUid,
  });

  @override
  Widget build(BuildContext context) {
    final uid = currentUid;
    final won = challenge.didCurrentUserWin(uid);
    final isDraw = challenge.isDraw;
    final kind = challenge.kind;

    final ac = challenge.acSettlementFor(won: won, isDraw: isDraw);
    final wpStakePart =
        challenge.wpStakeSettlementFor(won: won, isDraw: isDraw);
    final wpBonus = challenge.wpBonusFor(won: won, isDraw: isDraw);
    final wpTotal = wpStakePart + wpBonus;

    return Column(
      children: [
        _CurrencyCard(
          title: 'Anime Coins',
          icon: '🪙',
          iconColor: AppColors.accent,
          headline: won
              ? '+$ac AC credited'
              : isDraw
                  ? '+$ac AC refunded'
                  : 'No Anime Coins',
          detail: _acDetail(challenge, won: won, isDraw: isDraw),
          value: ac,
          accent: won
              ? AppColors.correct
              : isDraw
                  ? AppColors.secondary
                  : AppColors.textMuted,
          muted: ac == 0,
        ),
        SizedBox(height: 10.h),
        _CurrencyCard(
          title: 'Weekly Points',
          icon: '⭐',
          iconColor: AppColors.secondary,
          headline: wpTotal > 0 ? '+$wpTotal WP credited' : 'No Weekly Points',
          detail: _wpDetail(
            challenge,
            won: won,
            isDraw: isDraw,
          ),
          value: wpTotal,
          accent: wpTotal > 0
              ? (won
                  ? AppColors.correct
                  : isDraw
                      ? AppColors.secondary
                      : AppColors.textMuted)
              : AppColors.textMuted,
          muted: wpTotal == 0,
          breakdown: wpStakePart > 0 || (kind.stakesWeeklyPoints)
              ? [
                  if (kind.stakesWeeklyPoints)
                    _BreakdownLine(
                      label: challenge.wpStake == null
                          ? 'Rival stake'
                          : 'Rival stake (${challenge.wpStake} WP)',
                      value: wpStakePart,
                      muted: wpStakePart == 0,
                    ),
                  _BreakdownLine(
                    label: isDraw
                        ? 'Draw participation reward'
                        : won
                            ? 'Win participation reward'
                            : 'Participation reward',
                    value: wpBonus,
                    muted: wpBonus == 0,
                  ),
                ]
              : null,
        ),
      ],
    );
  }

  String _acDetail(
    ChallengeModel c, {
    required bool won,
    required bool isDraw,
  }) {
    final opponent = c.opponentNameFor(currentUid);

    if (c.kind == ChallengeKind.quick) {
      if (won) return 'Flat Quick Match reward for a win. Nothing was staked.';
      if (isDraw)
        return 'Flat Quick Match reward for a draw. Nothing was staked.';
      return 'Quick Matches pay no Anime Coins for a loss. Nothing was staked.';
    }

    if (c.stakeAmount <= 0)
      return 'No Anime Coins were staked in this challenge.';

    if (won) {
      return 'Your ${c.stakeAmount} AC stake came back, plus 90% of '
          '$opponent\'s ${c.stakeAmount} AC stake.';
    }
    if (isDraw) {
      return '${c.stakeAmount} AC stake refunded to you, less the 5% house fee.';
    }
    return 'Your ${c.stakeAmount} AC stake was spent when you created this '
        'challenge and now belongs to $opponent. Nothing further is deducted.';
  }

  String _wpDetail(
    ChallengeModel c, {
    required bool won,
    required bool isDraw,
  }) {
    if (c.kind == ChallengeKind.quick) {
      if (won) return 'Flat Quick Match reward for a win.';
      if (isDraw) return 'Flat Quick Match reward for a draw.';
      return 'Flat participation credit for completing a Quick Match. This is '
          'the only mode that pays Weekly Points for a loss.';
    }

    if (!c.kind.stakesWeeklyPoints) {
      if (won) {
        return 'Code Challenges stake Anime Coins only. This is a flat reward '
            'for winning, paid on top of the Anime Coins above.';
      }
      if (isDraw) {
        return 'Code Challenges stake Anime Coins only. This is a flat reward '
            'for a draw, paid on top of the refund above.';
      }
      return 'Code Challenges stake Anime Coins only, and a loss pays no '
          'Weekly Points at all.';
    }

    final opponent = c.opponentNameFor(currentUid);
    final stake = c.wpStake ?? 0;

    if (won) {
      return 'Your $stake WP stake came back, plus 90% of $opponent\'s $stake WP '
          'stake, plus a flat win reward.';
    }
    if (isDraw) {
      return '$stake WP stake refunded, less the 10% house fee, plus a flat '
          'draw reward.';
    }
    return 'Your $stake WP stake was spent when you created this challenge and '
        'now belongs to $opponent. A loss pays no participation reward.';
  }
}

/// One currency's worth of settlement. The count-up value is always the
/// number in the headline and the icon always names the currency, so a WP
/// figure can never be read as Anime Coins or vice versa.
class _CurrencyCard extends StatelessWidget {
  final String title;
  final String icon;
  final Color iconColor;
  final String headline;
  final String detail;
  final int value;
  final Color accent;
  final bool muted;
  final List<_BreakdownLine>? breakdown;

  const _CurrencyCard({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.headline,
    required this.detail,
    required this.value,
    required this.accent,
    required this.muted,
    this.breakdown,
  });

  @override
  Widget build(BuildContext context) {
    final showCount = value > 0;

    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: (muted ? AppColors.textMuted : accent).withValues(alpha: 0.065),
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(
          color: (muted ? AppColors.textMuted : accent).withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44.r,
                height: 44.r,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13.r),
                  border: Border.all(
                    color: iconColor.withValues(alpha: 0.24),
                  ),
                ),
                child: Center(
                  child: Text(icon, style: TextStyle(fontSize: 20.sp)),
                ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: iconColor,
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                    SizedBox(height: 3.h),
                    Text(
                      headline,
                      style: TextStyle(
                        color: muted ? AppColors.textMuted : accent,
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (showCount) ...[
                SizedBox(width: 10.w),
                _CountUpText(
                  value: value,
                  prefix: '+',
                  style: TextStyle(
                    color: accent,
                    fontSize: 26.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: 10.h),
          Text(
            detail,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.5.sp,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (breakdown != null && breakdown!.isNotEmpty) ...[
            SizedBox(height: 10.h),
            const Divider(height: 1, color: AppColors.divider),
            SizedBox(height: 6.h),
            ...breakdown!.map(
              (b) => Padding(
                padding: EdgeInsets.symmetric(vertical: 3.h),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        b.label,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11.5.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      b.value > 0 ? '+${b.value}' : '0',
                      style: TextStyle(
                        color: b.muted
                            ? AppColors.textMuted.withValues(alpha: 0.7)
                            : AppColors.textPrimary,
                        fontSize: 12.5.sp,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BreakdownLine {
  final String label;
  final int value;
  final bool muted;

  const _BreakdownLine({
    required this.label,
    required this.value,
    required this.muted,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// Credit dialog
// ═══════════════════════════════════════════════════════════════════════════

class _CreditDialog extends StatefulWidget {
  final int? acAmount;
  final int? wpAmount;
  final String label;

  const _CreditDialog({
    this.acAmount,
    this.wpAmount,
    required this.label,
  });

  @override
  State<_CreditDialog> createState() => _CreditDialogState();
}

class _CreditDialogState extends State<_CreditDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _scale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut),
    );
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _ctrl.forward().then((_) {
      Future.delayed(const Duration(milliseconds: 1100), () {
        if (mounted) Navigator.of(context).pop();
      });
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasAc = (widget.acAmount ?? 0) > 0;
    final hasWp = (widget.wpAmount ?? 0) > 0;

    return Center(
      child: FadeTransition(
        opacity: _fade,
        child: ScaleTransition(
          scale: _scale,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(blurRadius: 30, color: Colors.black26)
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hasAc && hasWp
                      ? '🏆'
                      : hasWp
                          ? '⭐'
                          : '🪙',
                  style: const TextStyle(fontSize: 48),
                ),
                const SizedBox(height: 12),
                if (hasAc)
                  Text(
                    '+${widget.acAmount} AC',
                    style: const TextStyle(
                      color: Color(0xFFFBBF24),
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                if (hasAc && hasWp) const SizedBox(height: 4),
                if (hasWp)
                  Text(
                    '+${widget.wpAmount} WP',
                    style: TextStyle(
                      color: AppColors.secondary,
                      fontSize: hasAc ? 20 : 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  widget.label,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Count-up text
// ═══════════════════════════════════════════════════════════════════════════

class _CountUpText extends StatelessWidget {
  final int value;
  final String prefix;
  final TextStyle style;

  const _CountUpText({
    required this.value,
    required this.prefix,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: value.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => Text('$prefix${v.round()}', style: style),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Corner accents
// ═══════════════════════════════════════════════════════════════════════════

class _CornerAccent extends StatelessWidget {
  final Color color;
  final bool mirrored;

  const _CornerAccent({required this.color, this.mirrored = false});

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scaleX: mirrored ? -1 : 1,
      child: SizedBox(
        width: 20.r,
        height: 20.r,
        child: CustomPaint(painter: _CornerAccentPainter(color: color)),
      ),
    );
  }
}

class _CornerAccentPainter extends CustomPainter {
  final Color color;
  const _CornerAccentPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(0, size.height * 0.6)
      ..lineTo(0, 0)
      ..lineTo(size.width * 0.6, 0);

    canvas.drawPath(path, paint);
    canvas.drawCircle(
      Offset(size.width * 0.75, size.height * 0.15),
      1.6,
      Paint()..color = color.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(_CornerAccentPainter old) => old.color != color;
}

// ═══════════════════════════════════════════════════════════════════════════
// Ambient painters — one per effect
// ═══════════════════════════════════════════════════════════════════════════

/// Rival win — three expanding duel rings.
class _BurstRingsPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _BurstRingsPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const rings = 3;

    for (int i = 0; i < rings; i++) {
      final t = (progress - i * 0.18).clamp(0.0, 1.0);
      if (t <= 0) continue;

      final radius = size.width * 0.36 + t * size.width * 0.34;
      final opacity = (1.0 - t) * 0.55;

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 - t * 0.6,
      );
    }
  }

  @override
  bool shouldRepaint(_BurstRingsPainter old) =>
      old.progress != progress || old.color != color;
}

/// Code win — QR/scan burst: four corner brackets snap outward in sequence
/// while a scan line sweeps vertically across the medallion.
class _QrScanPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _QrScanPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxHalf = size.width * 0.46;

    // Corner brackets, staggered 0.12 apart.
    for (int i = 0; i < 4; i++) {
      final t = (progress - i * 0.12).clamp(0.0, 1.0);
      if (t <= 0) continue;

      final half = maxHalf * (0.35 + t * 0.65);
      final arm = maxHalf * 0.34;
      final alpha = (1.0 - t) * 0.75;

      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4 - t * 1.2
        ..strokeCap = StrokeCap.round;

      // Top-left / top-right / bottom-right / bottom-left
      final path = Path();
      if (i == 0) {
        path
          ..moveTo(center.dx - half, center.dy - half + arm)
          ..lineTo(center.dx - half, center.dy - half)
          ..lineTo(center.dx - half + arm, center.dy - half);
      } else if (i == 1) {
        path
          ..moveTo(center.dx + half - arm, center.dy - half)
          ..lineTo(center.dx + half, center.dy - half)
          ..lineTo(center.dx + half, center.dy - half + arm);
      } else if (i == 2) {
        path
          ..moveTo(center.dx + half, center.dy + half - arm)
          ..lineTo(center.dx + half, center.dy + half)
          ..lineTo(center.dx + half - arm, center.dy + half);
      } else {
        path
          ..moveTo(center.dx - half + arm, center.dy + half)
          ..lineTo(center.dx - half, center.dy + half)
          ..lineTo(center.dx - half, center.dy + half - arm);
      }

      canvas.drawPath(path, paint);
    }

    // Scan line sweeping top to bottom, fading in then out.
    const scanStart = 0.10;
    const scanEnd = 0.85;
    if (progress > scanStart && progress < scanEnd) {
      final sp =
          ((progress - scanStart) / (scanEnd - scanStart)).clamp(0.0, 1.0);
      final y = size.height * (0.06 + sp * 0.88);
      final scanAlpha = math.sin(sp * math.pi) * 0.55;

      canvas.drawLine(
        Offset(center.dx - maxHalf * 0.8, y),
        Offset(center.dx + maxHalf * 0.8, y),
        Paint()
          ..color = color.withValues(alpha: scanAlpha)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_QrScanPainter old) =>
      old.progress != progress || old.color != color;
}

/// Quick Match win — a lightning bolt crack: two jagged bolts flash outward
/// from the centre and fade fast.
class _BoltPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _BoltPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width * 0.46;

    // Two bolts, offset in time, mirrored so it reads as an electrical arc.
    for (int pass = 0; pass < 2; pass++) {
      final t = (progress - pass * 0.18).clamp(0.0, 1.0);
      if (t <= 0 || t >= 1) continue;

      final alpha = (1.0 - t) * 0.8;
      final reach = maxR * (0.3 + t * 0.7);
      final up = pass == 0;
      final dir = up ? -1.0 : 1.0;

      final path = Path()..moveTo(center.dx, center.dy + dir * reach * 0.15);

      // Zig-zag outward.
      const segments = 4;
      for (int s = 1; s <= segments; s++) {
        final f = s / segments;
        final y = center.dy + dir * reach * f;
        final jitter = (s.isEven ? 1.0 : -1.0) * maxR * 0.16 * (1.0 - f);
        path.lineTo(center.dx + jitter, y);
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(_BoltPainter old) =>
      old.progress != progress || old.color != color;
}

/// Draw — two concentric rings breathing in and out. Calm, symmetric, and
/// tinted with the mode's accent so a drawn duel, a drawn code challenge and
/// a drawn Quick Match are each recognisably their own mode.
class _TieRingsPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _TieRingsPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width * 0.44;

    // Two out-of-phase pulses.
    for (int i = 0; i < 2; i++) {
      final t = ((progress + i * 0.5) % 1.0);
      final radius = maxR * (0.55 + t * 0.45);
      final alpha = (1.0 - t) * 0.4;

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
    }

    // Static inner ring so the medallion never sits on dead space.
    canvas.drawCircle(
      center,
      maxR * 0.5,
      Paint()
        ..color = color.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_TieRingsPainter old) =>
      old.progress != progress || old.color != color;
}

/// Loss — a slow descending fade: a ring drops and dissolves downward, with
/// short downward streaks that read as "the result is closing".
class _DescentPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _DescentPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width * 0.44;

    // Ring sinking and shrinking.
    final radius = maxR * (1.0 - progress * 0.35);
    final alpha = (1.0 - progress) * 0.45;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 - progress * 0.8,
    );

    // Downward streaks, offset in time.
    const streaks = 5;
    for (int i = 0; i < streaks; i++) {
      final t = ((progress + i * 0.17) % 1.0);
      final x = center.dx + (i - streaks / 2) * maxR * 0.34;
      final y = center.dy - maxR * 0.5 + t * size.height * 0.9;
      final len = maxR * 0.30;
      final streakAlpha = (1.0 - t) * 0.22;

      canvas.drawLine(
        Offset(x, y),
        Offset(x, y + len),
        Paint()
          ..color = color.withValues(alpha: streakAlpha)
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_DescentPainter old) =>
      old.progress != progress || old.color != color;
}

// ═══════════════════════════════════════════════════════════════════════════
// Confetti painter
// ═══════════════════════════════════════════════════════════════════════════

class _ConfettiPainter extends CustomPainter {
  final double progress;

  static final math.Random _rand = math.Random(42);

  static final List<_Particle> _particles = List.generate(
    72,
    (index) => _Particle(
      x: _rand.nextDouble(),
      startY: -0.12 - _rand.nextDouble() * 0.42,
      speed: 0.40 + _rand.nextDouble() * 0.80,
      size: 4 + _rand.nextDouble() * 8,
      color: _colors[index % _colors.length],
      rotation: _rand.nextDouble() * math.pi * 2,
      shape: _Shape.values[index % _Shape.values.length],
      drift: (_rand.nextDouble() - 0.5) * 0.24,
      wobbleSpeed: 2.5 + _rand.nextDouble() * 2.0,
    ),
  );

  static const List<Color> _colors = [
    Color(0xFF7C3AED),
    Color(0xFF60A5FA),
    Color(0xFF34D399),
    Color(0xFFFBBF24),
    Color(0xFFF472B6),
    Color(0xFFA78BFA),
    Color(0xFFFF6B6B),
    Color(0xFFE63946),
    Color(0xFF4EA8DE),
  ];

  const _ConfettiPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    for (final particle in _particles) {
      final y = particle.startY + progress * particle.speed;

      if (y < -0.15 || y > 1.15) continue;

      final wave = math.sin(
        progress * math.pi * particle.wobbleSpeed + particle.rotation,
      );

      final x = (particle.x + wave * particle.drift) * size.width;
      final py = y * size.height;

      final fadeIn = (y / 0.15).clamp(0.0, 1.0);
      final fadeOut =
          y < 0.85 ? 1.0 : (1.0 - (y - 0.85) / 0.30).clamp(0.0, 1.0);
      final alpha = fadeIn * fadeOut;

      final paint = Paint()
        ..color = particle.color.withValues(alpha: 0.9 * alpha);

      canvas.save();
      canvas.translate(x, py);
      canvas.rotate(particle.rotation + progress * math.pi * 5);

      switch (particle.shape) {
        case _Shape.rect:
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset.zero,
                width: particle.size,
                height: particle.size * 0.48,
              ),
              Radius.circular(particle.size * 0.18),
            ),
            paint,
          );
          break;
        case _Shape.circle:
          canvas.drawCircle(Offset.zero, particle.size * 0.42, paint);
          break;
        case _Shape.triangle:
          final path = Path()
            ..moveTo(0, -particle.size * 0.5)
            ..lineTo(particle.size * 0.5, particle.size * 0.4)
            ..lineTo(-particle.size * 0.5, particle.size * 0.4)
            ..close();
          canvas.drawPath(path, paint);
          break;
        case _Shape.star:
          final path = _starPath(
            center: Offset.zero,
            outer: particle.size * 0.55,
            inner: particle.size * 0.24,
            points: 5,
          );
          canvas.drawPath(path, paint);
          break;
      }

      canvas.restore();
    }
  }

  Path _starPath({
    required Offset center,
    required double outer,
    required double inner,
    required int points,
  }) {
    final path = Path();
    final step = math.pi / points;
    var angle = -math.pi / 2;

    path.moveTo(
      center.dx + outer * math.cos(angle),
      center.dy + outer * math.sin(angle),
    );

    for (int i = 0; i < points * 2; i++) {
      angle += step;
      final r = i.isEven ? inner : outer;
      path.lineTo(
        center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle),
      );
    }

    path.close();
    return path;
  }

  @override
  bool shouldRepaint(_ConfettiPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

enum _Shape { rect, circle, triangle, star }

class _Particle {
  final double x;
  final double startY;
  final double speed;
  final double size;
  final Color color;
  final double rotation;
  final _Shape shape;
  final double drift;
  final double wobbleSpeed;

  const _Particle({
    required this.x,
    required this.startY,
    required this.speed,
    required this.size,
    required this.color,
    required this.rotation,
    required this.shape,
    required this.drift,
    required this.wobbleSpeed,
  });
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
            const Text(
              'Challenge not found',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'It may have been deleted or already expired.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                height: 1.4,
              ),
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
