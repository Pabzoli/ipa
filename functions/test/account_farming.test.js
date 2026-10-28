// functions/test/account_farming.test.js
//
// Multi-account and farming rules: referral abuse, self-referral,
// device flags, same-device challenges, pair reward caps, payout age.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes, FakeTimestamp } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');
const TH = fns._testHelpers;

const WEB = { platform: 'web' };

function withIp(uid, data, ip, token = {}) {
  return H.req(uid, data, {
    rawRequest: { headers: { 'x-forwarded-for': ip } },
    ...(Object.keys(token).length ? { auth: { uid, token } } : {}),
  });
}

async function balances(...uids) {
  const out = {};
  for (const u of uids) {
    const d = (await db.collection('users').doc(u).get()).data() || {};
    out[u] = { ac: d.animeCoins || 0, wp: d.weeklyPoints || 0 };
  }
  return out;
}

function clearCooldowns() {
  return Promise.all(['A', 'B'].map((u) =>
    db.collection('users').doc(u).update({
      rivalCooldowns: {}, lastRivalUid: null, lastRivalChallenge: null,
      challengesCreatedDate: H.watDaysAgo(1), challengesJoinedDate: H.watDaysAgo(1),
    })));
}

async function makeDuel() {
  const r = await fns.createChallenge.run(H.req('A', {
    animeTitle: 'testanime', stakeAmount: 100, wpStake: 50,
    opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival', ...WEB,
  }));
  await fns.joinChallenge.run(H.req('B', { challengeId: r.challengeId, ...WEB }));
  return r.challengeId;
}

async function settle(id, cs, os) {
  const ref = db.collection('challenges').doc(id);
  await ref.update({ creatorScore: cs, opponentScore: os, status: 'opponent_submitted' });
  const snap = await ref.get();
  await fns._resolveChallengeCore(id, ref, snap.data());
}

describe('pair reward cap', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
    await H.mkUser(db, 'A', { animeCoins: 1000, weeklyPoints: 500 });
    await H.mkUser(db, 'B', { animeCoins: 1000, weeklyPoints: 500 });
    await H.seedQuestions(db);
  });

  it('pays 3 rewarded matches per pair per day, then only settles stakes', async () => {
    for (let i = 0; i < 3; i += 1) {
      const id = await makeDuel();
      await settle(id, 9, 4);
      await clearCooldowns();
    }
    let b = await balances('A', 'B');
    const wpAfter3 = b.A.wp;
    assert.ok(wpAfter3 > 500, `3 rewarded wins must earn WP, got ${wpAfter3}`);

    const fourth = await makeDuel();
    // Neutralise the daily WP soft cap so the only variable is the pair cap.
    for (const uid of ['A', 'B']) {
      await db.collection('users').doc(uid).update({
        wpEarnedToday: 0,
        wpEarnedDate: FakeTimestamp.now(),
      });
    }
    const wpBeforeResolve = (await balances('A')).A.wp;
    const acBeforeResolve = (await balances('A')).A.ac;
    await settle(fourth, 9, 4);
    b = await balances('A', 'B');

    // No flat reward: the only credit is the 95 WP stake return (50 + 90%).
    assert.equal(b.A.wp, wpBeforeResolve + 95, '4th win mints no flat WP');
    // Stake still settles (achievement grants can add extra AC on top).
    assert.ok(b.A.ac >= acBeforeResolve + 190, '4th stake still pays');

    const pair = await H.getDoc(db, 'challengePairs/A_B');
    assert.equal(pair.rewardedCount, 3);
  });
});

