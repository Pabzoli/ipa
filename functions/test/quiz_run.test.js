// functions/test/quiz_run.test.js — server-minted runs (anti-cheat P0).
//
// Invariants under test:
//   • getQuizRun decides the question set and difficulty; the response never
//     contains correctAnswerIndex.
//   • submitAnswer locks a solo answer and a duel answer, returning
//     {correct, correctIndex} for the solo lock and an acknowledgement for
//     the duel lock (correctness stays hidden until the result). Duel locks
//     are the anti-preview mechanism: submitRun scores challenge/quickmatch
//     runs from the locked records and ignores the client array.
//   • submitRun scores against the server-held key and pays exactly once.
//   • one active run per user; cancelRun releases it.
//   • useQuizHint eliminates a wrong option server-side and charges 10 AC.
//   • enterDailyGauntlet(runV2) mints the 30-question Blitz run before charging.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes, FakeTimestamp } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const STAMP = { platform: 'android', appBuild: 3 };
const TITLES = ['naruto', 'bleach'];

async function seedTier(anime, tier, count, offset = 0) {
  for (let i = 0; i < count; i++) {
    const n = offset + i;
    await db.collection('questions').doc(`${anime}_${tier}_${n}`).set({
      animeTitle: anime,
      difficulty: tier,
      question: `${anime} ${tier} question ${n}?`,
      options: ['A', 'B', 'C', 'D'],
      correctAnswerIndex: n % 4,
    });
  }
}

async function seedPool() {
  // Plenty of every tier so each solo mix (7/2/1, 3/4/3, 1/2/7) and the
  // Blitz (10/10/10) can be satisfied without backfill noise.
  await seedTier('naruto', 'easy', 12, 0);
  await seedTier('naruto', 'medium', 12, 100);
  await seedTier('naruto', 'hard', 12, 200);
}

function startSolo(uid = 'A') {
  return fns.startSoloCooldowns.run(H.req(uid, {
    titles: TITLES,
    ...STAMP,
  }));
}

function getSoloRun(uid, sessionId, difficulty = 'easy') {
  return fns.getQuizRun.run(H.req(uid, {
    mode: 'solo',
    sessionId,
    titles: TITLES,
    difficulty,
    ...STAMP,
  }));
}

function answer(uid, runId, questionIndex, selectedAnswer) {
  return fns.submitAnswer.run(H.req(uid, {
    runId,
    questionIndex,
    selectedAnswer,
    ...STAMP,
  }));
}

function settle(uid, runId, answers) {
  return fns.submitRun.run(H.req(uid, {
    runId,
    ...(answers ? { answers } : {}),
    ...STAMP,
  }));
}

