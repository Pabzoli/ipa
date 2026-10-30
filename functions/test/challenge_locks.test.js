// functions/test/challenge_locks.test.js — duel answer locks + quit fee.
//
//   • Challenge/Quick Match answers lock one question at a time via
//     submitAnswer (same pattern as solo). submitRun scores duel runs from
//     the locked records and ignores the client array, so quitting mid-duel
//     (or killing the app) and replaying the fixed question set cannot
//     improve the score — a resume continues from the first unlocked
//     question.
//   • Cancelling a live duel run deducts the 100 AC walkaway fee (floored at
//     zero) on top of forfeiting the match.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const STAMP = { platform: 'android', appBuild: 999 };
const CORRECT = 2; // every seeded question is rewritten to this answer
const WRONG = 0;

async function makeWaitingDuel(stakeAC = 100, wpStake = 50) {
  const r = await fns.createChallenge.run(H.req('A', {
    animeTitle: 'testanime', stakeAmount: stakeAC, wpStake,
    opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival', ...STAMP,
  }));
  return r.challengeId;
}

function duelRun(uid, challengeId) {
  return fns.getQuizRun.run(H.req(uid, { mode: 'challenge', challengeId, ...STAMP }));
}

function lock(uid, runId, questionIndex, selectedAnswer = CORRECT) {
  return fns.submitAnswer.run(H.req(uid, {
    runId, questionIndex, selectedAnswer, ...STAMP,
  }));
}

async function lockAll(uid, runId, correctCount) {
  for (let i = 0; i < 10; i++) {
    await lock(uid, runId, i, i < correctCount ? CORRECT : WRONG);
  }
}

describe('duel answer locks and quit fee', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'A', animeCoins: 1000, weeklyPoints: 500 });
    await H.mkUser(db, 'B', { username: 'B', animeCoins: 1000, weeklyPoints: 500 });
    await H.seedQuestions(db);
    const qs = await db.collection('questions').get();
    for (const q of qs.docs) await q.ref.update({ correctAnswerIndex: CORRECT });
  });

  it('locked answers score the duel; the client array is ignored', async () => {
    const id = await makeWaitingDuel();
    const run = await duelRun('A', id);
    assert.equal(run.questions.length, 10);
    assert.equal(run.questions[0].correctAnswerIndex, undefined);

    await lockAll('A', run.runId, 7);

    // A hostile client array claiming 0/10 must not move the score.
    const settled = await fns.submitRun.run(H.req('A', {
      runId: run.runId,
      answers: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      ...STAMP,
    }));
    assert.equal(settled.correctCount, 7);
    const ch = await H.getDoc(db, `challenges/${id}`);
    assert.equal(ch.creatorScore, 7);
  });

  it('re-locking a question is idempotent', async () => {
    const id = await makeWaitingDuel();
    const run = await duelRun('A', id);
    const first = await lock('A', run.runId, 0);
    assert.equal(first.already, false);
    assert.equal(first.correct, true);
    const second = await lock('A', run.runId, 0);
    assert.equal(second.already, true);
    assert.equal(second.correct, true);
  });

  it('submitRun with no locks is rejected', async () => {
    const id = await makeWaitingDuel();
    const run = await duelRun('A', id);
    await H.rejectsWith(
      fns.submitRun.run(H.req('A', { runId: run.runId, ...STAMP })),
      'failed-precondition', 'answers_not_locked');
  });

  it('locking a filled seat is rejected', async () => {
    const id = await makeWaitingDuel();
    const run = await duelRun('A', id);
    await lockAll('A', run.runId, 10);
    await fns.submitRun.run(H.req('A', { runId: run.runId, ...STAMP }));
    await H.rejectsWith(
      lock('A', run.runId, 0),
      'failed-precondition', 'score_already_submitted');
  });

  it('opponent locks after joining', async () => {
    const id = await makeWaitingDuel();
    await fns.joinChallenge.run(H.req('B', { challengeId: id, ...STAMP }));
    const run = await duelRun('B', id);
    const res = await lock('B', run.runId, 0);
    assert.equal(res.correct, true);
    await lockAll('B', run.runId, 10);
    const settled = await fns.submitRun.run(H.req('B', { runId: run.runId, ...STAMP }));
    assert.equal(settled.correctCount, 10);
    const ch = await H.getDoc(db, `challenges/${id}`);
    assert.equal(ch.opponentScore, 10);
  });

  it('quitting a live duel deducts the 100 AC fee', async () => {
    const id = await makeWaitingDuel(); // 100 AC staked: 1000 -> 900
    const run = await duelRun('A', id);
    await lock('A', run.runId, 0);
    await lock('A', run.runId, 1);

    const res = await fns.cancelRun.run(H.req('A', { runId: run.runId, ...STAMP }));
    assert.equal(res.success, true);

    const u = await H.getDoc(db, 'users/A');
    assert.equal(u.animeCoins, 800);

    const ledger = await db.collection('users/A/coinTransactions').get();
    const fee = ledger.docs.map((d) => d.data()).find((e) => e.type === 'challenge_quit_fee');
    assert.ok(fee, 'quit fee ledger entry exists');
    assert.equal(fee.delta, -100);
    assert.equal(fee.challengeId, id);

    const stored = await H.getDoc(db, `quizRuns/${run.runId}`);
    assert.equal(stored.state, 'cancelled');
  });

  it('quit fee floors at zero for a broke player', async () => {
    const id = await makeWaitingDuel();
    const run = await duelRun('A', id);
    await lock('A', run.runId, 0);
    await db.collection('users').doc('A').update({ animeCoins: 30 });

    const res = await fns.cancelRun.run(H.req('A', { runId: run.runId, ...STAMP }));
    assert.equal(res.success, true);
    const u = await H.getDoc(db, 'users/A');
    assert.equal(u.animeCoins, 0);
  });

  it('resume returns locked picks and continues after them', async () => {
    const id = await makeWaitingDuel();
    const run = await duelRun('A', id);
    await lock('A', run.runId, 0);
    await lock('A', run.runId, 1);
    await lock('A', run.runId, 2, WRONG);

    const resumed = await duelRun('A', id);
    assert.equal(resumed.runId, run.runId);
    assert.deepEqual(resumed.lockedAnswers.slice(0, 3), [CORRECT, CORRECT, WRONG]);
    assert.ok(resumed.lockedAnswers.slice(3).every((a) => a === null));

    const next = await lock('A', resumed.runId, 3);
    assert.equal(next.already, false);
  });
});