describe('device rules', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('flags the 4th account on one device without blocking it', async () => {
    for (let i = 0; i < 4; i += 1) {
      const uid = `dev${i}`;
      await fns.ensureProfile.run(withIp(uid, {
        username: `device${i}`, email: `${uid}@t.co`, deviceId: 'shared-device',
        termsAccepted: true, ...WEB,
      }, `198.51.100.${10 + i}`, { email: `${uid}@t.co` }));
    }
    const user = await H.getDoc(db, 'users/dev3');
    assert.ok(user, 'the 4th account is still created');
    const flag = await H.getDoc(db, 'flaggedAccounts/dev3');
    assert.ok(flag, 'the 4th account is flagged');
    assert.ok(flag.signals.some((s) => s.type === 'multi_account_device'));
    const abuse = await db.collection('abuse_log').get();
    assert.ok(abuse.docs.some((d) => d.data().reason === 'multi_account_device'));
  });

  it('refuses a same-device opponent', async () => {
    await H.mkUser(db, 'A');
    await H.mkUser(db, 'B');
    await H.seedQuestions(db);

    const created = await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 100, wpStake: 50,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival',
      deviceId: 'device-same', ...WEB,
    }));

    await H.rejectsWith(
      fns.joinChallenge.run(H.req('B', {
        challengeId: created.challengeId,
        deviceId: 'device-same', ...WEB,
      })),
      'failed-precondition',
      'same_device_challenge',
    );
  });
});

describe('referral abuse', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('pays the referral bonus without an invitee email verification gate', async () => {
    await H.mkUser(db, 'A', { animeCoins: 1000, email: 'a@t.co' });
    await H.mkUser(db, 'B', { animeCoins: 0, email: 'b@t.co', emailVerified: false });
    await db.collection('users').doc('B').update({ referredBy: 'A' });

    for (let i = 0; i < 3; i += 1) {
      await db.collection('users').doc('B').collection('quizSessions').doc(`s${i}`).set({
        timestamp: FakeTimestamp.fromMillis(Date.now() - i * 24 * 60 * 60 * 1000),
      });
    }

    ctx.authUsers.set('B', { email: 'b@t.co', emailVerified: false });
    await fns.claimReferralBonus.run(H.req('B', { referredBy: 'A' }));
    const after = await balances('A', 'B');
    assert.equal(after.A.ac, 1100);
    assert.equal(after.B.ac, 50);
  });

  it('blocks a referral whose referrer is on the same IP', async () => {
    await H.mkUser(db, 'A', { email: 'a@t.co' });
    await H.mkUser(db, 'B', { email: 'b@t.co' });
    await db.collection('users').doc('B').update({ referredBy: 'A' });
    await db.collection('telemetry').doc('account_signals')
      .collection('users').doc('A').set({ createdIp: '203.0.113.77' });
    for (let i = 0; i < 3; i += 1) {
      await db.collection('users').doc('B').collection('quizSessions').doc(`s${i}`).set({
        timestamp: FakeTimestamp.fromMillis(Date.now() - i * 24 * 60 * 60 * 1000),
      });
    }

    const out = await fns.claimReferralBonus.run(withIp('B', { referredBy: 'A' }, '203.0.113.77'));
    assert.equal(out.blocked, 'self_referral');
    assert.equal((await balances('A', 'B')).A.ac, 1000);
  });
});

describe('payout eligibility', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('refuses payout details for a 1-day-old account', async () => {
    await H.mkUser(db, 'newbie', { createdAt: Date.now() - 24 * 60 * 60 * 1000 });
    await H.rejectsWith(
      fns.savePayoutDetail.run(H.req('newbie', {
        bankCode: '058', accountNumber: '0123456789', beneficiaryName: 'New Player',
      })),
      'failed-precondition',
      'at least 7 days',
    );
  });

  it('allows payout details once the account is 7 days old', async () => {
    await H.mkUser(db, 'oldie', { createdAt: Date.now() - 8 * 24 * 60 * 60 * 1000 });
    const out = await fns.savePayoutDetail.run(H.req('oldie', {
      bankCode: '058', accountNumber: '0123456789', beneficiaryName: 'Old Player',
    }));
    assert.equal(out.success, true);
  });
});