describe('server-minted solo runs', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', {
      username: 'A',
      animeCoins: 1000,
      weeklyPoints: 500,
      unlockedAnimes: TITLES,
    });
    await seedPool();
  });

  it('returns sanitized questions and keeps the answer key server-side', async () => {
    const started = await startSolo();
    const run = await getSoloRun('A', started.sessionId, 'easy');

    assert.equal(run.runId, started.sessionId);
    assert.equal(run.questions.length, 10);
    for (const q of run.questions) {
      assert.equal(q.correctAnswerIndex, undefined, 'key never leaves the server');
      assert.ok(Array.isArray(q.options) && q.options.length === 4);
    }

    const doc = await H.getDoc(db, `quizRuns/${run.runId}`);
    assert.equal(doc.uid, 'A');
    assert.equal(doc.state, 'active');
    assert.equal(doc.answerKey.length, 10);
    assert.equal((await H.getDoc(db, 'users/A')).activeRunId, run.runId);
  });

  it('enforces the server-chosen difficulty mix', async () => {
    const started = await startSolo();
    const run = await getSoloRun('A', started.sessionId, 'hard');
    const counts = run.questions.reduce((acc, q) => {
      acc[q.difficulty] = (acc[q.difficulty] || 0) + 1;
      return acc;
    }, {});
    assert.deepEqual(counts, { easy: 1, medium: 2, hard: 7 });

    const doc = await H.getDoc(db, `quizRuns/${run.runId}`);
    assert.equal(doc.difficulty, 'hard');
  });

  it('locks each answer, heals gaps as timeouts, and reveals the locked correctIndex', async () => {
    const started = await startSolo();
    const run = await getSoloRun('A', started.sessionId, 'easy');
    const doc = await H.getDoc(db, `quizRuns/${run.runId}`);

    // A dropped timeout lock must not strand the player: answering index 1
    // first fills index 0 as a timeout (-1), which can never score.
    const second = await answer('A', run.runId, 1, doc.answerKey[1]);
    assert.deepEqual(second, {
      index: 1,
      correct: true,
      already: false,
      correctIndex: doc.answerKey[1],
    });
    assert.equal(Object.prototype.hasOwnProperty.call(second, 'answerKey'), false);

    const afterGap = await H.getDoc(db, `quizRuns/${run.runId}`);
    assert.equal(afterGap.answers[0].answer, -1);
    assert.equal(afterGap.answers[0].correct, false);
    assert.equal(afterGap.answers[1].answer, doc.answerKey[1]);

    const timeoutSlot = await answer('A', run.runId, 0, doc.answerKey[0]);
    assert.equal(timeoutSlot.already, true);
    assert.equal(timeoutSlot.correct, false, 'a healed timeout stays wrong');
    assert.equal(timeoutSlot.correctIndex, doc.answerKey[0]);

    const wrong = await answer('A', run.runId, 2, (doc.answerKey[2] + 1) % 4);
    assert.equal(wrong.correct, false);
    assert.equal(
      wrong.correctIndex,
      doc.answerKey[2],
      'a wrong lock reveals the correct option for that question only',
    );
  });

  it('settles from the server key and pays exactly once', async () => {
    const started = await startSolo();
    const run = await getSoloRun('A', started.sessionId, 'easy');
    const doc = await H.getDoc(db, `quizRuns/${run.runId}`);

    for (let i = 0; i < 10; i++) {
      await answer('A', run.runId, i, doc.answerKey[i]);
    }

    // Replace the test's rapid-fire timestamps with a plausible client cadence
    // (the real client waits 1.5s + 900ms feedback between answers). Otherwise
    // the anti-bot timing signal would correctly classify this test as a bot.
    const base = Date.now() - 30_000;
    await db.collection('quizRuns').doc(run.runId).update({
      startedAt: FakeTimestamp.fromMillis(base - 1000),
      answers: doc.questionIds.map((_, i) => ({
        index: i,
        answer: doc.answerKey[i],
        correct: true,
        at: base + i * 2500,
      })),
    });

    const settled = await settle('A', run.runId);
    assert.equal(settled.correctCount, 10);
    // easy: 10 slow answers x15 + 20 completion + 10 perfect = 180 WP, 8 AC.
    assert.equal(settled.totalWP, 180);
    assert.equal(settled.acEarned, 8);

    const paid = await H.getDoc(db, 'users/A');
    assert.equal(paid.animeCoins, 1008);
    assert.equal(paid.soloSession, undefined, 'session consumed');
    assert.equal(paid.activeRunId, undefined, 'run lock released');
    assert.equal((await H.getDoc(db, `quizRuns/${run.runId}`)).state, 'submitted');

    const replay = await settle('A', run.runId);
    assert.deepEqual(replay, settled);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1008);
  });

  it('rejects a second run while one is active, then cancelRun releases it', async () => {
    const first = await startSolo();
    const run = await getSoloRun('A', first.sessionId, 'easy');

    // A stale page cannot mint a new run on top of the live one: the start is
    // rejected before it writes cooldown locks or a new session.
    await H.rejectsWith(
      startSolo(),
      'failed-precondition', 'run_in_progress');

    await fns.cancelRun.run(H.req('A', { runId: run.runId, ...STAMP }));
    assert.equal((await H.getDoc(db, 'users/A')).activeRunId, undefined);
    assert.equal((await H.getDoc(db, `quizRuns/${run.runId}`)).state, 'cancelled');

    const third = await startSolo();
    const rerun = await getSoloRun('A', third.sessionId, 'easy');
    assert.equal(rerun.questions.length, 10);
  });

  it('getActiveRunStatus reports the countdown and self-heals a settled lock', async () => {
    assert.deepEqual(
      await fns.getActiveRunStatus.run(H.req('A', {})),
      { active: false },
    );

    const first = await startSolo();
    const run = await getSoloRun('A', first.sessionId, 'easy');
    const status = await fns.getActiveRunStatus.run(H.req('A', {}));
    assert.equal(status.active, true);
    assert.equal(status.runId, run.runId);
    assert.equal(status.kind, 'solo');
    assert.ok(
      typeof status.secondsLeft === 'number' && status.secondsLeft > 0,
      'live run reports a positive countdown',
    );

    // A stuck lock pointing at an expired run clears itself here.
    await db.collection('quizRuns').doc(run.runId).update({
      expiresAt: FakeTimestamp.fromMillis(Date.now() - 1000),
    });
    const healed = await fns.getActiveRunStatus.run(H.req('A', {}));
    assert.equal(healed.active, false);
    assert.equal(healed.cleared, true);
    assert.equal((await H.getDoc(db, 'users/A')).activeRunId, undefined);

    // And a cancelled run also self-heals if its lock was somehow left set.
    const second = await startSolo();
    const run2 = await getSoloRun('A', second.sessionId, 'easy');
    await fns.cancelRun.run(H.req('A', { runId: run2.runId, ...STAMP }));
    const healed2 = await fns.getActiveRunStatus.run(H.req('A', {}));
    assert.equal(healed2.active, false);
  });

  it('serves a hint from the server and charges 10 AC', async () => {
    const started = await startSolo();
    const run = await getSoloRun('A', started.sessionId, 'easy');
    const doc = await H.getDoc(db, `quizRuns/${run.runId}`);

    const hint = await fns.useQuizHint.run(H.req('A', {
      runId: run.runId,
      questionIndex: 0,
      ...STAMP,
    }));
    assert.notEqual(hint.eliminatedIndex, doc.answerKey[0]);
    assert.equal(hint.newBalance, 990);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 990);

    await fns.useQuizHint.run(H.req('A', { runId: run.runId, questionIndex: 0, ...STAMP }));
    await H.rejectsWith(
      fns.useQuizHint.run(H.req('A', { runId: run.runId, questionIndex: 0, ...STAMP })),
      'resource-exhausted', 'hint_limit_reached');
  });

  it('binds the legacy submit to the run set and difficulty', async () => {
    const started = await startSolo();
    const run = await getSoloRun('A', started.sessionId, 'easy');
    const doc = await H.getDoc(db, `quizRuns/${run.runId}`);

    // Calling the legacy callable directly with a hard label must not upgrade
    // the easy reward table: the session's server-chosen difficulty wins.
    const res = await fns.submitQuizAnswers.run(H.req('A', {
      sessionId: run.runId,
      questionIds: doc.questionIds,
      selectedAnswers: doc.answerKey,
      timings: Array(10).fill(10),
      soloDifficulty: 'hard',
      ...STAMP,
    }));
    assert.equal(res.totalWP, 180, 'easy table, not the hard 480');
    assert.equal(res.acEarned, 8);
  });

  it('rejects a swapped question set on the legacy solo callable', async () => {
    const started = await startSolo();
    const run = await getSoloRun('A', started.sessionId, 'easy');
    const doc = await H.getDoc(db, `quizRuns/${run.runId}`);
    const swapped = [...doc.questionIds];
    [swapped[0], swapped[1]] = [swapped[1], swapped[0]];

    await H.rejectsWith(
      fns.submitQuizAnswers.run(H.req('A', {
        sessionId: run.runId,
        questionIds: swapped,
        selectedAnswers: doc.answerKey,
        timings: Array(10).fill(10),
        soloDifficulty: 'easy',
        ...STAMP,
      })),
      'failed-precondition', 'question_set_mismatch');
  });

  it('refuses to save a solo run as a ghost', async () => {
    const started = await startSolo();
    const run = await getSoloRun('A', started.sessionId, 'easy');
    let err;
    try {
      await fns.saveGhostSession.run(H.req('A', {
        runId: run.runId,
        animeTitle: 'naruto',
        ...STAMP,
      }));
    } catch (e) {
      err = e;
    }
    assert.ok(err, 'expected a rejection');
    assert.match(String(err.message), /invalid_run_kind/);
  });
});

