// functions/test/security.test.js — server-authoritative profile, username,
// university, payout-detail audit, ad sessions and redemption lockout.
//
// Same harness as the other suites: REAL handlers, fake Firestore, no emulator.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

const { installFakes } = require('./_fakes');
const ctx = installFakes();
const db = ctx.db;
const H = require('./helpers');
const fns = require('../index.js');

const DAY_MS = 24 * 60 * 60 * 1000;

describe('server-authoritative profile', () => {
  beforeEach(() => H.clearDb(db));

  it('ensureProfile seeds the profile and claims the username', async () => {
    const res = await fns.ensureProfile.run(H.req('u1', {
      username: 'Alice',
      email: 'alice@example.com',
      university: 'UNILAG',
    }));
    assert.equal(res.profileCreated, true);
    assert.equal(res.username, 'Alice');

    const user = await H.getDoc(db, 'users/u1');
    assert.equal(user.username, 'Alice');
    assert.equal(user.totalScore, 500);
    assert.equal(user.animeCoins, 0);
    assert.equal(user.weeklyPoints, 0);
    assert.equal(user.university, 'UNILAG');
    assert.deepEqual(user.stats, {
      gamesPlayed: 0, gamesWon: 0, gamesLost: 0,
      hseWon: 0, hseLost: 0, hseStaked: 0,
    });

    const claim = await H.getDoc(db, 'usernames/alice');
    assert.equal(claim.uid, 'u1');
  });

  it('rejects a duplicate username (case/space insensitive)', async () => {
    await fns.ensureProfile.run(H.req('u1', { username: 'Alice' }));
    await H.rejectsWith(
      fns.ensureProfile.run(H.req('u2', { username: '  alice ' })),
      'already-exists');
    const user = await H.getDoc(db, 'users/u2');
    assert.equal(user, null, 'the second account must not be created');
  });

  it('rejects unknown universities at creation', async () => {
    await H.rejectsWith(
      fns.ensureProfile.run(H.req('u1', {
        username: 'alice', university: 'Hogwarts',
      })),
      'invalid-argument');
  });

  it('never overwrites an existing profile name (no cooldown bypass)', async () => {
    await H.mkUser(db, 'u1', { username: 'original' });
    const res = await fns.ensureProfile.run(H.req('u1', {
      username: 'renamed',
    }));
    assert.equal(res.profileCreated, false);
    assert.equal((await H.getDoc(db, 'users/u1')).username, 'original');
    assert.equal((await H.getDoc(db, 'usernames/original')).uid, 'u1');
    assert.equal((await H.getDoc(db, 'usernames/renamed')), null);
  });
});

describe('changeUsername', () => {
  beforeEach(() => H.clearDb(db));

  it('moves the uniqueness claim and enforces the 7-day cooldown', async () => {
    await H.mkUser(db, 'u1', { username: 'alice' });
    await H.setDoc(db, 'usernames/alice', { uid: 'u1', username: 'alice' });

    const res = await fns.changeUsername.run(
      H.req('u1', { username: 'Alice2', platform: 'web' }));
    assert.equal(res.username, 'Alice2');
    assert.equal((await H.getDoc(db, 'users/u1')).username, 'Alice2');
    assert.equal((await H.getDoc(db, 'usernames/alice2')).uid, 'u1');
    assert.equal(await H.getDoc(db, 'usernames/alice'), null);

    // Immediately again → cooldown (server-side; no client check involved).
    await H.rejectsWith(
      fns.changeUsername.run(H.req('u1', { username: 'Alice3', platform: 'web' })),
      'failed-precondition', 'change your username again in');
  });

  it('allows a change after the cooldown has elapsed', async () => {
    await H.mkUser(db, 'u1', {
      username: 'alice',
      lastUsernameChange: ctx.FakeTimestamp.fromMillis(Date.now() - 8 * DAY_MS),
    });
    const res = await fns.changeUsername.run(
      H.req('u1', { username: 'fresh', platform: 'web' }));
    assert.equal(res.success, true);
    assert.equal((await H.getDoc(db, 'users/u1')).username, 'fresh');
  });

  it('refuses a name already claimed by another account', async () => {
    await H.mkUser(db, 'u1', { username: 'alice' });
    await H.mkUser(db, 'u2', { username: 'bob' });
    await H.setDoc(db, 'usernames/bob', { uid: 'u2', username: 'bob' });

    await H.rejectsWith(
      fns.changeUsername.run(H.req('u1', { username: 'bob', platform: 'web' })),
      'already-exists');
    assert.equal((await H.getDoc(db, 'users/u1')).username, 'alice');
  });

  it('rejects invalid usernames', async () => {
    await H.mkUser(db, 'u1', { username: 'alice' });
    for (const bad of ['ab', 'x'.repeat(21), '   ']) {
      await H.rejectsWith(
        fns.changeUsername.run(H.req('u1', { username: bad, platform: 'web' })),
        'invalid-argument');
    }
  });
});

