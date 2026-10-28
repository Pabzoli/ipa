// lib/core/constants/referral_economy.dart
//
// Display mirror of the reward numbers inside the `claimReferralBonus`
// Cloud Function (functions/index.js). Change both together — the server
// transaction is authoritative, these values are copy only.

import 'dart:math' as math;

/// AC paid to the referrer when an invitee qualifies. Server: +100.
const int kReferralReferrerReward = 100;

/// AC paid to the invited player alongside the referrer's bonus. Server: +50.
const int kReferralRefereeReward = 50;

/// Quizzes an invitee must finish before any bonus fires. Server gate:
/// fewer than 3 sessions leaves the referral untouched.
const int kReferralQualifyingQuizCount = 3;

/// Distinct calendar days (WAT) those quizzes must span. Server gate:
/// a single quiz day never pays out.
const int kReferralQualifyingDays = 2;

/// Rewarded referrals a referrer may earn per rolling window.
/// Server cap: the 11th bonus in 30 days is skipped.
const int kReferralMonthlyCap = 10;

/// The rolling window the cap is counted over. Server: 30 * 24h.
const Duration kReferralRollingWindow = Duration(days: 30);

// ─── Referral cashout (NGN 5,000 / 20 qualifying invitees) ─────────────────
//
// Mirrors REFERRAL_CASHOUT_TARGET / REFERRAL_CASHOUT_AMOUNT in
// functions/index.js. A QUALIFYING invitee signed up with the referrer's code
// AND activated a leaderboard entry on that account. The amount is real cash
// paid by hand from a budget kept separate from the weekly prize pool.
const int kReferralCashoutTarget = 20;
const int kReferralCashoutAmountNaira = 5000;

/// Display-only easing for the cashout bar: `(qualified / target) ^ 0.5`.
///
/// The bar moves fast on the first referrals and crawls near the end, which is
/// the intended feel. The target is intentionally never printed on the card
/// (it is disclosed in the Terms of Service), so this curve is the only hint a
/// player gets. Server-side qualification does not depend on this value.
const double kReferralCashoutProgressExponent = 0.5;

/// 0..1 fill for the cashout bar. Clamped so an over-qualified account never
/// overflows the track.
double referralCashoutProgress(int qualifiedCount) {
  if (qualifiedCount <= 0) return 0;
  final ratio = (qualifiedCount / kReferralCashoutTarget).clamp(0.0, 1.0);
  return math.pow(ratio, kReferralCashoutProgressExponent).toDouble();
}