describe('server-minted Gauntlet Blitz run', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', {
      username: 'A',
      animeCoins: 1000,
      weeklyPoints: 500,
      unlockedAnimes: TITLES,
    });
    await seedPool();
  });

  it('enterDailyGauntlet(runV2) mints 30 questions before charging', async () => {
    const entry = await fns.enterDailyGauntlet.run(H.req('A', {
      runV2: true,
      ...STAMP,
    }));
    assert.ok(entry.runId, 'run id returned');
    assert.equal(entry.isFreeAttempt, true);
    assert.equal(entry.retryCost, 0);

    const run = await fns.getQuizRun.run(H.req('A', {
      mode: 'gauntlet',
      runId: entry.runId,
      ...STAMP,
    }));
    assert.equal(run.questions.length, 30);
    assert.equal(run.questions.some((q) => q.correctAnswerIndex !== undefined), false);

    const doc = await H.getDoc(db, `quizRuns/${entry.runId}`);
    assert.equal(doc.answerKey.length, 30);
    assert.equal(doc.state, 'active');
  });

  it('settles the Blitz from the run key with difficulty WP and tiered AC', async () => {
    const entry = await fns.enterDailyGauntlet.run(H.req('A', {
      runV2: true,
      ...STAMP,
    }));
    const doc = await H.getDoc(db, `quizRuns/${entry.runId}`);
    const answers = doc.answerKey.slice();
    const settled = await settle('A', entry.runId, answers);

    assert.equal(settled.correctCount, 30);
    assert.equal(settled.answeredCount, 30);
    assert.equal(settled.totalQuestions, 30);
    // Ramp is 10 easy / 10 medium / 10 hard → 10×5 + 10×8 + 10×12.
    assert.deepEqual(settled.perQuestionWP, [
      ...Array(10).fill(5),
      ...Array(10).fill(8),
      ...Array(10).fill(12),
    ]);
    // Top gamble tier: 30 correct → 60 AC.
    assert.equal(settled.acEarned, 60);
    assert.ok(settled.totalWP > 0);
    assert.equal((await H.getDoc(db, `quizRuns/${entry.runId}`)).state, 'submitted');
  });

  it('pays the consolation tier for a poor Blitz run', async () => {
    const entry = await fns.enterDailyGauntlet.run(H.req('A', {
      runV2: true,
      ...STAMP,
    }));
    const doc = await H.getDoc(db, `quizRuns/${entry.runId}`);
    // Answer everything wrong: correct option is n%4, so (key+1)%4 always misses.
    const answers = doc.answerKey.map((k) => (k + 1) % 4);
    const settled = await settle('A', entry.runId, answers);

    assert.equal(settled.correctCount, 0);
    assert.equal(settled.acEarned, 2);
    assert.ok(settled.totalWP >= 0);
  });

  it('rejects a swapped question set on the legacy Blitz callable', async () => {
    const entry = await fns.enterDailyGauntlet.run(H.req('A', {
      runV2: true,
      ...STAMP,
    }));
    const fakeIds = Array.from({ length: 7 }, (_, i) => `naruto_easy_${i}`);
    await H.rejectsWith(
      fns.submitDailyGauntlet.run(H.req('A', {
        sessionId: entry.runId,
        questionIds: fakeIds,
        selectedAnswers: Array(7).fill(0),
        ...STAMP,
      })),
      'failed-precondition', 'question_set_mismatch');
  });
});

