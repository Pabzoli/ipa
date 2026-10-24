// lib/core/constants/referral_economy.dart
//
// Display mirror of the reward numbers inside the `claimReferralBonus`
// Cloud Function (functions/index.js). Change both together — the server
// transaction is authoritative, these values are copy only.

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
