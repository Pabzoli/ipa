// functions/test/solo_session.test.js — the server-issued solo session that
// makes a solo run payable exactly once.
//
// startSoloCooldowns stamps users/{uid}.soloSession = {id, titles, startedAt}.
// submitQuizAnswers requires an open stamp and consumes it in the same
// transaction that awards. That is what stops the duplicate-tap bug (two stacked
// QuestionsPages) from collecting two payouts: one start, one payout, whichever
// submission lands first. The submitted id is recorded but not required to match
// while the field build (which mints its own id) is still live.
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
const TITLES = ['naruto', 'bleach'];

// 10 distinct seeded question ids; all timed out, so the run always scores 0
// and the easy completion award (8 AC) is the deterministic payout.
const QIDS = Array.from({ length: 10 }, (_, i) => `q${i}`);
const ANSWERS = Array(10).fill(-1);
const TIMINGS = Array(10).fill(-1);

function start(uid = 'A', titles = TITLES) {
  return fns.startSoloCooldowns.run(H.req(uid, { titles, ...STAMP }));
}

function submit(uid, sessionId) {
  return fns.submitQuizAnswers.run(H.req(uid, {
    sessionId,
    questionIds: QIDS,
    selectedAnswers: ANSWERS,
    timings: TIMINGS,
    soloDifficulty: 'easy',
  }));
}

describe('solo session', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'A', animeCoins: 1000, weeklyPoints: 500 });
    await H.seedQuestions(db);
  });

  it('start mints the session and submit pays it exactly once', async () => {
    const started = await start();
    assert.ok(started.sessionId, 'startSoloCooldowns returns a sessionId');
    assert.equal(started.lockSeconds, 600, '2 titles lock for 10 minutes');

    const stamped = await H.getDoc(db, 'users/A');
    assert.equal(stamped.soloSession.id, started.sessionId);
    assert.deepEqual(stamped.soloSession.titles, TITLES);
    assert.ok(await H.getDoc(db, 'users/A/cooldowns/naruto'), 'lock written');

    const res = await submit('A', started.sessionId);
    assert.equal(res.correctCount, 0);
    assert.equal(res.acEarned, 8);
    const paid = await H.getDoc(db, 'users/A');
    assert.equal(paid.animeCoins, 1008);
    assert.equal(paid.soloSession, undefined, 'session consumed on award');

    // A retried/replayed submission with the same id is a cache hit: same
    // result, no second payout.
    const replay = await submit('A', started.sessionId);
    assert.deepEqual(replay, res);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1008);
  });

  it('submit without an open run is rejected and pays nothing', async () => {
    await H.rejectsWith(
      submit('A', 'forged-session'),
      'failed-precondition', 'no_active_solo_session');
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1000);
    assert.equal(
      await H.getDoc(db, 'users/A/quizSessions/forged-session'), null,
      'nothing recorded for a rejected run');
  });

  it('one start pays at most one run, whichever submits first', async () => {
    const first = await start();
    // Permanently unlocked titles skip the lock, which is exactly the case
    // where a duplicate tap used to start two payable sessions.
    await db.collection('users').doc('A').update({ unlockedAnimes: TITLES });
    const second = await start();
    assert.notEqual(second.sessionId, first.sessionId);
    assert.equal((await H.getDoc(db, 'users/A')).soloSession.id, second.sessionId);

    // The first submission (even a field-build one whose id predates the
    // stamp — see the legacy test below) claims the single open run.
    const paid = await submit('A', first.sessionId);
    assert.equal(paid.acEarned, 8);

    // The other stacked run has nothing left to claim.
    await H.rejectsWith(
      submit('A', second.sessionId),
      'failed-precondition', 'no_active_solo_session');
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1008);
  });

  it('a field build submitting its own id is paid once (no marker, no payout)', async () => {
    const started = await start();
    // Field builds generate their own id; it does not match the minted one.
    const legacyId = 'legacyuid123456789012345678_1700000000000';
    const res = await submit('A', legacyId);
    assert.equal(res.acEarned, 8);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1008);
    assert.equal((await H.getDoc(db, 'users/A')).soloSession, undefined);

    // A second submission from the same start is rejected; a replayed id hits
    // the stored session result without paying again.
    await H.rejectsWith(
      submit('A', started.sessionId),
      'failed-precondition', 'no_active_solo_session');
    const replay = await submit('A', legacyId);
    assert.deepEqual(replay, res);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1008);
  });

  it('a 9-title lineup still locks and gets a payable session', async () => {
    const nine = [
      'naruto', 'bleach', 'one piece', 'death note', 'jujutsu kaisen',
      'demon slayer', 'attack on titan', 'my hero academia', 'dragon ball z',
    ];
    const started = await start('A', nine);
    assert.equal(started.lockSeconds, 360, '9 titles still lock for 6 minutes');
    assert.ok(started.sessionId, 'a locked run is still a real session');
    assert.ok(
      await H.getDoc(db, 'users/A/cooldowns/naruto'),
      'every picked title gets a lock');
    assert.equal((await H.getDoc(db, 'users/A')).soloSession.id, started.sessionId);

    const res = await submit('A', started.sessionId);
    assert.equal(res.acEarned, 8);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1008);
  });

  it('a new start replaces the session even after the previous one was consumed', async () => {
    const first = await start();
    await submit('A', first.sessionId);
    await db.collection('users').doc('A').update({ unlockedAnimes: TITLES });
    const second = await start();
    const res = await submit('A', second.sessionId);
    assert.equal(res.acEarned, 8);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1016);
  });
});