describe('server-minted challenge run', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', {
      username: 'A',
      animeCoins: 1000,
      weeklyPoints: 500,
      unlockedAnimes: TITLES,
    });
    await H.mkUser(db, 'B', {
      username: 'B',
      animeCoins: 1000,
      weeklyPoints: 500,
      unlockedAnimes: TITLES,
    });
    await seedPool();
  });

  it('mints from the challenge question set and settles the creator score', async () => {
    const created = await fns.createChallenge.run(H.req('A', {
      animeTitle: 'naruto',
      stakeAmount: 100,
      wpStake: 50,
      opponentUid: 'B',
      opponentUsername: 'B',
      challengeType: 'rival',
      ...STAMP,
    }));

    const run = await fns.getQuizRun.run(H.req('A', {
      mode: 'challenge',
      challengeId: created.challengeId,
      ...STAMP,
    }));
    const challenge = await H.getDoc(db, `challenges/${created.challengeId}`);
    assert.deepEqual(
      run.questions.map((q) => q.id),
      challenge.questionIds,
      'the run uses the challenge set, in order',
    );
    assert.equal(
      run.questions.some((q) => q.correctAnswerIndex !== undefined),
      false,
    );

    const doc = await H.getDoc(db, `quizRuns/${run.runId}`);
    assert.ok(Array.isArray(doc.answerKey) && doc.answerKey.length === 10);
    for (let i = 0; i < 10; i++) {
      const locked = await answer('A', run.runId, i, doc.answerKey[i]);
      assert.equal(locked.correct, true);
    }
    // The client array is ignored for duels: even an all-wrong array settles
    // at the locked 10/10.
    const settled = await settle('A', run.runId, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    assert.equal(settled.correctCount, 10);
    assert.equal(
      (await H.getDoc(db, `challenges/${created.challengeId}`)).creatorScore,
      10,
    );
  });

  it('rejects a non-participant', async () => {
    const created = await fns.createChallenge.run(H.req('A', {
      animeTitle: 'naruto',
      stakeAmount: 100,
      wpStake: 50,
      opponentUid: 'B',
      opponentUsername: 'B',
      challengeType: 'rival',
      ...STAMP,
    }));
    await H.rejectsWith(
      fns.getQuizRun.run(H.req('C', {
        mode: 'challenge',
        challengeId: created.challengeId,
        ...STAMP,
      })),
      'permission-denied', 'not_a_participant');
  });
});

