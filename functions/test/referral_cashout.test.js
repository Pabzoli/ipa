// functions/test/referral_cashout.test.js — the NGN 5,000 referral cashout.
//
// What must stay true:
//   • the marker is written when an invitee activates a leaderboard entry on
//     their own account, and by nothing else;
//   • the claim is refused below 20 qualifying invitees and accepted at 20;
//   • every submitted claim is encumbered in the SEPARATE cashout budget, so
//     leaderboard prize money is never touched or competed with;
//   • a missed marker is self-healed from the invitee profile;
//   • only the admin can list/mark/fund, and an account with a pending claim
//     cannot be deleted.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const ADMIN = 'pu4QTjHTijer7DLlqLU3w0npUUL2';
const WEEK = '2026-10-26';
const PAYOUT = {
  accountNumber: '0123456789',
  bankCode: '058',
  beneficiaryName: 'Ada Test',
};

async function seedReferral(inviter, invitee, over = {}) {
  await H.setDoc(db, `users/${inviter}/referrals/${invitee}`, {
    inviteeUsername: invitee,
    status: 'pending',
    quizzesCompleted: 0,
    quizzesRequired: 3,
    quizDays: 0,
    daysRequired: 2,
    createdAt: new Date(),
    qualifiedAt: null,
    expiresAt: null,
    rewardAmount: 100,
    leaderboardEntryPurchased: true,
    leaderboardEntryWeekId: WEEK,
    leaderboardEntryBuyerEmail: `${invitee.toLowerCase()}@t.co`,
    leaderboardEntryPurchasedAt: new Date(),
    ...over,
  });
}

async function seedQualified(inviter, count) {
  for (let i = 0; i < count; i++) {
    await seedReferral(inviter, `I${i}`);
  }
}

async function seedLeaderboardCode(code, email = 'invitee@t.co') {
  await H.setDoc(db, `redemptionCodes/${code}`, {
    type: 'leaderboard_entry',
    value: WEEK,
    status: 'unused',
    paidAmount: 500,
    buyerEmail: email,
  });
}

async function fund(amount) {
  return fns.fundReferralCashoutReserve.run(H.req(ADMIN, { amount }));
}

describe('referral cashout qualification marker', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'Ash', email: 'ash@t.co' });
    await H.mkUser(db, 'I', {
      username: 'Ivy',
      email: 'ivy@t.co',
      referredBy: 'A',
      leaderboardEntryWeekId: null,
    });
    await H.setDoc(db, 'users/A/referrals/I', {
      inviteeUsername: 'Ivy',
      status: 'pending',
      quizzesCompleted: 0,
      quizzesRequired: 3,
      quizDays: 0,
      daysRequired: 2,
      createdAt: new Date(),
      qualifiedAt: null,
      expiresAt: new Date(Date.now() + 86400000),
      rewardAmount: 100,
    });
  });

  it('marks the referrer record when the invitee activates an entry', async () => {
    await seedLeaderboardCode('AAAA-BBBB-CCCC', 'ivy@t.co');

    await fns.redeemCode.run(H.req('I', { code: 'AAAA-BBBB-CCCC', platform: 'web' }));

    const record = await H.getDoc(db, 'users/A/referrals/I');
    assert.equal(record.leaderboardEntryPurchased, true);
    assert.equal(record.leaderboardEntryWeekId, WEEK);
    assert.equal(record.leaderboardEntryBuyerEmail, 'ivy@t.co');
    assert.ok(record.leaderboardEntryPurchasedAt, 'purchase timestamp stored');
    assert.equal(record.status, 'pending', 'quiz status is not rewritten');
    assert.ok(record.expiresAt, 'existing deadline survives');
  });

  it('does not mark for an AC code or a self-referred account', async () => {
    await H.setDoc(db, 'redemptionCodes/DDDD-EEEE-FFFF', {
      type: 'ac', value: 500, status: 'unused',
    });
    await fns.redeemCode.run(H.req('I', { code: 'DDDD-EEEE-FFFF', platform: 'web' }));

    let record = await H.getDoc(db, 'users/A/referrals/I');
    assert.equal(record.leaderboardEntryPurchased, undefined);

    await H.mkUser(db, 'S', {
      username: 'Self', referredBy: 'S', leaderboardEntryWeekId: null,
    });
    await seedLeaderboardCode('GGGG-HHHH-IIII', 'self@t.co');
    await fns.redeemCode.run(H.req('S', { code: 'GGGG-HHHH-IIII', platform: 'web' }));

    const selfRecord = await H.getDoc(db, 'users/S/referrals/S');
    assert.equal(selfRecord, null, 'a self-referral record is never created');
  });

  it('creates a pending record if sign-up never wrote one', async () => {
    await db.collection('users').doc('A').collection('referrals').doc('I').delete();
    await seedLeaderboardCode('JJJJ-KKKK-LLLL', 'ivy@t.co');

    await fns.redeemCode.run(H.req('I', { code: 'JJJJ-KKKK-LLLL', platform: 'web' }));

    const record = await H.getDoc(db, 'users/A/referrals/I');
    assert.equal(record.leaderboardEntryPurchased, true);
    assert.equal(record.expiresAt, null, 'no misleading quiz deadline');
  });
});