describe('updateUniversity', () => {
  beforeEach(() => H.clearDb(db));

  it('accepts a canonical value and rejects free text', async () => {
    await H.mkUser(db, 'u1', { username: 'alice', university: 'UNILAG' });

    const res = await fns.updateUniversity.run(
      H.req('u1', { university: 'OAU', platform: 'web' }));
    assert.equal(res.university, 'OAU');
    assert.equal((await H.getDoc(db, 'users/u1')).university, 'OAU');

    await H.rejectsWith(
      fns.updateUniversity.run(
        H.req('u1', { university: 'Hogwarts', platform: 'web' })),
      'invalid-argument');
    await H.rejectsWith(
      fns.updateUniversity.run(H.req('u1', { university: '', platform: 'web' })),
      'invalid-argument');
  });
});

describe('payout detail audit', () => {
  beforeEach(() => H.clearDb(db));

  it('writes a masked before/after audit entry for create and update', async () => {
    await H.mkUser(db, 'u1', { username: 'alice' });

    const created = await fns.savePayoutDetail.run(H.req('u1', {
      accountNumber: '0123456789',
      bankCode: '058',
      beneficiaryName: 'Alice A',
      bankName: 'GTBank',
      platform: 'web',
    }));
    assert.equal(created.success, true);
    const detail = await H.getDoc(db, `users/u1/payoutDetails/${created.id}`);
    assert.equal(detail.accountNumber, '0123456789');

    let audits = await db.collection('payoutDetailAudit').get();
    assert.equal(audits.size, 1);
    const first = audits.docs[0].data();
    assert.equal(first.action, 'create');
    assert.equal(first.before, null);
    assert.equal(first.after.accountMask, '****6789');

    await fns.savePayoutDetail.run(H.req('u1', {
      docId: created.id,
      accountNumber: '9876543210',
      bankCode: '058',
      beneficiaryName: 'Alice A',
      platform: 'web',
    }));

    audits = await db.collection('payoutDetailAudit').get();
    assert.equal(audits.size, 2);
    const update = audits.docs.map((d) => d.data()).find((a) => a.action === 'update');
    assert.equal(update.before.accountMask, '****6789');
    assert.equal(update.after.accountMask, '****3210');
    // The full account number never reaches the audit collection.
    assert.ok(!JSON.stringify(update).includes('9876543210'));
  });

  it('validates the account payload', async () => {
    await H.mkUser(db, 'u1', { username: 'alice' });
    await H.rejectsWith(
      fns.savePayoutDetail.run(H.req('u1', {
        accountNumber: '12345', bankCode: '058', beneficiaryName: 'Alice',
        platform: 'web',
      })),
      'invalid-argument');
    await H.rejectsWith(
      fns.savePayoutDetail.run(H.req('u1', {
        accountNumber: '0123456789', bankCode: 'abc', beneficiaryName: 'Alice',
        platform: 'web',
      })),
      'invalid-argument');
  });

  it('refuses to update a detail that does not exist', async () => {
    await H.mkUser(db, 'u1', { username: 'alice' });
    await H.rejectsWith(
      fns.savePayoutDetail.run(H.req('u1', {
        docId: 'nope',
        accountNumber: '0123456789', bankCode: '058', beneficiaryName: 'Alice',
        platform: 'web',
      })),
      'not-found');
  });
});

