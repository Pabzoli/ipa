// functions/test/admin.test.js — ghost-admin isolation regression tests.
//
// Admin accounts are GHOSTS: never ranked, never paid, never notified, never
// counted on any player-facing board or query. The reported bug was that an
// admin who redeemed a weekly leaderboard-entry code was counted for the prize
// split (ranked[]/eligibleCount/top-5 winners) even though the client only hid
// the row from display. These tests exercise the REAL handlers:
//   1. runWeeklyReset excludes the admin from the cycle, the winner snapshot
//      and the push broadcast, and clears the admin's stale entry state.
//   2. redeemCode refuses an admin a leaderboard_entry code, while still
//      allowing an ordinary AC grant (no over-blocking).
//   3. getFriendsBoard filters the admin out of a player's friends board.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

// The real admin UID from functions/index.js ADMIN_UIDS.
const ADMIN = 'owMNkXmb6QSzO0xfHkSgMlx0zSJ3';
const STAMP = { platform: 'android', appBuild: 999 };

async function user(uid) {
  return H.getDoc(db, `users/${uid}`);
}

describe('ghost admin isolation', () => {
  beforeEach(async () => {
    await H.clearDb(db);
  });

  it('runWeeklyReset: admin never ranked/paid/counted, entry state cleared', async () => {
    const weekId = H.thisWeekId();

    // Active pool for THIS week with entry revenue so the cycle gets a pool.
    await H.setDoc(db, `prize_pool/${weekId}`, {
      weekId, status: 'active', totalNaira: 1000, entryCodeRevenue: 1000,
    });

    // The admin holds a stale entry + a token + a top score: exactly the state
    // that used to drag them into the split.
    await H.mkUser(db, ADMIN, {
      username: 'Admin', university: 'ADMIN_U',
      weeklyPoints: 999999,
      leaderboardEntryWeekId: weekId,
      leaderboardEntryEmail: 'admin@t.co',
      fcmToken: 'admin-token',
    });

    // Five ordinary eligible players, all safely under the WP cap.
    const players = [
      ['P1', 9000], ['P2', 8000], ['P3', 7000], ['P4', 6000], ['P5', 5000],
    ];
    for (const [uid, wp] of players) {
      await H.mkUser(db, uid, {
        username: uid, university: 'UNILAG', weeklyPoints: wp,
        leaderboardEntryWeekId: weekId, fcmToken: `${uid}-token`,
      });
    }

    await fns.weeklyReset.run({});

    // ── Cycle snapshot: only the five players, admin absent ─────────────────
    const cycle = await H.getDoc(db, `leaderboardCycles/${weekId}`);
    assert.equal(cycle.eligibleCount, 5, 'eligibleCount must exclude the admin');
    const rankedUids = cycle.ranked.map((r) => r.uid);
    assert.deepEqual(rankedUids, ['P1', 'P2', 'P3', 'P4', 'P5']);
    assert.ok(!rankedUids.includes(ADMIN), 'admin must not be ranked');
    // Each ranked row is a payout row — the admin must not own one.
    assert.ok(
      cycle.ranked.every((r) => r.uid !== ADMIN),
      'admin must have no payout row'
    );

    // ── Winner snapshot on the pool: admin absent, 5 real winners kept ──────
    const pool = await H.getDoc(db, `prize_pool/${weekId}`);
    const winnerUids = (pool.winners || []).map((w) => w.uid);
    assert.equal(winnerUids.length, 5, 'removing the ghost still yields 5 winners');
    assert.ok(!winnerUids.includes(ADMIN), 'admin must not be a winner');
    assert.deepEqual(winnerUids, ['P1', 'P2', 'P3', 'P4', 'P5']);

    // ── Admin state cleared by the ghost sweep (self-heals legacy dirt) ─────
    const adminDoc = await user(ADMIN);
    assert.ok(
      !('leaderboardEntryWeekId' in adminDoc),
      'admin entry week must be cleared so it can never carry forward'
    );
    assert.ok(
      !('leaderboardEntryEmail' in adminDoc),
      'admin buyer email must be cleared'
    );
    assert.equal(adminDoc.weeklyPoints, 0, 'admin WP must be zeroed');

    // ── No push may ever target the admin ───────────────────────────────────
    const adminPushes = ctx.sentPush.filter((p) => p.token === 'admin-token');
    assert.equal(adminPushes.length, 0, 'admin must receive no notification');
  });

  it('redeemCode: admin cannot take a leaderboard entry, but AC still works', async () => {
    const weekId = H.thisWeekId();
    await H.mkUser(db, ADMIN, {
      username: 'Admin', animeCoins: 1000, leaderboardEntryWeekId: null,
    });

    await H.setDoc(db, 'redemptionCodes/ADMINENTRY', {
      type: 'leaderboard_entry', value: weekId, status: 'unused',
    });
    await H.rejectsWith(
      fns.redeemCode.run(H.req(ADMIN, { code: 'ADMINENTRY', ...STAMP })),
      'invalid-argument', 'Invalid or expired code',
    );

    // The transaction must have aborted: code untouched, admin not entered.
    const code = await H.getDoc(db, 'redemptionCodes/ADMINENTRY');
    assert.equal(code.status, 'unused', 'rejected redemption must not burn the code');
    const adminDoc = await user(ADMIN);
    assert.ok(!adminDoc.leaderboardEntryWeekId, 'admin must not be entered');

    // …but the ghost rule only blocks the economy-granting entry path.
    await H.setDoc(db, 'redemptionCodes/ADMINAC', {
      type: 'ac', value: 250, status: 'unused',
    });
    const res = await fns.redeemCode.run(
      H.req(ADMIN, { code: 'ADMINAC', ...STAMP }));
    assert.equal(res.success, true);
    assert.equal(res.newBalance, 1250);
    assert.equal((await user(ADMIN)).animeCoins, 1250);
  });

  it('getFriendsBoard: the admin never appears as a friend', async () => {
    const weekId = H.thisWeekId();
    await H.mkUser(db, 'P1', { username: 'P1' });
    await H.mkUser(db, 'P2', { username: 'P2', leaderboardEntryWeekId: weekId });
    await H.mkUser(db, ADMIN, {
      username: 'Admin', leaderboardEntryWeekId: weekId, weeklyPoints: 100,
    });

    await H.setDoc(db, `users/P1/friendLinks/${ADMIN}`, { status: 'friend' });
    await H.setDoc(db, 'users/P1/friendLinks/P2', { status: 'friend' });

    const res = await fns.getFriendsBoard.run(
      H.req('P1', { platform: 'web', appBuild: 1 }));
    const uids = res.friends.map((f) => f.uid);
    assert.ok(!uids.includes(ADMIN), 'admin must be filtered off the board');
    assert.deepEqual(uids, ['P2']);
  });
});
