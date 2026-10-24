// functions/test/challenge_score.test.js — B1 + B4/B5/B6 regression coverage.
//
//   • submitChallengeScore is now the ONLY way a Rival/Code/Spar score reaches
//     the challenge doc; it computes the score SERVER-side from the submitted
//     answers (the client can no longer write creatorScore/opponentScore).
//   • A creator may play before the invitee accepts, and the invite stays
//     takeable.
//   • The forfeit/expiry sweeps never settle a seat whose invitee never joined
//     (no minted payout, no refund to someone who never paid).
//   • An abandoned Quick Match is settled and its ghost recording is returned to
//     the pool.
'use strict';
process.env.NODE_ENV = 'test';
const { test, describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes, FakeTimestamp } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const STAMP = { platform: 'android', appBuild: 999 };
const CORRECT = 2; // every seeded question is rewritten to this answer

async function balances(...uids) {
  const out = {};
  for (const u of uids) {
    const s = await db.collection('users').doc(u).get();
    const d = s.data() || {};
    out[u] = { ac: d.animeCoins || 0, wp: d.weeklyPoints || 0 };
  }
  return out;
}

async function makeWaitingDuel(stakeAC = 100, wpStake = 50) {
  const r = await fns.createChallenge.run(H.req('A', {
    animeTitle: 'testanime', stakeAmount: stakeAC, wpStake,
    opponentUid: 'B', opponentUsername: 'B', challengeType: 'rival', ...STAMP,
  }));
  return r.challengeId;
}

// All 10 answers right → server-computed score of 10.
function answerPayload(questionIds, correctCount) {
  return {
    challengeId: undefined, // filled by caller
    questionIds,
    selectedAnswers: questionIds.map((_, i) => (i < correctCount ? CORRECT : 0)),
    timings: questionIds.map(() => 5),
    ...STAMP,
  };
}

