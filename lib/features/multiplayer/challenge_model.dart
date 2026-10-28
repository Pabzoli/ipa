import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Challenge kind — the single source of truth for "which multiplayer mode is
// this?", shared by every page.
//
// This replaces three separate, subtly different private helpers that used to
// each decide "is this a Rival Challenge?" on their own:
//
//   • challenge_lobby_page.dart  _isRivalChallenge()  (x2, at lines 111 & 281)
//   • challenge_lobby_page.dart  _ChallengeDetailsCard.hasRival
//   • challenge_result_page.dart _isRivalChallenge
//
// All three now read `c.kind` / `kind` instead.
//
// They disagreed on the Quick Match check, which is why a Quick Match badge
// fell through to "📤 Code Challenge" in the lobby while the result page got
// it right. There is now exactly one implementation, below.
// ═══════════════════════════════════════════════════════════════════════════

enum ChallengeKind {
  /// A 1v1 duel against a pre-assigned opponent. Dual-currency stake: Anime
  /// Coins (stakeAmount) AND Weekly Points (wpStake).
  rival,

  /// Shared by a code. Single-currency stake: Anime Coins only, plus a flat
  /// Weekly Points participation reward on a win or draw.
  code,

  /// Fast match vs. a ghost. No stake at all — flat AC and WP rewards only.
  quick,

  /// Friendly unranked duel vs a named rival. Zero stakes, zero WP at risk —
  /// a flat 5 WP on a win (inside the daily spar budget), nothing otherwise.
  /// Never touches series score or win stats.
  spar,
}

extension ChallengeKindX on ChallengeKind {
  String get label => switch (this) {
        ChallengeKind.rival => '⚔️ Rival Challenge',
        ChallengeKind.code => '📤 Code Challenge',
        ChallengeKind.quick => '⚡ Quick Match',
        ChallengeKind.spar => '🤝 Spar',
      };

  /// Short form for dense chips.
  String get shortLabel => switch (this) {
        ChallengeKind.rival => 'Rival',
        ChallengeKind.code => 'Code',
        ChallengeKind.quick => 'Quick Match',
        ChallengeKind.spar => 'Spar',
      };

  Color get accentColor => switch (this) {
        ChallengeKind.rival => AppColors.rival,
        ChallengeKind.code => AppColors.secondary,
        ChallengeKind.quick => AppColors.primary,
        ChallengeKind.spar => AppColors.correct,
      };

  IconData get icon => switch (this) {
        ChallengeKind.rival => Icons.sports_martial_arts_rounded,
        ChallengeKind.code => Icons.qr_code_rounded,
        ChallengeKind.quick => Icons.bolt_rounded,
        ChallengeKind.spar => Icons.sports_mma_rounded,
      };

  /// True when the mode puts a real currency at risk that was already deducted
  /// at create/join time. Only Rival and Code are "staked" — Quick Match and
  /// Spar are always free-to-enter, so their result copy must never talk
  /// about a stake.
  bool get isStaked => this == ChallengeKind.rival || this == ChallengeKind.code;

  /// True when the mode additionally risks Weekly Points. Rival stakes both
  /// currencies; Code stakes AC only.
  bool get stakesWeeklyPoints => this == ChallengeKind.rival;
}

// ─── Status enum ──────────────────────────────────────────────────────────────
enum ChallengeStatus {
  waiting,
  opponentJoined,
  creatorSubmitted,
  opponentSubmitted,
  completed,
  expired,
  expiredRefunded,
  ghost,
  declined,
}

extension ChallengeStatusX on ChallengeStatus {
  /// Every literal the backend can write to `challenges/{id}.status`.
  ///
  /// `'declined'` is written by declineChallenge (index.js:2212) and was
  /// previously missing here, so it silently parsed as `waiting` — which made
  /// a dead challenge render as "Pending — Accept to play" on a screen whose
  /// own accept button was disabled, leaving the invitee stuck.
  static ChallengeStatus parse(String? s) => switch (s) {
        'opponent_joined' => ChallengeStatus.opponentJoined,
        'creator_submitted' => ChallengeStatus.creatorSubmitted,
        'opponent_submitted' => ChallengeStatus.opponentSubmitted,
        'completed' => ChallengeStatus.completed,
        'expired' => ChallengeStatus.expired,
        'expired_refunded' => ChallengeStatus.expiredRefunded,
        'ghost' => ChallengeStatus.ghost,
        'declined' => ChallengeStatus.declined,
        _ => ChallengeStatus.waiting,
      };
}