describe('referral cashout claim', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'Ash', email: 'ash@t.co' });
    // The leaderboard's own money: a claim must never touch these.
    await H.setDoc(db, 'prize_pool/2026-10-26', {
      weekId: '2026-10-26', status: 'active', entryCodeRevenue: 10000,
    });
    await H.setDoc(db, 'app_config/leaderboard_entry_config', { floor: 1000 });
  });

  it('refuses below 20 qualifying invitees', async () => {
    await seedQualified('A', 19);
    await fund(5000);

    await H.rejectsWith(
      fns.claimReferralCashout.run(H.req('A', PAYOUT)),
      'failed-precondition', '19/20');

    assert.equal(await H.getDoc(db, 'referralCashouts/A'), null);
  });

  it('accepts at 20 and encumbers the separate budget only', async () => {
    await seedQualified('A', 20);
    await fund(5000);

    const res = await fns.claimReferralCashout.run(H.req('A', PAYOUT));

    assert.equal(res.success, true);
    assert.equal(res.status, 'pending');
    assert.equal(res.amount, 5000);
    assert.equal(res.qualifiedCount, 20);

    const claim = await H.getDoc(db, 'referralCashouts/A');
    assert.equal(claim.status, 'pending');
    assert.equal(claim.amount, 5000);
    assert.equal(claim.qualifiedCount, 20);
    assert.equal(claim.accountNumber, '0123456789');
    assert.equal(claim.reserved, true);
    assert.deepEqual(claim.riskFlags, []);

    const reserve = await H.getDoc(db, 'referralCashoutReserve/ledger');
    assert.equal(reserve.available, 0);
    assert.equal(reserve.encumbered, 5000);
    assert.equal(reserve.totalFunded, 5000);

    // Payout destination is mirrored for the admin's usual workflow.
    const details = await db.collection('users').doc('A')
      .collection('payoutDetails').get();
    assert.equal(details.size, 1);
    assert.equal(details.docs[0].data().accountNumber, '0123456789');
    const audit = await db.collection('payoutDetailAudit')
      .where('source', '==', 'claimReferralCashout').get();
    assert.equal(audit.size, 1);

    // Leaderboard money is untouched.
    const pool = await H.getDoc(db, 'prize_pool/2026-10-26');
    assert.equal(pool.entryCodeRevenue, 10000);
    const config = await H.getDoc(db, 'app_config/leaderboard_entry_config');
    assert.equal(config.floor, 1000);
  });

  it('accepts an earned claim even when the budget is short (negative available)', async () => {
    await seedQualified('A', 20);
    await fund(2000);

    const res = await fns.claimReferralCashout.run(H.req('A', PAYOUT));
    assert.equal(res.status, 'pending');

    const reserve = await H.getDoc(db, 'referralCashoutReserve/ledger');
    assert.equal(reserve.available, -3000, 'operator shortfall is visible');
    assert.equal(reserve.encumbered, 5000, 'the obligation is fully earmarked');

    // An unfunded budget must never block the payout bookkeeping.
    await fns.markReferralCashoutPaid.run(H.req(ADMIN, {
      claimId: 'A', status: 'paid',
    }));
    const after = await H.getDoc(db, 'referralCashoutReserve/ledger');
    assert.equal(after.encumbered, 0);
    assert.equal(after.paidTotal, 5000);
    assert.equal(after.available, -3000, 'shortfall stays visible until funded');
  });

  it('re-submitting corrects the destination without double-charging', async () => {
    await seedQualified('A', 20);
    await fund(5000);

    await fns.claimReferralCashout.run(H.req('A', PAYOUT));
    const res = await fns.claimReferralCashout.run(H.req('A', {
      accountNumber: '9999999999', bankCode: '058', beneficiaryName: 'Ada Test',
    }));

    assert.equal(res.status, 'pending');
    const claim = await H.getDoc(db, 'referralCashouts/A');
    assert.equal(claim.accountNumber, '9999999999');
    const reserve = await H.getDoc(db, 'referralCashoutReserve/ledger');
    assert.equal(reserve.encumbered, 5000, 'not charged twice');
  });

  it('counts an existing entry even when the marker was never written', async () => {
    for (let i = 0; i < 20; i++) {
      await seedReferral('A', `L${i}`, {
        leaderboardEntryPurchased: undefined,
        leaderboardEntryWeekId: undefined,
        leaderboardEntryBuyerEmail: undefined,
        leaderboardEntryPurchasedAt: undefined,
      });
      await H.mkUser(db, `L${i}`, {
        username: `L${i}`,
        leaderboardEntryWeekId: WEEK,
        leaderboardEntryEmail: `l${i}@t.co`,
      });
    }
    await fund(5000);

    const res = await fns.claimReferralCashout.run(H.req('A', PAYOUT));
    assert.equal(res.status, 'pending');
    assert.equal(res.qualifiedCount, 20);

    const healed = await H.getDoc(db, 'users/A/referrals/L0');
    assert.equal(healed.leaderboardEntryPurchased, true);
    assert.equal(healed.leaderboardEntryWeekId, WEEK);
  });

  it('flags a shared buyer email for the admin without blocking', async () => {
    for (let i = 0; i < 20; i++) {
      await seedReferral('A', `E${i}`, {
        leaderboardEntryBuyerEmail: 'one-buyer@t.co',
      });
    }
    await fund(5000);

    const res = await fns.claimReferralCashout.run(H.req('A', PAYOUT));
    assert.equal(res.status, 'pending');
    const claim = await H.getDoc(db, 'referralCashouts/A');
    assert.ok(claim.riskFlags.some((f) => /buyer email/i.test(f)));
  });

  it('rejects admins and unauthenticated callers', async () => {
    await seedQualified('A', 20);
    await fund(5000);
    await H.rejectsWith(
      fns.claimReferralCashout.run(H.req(ADMIN, PAYOUT)),
      'failed-precondition');
    await H.rejectsWith(
      fns.claimReferralCashout.run(H.req(null, PAYOUT)),
      'unauthenticated');
  });
});