// ── Legacy client compatibility ───────────────────────────────────────────
// The shipped build (build 1) reads questions directly and submits without
// runId/runV2. It must keep working until app_config/android.minBuild is
// raised. These tests exercise the exact legacy shapes end to end.
describe('legacy client compatibility', () => {
  const LEGACY = { platform: 'android', appBuild: 1 };

  beforeEach(async () => {
    await H.clearDb(db);
    fns._testHelpers._resetAndroidConfigCache();
    await H.mkUser(db, 'A', {
      username: 'A',
      animeCoins: 1000,
      weeklyPoints: 500,
      unlockedAnimes: TITLES,
    });
    await seedPool();
  });

  it('legacy solo start and direct submit still pay end to end', async () => {
    const started = await fns.startSoloCooldowns.run(H.req('A', {
      titles: TITLES,
      ...LEGACY,
    }));
    assert.ok(started.sessionId);

    // The shipped client picks its own 10 questions from Firestore and sends
    // the legacy payload (no runId, no getQuizRun).
    const qs = (await db.collection('questions').get()).docs.slice(0, 10);
    const ids = qs.map((d) => d.id);
    const answers = qs.map((d) => d.data().correctAnswerIndex);
    const res = await fns.submitQuizAnswers.run(H.req('A', {
      sessionId: started.sessionId,
      questionIds: ids,
      selectedAnswers: answers,
      timings: Array(10).fill(10),
      soloDifficulty: 'easy',
      ...LEGACY,
    }));

    assert.equal(res.correctCount, 10);
    assert.equal(res.acEarned, 8);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1008);
  });

  it('an unstamped legacy build still starts and submits while minBuild is 1', async () => {
    const started = await fns.startSoloCooldowns.run(H.req('A', {
      titles: TITLES,
    }));
    assert.ok(started.sessionId);

    const qs = (await db.collection('questions').get()).docs.slice(0, 10);
    const res = await fns.submitQuizAnswers.run(H.req('A', {
      sessionId: started.sessionId,
      questionIds: qs.map((d) => d.id),
      selectedAnswers: qs.map((d) => d.data().correctAnswerIndex),
      timings: Array(10).fill(10),
      soloDifficulty: 'easy',
    }));
    assert.equal(res.correctCount, 10);
  });

  it('legacy Gauntlet Blitz entry and direct submit still pay end to end', async () => {
    const entry = await fns.enterDailyGauntlet.run(H.req('A', LEGACY));
    assert.equal(entry.isFreeAttempt, true);
    assert.equal(entry.runId, undefined, 'legacy entry mints no run');

    const qs = (await db.collection('questions').get()).docs.slice(0, 7);
    const ids = qs.map((d) => d.id);
    const answers = qs.map((d) => d.data().correctAnswerIndex);
    const res = await fns.submitDailyGauntlet.run(H.req('A', {
      sessionId: 'legacy_gauntlet_session',
      questionIds: ids,
      selectedAnswers: answers,
      ...LEGACY,
    }));

    assert.equal(res.correctCount, 7);
    assert.equal(res.isFreeAttempt, true);
    // 7 correct lands the 5–8 gamble tier → 8 AC.
    assert.equal(res.acEarned, 8);
    assert.ok(res.totalWP > 0);
  });
});