// ─── Model ────────────────────────────────────────────────────────────────────
class ChallengeModel {
  final String challengeId;
  final String creatorUid;
  final String creatorUsername;
  final String? opponentUid;
  final String? opponentUsername;
  final int stakeAmount;
  final int? wpStake; // WP stake (only for rival challenges)
  final String? wpOutcome; // 'win', 'draw', 'lose' for WP (optional)
  final String animeTitle;
  final List<String> questionIds;
  final int? creatorScore;
  final int? opponentScore;
  final ChallengeStatus status;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String? outcome; // "creator_wins" | "opponent_wins" | "draw"
  final bool isQuickMatch;
  final String challengeType; // 'quick' | 'code' | 'rival' | 'spar'

  /// Upset-bounty winner (ranked rival duels only), written at resolve time.
  final String? bountyWinnerUid;
  final int bountyWP;

  /// Rivalry-series state snapshot at resolve time (ranked duels only).
  final int seriesNo;
  final String? seriesWinnerUid;

  /// Whether the +100 AC series prize was actually paid (false when the
  /// 7-day anti-farm gate suppressed it). Written by _resolveChallengeCore.
  final bool seriesPrizePaid;

  const ChallengeModel({
    required this.challengeId,
    required this.creatorUid,
    required this.creatorUsername,
    this.opponentUid,
    this.opponentUsername,
    required this.stakeAmount,
    this.wpStake,
    this.wpOutcome,
    required this.animeTitle,
    required this.questionIds,
    this.creatorScore,
    this.opponentScore,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.outcome,
    this.isQuickMatch = false,
    required this.challengeType,
    this.bountyWinnerUid,
    this.bountyWP = 0,
    this.seriesNo = 0,
    this.seriesWinnerUid,
    this.seriesPrizePaid = false,
  });

  // ── Kind ───────────────────────────────────────────────────────────────
  /// Which of the four multiplayer modes this challenge belongs to.
  ///
  /// `isQuickMatch` is tested first because it is the one field the backend
  /// sets on every Quick Match document from creation (joinMatchmakingQueue).
  /// string. `challengeType` is written as 'rival' | 'code' | 'quick' | 'spar'
  /// and is only a *final* value — it is stamped at resolve time
  /// (_resolveChallengeCore) and by saveGhostSession, so an in-flight
  /// document falls back to the wpStake + opponent shape below. Spar docs
  /// carry the explicit type from creation (createChallenge), so they
  /// resolve before any fallback is consulted.
  ChallengeKind get kind {
    if (isQuickMatch == true) return ChallengeKind.quick;
    if (challengeType == 'quick') return ChallengeKind.quick;
    if (challengeType == 'spar') return ChallengeKind.spar;
    if (challengeType == 'rival' ||
        ((wpStake ?? 0) > 0 && opponentUid != null)) {
      return ChallengeKind.rival;
    }
    return ChallengeKind.code;
  }

  bool get isRivalChallenge => kind == ChallengeKind.rival;
  bool get isCodeChallenge => kind == ChallengeKind.code;
  bool get isQuickMatchChallenge => kind == ChallengeKind.quick;
  bool get isSparChallenge => kind == ChallengeKind.spar;

  /// True when Weekly Points are at stake (Rival only). Drives whether the
  /// result page splits WP into "stake settlement" + "participation reward".
  bool get hasWpStake => (wpStake ?? 0) > 0;

  // ── Derived helpers ──────────────────────────────────────────────────────
  bool get isExpired =>
      status == ChallengeStatus.expired ||
      status == ChallengeStatus.expiredRefunded ||
      (DateTime.now().isAfter(expiresAt) &&
          status != ChallengeStatus.completed);

  bool get isCompleted => status == ChallengeStatus.completed;
  bool get isDraw => outcome == 'draw';

  bool get isDeclined => status == ChallengeStatus.declined;

  /// Quick Match is always played against a ghost sentinel rather than a real
  /// opponent. The lobby used to infer this from `opponentUid == 'ghost'`
  /// while the backend separately stored `status: 'ghost'`; both are checked
  /// here so neither notion can drift.
  bool get isGhostMatch =>
      opponentUid == 'ghost' || status == ChallengeStatus.ghost;

  /// `completed` AND an outcome was actually written. The result page gates
  /// its entire resolved layout on this — an expired or declined challenge has
  /// no outcome and must never be shown as a win, loss or draw.
  bool get isSettled => isCompleted && outcome != null;

  /// The user finished but the opponent has not, so no outcome exists yet.
  /// This is the state the result page is entered in when the creator submits
  /// first, and it must read as "waiting", never as "calculating".
  bool hasSubmittedScore(String uid) =>
      uid == creatorUid ? creatorScore != null : opponentScore != null;

