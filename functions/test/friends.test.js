// functions/test/friends.test.js �?friend graph, code lookup, spar friendship
// gate, friends board, nudge preset.
'use strict';
process.env.NODE_ENV = 'test';
const { test, describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const STAMP = { platform: 'android', appBuild: 3 };

async function pairDoc(a, b) {
  const id = [a, b].sort().join('_');
  return H.getDoc(db, `friendships/${id}`);
}
async function linkDoc(owner, other) {
  return H.getDoc(db, `users/${owner}/friendLinks/${other}`);
}

async function beFriends(a, b) {
  await db.collection('friendships').doc([a, b].sort().join('_')).set({
    aUid: [a, b].sort()[0], bUid: [a, b].sort()[1], status: 'active',
    requestedBy: a,
  });
  for (const [x, y] of [[a, b], [b, a]]) {
    await db.collection('users').doc(x).collection('friendLinks').doc(y)
      .set({ otherUid: y, status: 'friend', username: y, since: Date.now() });
  }
}

async function friendCode(uid) {
  const r = await fns.getMyFriendCode.run(H.req(uid, { ...STAMP }));
  return r.friendCode;
}

describe('friends', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    for (const u of ['A', 'B', 'C', 'D']) {
      await H.mkUser(db, u, { username: u, friendCount: 0, fcmToken: `tok_${u}` });
    }
    await H.seedQuestions(db);
  });

  it('mint code: 6 chars, idempotent, stable across calls', async () => {
    const c1 = await friendCode('A');
    assert.match(c1, /^[A-Z0-9]{6}$/);
    const c2 = await fns.getMyFriendCode.run(H.req('A', { ...STAMP }));
    assert.equal(c2.friendCode, c1, 'idempotent');
    const back = await H.getDoc(db, `friendCodes/${c1}`);
    assert.equal(back.uid, 'A');
    const userDoc = await H.getDoc(db, 'users/A');
    assert.equal(userDoc.friendCode, c1);
  });

  it('request by code creates pending pair + both friendLinks', async () => {
    const code = await friendCode('B');
    await fns.sendFriendRequest.run(H.req('A', { code, ...STAMP }));
    const pair = await pairDoc('A', 'B');
    assert.equal(pair.status, 'pending');
    assert.equal(pair.aUid, 'A');
    assert.equal(pair.bUid, 'B');
    const myLink = await linkDoc('A', 'B');
    assert.equal(myLink.status, 'outgoing');
    const peerLink = await linkDoc('B', 'A');
    assert.equal(peerLink.status, 'incoming');
  });

  it('unknown code �?not_found and counts against the 15/day attempt budget', async () => {
    await H.rejectsWith(
      fns.sendFriendRequest.run(H.req('A', { code: 'ZZZZZZ', ...STAMP })),
      'not-found', 'not_found');
    let u = await H.getDoc(db, 'users/A');
    assert.equal(u.failedCodeCount, 1);
    // Grind to the ceiling.
    for (let i = 0; i < 14; i++) {
      await H.rejectsWith(
        fns.sendFriendRequest.run(H.req('A', { code: 'ZZZZZZ', ...STAMP })),
        'not-found');
    }
    await H.rejectsWith(
      fns.sendFriendRequest.run(H.req('A', { code: 'ZZZZZZ', ...STAMP })),
      'resource-exhausted', 'too_many_attempts');
    u = await H.getDoc(db, 'users/A');
    assert.equal(u.failedCodeCount, 15);
  });

  it('accept makes pair active, friendCount both sides, links friend', async () => {
    const code = await friendCode('B');
    await fns.sendFriendRequest.run(H.req('A', { code, ...STAMP }));
    await fns.respondFriendRequest.run(H.req('B', { otherUid: 'A', accept: true, ...STAMP }));
    const pair = await pairDoc('A', 'B');
    assert.equal(pair.status, 'active');
    const a = await H.getDoc(db, 'users/A');
    const b = await H.getDoc(db, 'users/B');
    assert.equal(a.friendCount, 1);
    assert.equal(b.friendCount, 1);
    assert.equal((await linkDoc('A', 'B')).status, 'friend');
    assert.equal((await linkDoc('B', 'A')).status, 'friend');
  });

  it('cannot accept own request', async () => {
    const code = await friendCode('B');
    await fns.sendFriendRequest.run(H.req('A', { code, ...STAMP }));
    await H.rejectsWith(
      fns.respondFriendRequest.run(H.req('A', { otherUid: 'B', accept: true, ...STAMP })),
      'failed-precondition', 'cannot_accept_own_request');
  });

  it('reject keeps the pair as declined (cooldown) and drops both links', async () => {
    const code = await friendCode('B');
    await fns.sendFriendRequest.run(H.req('A', { code, ...STAMP }));
    await fns.respondFriendRequest.run(H.req('B', { otherUid: 'A', accept: false, ...STAMP }));
    assert.equal((await pairDoc('A', 'B')).status, 'declined');
    assert.equal(await linkDoc('A', 'B'), null);
    assert.equal(await linkDoc('B', 'A'), null);
  });

  it('block: pair blocked, friendCount slot freed, target link removed', async () => {
    await beFriends('A', 'B');
    await H.mkUser(db, 'A', { username: 'A', friendCount: 1 });
    await H.mkUser(db, 'B', { username: 'B', friendCount: 1 });
    await fns.blockUser.run(H.req('A', { otherUid: 'B', ...STAMP }));
    const pair = await pairDoc('A', 'B');
    assert.equal(pair.status, 'blocked');
    assert.equal(pair.blockedBy, 'A');
    assert.equal((await H.getDoc(db, 'users/A')).friendCount, 0);
    assert.equal((await H.getDoc(db, 'users/B')).friendCount, 0);
    assert.equal(await linkDoc('B', 'A'), null, 'blockee link removed');
    assert.equal((await linkDoc('A', 'B')).status, 'blocked');
  });

  it('block auto-declines a pending invite between the pair and refunds the creator', async () => {
    const code = await friendCode('B');
    await fns.sendFriendRequest.run(H.req('A', { code, ...STAMP }));
    await db.collection('users').doc('A').update({ animeCoins: 1000, weeklyPoints: 500 });
    const r = await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 100, wpStake: 50,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival', ...STAMP,
    }));
    const res = await fns.blockUser.run(H.req('A', { otherUid: 'B', ...STAMP }));
    assert.equal(res.autoDeclined, 1);
    const ch = await H.getDoc(db, `challenges/${r.challengeId}`);
    assert.equal(ch.status, 'declined');
    const after = await H.getDoc(db, 'users/A');
    assert.equal(after.animeCoins, 1000, 'stake refunded');
    assert.equal(after.weeklyPoints, 500, 'wp stake refunded');
  });

  it('blocked pairs report the same not_found as an unknown code (no oracle)', async () => {
    await beFriends('A', 'B');
    await fns.blockUser.run(H.req('A', { otherUid: 'B', ...STAMP }));
    const codeB = await friendCode('B');
    // A blocked B, so A requesting B must look identical to an unknown code.
    await H.rejectsWith(
      fns.sendFriendRequest.run(H.req('A', { code: codeB, ...STAMP })),
      'not-found', 'not_found');
  });

  it('spar on non-friend pair �?not_friends; spar on friend pair allowed', async () => {
    await H.seedQuestions(db);
    await H.rejectsWith(
      fns.createChallenge.run(H.req('A', {
        animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
        opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar', ...STAMP,
      })),
      'failed-precondition', 'not_friends');
    await beFriends('A', 'B');
    const r = await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar', ...STAMP,
    }));
    assert.ok(r.challengeId);
    const ch = await H.getDoc(db, `challenges/${r.challengeId}`);
    assert.equal(ch.challengeType, 'spar');
  });

  it('friends board: only board-safe fields, university whitelist enforced', async () => {
    await beFriends('A', 'B');
    await beFriends('A', 'C');
    await db.collection('users').doc('B').update({
      animeCoins: 999999, 'stats.gamesPlayed': 42, weeklyPoints: 700,
    });
    await db.collection('users').doc('C').update({
      university: 'NOT_A_UNIVERSITY', weeklyPoints: 999,
    });
    const today = H.watToday();
    await db.collection('users').doc('B').update({ leaderboardEntryWeekId: H.thisWeekId() });
    await db.collection('users').doc('C').update({ leaderboardEntryWeekId: H.thisWeekId() });
    const board = await fns.getFriendsBoard.run(H.req('A', { ...STAMP }));
    assert.ok(Array.isArray(board.friends));
    assert.equal(board.friends.length, 2);
    const byUid = Object.fromEntries(board.friends.map((f) => [f.uid, f]));
    assert.deepEqual(Object.keys(byUid).sort(), ['B', 'C']);
    for (const f of board.friends) {
      // Exactly the allowed keys �?no coins, no stats, no transaction history.
      const keys = Object.keys(f).sort();
      assert.deepEqual(keys, ['entryWeekId', 'myTurn', 'nudgedToday', 'playedToday', 'theirTurn', 'uid', 'university', 'username', 'weeklyPoints'],
        `unexpected keys: ${keys.join(',')}`);
      assert.ok(!('animeCoins' in f), 'animeCoins must not leak');
      assert.ok(!('stats' in f), 'stats must not leak');
    }
    // Whitelisted university passes through; junk is dropped.
    assert.equal(byUid.B.university, 'UNILAG');
    assert.equal(byUid.C.university, '');
    assert.equal(typeof byUid.B.username, 'string');
    assert.equal(byUid.B.weeklyPoints, 700);
  });

  it('friends board hides weeklyPoints for stale entry weeks', async () => {
    await beFriends('A', 'B');
    await beFriends('A', 'C');
    const stale = H.watDaysAgo(10);
    await db.collection('users').doc('B').update({
      leaderboardEntryWeekId: H.thisWeekId(), weeklyPoints: 700,
    });
    await db.collection('users').doc('C').update({
      leaderboardEntryWeekId: stale, weeklyPoints: 999,
    });
    const { friends } = await fns.getFriendsBoard.run(H.req('A', { ...STAMP }));
    const byUid = Object.fromEntries(friends.map((f) => [f.uid, f]));
    assert.equal(byUid.B.weeklyPoints, 700);
    assert.equal(byUid.C.weeklyPoints, null, 'stale-week friend shows no WP');
    assert.equal(byUid.C.entryWeekId, stale);
  });

  it('removeFriend frees both slots and drops both links', async () => {
    await beFriends('A', 'B');
    await H.mkUser(db, 'A', { username: 'A', friendCount: 1 });
    await H.mkUser(db, 'B', { username: 'B', friendCount: 1 });
    await fns.removeFriend.run(H.req('A', { otherUid: 'B', ...STAMP }));
    assert.equal(await pairDoc('A', 'B'), null);
    assert.equal(await linkDoc('A', 'B'), null);
    assert.equal(await linkDoc('B', 'A'), null);
    assert.equal((await H.getDoc(db, 'users/A')).friendCount, 0);
    assert.equal((await H.getDoc(db, 'users/B')).friendCount, 0);
  });

  it('nudge: non-friend �?not_friends; friend + their turn �?ok once/day', async () => {
    await H.seedQuestions(db);
    await H.rejectsWith(
      fns.nudgeFriend.run(H.req('A', { friendUid: 'B', ...STAMP })),
      'failed-precondition', 'not_friends');
    await beFriends('A', 'B');
    await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar', ...STAMP,
    }));
    const ok = await fns.nudgeFriend.run(H.req('A', { friendUid: 'B', ...STAMP }));
    assert.equal(ok.success, true);
    // Second nudge same WAT day is rate limited.
    await H.rejectsWith(
      fns.nudgeFriend.run(H.req('A', { friendUid: 'B', ...STAMP })),
      'resource-exhausted', 'nudge_limit_reached');
  });

  it('nudge is rolled back when the push fails, so today\'s one is still available', async () => {
    await H.seedQuestions(db);
    await beFriends('A', 'B');
    await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar', ...STAMP,
    }));
    ctx.pushFlags.failPush = true;
    await H.rejectsWith(
      fns.nudgeFriend.run(H.req('A', { friendUid: 'B', ...STAMP })),
      'unavailable', 'nudge_not_delivered');
    assert.equal((await pairDoc('A', 'B')).lastNudgeAt?.A_B, undefined, 'stamp rolled back');
    ctx.pushFlags.failPush = false;
    const ok = await fns.nudgeFriend.run(H.req('A', { friendUid: 'B', ...STAMP }));
    assert.equal(ok.success, true);
    assert.ok((await pairDoc('A', 'B')).lastNudgeAt.A_B, 'stamped after the push went out');
  });

  it('nudge to a friend with no push token is not delivered and not stamped', async () => {
    await H.seedQuestions(db);
    await beFriends('A', 'B');
    await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar', ...STAMP,
    }));
    await db.collection('users').doc('B').update({ fcmToken: null });
    await H.rejectsWith(
      fns.nudgeFriend.run(H.req('A', { friendUid: 'B', ...STAMP })),
      'unavailable', 'nudge_not_delivered');
    assert.equal((await pairDoc('A', 'B')).lastNudgeAt?.A_B, undefined);
  });

  it('board: nudgedToday is true only for a nudge stamped today (WAT)', async () => {
    await H.seedQuestions(db);
    await beFriends('A', 'B');
    await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar', ...STAMP,
    }));
    let board = await fns.getFriendsBoard.run(H.req('A', { ...STAMP }));
    assert.equal(board.friends[0].nudgedToday, false);
    await fns.nudgeFriend.run(H.req('A', { friendUid: 'B', ...STAMP }));
    board = await fns.getFriendsBoard.run(H.req('A', { ...STAMP }));
    assert.equal(board.friends[0].nudgedToday, true);
    // The nudge is A's to B: B's view of A has no stamp.
    const bBoard = await fns.getFriendsBoard.run(H.req('B', { ...STAMP }));
    assert.equal(bBoard.friends[0].nudgedToday, false);
    // A stamp from yesterday no longer counts.
    await db.collection('friendships').doc('A_B').update({
      'lastNudgeAt.A_B': new ctx.FakeTimestamp(Date.now() - 26 * 60 * 60 * 1000),
    });
    board = await fns.getFriendsBoard.run(H.req('A', { ...STAMP }));
    assert.equal(board.friends[0].nudgedToday, false);
  });

  it('board: myTurn means I owe the friend a move, theirTurn means they owe me', async () => {
    await H.seedQuestions(db);
    await beFriends('A', 'B');
    // B challenges A, so A owes the next move.
    await fns.createChallenge.run(H.req('B', {
      animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
      opponentUid: 'A', opponentUsername: 'A', challengeType: 'spar', ...STAMP,
    }));
    const aBoard = await fns.getFriendsBoard.run(H.req('A', { ...STAMP }));
    assert.equal(aBoard.friends[0].myTurn, true, 'A owes B');
    assert.equal(aBoard.friends[0].theirTurn, false);
    const bBoard = await fns.getFriendsBoard.run(H.req('B', { ...STAMP }));
    assert.equal(bBoard.friends[0].myTurn, false);
    assert.equal(bBoard.friends[0].theirTurn, true, 'A owes B, so B can nudge A');
  });

  it('board: playedToday is true only for a match played since WAT midnight', async () => {
    await beFriends('A', 'B');
    await beFriends('A', 'C');
    await db.collection('users').doc('B').collection('matches').doc('m1')
      .set({ timestamp: new ctx.FakeTimestamp(Date.now()) });
    await db.collection('users').doc('C').collection('matches').doc('m2')
      .set({ timestamp: new ctx.FakeTimestamp(Date.now() - 3 * 24 * 60 * 60 * 1000) });
    const { friends } = await fns.getFriendsBoard.run(H.req('A', { ...STAMP }));
    const byUid = Object.fromEntries(friends.map((f) => [f.uid, f]));
    assert.equal(byUid.B.playedToday, true);
    assert.equal(byUid.C.playedToday, false, 'a match from 3 days ago is not today');
  });

  it('mutual request: sending back to someone who asked you accepts instead', async () => {
    await fns.sendFriendRequest.run(H.req('B', { code: await friendCode('A'), ...STAMP }));
    const r = await fns.sendFriendRequest.run(
      H.req('A', { code: await friendCode('B'), ...STAMP }));
    assert.equal(r.status, 'active');
    assert.equal((await pairDoc('A', 'B')).status, 'active');
    assert.equal((await linkDoc('A', 'B')).status, 'friend');
    assert.equal((await linkDoc('B', 'A')).status, 'friend');
    assert.equal((await H.getDoc(db, 'users/A')).friendCount, 1);
    assert.equal((await H.getDoc(db, 'users/B')).friendCount, 1);
  });

  it('friend cap: cannot send a request while you are at 50 friends', async () => {
    const code = await friendCode('B');
    await H.mkUser(db, 'A', { username: 'A', friendCount: 50 });
    await H.rejectsWith(
      fns.sendFriendRequest.run(H.req('A', { code, ...STAMP })),
      'resource-exhausted', 'friend_limit_reached');
    assert.equal(await pairDoc('A', 'B'), null, 'nothing written');
  });

  it('friend cap: cannot send to a player who is already at 50 friends', async () => {
    await H.mkUser(db, 'B', { username: 'B', friendCount: 50 });
    const code = await friendCode('B');
    await H.rejectsWith(
      fns.sendFriendRequest.run(H.req('A', { code, ...STAMP })),
      'resource-exhausted', 'peer_friend_limit');
    assert.equal(await pairDoc('A', 'B'), null, 'nothing written');
  });

  it('declined request: the same requester waits 7 days before asking again', async () => {
    const code = await friendCode('B');
    await fns.sendFriendRequest.run(H.req('A', { code, ...STAMP }));
    await fns.respondFriendRequest.run(H.req('B', { otherUid: 'A', accept: false, ...STAMP }));
    assert.equal((await pairDoc('A', 'B')).status, 'declined');
    assert.equal(await linkDoc('A', 'B'), null);
    assert.equal(await linkDoc('B', 'A'), null);
    await H.rejectsWith(
      fns.sendFriendRequest.run(H.req('A', { code, ...STAMP })),
      'failed-precondition', 'request_cooldown');
    await db.collection('friendships').doc('A_B').update({
      declinedAt: new ctx.FakeTimestamp(Date.now() - 8 * 24 * 60 * 60 * 1000),
    });
    await fns.sendFriendRequest.run(H.req('A', { code, ...STAMP }));
    assert.equal((await pairDoc('A', 'B')).status, 'pending');
  });

  it('raw-uid requests are limited to the same campus or paid cohort', async () => {
    const week = H.thisWeekId();
    await db.collection('users').doc('A').update({ university: 'UNILAG', leaderboardEntryWeekId: week });
    await db.collection('users').doc('B').update({ university: 'UNILAG', leaderboardEntryWeekId: week });
    await db.collection('users').doc('C').update({ university: 'OAU', leaderboardEntryWeekId: week + '-prev' });
    await db.collection('users').doc('D').update({ university: 'OAU', leaderboardEntryWeekId: week });
    // Different campus AND a different paid week: indistinguishable from unknown.
    await H.rejectsWith(
      fns.sendFriendRequest.run(H.req('A', { uid: 'C', ...STAMP })),
      'not-found', 'not_found');
    assert.equal(await pairDoc('A', 'C'), null);
    await fns.sendFriendRequest.run(H.req('A', { uid: 'B', ...STAMP }));
    assert.equal((await pairDoc('A', 'B')).status, 'pending');
    // Same paid week but a different campus (a Rankings board row the caller
    // paid to read): allowed via the paid cohort.
    await fns.sendFriendRequest.run(H.req('A', { uid: 'D', ...STAMP }));
    assert.equal((await pairDoc('A', 'D')).status, 'pending');
  });

  it('raw-uid requests are allowed for a player you have played', async () => {
    const week = H.thisWeekId();
    await db.collection('users').doc('A').update({ university: 'UNILAG', leaderboardEntryWeekId: week });
    await db.collection('users').doc('C').update({ university: 'OAU', leaderboardEntryWeekId: week + '-prev' });
    // Different campus, different paid week and no match yet: still indistinguishable from unknown.
    await H.rejectsWith(
      fns.sendFriendRequest.run(H.req('A', { uid: 'C', ...STAMP })),
      'not-found', 'not_found');
    // A real match in the caller's own history unlocks the rival-page request.
    await db.collection('users').doc('A').collection('matches').doc('m1').set({
      opponentUid: 'C', opponent: 'C', outcome: 'win',
      timestamp: new ctx.FakeTimestamp(Date.now()),
    });
    await fns.sendFriendRequest.run(H.req('A', { uid: 'C', ...STAMP }));
    assert.equal((await pairDoc('A', 'C')).status, 'pending');
    assert.equal((await linkDoc('C', 'A')).status, 'incoming');
  });

  it('block: blocking an active friend works (reads before writes)', async () => {
    await beFriends('A', 'B');
    await H.mkUser(db, 'A', { username: 'A', friendCount: 1 });
    await H.mkUser(db, 'B', { username: 'B', friendCount: 1 });
    const res = await fns.blockUser.run(H.req('A', { otherUid: 'B', ...STAMP }));
    assert.equal(res.success, true);
    assert.equal((await pairDoc('A', 'B')).status, 'blocked');
  });

  it('block: an unknown player is not_found and nothing is written', async () => {
    await H.rejectsWith(
      fns.blockUser.run(H.req('A', { otherUid: 'GHOST_X', ...STAMP })),
      'not-found', 'not_found');
    assert.equal(await pairDoc('A', 'GHOST_X'), null);
  });

  it('friends board: theirTurn is true only for the friend who owes a move', async () => {
    await H.seedQuestions(db);
    await beFriends('A', 'B');
    await beFriends('A', 'C');
    await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar', ...STAMP,
    }));
    const aBoard = await fns.getFriendsBoard.run(H.req('A', { ...STAMP }));
    const byA = Object.fromEntries(aBoard.friends.map((f) => [f.uid, f]));
    assert.equal(byA.B.theirTurn, true);
    assert.equal(byA.C.theirTurn, false);
    const bBoard = await fns.getFriendsBoard.run(H.req('B', { ...STAMP }));
    assert.equal(bBoard.friends[0].theirTurn, false, 'the challenger is waiting, not B');
  });

  it('staked duel: a blocked pair cannot create a duel', async () => {
    await H.seedQuestions(db);
    await db.collection('users').doc('A').update({ animeCoins: 1000, weeklyPoints: 500 });
    await db.collection('friendships').doc('A_B').set({
      aUid: 'A', bUid: 'B', status: 'blocked', blockedBy: 'B',
    });
    await H.rejectsWith(
      fns.createChallenge.run(H.req('A', {
        animeTitle: 'testanime', stakeAmount: 100, wpStake: 50,
        opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival', ...STAMP,
      })),
      'failed-precondition', 'blocked');
  });

  it('staked duel: a block placed after the invite stops the join', async () => {
    await H.seedQuestions(db);
    await db.collection('users').doc('A').update({ animeCoins: 1000, weeklyPoints: 500 });
    await db.collection('users').doc('B').update({ animeCoins: 1000, weeklyPoints: 500 });
    const r = await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 100, wpStake: 50,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival', ...STAMP,
    }));
    // Written directly so the invite is not auto-declined; this isolates the join gate.
    await db.collection('friendships').doc('A_B').set({
      aUid: 'A', bUid: 'B', status: 'blocked', blockedBy: 'A',
    });
    await H.rejectsWith(
      fns.joinChallenge.run(H.req('B', { challengeId: r.challengeId, ...STAMP })),
      'failed-precondition', 'blocked');
  });
});