describe('referral cashout admin queue', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'Ash', email: 'ash@t.co' });
  });

  it('is admin-only', async () => {
    await H.rejectsWith(
      fns.listReferralCashoutClaims.run(H.req('A', {})),
      'permission-denied');
    await H.rejectsWith(
      fns.fundReferralCashoutReserve.run(H.req('A', { amount: 5000 })),
      'permission-denied');
    await H.rejectsWith(
      fns.markReferralCashoutPaid.run(
        H.req('A', { claimId: 'A', status: 'paid' })),
      'permission-denied');
  });

  it('lists claims with the separate budget', async () => {
    await seedQualified('A', 20);
    await fund(5000);
    await fns.claimReferralCashout.run(H.req('A', PAYOUT));

    const res = await fns.listReferralCashoutClaims.run(H.req(ADMIN, {}));
    assert.equal(res.success, true);
    assert.equal(res.claims.length, 1);
    assert.equal(res.claims[0].uid, 'A');
    assert.equal(res.claims[0].amount, 5000);
    assert.equal(res.claims[0].accountNumber, '0123456789');
    assert.equal(res.counts.pending, 1);
    assert.equal(res.reserve.available, 0);
    assert.equal(res.reserve.encumbered, 5000);
    assert.equal(res.reserve.shortfall, 0);
  });

  it('filters by status without needing a composite index', async () => {
    await seedQualified('A', 20);
    await fund(5000);
    await fns.claimReferralCashout.run(H.req('A', PAYOUT));

    const pending =
        await fns.listReferralCashoutClaims.run(H.req(ADMIN, { status: 'pending' }));
    assert.equal(pending.claims.length, 1);
    const paid =
        await fns.listReferralCashoutClaims.run(H.req(ADMIN, { status: 'paid' }));
    assert.equal(paid.claims.length, 0);
    assert.equal(paid.counts.pending, 1, 'counts cover the unfiltered queue');
  });

  it('moves pending -> paid, and paid -> pending, in step with the ledger', async () => {
    await seedQualified('A', 20);
    await fund(5000);
    await fns.claimReferralCashout.run(H.req('A', PAYOUT));

    await fns.markReferralCashoutPaid.run(H.req(ADMIN, {
      claimId: 'A', status: 'paid', payoutReference: 'TRF-1',
    }));

    let claim = await H.getDoc(db, 'referralCashouts/A');
    assert.equal(claim.status, 'paid');
    assert.equal(claim.payoutReference, 'TRF-1');
    assert.equal(claim.markedBy, ADMIN);

    let reserve = await H.getDoc(db, 'referralCashoutReserve/ledger');
    assert.equal(reserve.encumbered, 0);
    assert.equal(reserve.paidTotal, 5000);

    // Undo a mis-tap.
    await fns.markReferralCashoutPaid.run(H.req(ADMIN, {
      claimId: 'A', status: 'pending',
    }));
    claim = await H.getDoc(db, 'referralCashouts/A');
    assert.equal(claim.status, 'pending');
    reserve = await H.getDoc(db, 'referralCashoutReserve/ledger');
    assert.equal(reserve.encumbered, 5000);
    assert.equal(reserve.paidTotal, 0);
  });

  it('rejecting returns the earmark to the budget', async () => {
    await seedQualified('A', 20);
    await fund(5000);
    await fns.claimReferralCashout.run(H.req('A', PAYOUT));

    await fns.markReferralCashoutPaid.run(H.req(ADMIN, {
      claimId: 'A', status: 'rejected', reason: 'Duplicate accounts',
    }));

    const claim = await H.getDoc(db, 'referralCashouts/A');
    assert.equal(claim.status, 'rejected');
    assert.equal(claim.rejectionReason, 'Duplicate accounts');
    const reserve = await H.getDoc(db, 'referralCashoutReserve/ledger');
    assert.equal(reserve.available, 5000);
    assert.equal(reserve.encumbered, 0);
  });

  it('funding tops up the cashout budget, never the prize pool', async () => {
    await H.setDoc(db, 'prize_pool/2026-10-26', {
      weekId: '2026-10-26', status: 'active', entryCodeRevenue: 10000,
    });

    const res = await fund(15000);
    assert.equal(res.reserve.available, 15000);
    assert.equal(res.reserve.totalFunded, 15000);
    assert.equal(
      (await H.getDoc(db, 'prize_pool/2026-10-26')).entryCodeRevenue, 10000);
  });
});

