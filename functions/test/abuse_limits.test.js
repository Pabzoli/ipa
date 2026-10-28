// functions/test/abuse_limits.test.js
//
// Server-side limits: failed sign-ins, resend/abuse-log retention, and the
// unverified-account cleanup (including its creation-epoch guard).
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes, FakeTimestamp } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');
const TH = fns._testHelpers;

const DAY = 24 * 60 * 60 * 1000;

function withIp(uid, data, ip) {
  return H.req(uid, data, { rawRequest: { headers: { 'x-forwarded-for': ip } } });
}

describe('failed sign-in lockout', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('locks an email after 5 failures and reports retryAfterSeconds', async () => {
    const ip = '192.0.2.10';
    for (let i = 0; i < TH._CFG.AUTH_FAILURE_MAX; i += 1) {
      await fns.reportAuthFailure.run(withIp(null, {
        email: 'Victim@Example.com', kind: 'signin',
      }, ip));
    }
    const check = await fns.checkAuthAttempt.run(withIp(null, {
      email: 'victim@example.com',
    }, ip));
    assert.equal(check.allowed, false);
    assert.ok(check.retryAfterSeconds > 0);
    assert.equal(check.retryAfterSeconds, TH._CFG.AUTH_LOCK_MINUTES * 60);

    const log = await db.collection('abuse_log').get();
    assert.ok(log.docs.some((d) => d.data().reason === 'auth_failure_lockout'));
  });

  it('normalizes the email before counting failures', async () => {
    const ip = '192.0.2.11';
    for (let i = 0; i < TH._CFG.AUTH_FAILURE_MAX - 1; i += 1) {
      await fns.reportAuthFailure.run(withIp(null, { email: 'a.b+x@gmail.com' }, ip));
    }
    // googlemail + dots + tag must hit the same counter
    const out = await fns.reportAuthFailure.run(withIp(null, {
      email: 'AB@googlemail.com',
    }, ip));
    assert.equal(out.locked, true);
  });

  it('reportAuthSuccess clears the email counter', async () => {
    const ip = '192.0.2.12';
    for (let i = 0; i < 3; i += 1) {
      await fns.reportAuthFailure.run(withIp(null, { email: 'ok@t.co' }, ip));
    }
    await fns.reportAuthSuccess.run(H.req(null, { email: 'ok@t.co' }));
    const check = await fns.checkAuthAttempt.run(withIp(null, {
      email: 'ok@t.co',
    }, '192.0.2.99')); // a fresh IP avoids the per-IP counter
    assert.equal(check.allowed, true);
    assert.equal(check.remainingAttempts, TH._CFG.AUTH_FAILURE_MAX);
  });
});

describe('cleanupAbuseState', () => {
  beforeEach(async () => {
    await H.clearDb(db);
  });

  it('deletes expired rows only', async () => {
    const past = FakeTimestamp.fromMillis(Date.now() - 1000);
    const future = FakeTimestamp.fromMillis(Date.now() + DAY);
    await db.collection('abuse_log').doc('old').set({ reason: 'x', expiresAt: past });
    await db.collection('abuse_log').doc('new').set({ reason: 'y', expiresAt: future });
    await db.collection('rate_limits').doc('rl-old').set({ expiresAt: past });
    await db.collection('challengePairs').doc('p-old').set({ expiresAt: past });

    await fns.cleanupAbuseState.run({});

    assert.equal(await H.getDoc(db, 'abuse_log/old'), null);
    assert.ok(await H.getDoc(db, 'abuse_log/new'));
    assert.equal(await H.getDoc(db, 'rate_limits/rl-old'), null);
    assert.equal(await H.getDoc(db, 'challengePairs/p-old'), null);
  });
});

describe('cleanupUnverifiedAccounts', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
    // The production epoch is the feature's deploy date, so nothing is old
    // enough to delete on day one. Tests move it back to exercise the job.
    TH._setUnverifiedCleanupEpoch(Date.now() - 100 * DAY);
  });

  function seedAuth(uid, { verified, ageDays, email }) {
    ctx.authUsers.set(uid, {
      email: email || `${uid}@t.co`,
      emailVerified: verified,
      metadata: {
        creationTime: new Date(Date.now() - ageDays * DAY).toISOString(),
      },
    });
  }

  it('deletes only post-epoch, unverified accounts older than 7 days', async () => {
    seedAuth('kill', { verified: false, ageDays: 8 });
    seedAuth('keep-fresh', { verified: false, ageDays: 2 });
    seedAuth('keep-verified', { verified: true, ageDays: 30 });
    seedAuth('keep-legacy', { verified: false, ageDays: 200 }); // pre-epoch

    await db.collection('users').doc('kill').set({ username: 'kill' });
    await db.collection('usernames').doc('kill').set({ uid: 'kill', username: 'kill' });
    await db.collection('emailIdentities').doc(TH._emailHash('kill@t.co'))
      .set({ uid: 'kill', emailNormalized: 'kill@t.co' });

    await fns.cleanupUnverifiedAccounts.run({});

    assert.equal(ctx.authUsers.has('kill'), false);
    assert.equal(await H.getDoc(db, 'users/kill'), null);
    assert.equal(await H.getDoc(db, 'usernames/kill'), null);
    assert.equal(await H.getDoc(db, `emailIdentities/${TH._emailHash('kill@t.co')}`), null);

    assert.equal(ctx.authUsers.has('keep-fresh'), true);
    assert.equal(ctx.authUsers.has('keep-verified'), true);
    assert.equal(ctx.authUsers.has('keep-legacy'), true);
  });

  it('honours the server_config/security kill switch', async () => {
    seedAuth('kill2', { verified: false, ageDays: 10 });
    await db.collection('server_config').doc('security').set({
      unverifiedCleanupEnabled: false,
    });
    await fns.cleanupUnverifiedAccounts.run({});
    assert.equal(ctx.authUsers.has('kill2'), true);
  });
});
