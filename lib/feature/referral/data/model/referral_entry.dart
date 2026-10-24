import '../../../../core/constants/referral_economy.dart';

/// Server-written status of a referral record. The server only ever writes
/// 'pending' or 'rewarded'; "expired" is derived on the client (a record that
/// never met the gate and is past its 2-day deadline).
enum ReferralStatus { pending, rewarded }

/// One row on the Referrals page.
///
/// Live entries come from `users/{inviter}/referrals/{invitee}` (written only
/// by Cloud Functions). [isLegacy] entries are reconstructed from older
/// `earn_referral` coin transactions that predate the records — they carry no
/// invitee identity and are labelled "Earlier referral".
class ReferralEntry {
  final String? inviteeUsername;
  final ReferralStatus status;
  final int quizzesCompleted;
  final int quizzesRequired;
  final int quizDays;
  final int daysRequired;
  final DateTime? createdAt;
  final DateTime? qualifiedAt;
  final DateTime? expiresAt;
  final int rewardAmount;
  final bool isLegacy;

  const ReferralEntry({
    required this.inviteeUsername,
    required this.status,
    required this.quizzesCompleted,
    required this.quizzesRequired,
    required this.quizDays,
    required this.daysRequired,
    required this.createdAt,
    required this.qualifiedAt,
    required this.expiresAt,
    required this.rewardAmount,
    this.isLegacy = false,
  });

  factory ReferralEntry.legacy({
    required DateTime awardedAt,
    required int coins,
  }) {
    return ReferralEntry(
      inviteeUsername: null,
      status: ReferralStatus.rewarded,
      quizzesCompleted: kReferralQualifyingQuizCount,
      quizzesRequired: kReferralQualifyingQuizCount,
      quizDays: kReferralQualifyingDays,
      daysRequired: kReferralQualifyingDays,
      createdAt: null,
      qualifiedAt: awardedAt,
      expiresAt: null,
      rewardAmount: coins,
      isLegacy: true,
    );
  }

  bool get isRewarded => status == ReferralStatus.rewarded;

  /// Both halves of the server gate (3 quizzes on 2 distinct days) are met.
  bool get isGateMet =>
      quizzesCompleted >= quizzesRequired && quizDays >= daysRequired;

  /// When the payout landed: records use qualifiedAt, legacy rows use the
  /// ledger timestamp.
  DateTime? get rewardedAt => qualifiedAt ?? createdAt;

  /// Past the 2-day deadline without meeting the gate. A gate-met record never
  /// expires here — it is waiting on the referral cap, not on the invitee.
  bool isExpiredAt(DateTime now) {
    final deadline = expiresAt;
    return !isRewarded &&
        !isGateMet &&
        deadline != null &&
        now.isAfter(deadline);
  }
}
