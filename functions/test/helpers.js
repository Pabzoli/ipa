// functions/test/helpers.js — shared factories + assertions for handler tests.
'use strict';
const assert = require('node:assert/strict');

function watToday(d = new Date()) {
  return new Date(d.getTime() + 60 * 60 * 1000).toISOString().slice(0, 10);
}
function watDaysAgo(n) {
  return watToday(new Date(Date.now() - n * 24 * 3600 * 1000));
}

// Mirrors currentWeekId() in functions/index.js: the ISO date of THIS week's
// Monday. Used as leaderboardEntryWeekId so the friends board treats a row as
// current-week (a raw watToday() date would compare unequal and hide WP).
let _cachedWeekId = null;
function thisWeekId() {
  if (_cachedWeekId) return _cachedWeekId;
  const now = new Date();
  const utcNow = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()
  ));
  const day = utcNow.getUTCDay();
  const diff = day === 0 ? -6 : 1 - day;
  const monday = new Date(utcNow);
  monday.setUTCDate(utcNow.getUTCDate() + diff);
  _cachedWeekId = monday.toISOString().slice(0, 10);
  return _cachedWeekId;
}

async function clearDb(db) {
  db.store.reset();
}

async function mkUser(db, uid, over = {}) {
  const email = over.email ?? `${uid}@t.co`;
  await db.collection('users').doc(uid).set({
    username: uid,
    email,
    animeCoins: 1000,
    weeklyPoints: 500,
    premiumActive: false,
    university: 'UNILAG',
    leaderboardEntryWeekId: 'W1',
    // Fixtures are "established" accounts by default; payout paths now require
    // PAYOUT_MIN_ACCOUNT_AGE_DAYS. Tests that care pass createdAt explicitly.
    createdAt: Date.now() - 30 * 24 * 60 * 60 * 1000,
    // Email-verification mirror. No server path gates on it any more; the field
    // exists so referral/payout fixtures look like real profiles.
    emailVerified: true,
    ...over,
  });

  if (db.authUsers) {
    db.authUsers.set(uid, {
      email,
      emailVerified: over.emailVerified !== false,
      metadata: { creationTime: new Date(over.createdAt || Date.now()).toISOString() },
    });
  }
}

async function seedQuestions(db, anime = 'testanime') {
  // Challenge mix needs 3 easy + 4 medium + 3 hard.
  const tiers = { easy: 4, medium: 5, hard: 4 };
  let n = 0;
  for (const [tier, count] of Object.entries(tiers)) {
    for (let i = 0; i < count; i++) {
      await db.collection('questions').doc(`q${n++}`).set({
        animeTitle: anime,
        difficulty: tier,
        question: `Question ${n}?`,
        options: ['A', 'B', 'C', 'D'],
        correctAnswerIndex: 0,
      });
    }
  }
}

// HttpsError from the fake https module carries .code + .message.
async function rejectsWith(promise, code, msgPart) {
  try {
    await promise;
  } catch (e) {
    assert.equal(e.code, code, `expected code ${code}, got ${e.code}: ${e.message}`);
    if (msgPart !== undefined) {
      assert.match(String(e.message), new RegExp(msgPart),
        `expected message to match ${msgPart}, got: ${e.message}`);
    }
    return e;
  }
  assert.fail(`expected rejection ${code}/${msgPart ?? ''}, but call succeeded`);
}

const req = (uid, data = {}, extra = {}) => ({
  data: { ...data },
  // Verified by default: real clients send email_verified:true after the
  // verification screen + token refresh. Use unverifiedReq for the negative
  // case. An explicit extra.auth replaces this wholesale.
  ...(uid ? { auth: { uid, token: { email_verified: true } } } : {}),
  ...extra,
});

// Requests whose ID token carries email_verified: false. The five money-path
// callables (submitPayoutDetails, savePayoutDetail, claimReferralCashout,
// requestPaymentLink, claimReferralBonus) reject these; everything else
// serves them.
const unverifiedReq = (uid, data = {}, extra = {}) => req(uid, data, {
  auth: { uid, token: { email_verified: false } },
  ...extra,
});

// Walks an arbitrary slash path (users/A/friendLinks/B) — coll/doc pairs.
function pathRef(db, path) {
  const parts = path.split('/').filter(Boolean);
  let ref = db.collection(parts[0]).doc(parts[1]);
  for (let i = 2; i < parts.length; i += 2) {
    ref = ref.collection(parts[i]).doc(parts[i + 1]);
  }
  return ref;
}

async function getDoc(db, path) {
  const s = await pathRef(db, path).get();
  return s.exists ? s.data() : null;
}

async function setDoc(db, path, data, opts) {
  return pathRef(db, path).set(data, opts);
}

module.exports = { watToday, watDaysAgo, thisWeekId, clearDb, mkUser, seedQuestions, rejectsWith, req, unverifiedReq, getDoc, setDoc, pathRef };
