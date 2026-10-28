// functions/test/leaderboard_payout.test.js — regression tests for the
// leaderboard audit fixes. These run the REAL handlers against the in-memory
// Firestore fake (no emulator).
//   1. The Monday announcement's winners are the PAID entrants with a real
//      share, not the top scorers over every user (non-entrants and ₦0 prizes).
//   2. submitPayoutDetails refuses a zero-share rank (only the top 3 are paid).
//   3. submitPayoutDetails enforces the advertised 3-day claim window.
//   4. checkPendingClaim forfeits a winner who never submitted, once.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes, FakeTimestamp } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const STAMP = { platform: 'android', appBuild: 999 };
const DAY = 24 * 60 * 60 * 1000;
const CLAIM = {
  weekId: null,
  accountNumber: '0123456789',
  bankCode: '058',
  beneficiaryName: 'Ada Obi',
};

describe('leaderboard payout audit fixes', () => {
  beforeEach(async () => {
    await H.clearDb(db);
  });

  it('weeklyReset: winners are paid entrants with their real share, not the top scorers', async () => {
    const weekId = H.thisWeekId();
    await H.setDoc(db, `prize_pool/${weekId}`, {
      weekId, status: 'active', totalNaira: 0, entryCodeRevenue: 1000,
    });
    // The highest scorer never bought an entry: must NOT be announced a winner.
    await H.mkUser(db, 'NOENTRY', {
      username: 'NoEntry', university: 'UNILAG', weeklyPoints: 9000,
      fcmToken: 'noentry-token',
    });
    await H.mkUser(db, 'E1', {
      username: 'E1', university: 'UNILAG', weeklyPoints: 8000,
      leaderboardEntryWeekId: weekId, fcmToken: 'e1-token',
    });
    await H.mkUser(db, 'E2', {
      username: 'E2', university: 'UNILAG', weeklyPoints: 7000,
      leaderboardEntryWeekId: weekId, fcmToken: 'e2-token',
    });

    await fns.weeklyReset.run({});

    const pool = await H.getDoc(db, `prize_pool/${weekId}`);
    assert.deepEqual(pool.winners.map((w) => w.uid), ['E1', 'E2']);
    // 70% of ₦1,000 = ₦700 → 50% and 30%. Never ₦0.
    assert.equal(pool.winners[0].prize, 350);
    assert.equal(pool.winners[1].prize, 210);

    const cycle = await H.getDoc(db, `leaderboardCycles/${weekId}`);
    assert.deepEqual(cycle.ranked.map((r) => r.uid), ['E1', 'E2']);
    assert.equal(cycle.ranked[0].share, pool.winners[0].prize,
      'the announced prize must equal the payable share');
  });

  it('submitPayoutDetails: a zero-share rank cannot submit a payout', async () => {
    const weekId = H.thisWeekId();
    // The claimant needs a real account so the zero-share check is what rejects it.
    await H.mkUser(db, 'L6');
    await H.setDoc(db, `leaderboardCycles/${weekId}`, {
      weekId,
      status: 'calculated',
      calculatedAt: FakeTimestamp.now(),
      ranked: [
        { rank: 1, uid: 'W1', share: 280, paid: false },
        { rank: 6, uid: 'L6', share: 0, paid: false },
      ],
    });

    await H.rejectsWith(
      fns.submitPayoutDetails.run(H.req('L6', { ...STAMP, ...CLAIM, weekId })),
      'failed-precondition', 'No prize share',
    );
    const claim = await H.getDoc(db, `leaderboardCycles/${weekId}/pendingClaim/L6`);
    assert.equal(claim, null, 'a rejected zero-share submission must write nothing');
  });

  it('submitPayoutDetails: rejects a submission after the 3-day claim window', async () => {
    const weekId = H.thisWeekId();
    await H.mkUser(db, 'W1');
    await H.setDoc(db, `leaderboardCycles/${weekId}`, {
      weekId,
      status: 'calculated',
      calculatedAt: FakeTimestamp.fromMillis(Date.now() - 4 * DAY),
      ranked: [{ rank: 1, uid: 'W1', share: 280, paid: false }],
    });

    await H.rejectsWith(
      fns.submitPayoutDetails.run(H.req('W1', { ...STAMP, ...CLAIM, weekId })),
      'failed-precondition', 'claim window has closed',
    );
  });

  it('submitPayoutDetails: a winner inside the window can still submit', async () => {
    const weekId = H.thisWeekId();
    await H.mkUser(db, 'W1');
    await H.setDoc(db, `leaderboardCycles/${weekId}`, {
      weekId,
      status: 'calculated',
      calculatedAt: FakeTimestamp.now(),
      ranked: [{ rank: 1, uid: 'W1', share: 280, paid: false }],
    });

    const res = await fns.submitPayoutDetails.run(
      H.req('W1', { ...STAMP, ...CLAIM, weekId }));
    assert.equal(res.success, true);
    assert.equal(res.status, 'pending');
  });

  it('checkPendingClaim: forfeits a winner who never submitted, exactly once', async () => {
    const weekId = H.thisWeekId();
    await H.setDoc(db, `leaderboardCycles/${weekId}`, {
      weekId,
      status: 'calculated',
      calculatedAt: FakeTimestamp.fromMillis(Date.now() - 4 * DAY),
      ranked: [
        { rank: 1, uid: 'W1', share: 280, paid: false },
        { rank: 2, uid: 'W2', share: 175, paid: false },
      ],
    });
    // W2 submitted but was never marked paid; W1 never submitted at all.
    await H.setDoc(db, `leaderboardCycles/${weekId}/pendingClaim/W2`, {
      uid: 'W2', status: 'pending', accountNumber: '0123456789',
    });

    await fns.checkPendingClaim.run({});

    const w1 = await H.getDoc(db, `leaderboardCycles/${weekId}/pendingClaim/W1`);
    assert.equal(w1.status, 'expired');
    assert.equal(w1.neverSubmitted, true);
    assert.equal(w1.forfeitedNaira, 280);

    const w2 = await H.getDoc(db, `leaderboardCycles/${weekId}/pendingClaim/W2`);
    assert.equal(w2.status, 'expired');
    assert.equal(w2.forfeitedNaira, 175);

    // A second run must not forfeit again.
    await fns.checkPendingClaim.run({});
    const again = await H.getDoc(db, `leaderboardCycles/${weekId}/pendingClaim/W1`);
    assert.equal(again.status, 'expired');
    assert.equal(again.forfeitedNaira, 280);
  });
});