describe('rewarded-ad sessions', () => {
  beforeEach(() => H.clearDb(db));

  it('mints a single-use session and awards coins exactly once', async () => {
    await H.mkUser(db, 'u1', { username: 'alice', animeCoins: 100, dailyAdWatched: 0 });

    const session = await fns.startAdSession.run(
      H.req('u1', { platform: 'web' }));
    assert.match(session.sessionToken, /^[0-9a-f-]{36}$/);

    const first = await fns.recordAdWatch.run(H.req('u1', {
      sessionToken: session.sessionToken,
      platform: 'web',
    }));
    assert.equal(first.success, true);
    assert.equal(first.coinsAwarded, 15);
    assert.equal((await H.getDoc(db, 'users/u1')).animeCoins, 115);

    // Same token cannot mint a second reward.
    const replay = await fns.recordAdWatch.run(H.req('u1', {
      sessionToken: session.sessionToken,
      platform: 'web',
    }));
    assert.equal(replay.success, false);
    assert.equal(replay.error, 'ad_session_invalid');
    assert.equal((await H.getDoc(db, 'users/u1')).animeCoins, 115);
  });

  it('keeps legacy (untokened) callers working during the migration', async () => {
    await H.mkUser(db, 'u1', { username: 'alice' });
    await H.mkUser(db, 'u2', { username: 'bob' });

    // requireAdSession is false by default, so the shipped APK still earns.
    const legacy = await fns.recordAdWatch.run(H.req('u1', { platform: 'web' }));
    assert.equal(legacy.success, true);

    // A token minted for one user is never redeemable by another.
    const session = await fns.startAdSession.run(
      H.req('u1', { platform: 'web' }));
    const stolen = await fns.recordAdWatch.run(H.req('u2', {
      sessionToken: session.sessionToken,
      platform: 'web',
    }));
    assert.equal(stolen.success, false);
    assert.equal(stolen.error, 'ad_session_invalid');
  });

  it('keeps the 30-second spacing rule', async () => {
    await H.mkUser(db, 'u1', {
      username: 'alice',
      animeCoins: 100,
      lastAdWatchDate: ctx.FakeTimestamp.fromMillis(Date.now() - 5 * 1000),
    });

    const session = await fns.startAdSession.run(
      H.req('u1', { platform: 'web' }));
    const res = await fns.recordAdWatch.run(H.req('u1', {
      sessionToken: session.sessionToken,
      platform: 'web',
    }));
    assert.equal(res.success, false);
    assert.equal(res.error, 'ad_cooldown_active');
    assert.equal((await H.getDoc(db, 'users/u1')).animeCoins, 100);
  });

  it('keeps the daily cap', async () => {
    await H.mkUser(db, 'u1', {
      username: 'alice',
      animeCoins: 100,
      dailyAdWatched: 10,
      lastAdWatchDate: ctx.FakeTimestamp.fromMillis(Date.now() - 60 * 1000),
    });

    const session = await fns.startAdSession.run(
      H.req('u1', { platform: 'web' }));
    const res = await fns.recordAdWatch.run(H.req('u1', {
      sessionToken: session.sessionToken,
      platform: 'web',
    }));
    assert.equal(res.success, false);
    assert.equal(res.error, 'daily_limit_reached');
    assert.equal((await H.getDoc(db, 'users/u1')).animeCoins, 100);
  });
});