// ── minBuild retires the legacy paths ─────────────────────────────────────
describe('minBuild retirement of legacy quiz paths', () => {
  const NEW_CLIENT = { platform: 'android', appBuild: 2 };

  beforeEach(async () => {
    await H.clearDb(db);
    await H.setDoc(db, 'app_config/android', { minBuild: 2, latestBuild: 2 });
    fns._testHelpers._resetAndroidConfigCache();
    await H.mkUser(db, 'A', {
      username: 'A',
      animeCoins: 1000,
      weeklyPoints: 500,
      unlockedAnimes: TITLES,
    });
    await seedPool();
  });

  it('rejects a legacy solo start but allows the runV2 start', async () => {
    await H.rejectsWith(
      fns.startSoloCooldowns.run(H.req('A', {
        titles: TITLES,
        ...NEW_CLIENT,
      })),
      'failed-precondition', 'App update required');

    const started = await fns.startSoloCooldowns.run(H.req('A', {
      titles: TITLES,
      runV2: true,
      ...NEW_CLIENT,
    }));
    const run = await fns.getQuizRun.run(H.req('A', {
      mode: 'solo',
      sessionId: started.sessionId,
      titles: TITLES,
      difficulty: 'easy',
      ...NEW_CLIENT,
    }));
    assert.equal(run.questions.length, 10);
  });

  it('rejects a legacy solo session that never went through getQuizRun', async () => {
    const qs = (await db.collection('questions').get()).docs.slice(0, 10);
    await db.collection('users').doc('A').update({
      soloSession: {
        id: 'legacy_solo_session',
        titles: TITLES,
        startedAt: FakeTimestamp.now(),
      },
    });
    await H.rejectsWith(
      fns.submitQuizAnswers.run(H.req('A', {
        sessionId: 'legacy_solo_session',
        questionIds: qs.map((d) => d.id),
        selectedAnswers: qs.map((d) => d.data().correctAnswerIndex),
        timings: Array(10).fill(10),
        soloDifficulty: 'easy',
        ...NEW_CLIENT,
      })),
      'failed-precondition', 'App update required');
  });

  it('rejects a legacy paid retry before charging', async () => {
    await db.collection('users').doc('A').update({ premiumActive: true });
    const base = {
      amount: 80,
      type: 'spend_retry',
      titles: TITLES,
      ...NEW_CLIENT,
    };
    await H.rejectsWith(
      fns.spendCoins.run(H.req('A', base)),
      'failed-precondition', 'App update required');
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 1000);

    const res = await fns.spendCoins.run(H.req('A', { ...base, runV2: true }));
    assert.ok(res.sessionId);
    assert.equal((await H.getDoc(db, 'users/A')).animeCoins, 920);
  });

  it('rejects legacy Gauntlet entry and submission, allows runV2', async () => {
    await H.rejectsWith(
      fns.enterDailyGauntlet.run(H.req('A', NEW_CLIENT)),
      'failed-precondition', 'App update required');

    const qs = (await db.collection('questions').get()).docs.slice(0, 7);
    await H.rejectsWith(
      fns.submitDailyGauntlet.run(H.req('A', {
        sessionId: 'legacy_gauntlet_session',
        questionIds: qs.map((d) => d.id),
        selectedAnswers: Array(7).fill(0),
        ...NEW_CLIENT,
      })),
      'failed-precondition', 'App update required');

    const entry = await fns.enterDailyGauntlet.run(H.req('A', {
      runV2: true,
      ...NEW_CLIENT,
    }));
    assert.ok(entry.runId);
  });
});

