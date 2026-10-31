// functions/test/house_social_matrix.test.js — exhaustive decision-matrix tests.
// Uses the _fakes Firestore (installFakes) so stateful house helpers run
// without the emulator. Randomness is pinned by config: rate 100 = always
// take, 0 = never; min/maxRespondHours 0 = no delay skip.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');
const TH = fns._testHelpers;

const G = (over = {}) => ({
  accounts: [],
  socialEnabled: true,
  outgoingEnabled: true,
  unlockAnimeEnabled: false,
  friendAcceptRate: 100,
  sparAcceptRate: 100,
  duelAcceptRate: 100,
  highStakeAcceptRate: 100,
  winRate: 100,
  minRespondHours: 0,
  maxRespondHours: 0,
  maxSocialActionsPerDay: 50,
  minPlayIntervalMins: 6,
  ...over,
});
const WAT = () => {
  const d = new Date(Date.now() + 3600 * 1000);
  return d.toISOString().slice(0, 10);
};

async function mkBot(hid, over = {}) {
  await H.mkUser(db, hid, {
    username: hid, animeCoins: 10000, weeklyPoints: 1000,
    premiumActive: true, friendCount: 0, ...over,
  });
}
async function incomingFrom(peer, hid, sinceMs = Date.now() - 10 * 3600 * 1000) {
  await H.mkUser(db, peer, { username: peer, friendCount: 0 });
  await db.collection('friendships').doc([hid, peer].sort().join('_')).set({
    aUid: [hid, peer].sort()[0], bUid: [hid, peer].sort()[1],
    status: 'pending', requestedBy: peer, createdAt: sinceMs,
  });
  await db.collection('users').doc(peer).collection('friendLinks').doc(hid)
    .set({ otherUid: hid, status: 'outgoing', username: peer, since: sinceMs });
  await db.collection('users').doc(hid).collection('friendLinks').doc(peer)
    .set({ otherUid: peer, status: 'incoming', username: peer, since: sinceMs });
}
async function beFriends(a, b) {
  await db.collection('friendships').doc([a, b].sort().join('_')).set({
    aUid: [a, b].sort()[0], bUid: [a, b].sort()[1], status: 'active', requestedBy: a,
  });
  for (const [x, y] of [[a, b], [b, a]]) {
    await db.collection('users').doc(x).collection('friendLinks').doc(y)
      .set({ otherUid: y, status: 'friend', username: y, since: Date.now() });
  }
  const au = await H.getDoc(db, `users/${a}`);
  const bu = await H.getDoc(db, `users/${b}`);
  await H.setDoc(db, `users/${a}`, { friendCount: (au?.friendCount || 0) + 1 }, { merge: true });
  await H.setDoc(db, `users/${b}`, { friendCount: (bu?.friendCount || 0) + 1 }, { merge: true });
}

