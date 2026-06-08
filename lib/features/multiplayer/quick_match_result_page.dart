// lib/features/multiplayer/quick_match_result_page.dart
//
// [DEV-AD-08] Quick Match result screen.
//
// What changed (Stage 12 wiring):
//   • Constructor now accepts wpEarned (WP from submitQuickMatchResult),
//     isGhost (true when matched against a recorded session), and
//     opponentScore (renamed from opponentCorrect — same semantic value,
//     clearer name since it's the opponent's correct-answer count).
//   • WP badge displayed alongside the AC badge when wpEarned > 0.
//   • Ghost label ("You played a recorded match") shown below the opponent
//     name column when isGhost == true.
//   • Real-opponent quick matches arrive with opponentScore = 0 and
//     wpEarned = 0 (async resolution via resolveChallengeOutcome trigger).
//     The result page shows the player's score and outcome; WP / AC are
//     awarded in the background and reflected on the next app open.
//
// Ghost-pool fix (BUG: saveGhostSession never called):
//   • Constructor now also requires animeTitle, questionIds, and answers.
//   • _saveGhostSession() fires once from initState (fire-and-forget) and
//     calls the saveGhostSession CF with the local player's session data.
//     This applies to BOTH real and ghost matches — every completed QM is a
//     valid pool entry. Errors are swallowed silently (non-fatal).
//
// Ad loop follows the corrected [DEV-AD-05] spec:
//   • Rewarded interstitial — all users, zero coin credit in onRewarded.
//   • Regular interstitial  — non-Premium, every 3rd session quiz, sequential.
// Quiz tally: increments sessionQuizCount + totalMatchesPlayed (+ totalMatchesWon
// when the local player wins).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/services/ad_service.dart';
import '../../core/providers/user_data_provider.dart';
import 'multiplayer_hub_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Result screen shown at the end of a Quick Match round.
///
/// Parameters
/// ----------
/// [localCorrect]   Number of questions the local player answered correctly.
/// [opponentScore]  Opponent's correct-answer count.
///                  Ghost matches: the stored ghost score returned by CF.
///                  Real-opponent matches: 0 (opponent hasn't played yet).
/// [totalQuestions] Total questions in the match (same for both players).
/// [opponentName]   Display name of the opponent (ghost username or real player).
/// [coinsEarned]    Anime Coins awarded immediately (ghost: 35 / 15 / 0;
///                  real: 0 — resolveChallengeOutcome handles it).
/// [wpEarned]       Weekly Points awarded immediately (ghost: 35 / 15 / 5;
///                  real: 0 — resolveChallengeOutcome handles it).
/// [isGhost]        True when the opponent is a recorded ghost session. Shows
///                  "You played a recorded match" label below the opponent column.
/// [animeTitle]     The anime this match was played on. Forwarded to
///                  saveGhostSession so the session lands in the right pool bucket.
/// [questionIds]    The 10 question document IDs used in this match. Required by
///                  saveGhostSession so future ghost opponents see the same set.
/// [answers]        The local player's selected answer index for each question
///                  (0-3, or -1 for skipped). Required by saveGhostSession.
class QuickMatchResultPage extends StatefulWidget {
  final int    localCorrect;
  final int    opponentScore;
  final int    totalQuestions;
  final String opponentName;
  final int    coinsEarned;
  final int    wpEarned;
  final bool   isGhost;

  // ── Ghost-pool replenishment ───────────────────────────────────────────────
  // These three fields are forwarded verbatim to the saveGhostSession CF so
  // this player's session is recorded and future QM users can be matched
  // against it.  They are required — callers already hold all three values
  // from the submitQuickMatchResult response / the questions page.
  final String       animeTitle;
  final List<String> questionIds;
  final List<int>    answers;

  const QuickMatchResultPage({
    super.key,
    required this.localCorrect,
    required this.opponentScore,
    required this.totalQuestions,
    this.opponentName = 'Opponent',
    this.coinsEarned  = 0,
    this.wpEarned     = 0,
    this.isGhost      = false,
    // Ghost-pool replenishment — always required.
    required this.animeTitle,
    required this.questionIds,
    required this.answers,
  });

  @override
  State<QuickMatchResultPage> createState() => _QuickMatchResultPageState();
}

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────

