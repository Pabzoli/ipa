// functions/test/support.test.js — contact / bug-report / suggestion intake.
//
// What must stay true:
//   • only signed-in users can submit, and only through the callable;
//   • every report is stored with the caller's identity + app context;
//   • input is validated server-side (category, length) regardless of the UI;
//   • the flood guard (30s cooldown + per-WAT-day budget) is transactional.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const STAMP = { platform: 'android', appBuild: 7 };
const MESSAGE = 'The timer freezes on the last question.';

async function send(uid, data = {}) {
  return fns.submitFeedback.run(H.req(uid, {
    category: 'bug',
    message: MESSAGE,
    ...STAMP,
    ...data,
  }));
}

async function reports() {
  const snap = await db.collection('feedback').get();
  return snap.docs.map((doc) => doc.data());
}

describe('submitFeedback', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'Ash', email: 'ash@t.co' });
  });

  it('stores the report with identity and diagnostic context', async () => {
    const res = await send('A', { subject: '  Timer stuck  ' });

    assert.equal(res.success, true);
    assert.ok(res.id);

    const [doc] = await reports();
    assert.equal(doc.uid, 'A');
    assert.equal(doc.username, 'Ash');
    assert.equal(doc.email, 'ash@t.co');
    assert.equal(doc.category, 'bug');
    assert.equal(doc.subject, 'Timer stuck');
    assert.equal(doc.message, MESSAGE);
    assert.equal(doc.platform, 'android');
    assert.equal(doc.appBuild, 7);
    assert.equal(doc.status, 'new');
    assert.ok(doc.createdAt instanceof ctx.FakeTimestamp);
  });

  it('falls back to the category when the subject is blank', async () => {
    await send('A', { subject: '   ' });
    const [doc] = await reports();
    assert.equal(doc.subject, 'bug');
  });

  it('rejects unsigned callers', async () => {
    await H.rejectsWith(
      fns.submitFeedback.run(H.req(null, {
        category: 'bug', message: MESSAGE, ...STAMP,
      })),
      'unauthenticated',
    );
  });

  it('rejects unknown categories and short or oversized messages', async () => {
    await H.rejectsWith(
      send('A', { category: 'spam' }),
      'invalid-argument',
      'invalid_category',
    );
    await H.rejectsWith(
      send('A', { message: '   too short   ' }),
      'invalid-argument',
      'message_too_short',
    );
    await H.rejectsWith(
      send('A', { message: 'x'.repeat(2001) }),
      'invalid-argument',
      'message_too_long',
    );
  });

  it('caps the stored subject at 120 characters', async () => {
    await send('A', { subject: 's'.repeat(200) });
    const [doc] = await reports();
    assert.equal(doc.subject.length, 120);
  });

  it('enforces the 30-second cooldown', async () => {
    await send('A');
    await H.rejectsWith(
      send('A'),
      'resource-exhausted',
      'wait a moment',
    );
    // Rejected attempts must not create a second document.
    assert.equal((await reports()).length, 1);
  });

  it('enforces a 10-per-day budget and rolls over on a new WAT day', async () => {
    await H.setDoc(db, 'users/A', {
      feedbackLastAt: null,
      feedbackDate: H.watToday(),
      feedbackSentToday: 10,
    }, { merge: true });
    await H.rejectsWith(
      send('A'),
      'resource-exhausted',
      'feedback limit',
    );

    await H.setDoc(db, 'users/A', {
      feedbackDate: '2000-01-01',
      feedbackSentToday: 10,
    }, { merge: true });
    await send('A');

    const user = await H.getDoc(db, 'users/A');
    assert.equal(user.feedbackSentToday, 1);
    assert.equal(user.feedbackDate, H.watToday());
    assert.equal(user.username, 'Ash', 'unrelated profile fields untouched');
  });

  it('deletes only the deleted account\'s reports', async () => {
    await H.mkUser(db, 'B', { username: 'Brock', email: 'b@t.co' });
    await send('A');
    await send('B');
    assert.equal((await reports()).length, 2);

    await fns.deleteAccount.run(H.req('A'));

    const left = await reports();
    assert.equal(left.length, 1, 'account erasure removes the sender\'s reports');
    assert.equal(left[0].uid, 'B', 'other players\' reports are untouched');
  });
});

describe('deleteAccount leaderboard claims', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await H.mkUser(db, 'A', { username: 'Ash', email: 'ash@t.co' });
  });

  async function claims(weekId) {
    const snap = await db.collection('leaderboardCycles').doc(weekId)
      .collection('pendingClaim').get();
    return snap.docs;
  }

  it('creates no pendingClaim when the deleted user never won', async () => {
    await H.setDoc(db, 'leaderboardCycles/2026-10-05', {
      status: 'calculated', ranked: [],
    });
    await H.setDoc(db, 'leaderboardCycles/2026-10-12', {
      status: 'calculated', ranked: [],
    });

    const res = await fns.deleteAccount.run(H.req('A'));

    assert.equal((await claims('2026-10-05')).length, 0,
      'no phantom claim in a cycle the user never won');
    assert.equal((await claims('2026-10-12')).length, 0);
    assert.equal(res.anonymized.pendingClaims, undefined);
  });

  it('anonymizes only claims that already exist and leaves others alone', async () => {
    await H.setDoc(db, 'leaderboardCycles/2026-10-05', {
      status: 'calculated', ranked: [],
    });
    await H.setDoc(db, 'leaderboardCycles/2026-10-12', {
      status: 'calculated', ranked: [],
    });
    await H.setDoc(db, 'leaderboardCycles/2026-10-05/pendingClaim/A', {
      uid: 'A', accountNumber: '0123456789', bankCode: '058',
      beneficiaryName: 'Ash', status: 'marked', amount: 500,
    });
    await H.setDoc(db, 'leaderboardCycles/2026-10-05/pendingClaim/OTHER', {
      uid: 'OTHER', accountNumber: '9999999999', bankCode: '058',
      beneficiaryName: 'Other', status: 'marked', amount: 500,
    });

    const res = await fns.deleteAccount.run(H.req('A'));

    const own = (await claims('2026-10-05')).find((d) => d.id === 'A');
    assert.ok(own, 'existing claim is kept as the payout record');
    assert.equal(own.data().status, 'anonymized');
    assert.equal(own.data().accountNumber, undefined);
    assert.equal(own.data().bankCode, undefined);
    assert.equal(own.data().beneficiaryName, undefined);
    assert.equal(own.data().amount, 500, 'accounting fields survive');

    const other = (await claims('2026-10-05')).find((d) => d.id === 'OTHER');
    assert.equal(other.data().status, 'marked', 'another user is untouched');
    assert.equal(other.data().accountNumber, '9999999999');

    assert.equal((await claims('2026-10-12')).length, 0,
      'no phantom claim in a cycle with no existing claim');
    assert.equal(res.anonymized.pendingClaims, 1);
  });
});
