// functions/test/referral_code.test.js — short referral codes, and the uid
// path that predates them.
//
// What must stay true:
//   • a code resolves to a uid and `referredBy` keeps storing that uid;
//   • a uid is still accepted anywhere a code is (every referral created
//     before this feature must keep working);
//   • the claim gate (3 quizzes across 2 WAT days) is untouched, and nothing
//     pays out client-side.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const STAMP = { platform: 'android', appBuild: 3 };

async function mintCode(uid) {
  const r = await fns.getMyReferralCode.run(H.req(uid, { ...STAMP }));
  return r.referralCode;
}

async function resolve(viewer, code) {
  const r = await fns.resolveReferralCode.run(
    H.req(viewer, { code, ...STAMP }),
  );
  return r.uid;
}

// The payout gate: 3 sessions across 2 distinct WAT days.
async function seedQualifyingQuizzes(uid) {
  const daysAgo = [0, 1, 1];
  for (let i = 0; i < daysAgo.length; i++) {
    await db.collection('users').doc(uid)
      .collection('quizSessions').doc(`s${i}`)
      .set({
        timestamp: ctx.FakeTimestamp.fromDate(
          new Date(Date.now() - daysAgo[i] * 24 * 60 * 60 * 1000),
        ),
      });
  }
}

describe('referral codes', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    for (const u of ['A', 'B']) {
      await H.mkUser(db, u, { username: u });
    }
  });

  it('mints a 6-character code, idempotent, mapped to the uid', async () => {
    const c1 = await mintCode('A');
    assert.match(c1, /^[A-Z0-9]{6}$/);

    const c2 = await mintCode('A');
    assert.equal(c2, c1, 'idempotent');

    assert.equal((await H.getDoc(db, `referralCodes/${c1}`)).uid, 'A');
    assert.equal((await H.getDoc(db, 'users/A')).referralCode, c1);
  });

  it('re-mints when the cached code no longer resolves to the user', async () => {
    const code = await mintCode('A');
    await db.collection('referralCodes').doc(code).delete();

    const replacement = await mintCode('A');

    assert.match(replacement, /^[A-Z0-9]{6}$/);
    assert.notEqual(replacement, code);
    assert.equal(
      (await H.getDoc(db, `referralCodes/${replacement}`)).uid, 'A',
    );
    assert.equal((await H.getDoc(db, 'users/A')).referralCode, replacement);
  });

  it('resolves a short code and a legacy uid to the same uid', async () => {
    const code = await mintCode('B');

    assert.equal(await resolve('A', code), 'B');
    assert.equal(
      await resolve('A', code.toLowerCase()), 'B', 'case-insensitive',
    );
    assert.equal(await resolve('A', 'B'), 'B', 'uid still accepted');
  });

  it('returns null for unknown codes and for your own code', async () => {
    assert.equal(await resolve('A', 'ZZZZZZ'), null);
    assert.equal(await resolve('A', 'not-a-code'), null);
    // A '/' would throw on the user-doc lookup if it were not filtered.
    assert.equal(await resolve('A', 'x/y'), null);

    const mine = await mintCode('A');
    assert.equal(await resolve('A', mine), null, 'no self-referral');
  });

  it('rejects unauthenticated callers', async () => {
    await assert.rejects(
      async () =>
        fns.resolveReferralCode.run(H.req(null, { code: 'ABCDEF', ...STAMP })),
      (e) => e.code === 'unauthenticated',
    );
  });

  it('pays both sides when referredBy holds a short code', async () => {
    const code = await mintCode('A');
    await H.mkUser(db, 'I', { username: 'I' });
    await db.collection('users').doc('I')
      .set({ referredBy: code }, { merge: true });
    await seedQualifyingQuizzes('I');

    await fns.claimReferralBonus.run(H.req('I', { referredBy: code }));

    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1100);
    const invitee = await H.getDoc(db, 'users/I');
    assert.equal(invitee.animeCoins, 1050);
    assert.equal(invitee.referredBy, 'A', 'normalized back to a uid');
    assert.equal(invitee.referralBonusClaimed, true);

    const record = await H.getDoc(db, 'users/A/referrals/I');
    assert.equal(record.status, 'rewarded');
  });

  it('still pays when referredBy holds a uid (pre-existing referrals)', async () => {
    await H.mkUser(db, 'I', { username: 'I' });
    await seedQualifyingQuizzes('I');

    await fns.claimReferralBonus.run(H.req('I', { referredBy: 'A' }));

    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1100);
    assert.equal((await H.getDoc(db, 'users/I')).animeCoins, 1050);
    assert.equal((await H.getDoc(db, 'users/A/referrals/I')).status, 'rewarded');
  });

  it('pays nobody before the 3-quiz / 2-day gate', async () => {
    const code = await mintCode('A');
    await H.mkUser(db, 'I', { username: 'I' });
    await db.collection('users').doc('I')
      .set({ referredBy: code }, { merge: true });
    await db.collection('users').doc('I')
      .collection('quizSessions').doc('s0')
      .set({ timestamp: ctx.FakeTimestamp.fromDate(new Date()) });

    await fns.claimReferralBonus.run(H.req('I', { referredBy: code }));

    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1000);
    assert.equal((await H.getDoc(db, 'users/I')).animeCoins, 1000);
    assert.equal(
      (await H.getDoc(db, 'users/I')).referredBy, code,
      'no normalization when nothing was paid',
    );
  });

  it('pays nobody for an unknown code or a retired one', async () => {
    await H.mkUser(db, 'I', { username: 'I' });
    await seedQualifyingQuizzes('I');

    const result = await fns.claimReferralBonus.run(
      H.req('I', { referredBy: 'ZZZZZZ' }),
    );

    assert.equal(result.success, true);
    assert.equal((await H.getDoc(db, 'users/I')).animeCoins, 1000);
    assert.equal((await H.getDoc(db, 'users/I')).referralBonusClaimed, undefined);
  });

  it('never pays twice for the same invitee', async () => {
    const code = await mintCode('A');
    await H.mkUser(db, 'I', { username: 'I' });
    await db.collection('users').doc('I')
      .set({ referredBy: code }, { merge: true });
    await seedQualifyingQuizzes('I');

    await fns.claimReferralBonus.run(H.req('I', { referredBy: code }));
    await fns.claimReferralBonus.run(H.req('I', { referredBy: code }));

    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1100);
    assert.equal((await H.getDoc(db, 'users/I')).animeCoins, 1050);
  });
});