  bool opponentHasSubmittedScore(String uid) =>
      uid == creatorUid ? opponentScore != null : creatorScore != null;

  bool isAwaitingOpponent(String uid) =>
      isParticipant(uid) &&
      hasSubmittedScore(uid) &&
      !opponentHasSubmittedScore(uid) &&
      !isSettled;

  bool isParticipant(String uid) => uid == creatorUid || uid == opponentUid;

  /// This user's own score, or null before they have played.
  int? scoreFor(String uid) => uid == creatorUid
      ? creatorScore
      : (uid == opponentUid ? opponentScore : null);

  /// The name of the *other* player, for result/lobby copy.
  String opponentNameFor(String uid) =>
      uid == creatorUid ? (opponentUsername ?? 'Opponent') : creatorUsername;

  /// Returns the UID of the winner, or null for a draw/unresolved challenge.
  String? winnerUid({required String currentUid}) {
    if (outcome == null || outcome == 'draw') return null;
    if (outcome == 'creator_wins') return creatorUid;
    if (outcome == 'opponent_wins') return opponentUid;
    return null;
  }

  bool didCurrentUserWin(String currentUid) =>
      winnerUid(currentUid: currentUid) == currentUid;

  Duration get timeRemaining {
    final diff = expiresAt.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  // ═════════════════════════════════════════════════════════════════════
  // Payout math.
  //
  // All three modes funnel through the instance getters at the bottom of
  // this section, so a page can never pair a WP number with an "Anime Coins"
  // label again. Every constant here mirrors _resolveChallengeCore /
  // submitQuickMatchResult in functions/index.js.
  // ═════════════════════════════════════════════════════════════════════

  // ── House rake, AC stake (r = 5% of the stake) ─────────────────────────
  // Win  -> stake returned + 90% of the opponent's stake, both paid to winner
  // Draw -> each side refunded 95% (5% fee each)
  // Loss -> nothing further; the stake was already deducted at stake time.
  static int acStakeWin(int stake) => stake + (stake * 0.9).floor();

  /// NOTE: this is `floor(stake * 0.95)`, not `stake - floor(stake * 0.05)`.
  /// The two disagree by 1 on any stake that is not a multiple of 20 — the
  /// old Dart form showed a 23-coin draw as +22 when the server credited 21.
  static int acStakeDraw(int stake) => (stake * 0.95).floor();

  static int acStakeLose(int stake) => 0;

  // ── House rake, WP stake (Rival only — a 10% draw fee, not 5%) ─────────
  static int wpStakeWin(int wpStake) => wpStake + (wpStake * 0.9).floor();
  static int wpStakeDraw(int wpStake) => (wpStake * 0.9).floor();
  static int wpStakeLose(int wpStake) => 0;

  // ── Flat Weekly Points participation reward, independent of any stake ──
  static const int challengeWinWpBonus = 50;
  static const int challengeDrawWpBonus = 25;
  static const int challengeLoseWpBonus = 0;

  // ── Spar flat reward (mirrors SPAR_WP_WIN in functions/index.js) ─────────
  // Spars pay 5 WP on a win while inside the daily spar budget, nothing
  // otherwise. Change both together.
  static const int sparWinWpBonus = 5;
  static const int sparDrawWpBonus = 0;
  static const int sparLoseWpBonus = 0;

  // ── Quick Match flat rewards (no stake involved at all) ─────────────────
  static const int quickMatchAcWin = 35;
  static const int quickMatchAcDraw = 15;
  static const int quickMatchAcLose = 0;
  static const int quickMatchWpWin = 35;
  static const int quickMatchWpDraw = 15;

  /// Quick Match is the only mode that pays WP for a loss — a 5 WP
  /// participation credit. Every other mode pays 0 on a loss.
  static const int quickMatchWpLose = 5;

  // ── Legacy aliases ──────────────────────────────────────────────────────
  // Retained because the result page's payout listener still references the
  // old names; they now simply delegate so the math lives in one place.
  static int payoutWin(int stake) => acStakeWin(stake);
  static int payoutDraw(int stake) => acStakeDraw(stake);
  static int payoutLose(int stake) => acStakeLose(stake);
  static int wpPayoutWin(int wpStake) => wpStakeWin(wpStake);
  static int wpPayoutDraw(int wpStake) => wpStakeDraw(wpStake);
  static int wpPayoutLose(int wpStake) => wpStakeLose(wpStake);

  static int houseFeeWin(int stake) => (stake * 0.1).floor();
  static int houseFeeDraw(int stake) => (stake * 0.05).floor() * 2;

  // ═════════════════════════════════════════════════════════════════════
  // Net balance deltas — what the History ledger on the Pi page renders.
  //
  // These are NOT the same numbers as the settlement credits above, and that
  // difference is the whole point. Both the AC stake and the WP stake are
  // debited from the balance when the challenge is *created/joined*
  // (functions/index.js:1841 for the creator, :2121 for the joiner), long
  // before the result is known. The settlement credit is therefore only half
  // the story, and a ledger that renders the credit alone is wrong in both
  // directions:
  //
  //   * On a LOSS the credit is 0, so the row showed no WP line whatsoever
  //     even though the stake had already left the balance. This is the bug
  //     that made a rival loss look free.
  //   * On a WIN the credit is stake + rake, so the row showed the stake
  //     refund as if it were new money.
  //
  // A ledger row has to answer "how much did my balance actually move", so
  // it combines the two: credit − stake.
  // ═════════════════════════════════════════════════════════════════════

  /// Net Weekly Points balance movement for one resolved match.
  ///
  /// [wpChange] is the stake-settlement credit stored on the match document
  /// (functions/index.js:2668). [wpAwarded] is the post-premium, post-daily-cap
  /// WP that was actually applied to `weeklyPoints`; it is absent on matches
  /// resolved before that field existed, in which case the pre-multiplier
  /// stake credit plus the flat participation bonus is the best available
  /// reconstruction.
  static int wpLedgerDelta({
    required bool isQuickMatch,
    required int wpStake,
    required int wpChange,
    required bool won,
    required bool isDraw,
    int? wpAwarded,
  }) {
    // Quick Match never stakes WP, so the recorded award already IS the whole
    // delta — and it is written post-multiplier and post-cap
    // (functions/index.js:5258), so it must never be re-derived.
    if (isQuickMatch) return wpAwarded ?? wpChange;

    // Flat participation bonus, credited on top of any stake settlement.
    final bonus = won
        ? challengeWinWpBonus
        : isDraw
            ? challengeDrawWpBonus
            : challengeLoseWpBonus;

    if (wpAwarded != null) return wpAwarded - wpStake;
    return bonus + wpChange - wpStake;
  }

  /// Net Anime Coins balance movement for one resolved match. Same ledger
  /// semantics as [wpLedgerDelta]: the stake left the balance at create/join
  /// time, so the settlement credit and the stake have to be combined.
  ///
  /// [pointsChange] is only consulted for stake-free matches, where it is the
  /// only delta the document carries. It is an AC value and must never be
  /// rendered under a WP label.
  static int acLedgerDelta({
    required bool isQuickMatch,
    required int stakeAmount,
    required int pointsChange,
    required bool won,
    required bool isDraw,
  }) {
    if (isQuickMatch) {
      return won
          ? quickMatchAcWin
          : isDraw
              ? quickMatchAcDraw
              : quickMatchAcLose;
    }
    if (stakeAmount <= 0) return pointsChange;
    if (won) {
      // Credited stake + rake; the stake already left the balance, so the
      // net movement is the rake bonus alone.
      return (stakeAmount * 0.9).floor();
    }
    if (isDraw) {
      // Credited acStakeDraw. The fee actually paid is
      // stake − floor(stake × 0.95), which is NOT floor(stake × 0.05) — the two
      // disagree by 1 on any stake that is not a multiple of 20.
      return acStakeDraw(stakeAmount) - stakeAmount;
    }
    // Nothing credited; the stake was already forfeited at create/join time.
    return -stakeAmount;
  }

  static int baseWpRewardWin = challengeWinWpBonus;
  static int baseWpRewardDraw = challengeDrawWpBonus;

  static int wpTotalCredited({
    required int wpStake,
    required bool won,
    required bool isDraw,
  }) {
    if (won) return challengeWinWpBonus + wpStakeWin(wpStake);
    if (isDraw) return challengeDrawWpBonus + wpStakeDraw(wpStake);
    return 0;
  }

  // ═════════════════════════════════════════════════════════════════════
  // Per-instance settlement, already split by currency and by purpose.
  //
  // The result page renders these four values directly and labels each one
  // for exactly what it is. Splitting them here is what makes it impossible
  // to reintroduce the old "Points Earned" card that showed an AC value.
  // ═════════════════════════════════════════════════════════════════════

  /// Anime Coins credited to this user's balance at resolve time.
  /// Excludes Weekly Points entirely. For a loss this is always 0 — the AC was
  /// already spent when the challenge was created/joined, so re-showing it
  /// here as a negative delta would double-count the loss.
  int acSettlementFor({required bool won, required bool isDraw}) {
    if (kind == ChallengeKind.quick) {
      return won
          ? quickMatchAcWin
          : isDraw
              ? quickMatchAcDraw
              : quickMatchAcLose;
    }
    if (stakeAmount <= 0) return 0;
    return won
        ? acStakeWin(stakeAmount)
        : isDraw
            ? acStakeDraw(stakeAmount)
            : acStakeLose(stakeAmount);
  }

  /// The WP *stake* portion only — the money won back from the pot, or
  /// nothing on a loss. Always 0 for Code and Quick Match: neither stakes WP.
  int wpStakeSettlementFor({required bool won, required bool isDraw}) {
    if (!kind.stakesWeeklyPoints) return 0;
    final stake = wpStake ?? 0;
    if (stake <= 0) return 0;
    return won
        ? wpStakeWin(stake)
        : isDraw
            ? wpStakeDraw(stake)
            : wpStakeLose(stake);
  }

  /// The flat Weekly Points participation reward, entirely separate from any
  /// stake. This is the "what you won for playing" number, and it is the one
  /// that used to be mislabelled as a stake settlement on a loss.
  /// Spar preview: 5 WP on a win while inside the daily spar budget
  /// (server-authoritative; over-budget wins pay 0).
  int wpBonusFor({required bool won, required bool isDraw}) {
    if (kind == ChallengeKind.quick) {
      return won
          ? quickMatchWpWin
          : isDraw
              ? quickMatchWpDraw
              : quickMatchWpLose;
    }
    if (kind == ChallengeKind.spar) {
      return won
          ? sparWinWpBonus
          : isDraw
              ? sparDrawWpBonus
              : sparLoseWpBonus;
    }
    return won
        ? challengeWinWpBonus
        : isDraw
            ? challengeDrawWpBonus
            : challengeLoseWpBonus;
  }

  /// Total WP credited — stake settlement plus participation reward. Used for
  /// the "Weekly Points" total line and for the balance-delta listener.
  int wpTotalFor({required bool won, required bool isDraw}) =>
      wpStakeSettlementFor(won: won, isDraw: isDraw) +
      wpBonusFor(won: won, isDraw: isDraw);

  factory ChallengeModel.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data() ?? {};
    return ChallengeModel(
      challengeId: doc.id,
      creatorUid: (d['creatorUid'] as String?) ?? '',
      creatorUsername: (d['creatorUsername'] as String?) ?? 'Unknown',
      opponentUid: d['opponentUid'] as String?,
      opponentUsername: d['opponentUsername'] as String?,
      stakeAmount: ((d['stakeAmount'] as num?)?.toInt()) ?? 0,
      wpStake: ((d['wpStake'] as num?)?.toInt()),
      wpOutcome: d['wpOutcome'] as String?,
      animeTitle: (d['animeTitle'] as String?) ?? '',
      questionIds: List<String>.unmodifiable(
        (d['questionIds'] is List
            ? (d['questionIds'] as List).map((e) => '$e')
            : const <dynamic>[]),
      ),
      creatorScore: (d['creatorScore'] as num?)?.toInt(),
      opponentScore: (d['opponentScore'] as num?)?.toInt(),
      status: ChallengeStatusX.parse(d['status'] as String?),
      createdAt: ((d['createdAt'] as Timestamp?)?.toDate()) ?? DateTime.now(),
      expiresAt: ((d['expiresAt'] as Timestamp?)?.toDate()) ??
          DateTime.now().add(const Duration(hours: 24)),
      outcome: d['outcome'] as String?,
      isQuickMatch: (d['isQuickMatch'] as bool?) ?? false,
      challengeType: (d['challengeType'] as String?) ?? 'code',
      bountyWinnerUid: d['bountyWinnerUid'] as String?,
      bountyWP: ((d['bountyWP'] as num?)?.toInt()) ?? 0,
      seriesNo: ((d['seriesNo'] as num?)?.toInt()) ?? 0,
      seriesWinnerUid: d['seriesWinnerUid'] as String?,
      seriesPrizePaid: (d['seriesPrizePaid'] as bool?) ?? false,
    );
  }

  @override
  String toString() =>
      'ChallengeModel($challengeId · $status · $kind · $animeTitle · '
      'acStake: $stakeAmount · wpStake: $wpStake · $outcome)';
}

// ─── Return type from createChallenge ────────────────────────────────────────
class ChallengeCreationResult {
  final String challengeId;
  final List<String> questionIds;
  const ChallengeCreationResult({
    required this.challengeId,
    required this.questionIds,
  });
}