describe('deleteAccount + referral cashout', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'R', { username: 'Ref', email: 'r@t.co' });
    await H.mkUser(db, 'A', {
      username: 'Ash', email: 'ash@t.co', referredBy: 'R',
    });
    await seedReferral('R', 'A');
  });

  it('refuses deletion while a claim is pending', async () => {
    await H.setDoc(db, 'referralCashouts/A', {
      uid: 'A', amount: 5000, status: 'pending', accountNumber: '0123456789',
    });

    await H.rejectsWith(
      fns.deleteAccount.run(H.req('A')),
      'failed-precondition', 'awaiting payment');
    assert.ok(await H.getDoc(db, 'users/A'), 'profile survives');
  });

  it('keeps a paid record (bank fields redacted) and drops the qualifying row', async () => {
    await H.setDoc(db, 'referralCashouts/A', {
      uid: 'A', amount: 5000, status: 'paid', accountNumber: '0123456789',
      bankCode: '058', beneficiaryName: 'Ash', riskFlags: ['x'],
    });

    const res = await fns.deleteAccount.run(H.req('A'));

    const claim = await H.getDoc(db, 'referralCashouts/A');
    assert.equal(claim.status, 'paid', 'accounting status survives');
    assert.equal(claim.amount, 5000);
    assert.equal(claim.accountNumber, undefined);
    assert.equal(claim.beneficiaryName, undefined);
    assert.equal(claim.anonymized, true);
    assert.equal(res.anonymized.referralCashout, true);

    assert.equal(await H.getDoc(db, 'users/R/referrals/A'), null,
      'the invitee stops counting toward R');
  });
});