class _QuickMatchResultPageState extends State<QuickMatchResultPage>
    with SingleTickerProviderStateMixin {
  // ── Entrance animations ────────────────────────────────────────────────────
  late AnimationController _ctrl;
  late Animation<double>   _scaleAnim;
  late Animation<double>   _fadeAnim;

  /// Guards navigation so we never push/pop more than once.
  bool _navigating = false;

  /// Guards saveGhostSession so it fires exactly once per result page.
  bool _ghostSessionSaved = false;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _scaleAnim = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fadeAnim  = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // ── 1. Completion coin animation ───────────────────────────────────────
      // Fires at 400 ms so the score UI has settled before the overlay appears.
      if (widget.coinsEarned > 0) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) CoinEarnAnimation.show(context, amount: widget.coinsEarned);
        });
      }

      // ── 2. Ad sequence (DEV-AD-05 compliant) + tally increments ───────────
      _runAdSequence();

      // ── 3. Ghost-pool replenishment (fire-and-forget) ──────────────────────
      // Always save regardless of whether this match was real or ghost —
      // every completed QM session is a valid pool entry for future players.
      _saveGhostSession();
    });
  }

  // ── Ad sequence ─────────────────────────────────────────────────────────────
  Future<void> _runAdSequence() async {
    if (!mounted) return;

    final userData = context.read<UserDataProvider>();

    // Let the player see their result before any ad.
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    await AdService.instance.recordResultAndMaybeShowInterstitial(
      isPremium: userData.premiumActive,
    );
  }

  // ── Ghost-pool replenishment ─────────────────────────────────────────────────
  //
  // Saves this player's QM session to the ghost_sessions pool so future players
  // can be matched against it when the real-time queue is empty.
  //
  // Design notes:
  //   • Fire-and-forget — we unawaited-call this and never block the UI on it.
  //   • Exactly-once — the _ghostSessionSaved flag prevents a second call if
  //     the widget somehow rebuilds before the user navigates away.
  //   • Silent on error — a failed save is not user-visible; the pool will just
  //     be replenished on the next successful match instead.
  Future<void> _saveGhostSession() async {
    if (_ghostSessionSaved) return;
    _ghostSessionSaved = true;

    try {
      if (!mounted) return;

      // UserDataProvider does not expose a username getter — read it from
      // FirebaseAuth directly, matching what joinMatchmakingQueue does on the
      // CF side when it looks up the user document.
      final username =
          FirebaseAuth.instance.currentUser?.displayName ?? 'Anonymous';

      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('saveGhostSession')
          .call<Map<String, dynamic>>({
        'animeTitle':  widget.animeTitle,
        'questionIds': widget.questionIds,
        'answers':     widget.answers,
        'score':       widget.localCorrect,
        'username':    username,
      });

      debugPrint('[QuickMatchResultPage] saveGhostSession ✓ '
          'anime=${widget.animeTitle} score=${widget.localCorrect}/10');
    } catch (e) {
      // Non-fatal — ghost pool will grow from the next successful match.
      debugPrint('[QuickMatchResultPage] saveGhostSession failed (non-fatal): $e');
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ── Derived state helpers ──────────────────────────────────────────────────

  _MatchOutcome get _outcome {
    if (widget.localCorrect > widget.opponentScore) return _MatchOutcome.win;
    if (widget.localCorrect < widget.opponentScore) return _MatchOutcome.loss;
    return _MatchOutcome.draw;
  }

  _Tier get _tier {
    final ratio = widget.localCorrect / widget.totalQuestions;
    if (ratio == 1.0) return _Tier.perfect;
    if (ratio >= 0.8) return _Tier.great;
    if (ratio >= 0.5) return _Tier.good;
    return _Tier.keepPracticing;
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _goHome() {
    if (_navigating) return;
    _navigating = true;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _playAgain() {
    if (_navigating) return;
    _navigating = true;
    // Pop everything except the home root, then push the multiplayer hub so
    // the user lands directly back in the QM flow rather than at home.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MultiplayerHubPage()),
      (r) => r.isFirst,
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (_) => _goHome(),
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const SizedBox(height: 32),

                    // ── Outcome banner ─────────────────────────────────────
                    // Ghost matches: show immediate win/loss/draw result.
                    // Real-opponent matches: opponent hasn't played yet —
                    // suppress the outcome banner and show a pending notice
                    // instead to avoid showing a misleading result.
                    ScaleTransition(
                      scale: _scaleAnim,
                      child: widget.isGhost
                          ? Column(
                              children: [
                                Text(
                                  _outcome.emoji,
                                  style: const TextStyle(fontSize: 72),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _outcome.title,
                                  style: const TextStyle(
                                    color:      AppColors.textPrimary,
                                    fontSize:   28,
                                    fontWeight: FontWeight.w900,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _outcome.subtitle,
                                  style: const TextStyle(
                                    color:    AppColors.textSecondary,
                                    fontSize: 14,
                                    height:   1.5,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                const Text('⏳',
                                    style: TextStyle(fontSize: 72)),
                                const SizedBox(height: 16),
                                const Text(
                                  'Match in Progress',
                                  style: TextStyle(
                                    color:      AppColors.textPrimary,
                                    fontSize:   28,
                                    fontWeight: FontWeight.w900,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Waiting for your opponent to finish.\n'
                                  'Rewards land automatically when they\'re done.',
                                  style: TextStyle(
                                    color:    AppColors.textSecondary,
                                    fontSize: 14,
                                    height:   1.5,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                    ),

                    const SizedBox(height: 36),

                    // ── Head-to-head score card ────────────────────────────
                    GlassCard(
                      borderColor: _outcome.accentColor.withOpacity(0.4),
                      child: Column(
                        children: [
                          // ── Versus row ─────────────────────────────────
                          Row(
                            children: [
                              _PlayerScore(
                                label:  'You',
                                score:  widget.localCorrect,
                                total:  widget.totalQuestions,
                                color:  _outcome.accentColor,
                                isLeft: true,
                              ),
                              Expanded(
                                child: Center(
                                  child: Text(
                                    'VS',
                                    style: TextStyle(
                                      color:      AppColors.textMuted
                                          .withOpacity(0.5),
                                      fontSize:   18,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                              ),
                              // ── Opponent column + optional ghost label ───
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  _PlayerScore(
                                    label:  widget.opponentName,
                                    score:  widget.opponentScore,
                                    total:  widget.totalQuestions,
                                    color:  AppColors.textMuted,
                                    isLeft: false,
                                  ),
                                  if (widget.isGhost) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: AppColors.textMuted
                                            .withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: AppColors.textMuted
                                              .withOpacity(0.25),
                                        ),
                                      ),
                                      child: const Text(
                                        'Recorded match',
                                        style: TextStyle(
                                          color:      AppColors.textMuted,
                                          fontSize:   10,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),

                          const SizedBox(height: 20),

                          // ── Local player accuracy bar ──────────────────
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value:           widget.localCorrect /
                                               widget.totalQuestions,
                              backgroundColor: AppColors.divider,
                              valueColor: AlwaysStoppedAnimation(
                                  _outcome.accentColor),
                              minHeight: 10,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              '${widget.localCorrect}/${widget.totalQuestions} correct',
                              style: const TextStyle(
                                color:    AppColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ),

                          const SizedBox(height: 20),

                          // ── Points / pending notice ────────────────────
                          // Ghost: show actual WP earned (from CF).
                          // Real:  opponent hasn't played yet, so no award
                          //        yet. Show a "pending" pill instead of a
                          //        number that would be wrong.
                          if (widget.isGhost && widget.wpEarned > 0) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: AppColors.accent.withOpacity(0.3)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.stars_rounded,
                                      color: AppColors.accent, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    '+${widget.wpEarned} pts added to your balance',
                                    style: const TextStyle(
                                      color:      AppColors.accent,
                                      fontSize:   14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else if (!widget.isGhost) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: AppColors.textMuted.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color:
                                        AppColors.textMuted.withOpacity(0.2)),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.hourglass_top_rounded,
                                      color: AppColors.textMuted, size: 18),
                                  SizedBox(width: 8),
                                  Text(
                                    'Rewards pending opponent\'s result',
                                    style: TextStyle(
                                      color:      AppColors.textMuted,
                                      fontSize:   13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          // ── Weekly Points badge (ghost / immediate) ────
                          if (widget.wpEarned > 0) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF6366F1).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: const Color(0xFF6366F1)
                                        .withOpacity(0.35)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.trending_up_rounded,
                                      color: Color(0xFF818CF8), size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    '+${widget.wpEarned} WP earned!',
                                    style: const TextStyle(
                                      color:      Color(0xFF818CF8),
                                      fontSize:   14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          // ── Anime Coins badge ─────────────────────────
                          if (widget.coinsEarned > 0) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFBBF24).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: const Color(0xFFFBBF24)
                                        .withOpacity(0.35)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text('🪙',
                                      style: TextStyle(fontSize: 18)),
                                  const SizedBox(width: 8),
                                  Text(
                                    '+${widget.coinsEarned} coins earned!',
                                    style: const TextStyle(
                                      color:      Color(0xFFFBBF24),
                                      fontSize:   14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ── Performance tier nudge (low score) ────────────────
                    if (widget.localCorrect < (widget.totalQuestions ~/ 2))
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color:        AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border:       Border.all(color: AppColors.divider),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline_rounded,
                                color: AppColors.textMuted, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _tier.nudge,
                                style: const TextStyle(
                                  color:    AppColors.textSecondary,
                                  fontSize: 13,
                                  height:   1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 32),

                    // ── Actions ───────────────────────────────────────────

                    // Play Again
                    GestureDetector(
                      onTap: _playAgain,
                      child: Container(
                        width:  double.infinity,
                        height: 52,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF5B2D8E), Color(0xFF7B4FBB)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color:      const Color(0xFF7B4FBB)
                                  .withOpacity(0.35),
                              blurRadius: 16,
                              offset:     const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.replay_rounded,
                                color: Colors.white, size: 18),
                            SizedBox(width: 8),
                            Text(
                              'Play Again',
                              style: TextStyle(
                                color:      Colors.white,
                                fontSize:   15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Back to Home
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _goHome,
                        icon: const Icon(Icons.home_rounded,
                            color: AppColors.textSecondary, size: 18),
                        label: const Text(
                          'Back to Home',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          side: const BorderSide(color: AppColors.divider),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Displays one side of the head-to-head score (local player or opponent).
class _PlayerScore extends StatelessWidget {
  final String label;
  final int    score;
  final int    total;
  final Color  color;

  /// `true` = left-aligned (local player), `false` = right-aligned (opponent).
  final bool   isLeft;

  const _PlayerScore({
    required this.label,
    required this.score,
    required this.total,
    required this.color,
    required this.isLeft,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment:
            isLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: TextStyle(
              color:      color,
              fontSize:   13,
              fontWeight: FontWeight.w700,
            ),
            maxLines:  1,
            overflow:  TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            '$score',
            style: TextStyle(
              color:      color,
              fontSize:   52,
              fontWeight: FontWeight.w900,
              height:     1,
            ),
          ),
          Text(
            '/ $total',
            style: TextStyle(
              color:    AppColors.textMuted.withOpacity(0.6),
              fontSize: 13,
            ),
          ),
        ],
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Match outcome enum
// ─────────────────────────────────────────────────────────────────────────────

enum _MatchOutcome { win, loss, draw }

extension _MatchOutcomeProps on _MatchOutcome {
  String get emoji {
    switch (this) {
      case _MatchOutcome.win:  return '🏆';
      case _MatchOutcome.loss: return '💀';
      case _MatchOutcome.draw: return '🤝';
    }
  }

  String get title {
    switch (this) {
      case _MatchOutcome.win:  return 'You Won!';
      case _MatchOutcome.loss: return 'Defeated!';
      case _MatchOutcome.draw: return 'It\'s a Draw!';
    }
  }

  String get subtitle {
    switch (this) {
      case _MatchOutcome.win:
        return 'Dominant performance. The crown is yours.';
      case _MatchOutcome.loss:
        return 'Close fight. One more match and the tables turn.';
      case _MatchOutcome.draw:
        return 'Evenly matched — rematch to break the tie?';
    }
  }

  Color get accentColor {
    switch (this) {
      case _MatchOutcome.win:  return AppColors.correct;
      case _MatchOutcome.loss: return AppColors.wrong;
      case _MatchOutcome.draw: return AppColors.secondary;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Performance tier enum (accuracy-based)
// ─────────────────────────────────────────────────────────────────────────────

enum _Tier { perfect, great, good, keepPracticing }

extension _TierProps on _Tier {
  String get nudge {
    switch (this) {
      case _Tier.perfect:
      case _Tier.great:
        return 'Great accuracy — keep it up!';
      case _Tier.good:
        return 'Decent run. One more match and you\'re climbing the ranks.';
      case _Tier.keepPracticing:
        return 'Struggling? Solo mode is great for drilling weak spots.';
    }
  }
}