// ── Free Blitz re-entry cap ───────────────────────────────────────────────
describe('free Blitz re-entry cap', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    fns._testHelpers._resetAndroidConfigCache();
    await H.mkUser(db, 'A', {
      username: 'A',
      animeCoins: 1000,
      weeklyPoints: 500,
      unlockedAnimes: TITLES,
    });
    await seedPool();
  });

  it('caps free entries per day so quit/re-enter cannot reroll forever', async () => {
    for (let i = 0; i < 3; i++) {
      const entry = await fns.enterDailyGauntlet.run(H.req('A', {
        runV2: true,
        ...STAMP,
      }));
      assert.ok(entry.runId);
      await fns.cancelRun.run(H.req('A', {
        runId: entry.runId,
        ...STAMP,
      }));
    }

    await H.rejectsWith(
      fns.enterDailyGauntlet.run(H.req('A', { runV2: true, ...STAMP })),
      'failed-precondition', 'gauntlet_free_entry_limit');

    const user = await H.getDoc(db, 'users/A');
    assert.equal(user.gauntletFreeEntryCount, 3);
  });
});

// ── Run expiry cleanup ────────────────────────────────────────────────────
describe('quiz run expiry cleanup', () => {
  beforeEach(async () => {
    await H.clearDb(db);
  });

  it('deletes runs expired beyond the retention window only', async () => {
    await H.setDoc(db, 'quizRuns/old', {
      uid: 'A',
      state: 'submitted',
      expiresAt: FakeTimestamp.fromMillis(Date.now() - 48 * 60 * 60 * 1000),
    });
    await H.setDoc(db, 'quizRuns/fresh', {
      uid: 'A',
      state: 'active',
      expiresAt: FakeTimestamp.fromMillis(Date.now() + 60 * 60 * 1000),
    });

    await fns.cleanupExpiredQuizRuns.run({});

    assert.equal(await H.getDoc(db, 'quizRuns/old'), null);
    assert.ok(await H.getDoc(db, 'quizRuns/fresh'));
  });
});
