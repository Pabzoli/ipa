// functions/test/money.test.js — money paths with REAL handlers + fake Firestore.
// Covers: staked duel win, draw, decline refund, expiry refund, forfeit,
// spar pair-cap (3 paid/day, 4th 0, next-day reset), series prize (AC +
// earn_series log, NO frame, 7-day gate), trigger idempotency.
'use strict';
process.env.NODE_ENV = 'test';
const { test, describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes, FakeTimestamp } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const STAMP = { platform: 'android', appBuild: 3 };

async function balances(...uids) {
  const out = {};
  for (const u of uids) {
    const s = await db.collection('users').doc(u).get();
    const d = s.data() || {};
    out[u] = { ac: d.animeCoins || 0, wp: d.weeklyPoints || 0 };
  }
  return out;
}

async function makeDuel(stakeAC = 100, wpStake = 50) {
  const r = await fns.createChallenge.run(
    H.req('A', {
      animeTitle: 'testanime', stakeAmount: stakeAC, wpStake,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival', ...STAMP,
    }));
  await fns.joinChallenge.run(H.req('B', { challengeId: r.challengeId, ...STAMP }));
  return r.challengeId;
}

async function settle(id, cs, os, status = 'opponent_submitted') {
  const ref = db.collection('challenges').doc(id);
  await ref.update({ creatorScore: cs, opponentScore: os, status });
  const snap = await ref.get();
  await fns._resolveChallengeCore(id, ref, snap.data());
  return (await ref.get()).data();
}

function clearCooldowns() {
  return Promise.all(['A', 'B'].map((u) =>
    db.collection('users').doc(u).update({
      rivalCooldowns: {}, lastRivalUid: null, lastRivalChallenge: null,
      challengesCreatedDate: H.watDaysAgo(1), challengesJoinedDate: H.watDaysAgo(1),
    })));
}

// A pending invite the opponent has not accepted yet (status 'waiting').
async function makeWaitingDuel(stakeAC = 100, wpStake = 50) {
  const r = await fns.createChallenge.run(
    H.req('A', {
      animeTitle: 'testanime', stakeAmount: stakeAC, wpStake,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival', ...STAMP,
    }));
  return r.challengeId;
}

