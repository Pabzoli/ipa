// functions/test/single_session.test.js — single-device login.
//
// One account holds exactly one live login: claimSession records the caller's
// ID-token auth_time as users/{uid}.activeSession, and the onSecureCall
// wrapper rejects any caller whose auth_time is OLDER than the record with
// `failed-precondition / session_superseded`. A newer login (claim in flight)
// and a caller with no record at all (legacy builds that never claim) are
// allowed — the gate fails open everywhere except a proven-stale login.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const T_OLD = 1700000000;
const T_NEW = 1700003600;

// Authenticated request carrying the given login's auth_time (seconds).
// H.req's default auth carries no auth_time, which mirrors a legacy caller.
function atReq(uid, authTime, data = {}) {
  return H.req(uid, data, {
    auth: { uid, token: { email_verified: true, auth_time: authTime } },
  });
}

function claim(uid, authTime, extra = {}) {
  return fns.claimSession.run(atReq(uid, authTime, extra));
}

function referralCode(uid, authTime) {
  return fns.getMyReferralCode.run(atReq(uid, authTime));
}

describe('single-device login', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
    await H.mkUser(db, 'A');
  });

  it('claimSession records the login as the live session', async () => {
    const out = await claim('A', T_OLD, { sessionId: 'nonce-a' });
    assert.equal(out.ok, true);
    assert.equal(out.superseded, false);
    const stored = (await H.getDoc(db, 'users/A')).activeSession;
    assert.equal(stored.authTime, T_OLD);
    assert.equal(stored.sessionId, 'nonce-a');
  });

  it('a newer login supersedes the older one, which is then rejected', async () => {
    await claim('A', T_OLD, { sessionId: 'nonce-a' });
    const out = await claim('A', T_NEW, { sessionId: 'nonce-b' });
    assert.equal(out.ok, true);
    assert.equal(out.superseded, true);
    assert.equal((await H.getDoc(db, 'users/A')).activeSession.authTime, T_NEW);

    // The old login can no longer transact, even on a read-only callable.
    await H.rejectsWith(referralCode('A', T_OLD), 'failed-precondition', 'session_superseded');

    // The owning login is unaffected.
    const res = await referralCode('A', T_NEW);
    assert.ok(typeof res.referralCode === 'string' && res.referralCode.length > 0);
  });

  it('a same-second login with a different nonce is rejected', async () => {
    await claim('A', T_OLD, { sessionId: 'nonce-a' });
    await H.rejectsWith(
      fns.getMyReferralCode.run(atReq('A', T_OLD, { sessionId: 'nonce-b' })),
      'failed-precondition', 'session_superseded');
    // The owner (matching nonce) still passes.
    const res = await fns.getMyReferralCode.run(atReq('A', T_OLD, { sessionId: 'nonce-a' }));
    assert.ok(res.referralCode);
  });

  it('callers with no record and legacy callers without auth_time fail open', async () => {
    // No session ever claimed: a timestamped caller is allowed.
    const res = await referralCode('A', T_OLD);
    assert.ok(res.referralCode);

    // A session exists, but a caller that cannot be discriminated is allowed
    // (shipped builds send no auth_time until they are replaced).
    await claim('A', T_NEW);
    const legacy = await fns.getMyReferralCode.run(H.req('A', {}));
    assert.ok(legacy.referralCode);
  });

  it('releaseSession clears only the owning login', async () => {
    await claim('A', T_OLD, { sessionId: 'nonce-a' });
    await claim('A', T_NEW, { sessionId: 'nonce-b' });

    // The superseded login cannot clear the live session.
    const stale = await fns.releaseSession.run(atReq('A', T_OLD, { sessionId: 'nonce-a' }));
    assert.equal(stale.released, false);
    assert.equal((await H.getDoc(db, 'users/A')).activeSession.authTime, T_NEW);

    // The owner releases it.
    const own = await fns.releaseSession.run(atReq('A', T_NEW, { sessionId: 'nonce-b' }));
    assert.equal(own.released, true);
    assert.equal((await H.getDoc(db, 'users/A')).activeSession, undefined);

    // With no record, the previously stale login works again (fail open).
    const res = await referralCode('A', T_OLD);
    assert.ok(res.referralCode);
  });

  it('lifecycle callables stay reachable for a superseded login', async () => {
    await claim('A', T_OLD);
    await claim('A', T_NEW);
    // Re-claiming heals: the old device signing in again becomes live.
    const heal = await claim('A', T_OLD + 7200);
    assert.equal(heal.ok, true);
    const res = await referralCode('A', T_OLD + 7200);
    assert.ok(res.referralCode);
  });

  it('ensureProfile seeds the creating login as the live session', async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
    await fns.ensureProfile.run(atReq('N', T_NEW, {
      username: 'newbie9', email: 'n@t.co', deviceId: 'd1',
      termsAccepted: true, platform: 'web',
    }));
    const stored = (await H.getDoc(db, 'users/N')).activeSession;
    assert.equal(stored.authTime, T_NEW);
  });
});
