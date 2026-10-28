// functions/test/anticheat_p1.test.js — Play Integrity + silent enforcement.
//
// Invariants:
//   • The ladder is silent, progressive, and reversible.
//   • One hard signal triggers a payout hold; a cert failure suspends.
//   • Two independent soft signals restrict (decay + leaderboard exclusion).
//   • Payout account reuse across UIDs is a hard signal and holds the new
//     claimant without deleting anything.
//   • Integrity is log-only by default; enforce blocks with integrity_required.
//   • A restricted account earns decayed WP/AC; a suspended account cannot
//     submit (neutral account_under_review).
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
      question: `${anime} ${tier} ${n}?`,
      options: ['A', 'B', 'C', 'D'],
      correctAnswerIndex: n % 4,
    });
  }
}
async function seedPool() {
  await seedTier('naruto', 'easy', 10, 0);
  await seedTier('naruto', 'medium', 10, 100);
  await seedTier('naruto', 'hard', 10, 200);
}

async function seedPerfectSolo(uid = 'A') {
  const started = await fns.startSoloCooldowns.run(H.req(uid, {
    titles: TITLES, runV2: true, ...STAMP,
  }));
  const run = await fns.getQuizRun.run(H.req(uid, {
    mode: 'solo', sessionId: started.sessionId,
    titles: TITLES, difficulty: 'easy', ...STAMP,
  }));
  const doc = await H.getDoc(db, `quizRuns/${run.runId}`);
  for (let i = 0; i < 10; i++) {
    await fns.submitAnswer.run(H.req(uid, {
      runId: run.runId, questionIndex: i,
      selectedAnswer: doc.answerKey[i], ...STAMP,
    }));
  }
  // Simulate the real client cadence so the anti-bot timing signal stays quiet.
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
  return run.runId;
}

describe('silent enforcement ladder', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', {
      username: 'A', animeCoins: 1000, weeklyPoints: 500,
      unlockedAnimes: TITLES, lbEligible: true,
    });
    await H.mkUser(db, 'B', { username: 'B', lbEligible: true });
    await seedPool();
  });

  it('does nothing on a single soft signal', async () => {
    await fns._testHelpers._recordAntiCheatSignal('A', 'shared_ip', { hard: false });
    const enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.level, 'flagged');
    assert.equal(enf.decayFactor, 1);
    assert.equal(enf.leaderboardExcluded, false);
    assert.equal((await H.getDoc(db, 'users/A')).lbEligible, true);
  });

  it('restricts on two independent signals (decay + leaderboard exclusion)', async () => {
    await fns._testHelpers._recordAntiCheatSignal('A', 'shared_ip', { hard: false });
    await fns._testHelpers._recordAntiCheatSignal('A', 'rapid_cadence', { hard: false });
    const enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.level, 'restricted');
    assert.equal(enf.decayFactor, 0.5);
    assert.equal(enf.leaderboardExcluded, true);
    assert.equal((await H.getDoc(db, 'users/A')).lbEligible, false);
  });

  it('holds payouts on one hard signal', async () => {
    await fns._testHelpers._recordAntiCheatSignal('A', 'payout_account_multi_uid', {
      hard: true, detail: { hash: 'h', uidCount: 2 },
    });
    const enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.level, 'payout_hold');
    assert.equal(enf.payoutHold, true);
    assert.equal(enf.suspended, false);
    assert.equal(enf.decayFactor, 0.5);
  });

  it('holds payouts after three run/difficulty binding mismatches', async () => {
    for (let i = 0; i < 3; i++) {
      await fns._testHelpers._recordAntiCheatSignal('A', 'run_binding_mismatch', {
        hard: false, detail: { n: i },
      });
    }
    let enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.level, 'payout_hold');
    assert.equal(enf.payoutHold, true);

    // A later soft signal must not downgrade the hold.
    await fns._testHelpers._recordAntiCheatSignal('A', 'shared_ip', { hard: false });
    enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.level, 'payout_hold');
  });

  it('suspends on a cert failure and a second hard signal', async () => {
    await fns._testHelpers._recordAntiCheatSignal('A', 'integrity_cert_failed', {
      hard: true, detail: { packageName: 'com.animequiz.app' },
    });
    let enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.level, 'suspended');
    assert.equal(enf.suspended, true);

    // Never downgrades on a later softer signal.
    await fns._testHelpers._recordAntiCheatSignal('A', 'shared_ip', { hard: false });
    enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.level, 'suspended');
  });

  it('decays a restricted account’s solo reward without blocking play', async () => {
    await fns._testHelpers._recordAntiCheatSignal('A', 'soft_one', { hard: false });
    await fns._testHelpers._recordAntiCheatSignal('A', 'soft_two', { hard: false });

    const runId = await seedPerfectSolo('A');
    const res = await fns.submitRun.run(H.req('A', { runId, ...STAMP }));
    assert.equal(res.correctCount, 10);
    assert.equal(res.totalWP, 90, '180 raw x 0.5 enforcement decay');
    assert.equal(res.acEarned, 4, '8 AC x 0.5');
  });

  it('blocks a suspended account with a neutral review message', async () => {
    await fns._testHelpers._recordAntiCheatSignal('A', 'integrity_cert_failed', {
      hard: true,
    });
    await db.collection('users').doc('A').update({
      soloSession: { id: 'legacy_s', titles: TITLES, startedAt: FakeTimestamp.now() },
    });
    const qs = (await db.collection('questions').get()).docs.slice(0, 10);
    await H.rejectsWith(
      fns.submitQuizAnswers.run(H.req('A', {
        sessionId: 'legacy_s',
        questionIds: qs.map((d) => d.id),
        selectedAnswers: qs.map((d) => d.data().correctAnswerIndex),
        timings: Array(10).fill(10),
        soloDifficulty: 'easy',
        ...STAMP,
      })),
      'failed-precondition', 'account_under_review');
  });
});