describe('money', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'A', animeCoins: 1000, weeklyPoints: 500 });
    await H.mkUser(db, 'B', { username: 'B', animeCoins: 1000, weeklyPoints: 500 });
    await H.seedQuestions(db);
  });

  it('staked duel win pays exact AC+WP, loser keeps nothing further', async () => {
    const id = await makeDuel(100, 50);
    let b = await balances('A', 'B');
    assert.deepEqual(b.A, { ac: 900, wp: 450 });
    assert.deepEqual(b.B, { ac: 900, wp: 450 });
    const done = await settle(id, 8, 5);
    assert.equal(done.outcome, 'creator_wins');
    b = await balances('A', 'B');
    // AC: 100 + floor(90) = 190 credit. WP: flat 50 + (50 + 45) stake = 145.
    assert.deepEqual(b.A, { ac: 1090, wp: 595 });
    assert.deepEqual(b.B, { ac: 900, wp: 450 });
    const mA = await db.collection('users').doc('A').collection('matches').get();
    const mB = await db.collection('users').doc('B').collection('matches').get();
    assert.equal(mA.size, 1);
    assert.equal(mB.size, 1);
  });

  it('draw refunds 95% AC and 90% WP stake + flats', async () => {
    const id = await makeDuel(100, 50);
    const done = await settle(id, 7, 7);
    assert.equal(done.outcome, 'draw');
    const b = await balances('A', 'B');
    // AC: floor(95) = 95. WP: 25 + floor(45) = 70.
    assert.deepEqual(b.A, { ac: 995, wp: 520 });
    assert.deepEqual(b.B, { ac: 995, wp: 520 });
  });

  it('decline refunds creator exactly; double decline rejected', async () => {
    const id = await makeWaitingDuel(100, 50);
    const b0 = await balances('A', 'B');
    assert.deepEqual(b0.A, { ac: 900, wp: 450 }, 'creator paid the stake at create time');
    await fns.declineChallenge.run(H.req('B', { challengeId: id }));
    const b = await balances('A', 'B');
    assert.deepEqual(b.A, { ac: 1000, wp: 500 });
    const ch = await H.getDoc(db, `challenges/${id}`);
    assert.equal(ch.status, 'declined');
    await H.rejectsWith(
      fns.declineChallenge.run(H.req('B', { challengeId: id })),
      'failed-precondition', 'challenge_not_pending');
  });

  it('non-invited decline rejected (authz before state); decline after join rejected', async () => {
    const waiting = await makeWaitingDuel(100, 50);
    await H.rejectsWith(
      fns.declineChallenge.run(H.req('C', { challengeId: waiting })),
      'permission-denied', 'not_the_invited_opponent');
    // Once accepted the invite is no longer declinable.
    await clearCooldowns(); // A played B again too soon; 12h rematch gate applies
    const id = await makeDuel(100, 50);
    await H.rejectsWith(
      fns.declineChallenge.run(H.req('B', { challengeId: id })),
      'failed-precondition', 'challenge_not_pending');
  });

  it('expired invite refunds via sweep', async () => {
    const id = await makeWaitingDuel(100, 50);
    const ref = db.collection('challenges').doc(id);
    await ref.update({ expiresAt: FakeTimestamp.fromMillis(Date.now() - 1000) });
    await fns.expiredChallengeRefund.run({});
    const ch = (await ref.get()).data();
    assert.equal(ch.status, 'expired_refunded');
    const b = await balances('A', 'B');
    assert.equal(b.A.ac, 1000);
    assert.equal(b.A.wp, 500);
  });

  it('one-sided silence forfeits 0 after 15 minutes', async () => {
    const id = await makeDuel(100, 50);
    const ref = db.collection('challenges').doc(id);
    await ref.update({
      creatorScore: 8, status: 'creator_submitted',
      firstSubmittedAt: FakeTimestamp.fromMillis(Date.now() - 20 * 60 * 1000),
    });
    await fns.forfeitStalePartialChallenges.run({});
    const ch = (await ref.get()).data();
    assert.equal(ch.opponentScore, 0);
    assert.equal(ch.forfeitedUid, 'B');
  });

  it('spar: 3 paid wins per pair per day, 4th pays 0, counter resets next day', async () => {
    await db.collection('friendships').doc('A_B').set({
      aUid: 'A', bUid: 'B', status: 'active', requestedBy: 'A',
    });
    async function playSpar() {
      const r = await fns.createChallenge.run(H.req('A', {
        animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
        opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar', ...STAMP,
      }));
      await fns.joinChallenge.run(H.req('B', { challengeId: r.challengeId, ...STAMP }));
      await settle(r.challengeId, 9, 4);
    }
    await playSpar(); await playSpar(); await playSpar();
    let b = await balances('A', 'B');
    assert.equal(b.A.wp, 500 + 15, `3 paid spar wins = +15 WP, got ${b.A.wp}`);
    await playSpar();
    b = await balances('A', 'B');
    assert.equal(b.A.wp, 515, `4th spar same day pays 0, got ${b.A.wp}`);
    const pair = await H.getDoc(db, 'friendships/A_B');
    assert.equal(pair.sparWinsCount, 3);
    // Next WAT day: reset by backdating the counter, resolve again -> pays.
    await db.collection('friendships').doc('A_B').update({
      sparWinsDate: H.watDaysAgo(1),
    });
    await playSpar();
    b = await balances('A', 'B');
    assert.equal(b.A.wp, 520);
  });

  it('series: first-to-3 pays +100 AC + earn_series log, NO frame; draws replay', async () => {
    await H.mkUser(db, 'A', { username: 'A', animeCoins: 5000, weeklyPoints: 500 });
    await H.mkUser(db, 'B', { username: 'B', animeCoins: 5000, weeklyPoints: 500 });
    async function duel(a, bScore) {
      const id = await makeDuel(20, 5);
      return settle(id, a, bScore);
    }
    await duel(8, 5);
    await clearCooldowns();
    const d2 = await duel(6, 6); // draw replays: no series movement
    assert.equal(d2.outcome, 'draw');
    let riv = await H.getDoc(db, 'rivalries/A_B');
    assert.deepEqual([riv.winsA, riv.winsB, riv.seriesNo], [1, 0, 1]);
    await clearCooldowns();
    await duel(7, 5);
    await clearCooldowns();
    const d4 = await duel(9, 3);
    assert.equal(d4.seriesWinnerUid, 'A');
    assert.equal(d4.seriesPrizePaid, true);
    const aDoc = await H.getDoc(db, 'users/A');
    assert.ok(!(aDoc.ownedCosmetics || []).includes('frame_rivalry'), 'no frame granted');
    const logs = await db.collection('users').doc('A').collection('coinTransactions')
      .where('type', '==', 'earn_series').get();
    assert.equal(logs.size, 1);
    assert.equal(logs.docs[0].data().delta, 100);
    // 7-day gate: next series decides but pays nothing.
    await clearCooldowns();
    await duel(8, 2); await clearCooldowns();
    await duel(8, 2); await clearCooldowns();
    const d7 = await duel(8, 2);
    assert.equal(d7.seriesWinnerUid, 'A');
    assert.equal(d7.seriesPrizePaid, false);
    const logs2 = await db.collection('users').doc('A').collection('coinTransactions')
      .where('type', '==', 'earn_series').get();
    assert.equal(logs2.size, 1, 'no second earn_series inside 7 days');
    const aDoc2 = await H.getDoc(db, 'users/A');
    assert.ok(!(aDoc2.ownedCosmetics || []).includes('frame_rivalry'));
  });

  it('resolve trigger skips already-resolved docs (no double payout)', async () => {
    const id = await makeDuel(100, 50);
    await settle(id, 8, 5);
    const before = await balances('A', 'B');
    const ref = db.collection('challenges').doc(id);
    const snap = await ref.get();
    const afterData = snap.data();
    await fns.resolveChallengeOutcome.run({
      params: { challengeId: id },
      data: {
        before: { data: () => ({ ...afterData, resolved: false }) },
        after: { data: () => afterData, ref },
      },
    });
    const afterBal = await balances('A', 'B');
    assert.deepEqual(afterBal, before);
  });
});