describe('server-validated challenge scores', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'A', animeCoins: 1000, weeklyPoints: 500 });
    await H.mkUser(db, 'B', { username: 'B', animeCoins: 1000, weeklyPoints: 500 });
    await H.seedQuestions(db);
    const qs = await db.collection('questions').get();
    for (const q of qs.docs) await q.ref.update({ correctAnswerIndex: CORRECT });
  });

  it('creator may play before the invitee joins, and the invite stays takeable', async () => {
    const id = await makeWaitingDuel();
    const ch0 = await H.getDoc(db, `challenges/${id}`);

    const res = await fns.submitChallengeScore.run(H.req('A', {
      ...answerPayload(ch0.questionIds, 10), challengeId: id,
    }));
    assert.equal(res.correctCount, 10);

    const ch1 = await H.getDoc(db, `challenges/${id}`);
    assert.equal(ch1.creatorScore, 10, 'score computed server-side, not client-sent');

    // The invite was not consumed by the creator's early play.
    await fns.joinChallenge.run(H.req('B', { challengeId: id, ...STAMP }));
    const oppRes = await fns.submitChallengeScore.run(H.req('B', {
      ...answerPayload(ch0.questionIds, 3), challengeId: id,
    }));
    assert.equal(oppRes.correctCount, 3);
    const ch2 = await H.getDoc(db, `challenges/${id}`);
    assert.equal(ch2.opponentScore, 3);
  });

  it('rejects a non-participant', async () => {
    const id = await makeWaitingDuel();
    const ch = await H.getDoc(db, `challenges/${id}`);
    await H.rejectsWith(
      fns.submitChallengeScore.run(H.req('C', {
        ...answerPayload(ch.questionIds, 10), challengeId: id,
      })),
      'permission-denied', 'not_a_participant');
  });

  it('invited opponent may NOT play before joining (no free seat)', async () => {
    const id = await makeWaitingDuel();
    const ch0 = await H.getDoc(db, `challenges/${id}`);
    // Creator plays first → status becomes creator_submitted via the trigger in
    // production; the invite is still open and B has not paid their stake.
    await fns.submitChallengeScore.run(H.req('A', {
      ...answerPayload(ch0.questionIds, 10), challengeId: id,
    }));
    const ref = db.collection('challenges').doc(id);
    await ref.update({ status: 'creator_submitted' }); // simulate the trigger

    await H.rejectsWith(
      fns.submitChallengeScore.run(H.req('B', {
        ...answerPayload(ch0.questionIds, 10), challengeId: id,
      })),
      'failed-precondition', 'challenge_not_active');

    // Once B actually joins (paying the stake) they may play.
    await fns.joinChallenge.run(H.req('B', { challengeId: id, ...STAMP }));
    const res = await fns.submitChallengeScore.run(H.req('B', {
      ...answerPayload(ch0.questionIds, 4), challengeId: id,
    }));
    assert.equal(res.correctCount, 4);
  });

  it('ignores a question set that is not the one stored on the challenge', async () => {
    const id = await makeWaitingDuel();
    const ch = await H.getDoc(db, `challenges/${id}`);
    const swapped = [...ch.questionIds];
    [swapped[0], swapped[1]] = [swapped[1], swapped[0]];
    await H.rejectsWith(
      fns.submitChallengeScore.run(H.req('A', {
        ...answerPayload(swapped, 10), challengeId: id,
      })),
      'failed-precondition', 'question_set_mismatch');
  });

  it('forfeit sweep never settles a challenge whose invitee never joined', async () => {
    const id = await makeWaitingDuel();
    const ref = db.collection('challenges').doc(id);
    await ref.update({
      creatorScore: 8, status: 'creator_submitted',
      firstSubmittedAt: FakeTimestamp.fromMillis(Date.now() - 20 * 60 * 1000),
    });
    await fns.forfeitStalePartialChallenges.run({});
    const ch = (await ref.get()).data();
    assert.equal(ch.opponentScore, undefined, 'no opponent forfeit without a join');
    assert.notEqual(ch.status, 'completed');
  });

  it('expiry sweep refunds only the creator when the invitee never joined', async () => {
    const id = await makeWaitingDuel();
    const ref = db.collection('challenges').doc(id);
    await ref.update({
      creatorScore: 8, status: 'creator_submitted',
      expiresAt: FakeTimestamp.fromMillis(Date.now() - 1000),
    });
    await fns.expiredChallengeRefund.run({});
    const ch = (await ref.get()).data();
    assert.equal(ch.status, 'expired_refunded');
    const b = await balances('A', 'B');
    assert.deepEqual(b.A, { ac: 1000, wp: 500 }, 'creator refunded');
    assert.deepEqual(b.B, { ac: 1000, wp: 500 }, 'opponent never paid, never refunded');
  });

  it('abandoned quick match is settled and its ghost recording returned to the pool', async () => {
    await H.setDoc(db, 'ghost_sessions/testanime', { sessions: [] });
    await H.setDoc(db, 'challenges/ghostc', {
      creatorUid: 'A', opponentUid: 'ghost', isQuickMatch: true, status: 'ghost',
      animeTitle: 'testanime', ghostSessionId: 'gs1', ghostUsername: 'Ghosty',
      ghostScore: 7, ghostUid: 'rec1', challengeType: 'quick',
      questionIds: ['q0', 'q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7', 'q8', 'q9'],
      expiresAt: FakeTimestamp.fromMillis(Date.now() - 1000),
    });

    await fns.expireAbandonedQuickMatches.run({});

    const ch = await H.getDoc(db, 'challenges/ghostc');
    assert.equal(ch.status, 'expired_refunded');
    assert.equal(ch.resolved, true);

    const pool = await H.getDoc(db, 'ghost_sessions/testanime');
    assert.equal(pool.sessions.length, 1);
    assert.equal(pool.sessions[0].sessionId, 'gs1');
    assert.equal(pool.sessions[0].uid, 'rec1');

    // Idempotent: a second run must not duplicate the recording.
    await fns.expireAbandonedQuickMatches.run({});
    const pool2 = await H.getDoc(db, 'ghost_sessions/testanime');
    assert.equal(pool2.sessions.length, 1);
  });
});