describe('payout account fingerprinting', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'A', lbEligible: true });
    await H.mkUser(db, 'B', { username: 'B', lbEligible: true });
  });

  it('holds the second UID on a shared account without deleting anything', async () => {
    const first = await fns._testHelpers._recordPayoutAccount(
      'A', '058', '0123456789', 'test',
    );
    assert.equal(first.shared, false);
    assert.equal(first.uidCount, 1);

    const second = await fns._testHelpers._recordPayoutAccount(
      'B', '058', '0123456789', 'test',
    );
    assert.equal(second.shared, true);
    assert.equal(second.uidCount, 2);

    const graph = await H.getDoc(db, `payoutAccounts/${second.hash}`);
    assert.deepEqual(graph.uids.sort(), ['A', 'B']);
    assert.equal(graph.last4, '6789');

    const enf = await fns._testHelpers._readEnforcement('B');
    assert.equal(enf.payoutHold, true);
    assert.equal(enf.level, 'payout_hold');

    // The account docs are never deleted by the ladder.
    assert.ok(await H.getDoc(db, 'users/A'));
    assert.ok(await H.getDoc(db, 'users/B'));
  });

  it('holds the new claimant through submitPayoutDetails end to end', async () => {
    const weekId = '2026-10-19';
    await H.setDoc(db, `leaderboardCycles/${weekId}`, {
      calculatedAt: FakeTimestamp.now(),
      ranked: [
        { uid: 'A', rank: 1, share: 1000, paid: false, username: 'A' },
        { uid: 'B', rank: 2, share: 1000, paid: false, username: 'B' },
      ],
    });
    const base = {
      weekId, accountNumber: '0123456789', bankCode: '058',
      beneficiaryName: 'Same Person', ...STAMP,
    };
    await fns.submitPayoutDetails.run(H.req('A', base));
    await fns.submitPayoutDetails.run(H.req('B', base));

    const bClaim = await H.getDoc(db, `leaderboardCycles/${weekId}/pendingClaim/B`);
    assert.equal(bClaim.payoutAccountShared, true);
    assert.equal(bClaim.payoutAccountUidCount, 2);
    const enf = await fns._testHelpers._readEnforcement('B');
    assert.equal(enf.payoutHold, true);
  });
});

describe('Play Integrity mode', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'A', animeCoins: 1000 });
  });

  it('defaults to log-only and never blocks a missing token', async () => {
    const cfg = await fns._testHelpers._getPlayIntegrityConfig();
    assert.equal(cfg.enforce, false);
    assert.equal(cfg.logOnly, true);
    const res = await fns._testHelpers._verifyPlayIntegrity(
      H.req('A', {}), 'test',
    );
    assert.equal(res.ok, false);
    assert.equal(res.reason, 'missing');
    const enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.level, 'clean');
  });

  it('enforce mode blocks a missing token and holds the account', async () => {
    await H.setDoc(db, 'server_config/play_integrity', {
      packageName: 'com.animequiz.app',
      certificateSha256Digest: ['6edYv6JkZWefkzNwgx-1zO4Kh22eBnjQuHvRqp5r8QE'],
      allowedDeviceVerdicts: ['MEETS_DEVICE_INTEGRITY'],
      enforce: true,
      logOnly: false,
    });
    await H.rejectsWith(
      fns._testHelpers._verifyPlayIntegrity(H.req('A', {}), 'payout'),
      'failed-precondition', 'integrity_required');
    const enf = await fns._testHelpers._readEnforcement('A');
    assert.equal(enf.payoutHold, true);
  });
});
