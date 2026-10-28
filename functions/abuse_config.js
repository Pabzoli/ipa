// functions/abuse_config.js
//
// THE single source of truth for every abuse / verification-email threshold.
// Nothing else in functions/ may hardcode these numbers. The client only sees
// values returned by callables (e.g. retryAfterSeconds), never the thresholds.
//
// Email verification is enforced at login on the client; there are no feature
// flags here.
'use strict';

const DAY_MS = 24 * 60 * 60 * 1000;

module.exports = {
  // ── Signup ───────────────────────────────────────────────────────────────
  ACCOUNT_CREATE_MAX_PER_HOUR_PER_IP: 3,
  ACCOUNT_CREATE_MAX_PER_DAY_PER_IP: 10,

  // ── Verification email resends ───────────────────────────────────────────
  EMAIL_RESEND_MIN_INTERVAL_SECONDS: 60,
  EMAIL_RESEND_MAX_PER_DAY: 5,

  // ── Failed sign-ins / password resets ────────────────────────────────────
  AUTH_FAILURE_MAX: 5,
  AUTH_LOCK_MINUTES: 15,

  // ── Retention / cleanup ──────────────────────────────────────────────────
  UNVERIFIED_ACCOUNT_TTL_DAYS: 7,
  ABUSE_LOG_TTL_DAYS: 30,
  RATE_LIMIT_TTL_HOURS: 48,

  // Accounts created before this instant are NEVER deleted by the unverified
  // cleanup job. Every account that existed before the email-verification
  // build is grandfathered forever.
  UNVERIFIED_CLEANUP_EPOCH_MS: Date.UTC(2026, 9, 27, 0, 0, 0),

  // ── Referral ─────────────────────────────────────────────────────────────
  REFERRAL_QUIZZES_REQUIRED: 3,
  REFERRAL_DAYS_REQUIRED: 2,
  REFERRAL_MAX_PER_30_DAYS: 10,

  // ── Multi-account / farming ──────────────────────────────────────────────
  DEVICE_ACCOUNT_FLAG_THRESHOLD: 3,
  PAIR_REWARD_MAX_PER_DAY: 3,
  PAYOUT_MIN_ACCOUNT_AGE_DAYS: 7,

  // ── Derived helpers ──────────────────────────────────────────────────────
  DAY_MS,
};