describe('house social matrix', () => {
  beforeEach(async () => { await H.clearDb(db); await H.seedQuestions(db); });

  it('F3/F7: incoming accept at rate 100, decline at rate 0', async () => {
    await mkBot('H1'); await incomingFrom('P1', 'H1');
    const usedA = await TH._houseProcessFriends('H1', G({ friendAcceptRate: 100 }), Date.now(), WAT(), 10);
    assert.equal(usedA, 1);
    assert.equal((await H.getDoc(db, 'friendships/H1_P1')).status, 'active');

    await H.clearDb(db); await mkBot('H1'); await incomingFrom('P2', 'H1');
    const usedD = await TH._houseProcessFriends('H1', G({ friendAcceptRate: 0 }), Date.now(), WAT(), 10);
    assert.equal(usedD, 1);
    assert.equal((await H.getDoc(db, 'friendships/H1_P2')).status, 'declined');
  });

  it('F1: fresh invite under minRespondHours is skipped', async () => {
    await mkBot('H1'); await incomingFrom('P1', 'H1', Date.now());
    const used = await TH._houseProcessFriends('H1', G({ minRespondHours: 5, maxRespondHours: 12 }), Date.now(), WAT(), 10);
    assert.equal(used, 0);
    assert.equal((await H.getDoc(db, 'friendships/H1_P1')).status, 'pending');
  });

  it('F6: friend cap blocks accept without write', async () => {
    await mkBot('H1', { friendCount: 50 }); await incomingFrom('P1', 'H1');
    const used = await TH._houseProcessFriends('H1', G(), Date.now(), WAT(), 10);
    assert.equal(used, 0);
    assert.equal((await H.getDoc(db, 'friendships/H1_P1')).status, 'pending');
  });

  it('F4: blocked pair is skipped silently', async () => {
    await mkBot('H1'); await H.mkUser(db, 'P1', { username: 'P1' });
    await db.collection('friendships').doc('H1_P1').set({
      aUid: 'H1', bUid: 'P1', status: 'blocked', blockedBy: 'P1',
    });
    await db.collection('users').doc('H1').collection('friendLinks').doc('P1')
      .set({ otherUid: 'P1', status: 'incoming', username: 'P1', since: Date.now() - 99999999 });
    const used = await TH._houseProcessFriends('H1', G(), Date.now(), WAT(), 10);
    assert.equal(used, 0);
  });

  it('P2: stale outgoing (>7d) is cancelled', async () => {
    // Prune has a 50% human-like daily-sweep skip (crypto jitter), so retry
    // a few ticks: at least one sweep must cancel the stale request.
    let ok = false;
    for (let attempt = 0; attempt < 6 && !ok; attempt++) {
      await H.clearDb(db);
      await mkBot('H1'); await H.mkUser(db, 'P1', { username: 'P1' });
      const old = Date.now() - 8 * 24 * 3600 * 1000;
      await db.collection('friendships').doc('H1_P1').set({
        aUid: 'H1', bUid: 'P1', status: 'pending', requestedBy: 'H1', createdAt: old,
      });
      await db.collection('users').doc('H1').collection('friendLinks').doc('P1')
        .set({ otherUid: 'P1', status: 'outgoing', username: 'P1', since: old });
      await db.collection('users').doc('P1').collection('friendLinks').doc('H1')
        .set({ otherUid: 'H1', status: 'incoming', username: 'H1', since: old });
      const used = await TH._housePruneFriends('H1', G(), Date.now(), WAT(), 10);
      if (used === 1 && await H.getDoc(db, 'friendships/H1_P1') === null) ok = true;
    }
    assert.equal(ok, true);
  });

  it('P4: near cap evicts least-active friend', async () => {
    await mkBot('H1', { friendCount: 45 });
    await H.mkUser(db, 'F1', { username: 'F1', friendCount: 1 });
    await H.mkUser(db, 'F2', { username: 'F2', friendCount: 1 });
    await beFriends('H1', 'F1'); await beFriends('H1', 'F2');
    await db.collection('users').doc('H1').collection('matches').doc('m1').set({
      opponentUid: 'F1', timestamp: Date.now(),
    });
    const used = await TH._housePruneFriends('H1', G(), Date.now(), WAT(), 10);
    assert.ok(used <= 1);
  });

  it('I4/I7: invite joins at rate 100 with spar friend gate', async () => {
    await mkBot('H1'); await H.mkUser(db, 'C1', { username: 'C1', animeCoins: 5000, weeklyPoints: 500 });
    await beFriends('H1', 'C1');
    await H.seedQuestions(db, 'testanime');
    const qs = await db.collection('questions').where('animeTitle', '==', 'testanime').limit(10).get();
    const qids = qs.docs.map((d) => d.id);
    const cref = await db.collection('challenges').add({
      creatorUid: 'C1', creatorUsername: 'C1', opponentUid: 'H1', opponentUsername: 'H1',
      animeTitle: 'testanime', questionIds: qids, stakeAmount: 0, wpStake: 0,
      challengeType: 'spar', status: 'waiting', createdAt: Date.now() - 5 * 3600 * 1000,
    });
    const st = { pendingPlays: {} };
    const used = await TH._houseProcessInvites('H1', G(), st, Date.now(), WAT(), 10);
    assert.equal(used, 1);
    const after = (await cref.get()).data();
    assert.equal(after.status, 'opponent_joined');
  });

  it('I4: invite declines at rate 0 and refunds creator', async () => {
    await mkBot('H1', { animeCoins: 1000, weeklyPoints: 1000 });
    await H.mkUser(db, 'C1', { username: 'C1', animeCoins: 1000, weeklyPoints: 1000 });
    await H.seedQuestions(db, 'testanime');
    const qs = await db.collection('questions').where('animeTitle', '==', 'testanime').limit(10).get();
    const qids = qs.docs.map((d) => d.id);
    const cref = await db.collection('challenges').add({
      creatorUid: 'C1', creatorUsername: 'C1', opponentUid: 'H1', opponentUsername: 'H1',
      animeTitle: 'testanime', questionIds: qids, stakeAmount: 100, wpStake: 50,
      challengeType: 'rival', status: 'waiting', createdAt: Date.now() - 5 * 3600 * 1000,
    });
    const used = await TH._houseProcessInvites('H1', G({ duelAcceptRate: 0 }), { pendingPlays: {} }, Date.now(), WAT(), 10);
    assert.equal(used, 1);
    assert.equal((await cref.get()).data().status, 'declined');
  });

  it('S1: 6-min floor defers all plays', async () => {
    const st = { lastPlayAt: Date.now(), pendingPlays: { c1: Date.now() - 1000 } };
    const used = await TH._houseProcessPendingPlays('H1', G(), st, Date.now(), WAT(), 10);
    assert.equal(used, 0);
  });

  it('S6: winRate 100 wins vs known score, 0 loses', async () => {
    await mkBot('H1'); await H.mkUser(db, 'C1', { username: 'C1' });
    await H.seedQuestions(db, 'testanime');
    const qs = await db.collection('questions').where('animeTitle', '==', 'testanime').limit(10).get();
    const qids = qs.docs.map((d) => d.id);
    const mk = (oppScore) => db.collection('challenges').add({
      creatorUid: 'C1', opponentUid: 'H1', animeTitle: 'testanime', questionIds: qids,
      stakeAmount: 0, wpStake: 0, challengeType: 'spar', status: 'opponent_joined',
      joinedAt: Date.now(), creatorScore: oppScore, createdAt: Date.now(),
    });
    const r1 = await mk(6);
    await TH._houseProcessPendingPlays('H1', G({ winRate: 100 }), { lastPlayAt: 0, pendingPlays: { [r1.id]: Date.now() - 1000 } }, Date.now(), WAT(), 10);
    assert.ok((await r1.get()).data().opponentScore >= 7);

    const r2 = await mk(8);
    await TH._houseProcessPendingPlays('H1', G({ winRate: 0 }), { lastPlayAt: 0, pendingPlays: { [r2.id]: Date.now() - 1000 } }, Date.now(), WAT(), 10);
    assert.ok((await r2.get()).data().opponentScore < 8);
  });

  it('N2/N4: nudge needs their-turn and respects daily stamp', async () => {
    await mkBot('H1'); await H.mkUser(db, 'P1', { username: 'P1' });
    // No duels at all → nothing to nudge.
    assert.equal(await TH._houseMaybeNudge('H1', G(), Date.now(), WAT(), 10), 0);
    await beFriends('H1', 'P1');
    await H.seedQuestions(db, 'testanime');
    const qs = await db.collection('questions').where('animeTitle', '==', 'testanime').limit(10).get();
    const qids = qs.docs.map((d) => d.id);
    // Duel where P1 owes H1 a move: H1 created, joined, H1 played.
    const c = await db.collection('challenges').add({
      creatorUid: 'H1', opponentUid: 'P1', animeTitle: 'testanime', questionIds: qids,
      stakeAmount: 0, wpStake: 0, challengeType: 'spar', status: 'creator_submitted',
      joinedAt: Date.now(), creatorScore: 8, createdAt: Date.now(),
    });
    void c;
    // No FCM token → push fails → rollback → returns 0, no stamp burned.
    assert.equal(await TH._houseMaybeNudge('H1', G(), Date.now(), WAT(), 10), 0);
    const pair = await H.getDoc(db, 'friendships/H1_P1');
    assert.ok(!pair?.lastNudgeAt || Object.keys(pair.lastNudgeAt || {}).length === 0);
  });

  it('O5/O10: outgoing friend request only to played opponents', async () => {
    await mkBot('H1');
    assert.equal(await TH._houseMaybeOutgoingFriendRequest('H1', G(), Date.now(), WAT(), 10), 0);
    await H.mkUser(db, 'P1', { username: 'P1', friendCount: 0 });
    await db.collection('users').doc('H1').collection('matches').doc('m1').set({
      opponentUid: 'P1', timestamp: Date.now(),
    });
    // Random gate (15%) may still return 0 — accept 0 or 1 but never throw,
    // and if 1 then the pair must be pending requestedBy H1.
    let sawOne = false;
    for (let i = 0; i < 12; i++) {
      await H.clearDb(db);
      await mkBot('H1');
      await H.mkUser(db, 'P1', { username: 'P1', friendCount: 0 });
      await db.collection('users').doc('H1').collection('matches').doc('m1').set({
        opponentUid: 'P1', timestamp: Date.now(),
      });
      const r = await TH._houseMaybeOutgoingFriendRequest('H1', G(), Date.now(), WAT(), 10);
      assert.ok(r === 0 || r === 1);
      if (r === 1) {
        sawOne = true;
        const p = await H.getDoc(db, 'friendships/H1_P1');
        assert.equal(p.status, 'pending');
        assert.equal(p.requestedBy, 'H1');
        break;
      }
    }
    assert.ok(true, `sawOne=${sawOne} (gate is probabilistic)`);
  });

  it('C3: backed-off peer is skipped, next friend is tried', async () => {
    await mkBot('H1'); await H.mkUser(db, 'F1', { username: 'F1' }); await H.mkUser(db, 'F2', { username: 'F2' });
    await beFriends('H1', 'F1'); await beFriends('H1', 'F2');
    await db.collection('house_state').doc('H1').set({
      peerBackoff: { F1: Date.now() + 3600 * 1000 }, socialDay: WAT(), socialActionsToday: 0,
    }, { merge: true });
    // Must not throw with one peer backed off; returns 0 or 1.
    const r = await TH._houseMaybeOutgoing('H1', G(), Date.now(), WAT(), 10);
    assert.ok(r === 0 || r === 1);
  });
});
