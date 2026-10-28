// functions/test/email_verification.test.js
//
// What must stay true:
//   • email normalization, disposable blocking, per-IP account limits and
//     normalized-email uniqueness at signup;
//   • terms are accepted once, at profile creation, and the version is stamped
//     by the server;
//   • verification is informational: no callable gates on it any more, but the
//     uniqueness claim follows a verified email change;
//   • resend budgets (requestEmailVerification and prepareEmailChange).
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');
const TH = fns._testHelpers;

const WEB = { platform: 'web' };

function withIp(uid, data, ip = '198.51.100.7', token = {}) {
  return H.req(uid, data, {
    rawRequest: { headers: { 'x-forwarded-for': ip } },
    ...(Object.keys(token).length ? { auth: { uid, token } } : {}),
  });
}

describe('email normalization + blocklist', () => {
  it('lowercases, strips +tags and gmail dots, canonicalises googlemail', () => {
    assert.equal(TH._normalizeEmail(' A.B+promo@Gmail.com '), 'ab@gmail.com');
    assert.equal(TH._normalizeEmail('a.b@googlemail.com'), 'ab@gmail.com');
    assert.equal(TH._normalizeEmail('a.b@yahoo.com'), 'a.b@yahoo.com');
    assert.equal(TH._normalizeEmail('not-an-email'), '');
  });

  it('blocks disposable domains and their subdomains only', () => {
    assert.equal(TH._isDisposableEmail('x@mailinator.com'), true);
    assert.equal(TH._isDisposableEmail('x@inbox.mailinator.com'), true);
    assert.equal(TH._isDisposableEmail('x@gmail.com'), false);
    assert.equal(TH._isDisposableEmail('x@aol.com'), false);
  });
});

describe('only non-money callables skip the email gate', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('createChallenge accepts an unverified account', async () => {
    await H.mkUser(db, 'u1', { emailVerified: false });
    ctx.authUsers.set('u1', { email: 'u1@t.co', emailVerified: false });
    await H.seedQuestions(db);
    const out = await fns.createChallenge.run(H.unverifiedReq('u1', {
      animeTitle: 'testanime', stakeAmount: 100, wpStake: 0, challengeType: 'code', ...WEB,
    }));
    assert.ok(out.challengeId);
  });

  it('redeemCode accepts a leaderboard entry code for an unverified account', async () => {
    await H.mkUser(db, 'u1', { emailVerified: false });
    ctx.authUsers.set('u1', { email: 'u1@t.co', emailVerified: false });
    await db.collection('redemptionCodes').doc('LB1').set({
      type: 'leaderboard_entry', value: '2026-10-26', status: 'unused',
    });
    const out = await fns.redeemCode.run(H.unverifiedReq('u1', { code: 'LB1', ...WEB }));
    assert.equal(out.success, true);
  });
});

describe('verified-email gate on the five money paths', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('savePayoutDetail rejects an unverified token', async () => {
    await H.mkUser(db, 'u1', { emailVerified: false });
    const err = await H.rejectsWith(
      fns.savePayoutDetail.run(H.unverifiedReq('u1', {
        bankCode: '058', accountNumber: '0123456789',
        beneficiaryName: 'Test User', ...WEB,
      })),
      'failed-precondition',
      'Verify your email',
    );
    assert.equal(err.details?.reason, 'email_not_verified');
  });

  it('submitPayoutDetails rejects an unverified token', async () => {
    await H.mkUser(db, 'u1', { emailVerified: false });
    const err = await H.rejectsWith(
      fns.submitPayoutDetails.run(H.unverifiedReq('u1', {
        weekId: '2026-10-26', bankCode: '058',
        accountNumber: '0123456789', beneficiaryName: 'Test User', ...WEB,
      })),
      'failed-precondition',
      'Verify your email',
    );
    assert.equal(err.details?.reason, 'email_not_verified');
  });

  it('claimReferralBonus rejects an unverified invitee', async () => {
    await H.mkUser(db, 'inv', { emailVerified: false });
    await H.mkUser(db, 'ref', { emailVerified: true });
    const err = await H.rejectsWith(
      fns.claimReferralBonus.run(H.unverifiedReq('inv', { referredBy: 'ref' })),
      'failed-precondition',
      'Verify your email',
    );
    assert.equal(err.details?.reason, 'email_not_verified');
  });

  it('claimReferralCashout rejects an unverified token', async () => {
    await H.mkUser(db, 'u1', { emailVerified: false });
    const err = await H.rejectsWith(
      fns.claimReferralCashout.run(H.unverifiedReq('u1', {
        bankCode: '058', accountNumber: '0123456789',
        beneficiaryName: 'Test User', ...WEB,
      })),
      'failed-precondition',
      'Verify your email',
    );
    assert.equal(err.details?.reason, 'email_not_verified');
  });

  it('savePayoutDetail accepts a verified token', async () => {
    await H.mkUser(db, 'u1', { emailVerified: true });
    const out = await fns.savePayoutDetail.run(H.req('u1', {
      bankCode: '058', accountNumber: '0123456789',
      beneficiaryName: 'Test User', ...WEB,
    }));
    assert.equal(out.success, true);
  });
});

describe('acceptTerms', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('refuses without an explicit acceptance', async () => {
    await H.mkUser(db, 'u1');
    await H.rejectsWith(
      fns.acceptTerms.run(H.req('u1', { ...WEB })),
      'failed-precondition',
      'Accept the Terms',
    );
    await H.rejectsWith(
      fns.acceptTerms.run(H.req('u1', { termsAccepted: false, ...WEB })),
      'failed-precondition',
      'Accept the Terms',
    );
  });

  it('stamps termsAcceptedAt and the server version, ignoring client version', async () => {
    await H.mkUser(db, 'u1');
    const out = await fns.acceptTerms.run(H.req('u1', {
      termsAccepted: true, termsVersion: 'client-forged', ...WEB,
    }));
    assert.equal(out.success, true);
    const user = await H.getDoc(db, 'users/u1');
    assert.ok(user.termsAcceptedAt, 'termsAcceptedAt is stamped');
    assert.equal(typeof user.termsVersion, 'string');
    assert.notEqual(user.termsVersion, 'client-forged');
  });

  it('is idempotent when already accepted', async () => {
    await H.mkUser(db, 'u1', { termsAcceptedAt: 'stamp', termsVersion: 'v1' });
    const out = await fns.acceptTerms.run(H.req('u1', { termsAccepted: true, ...WEB }));
    assert.equal(out.success, true);
    assert.equal(out.alreadyAccepted, true);
  });
});

describe('syncEmailVerification', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('does not mirror when Admin says unverified', async () => {
    await H.mkUser(db, 'u1', { emailVerified: false });
    ctx.authUsers.set('u1', { email: 'u1@t.co', emailVerified: false });
    const out = await fns.syncEmailVerification.run(H.req('u1'));
    assert.equal(out.emailVerified, false);
    const user = await H.getDoc(db, 'users/u1');
    assert.equal(user.emailVerified, false);
  });

  it('mirrors the flag, hash and uniqueness claim when verified', async () => {
    await H.mkUser(db, 'u1', { emailVerified: false, email: 'U.1+tag@GoogleMail.com' });
    ctx.authUsers.set('u1', { email: 'U.1+tag@GoogleMail.com', emailVerified: true });
    const out = await fns.syncEmailVerification.run(H.req('u1'));
    assert.equal(out.emailVerified, true);
    assert.equal(out.emailNormalized, 'u1@gmail.com');
    assert.equal(out.mustRefreshToken, true);

    const user = await H.getDoc(db, 'users/u1');
    assert.equal(user.emailVerified, true);
    assert.equal(user.emailNormalized, 'u1@gmail.com');

    const claim = await H.getDoc(db, `emailIdentities/${TH._emailHash('u1@gmail.com')}`);
    assert.equal(claim.uid, 'u1');
  });

  it('moves the uniqueness claim when the verified email changes', async () => {
    const oldHash = TH._emailHash('old@gmail.com');
    const newHash = TH._emailHash('new@t.co');
    await H.mkUser(db, 'u1', { emailVerified: false, email: 'new@t.co' });
    await db.collection('users').doc('u1').update({ emailHash: oldHash });
    await H.setDoc(db, `emailIdentities/${oldHash}`, { uid: 'u1' });
    ctx.authUsers.set('u1', { email: 'new@t.co', emailVerified: true });

    const out = await fns.syncEmailVerification.run(H.req('u1'));
    assert.equal(out.emailVerified, true);
    assert.equal(await H.getDoc(db, `emailIdentities/${oldHash}`), null,
      'the previous address is released for a new signup');
    assert.equal((await H.getDoc(db, `emailIdentities/${newHash}`)).uid, 'u1');
    assert.equal((await H.getDoc(db, 'users/u1')).emailHash, newHash);
  });

  it('refuses a verified email whose claim belongs to another account', async () => {
    await H.mkUser(db, 'u1', { emailVerified: false, email: 'taken@t.co' });
    await H.setDoc(db, `emailIdentities/${TH._emailHash('taken@t.co')}`, { uid: 'other' });
    ctx.authUsers.set('u1', { email: 'taken@t.co', emailVerified: true });

    const err = await H.rejectsWith(
      fns.syncEmailVerification.run(H.req('u1')),
      'already-exists',
      'already exists',
    );
    assert.equal(err.details?.reason, 'email_already_registered');
    assert.equal((await H.getDoc(db, `emailIdentities/${TH._emailHash('taken@t.co')}`)).uid, 'other');
    assert.equal((await H.getDoc(db, 'users/u1')).emailVerified, false);
  });
});

describe('requestEmailVerification', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
    await H.mkUser(db, 'u1', { emailVerified: false, email: 'u1@t.co' });
    ctx.authUsers.set('u1', { email: 'u1@t.co', emailVerified: false });
  });

  it('allows one send, then enforces the 60s cooldown', async () => {
    const first = await fns.requestEmailVerification.run(H.req('u1', {}, { auth: { uid: 'u1', token: { email: 'u1@t.co' } } }));
    assert.equal(first.ok, true);
    assert.equal(first.remainingToday, TH._CFG.EMAIL_RESEND_MAX_PER_DAY - 1);

    const second = await fns.requestEmailVerification.run(H.req('u1', {}, { auth: { uid: 'u1', token: { email: 'u1@t.co' } } }));
    assert.equal(second.ok, false);
    assert.ok(second.retryAfterSeconds > 0 && second.retryAfterSeconds <= 60);
  });

  it('enforces the 5-per-day cap after the cooldown passes', async () => {
    await db.collection('emailResend').doc('u1').set({
      lastSentAtMs: Date.now() - 120 * 1000,
      dayStartMs: Date.now(),
      dayCount: TH._CFG.EMAIL_RESEND_MAX_PER_DAY,
    });
    const out = await fns.requestEmailVerification.run(H.req('u1', {}, { auth: { uid: 'u1', token: { email: 'u1@t.co' } } }));
    assert.equal(out.ok, false);
    assert.ok(out.retryAfterSeconds > 60);
  });

  it('does not count an already-verified account', async () => {
    ctx.authUsers.set('u1', { email: 'u1@t.co', emailVerified: true });
    const out = await fns.requestEmailVerification.run(H.req('u1', {}, { auth: { uid: 'u1', token: { email: 'u1@t.co' } } }));
    assert.equal(out.alreadyVerified, true);
    assert.equal(await H.getDoc(db, 'emailResend/u1'), null);
  });
});

describe('prepareEmailChange', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
    await H.mkUser(db, 'u1', { emailVerified: false, email: 'u1@t.co' });
    ctx.authUsers.set('u1', { email: 'u1@t.co', emailVerified: false });
  });

  it('refuses an account whose email is already verified', async () => {
    ctx.authUsers.set('u1', { email: 'u1@t.co', emailVerified: true });
    await H.rejectsWith(
      fns.prepareEmailChange.run(H.req('u1', { newEmail: 'fresh@t.co' })),
      'failed-precondition',
      'already verified',
    );
  });

  it('rejects an empty or malformed address', async () => {
    for (const newEmail of ['', 'not-an-email']) {
      await H.rejectsWith(
        fns.prepareEmailChange.run(H.req('u1', { newEmail })),
        'invalid-argument',
        'valid email',
      );
    }
  });

  it('rejects the address already on the account', async () => {
    await H.rejectsWith(
      fns.prepareEmailChange.run(H.req('u1', { newEmail: 'U1@t.co' })),
      'failed-precondition',
      'already your email',
    );
  });

  it('rejects a disposable address', async () => {
    const err = await H.rejectsWith(
      fns.prepareEmailChange.run(H.req('u1', { newEmail: 'burner@mailinator.com' })),
      'failed-precondition',
      'permanent email address',
    );
    assert.equal(err.details?.reason, 'disposable_email');
  });

  it('rejects an address claimed by another account, after normalization', async () => {
    await H.setDoc(db, `emailIdentities/${TH._emailHash('taken@gmail.com')}`, { uid: 'other' });
    const err = await H.rejectsWith(
      fns.prepareEmailChange.run(H.req('u1', { newEmail: 'T.A.K.E.N+promo@Gmail.com' })),
      'already-exists',
      'already exists',
    );
    assert.equal(err.details?.reason, 'email_already_registered');
  });

  it('reserves one send against the resend budget and enforces the cooldown', async () => {
    const first = await fns.prepareEmailChange.run(H.req('u1', { newEmail: 'fresh@t.co' }));
    assert.equal(first.ok, true);
    assert.equal(first.remainingToday, TH._CFG.EMAIL_RESEND_MAX_PER_DAY - 1);

    const second = await fns.prepareEmailChange.run(H.req('u1', { newEmail: 'fresh@t.co' }));
    assert.equal(second.ok, false);
    assert.ok(second.retryAfterSeconds > 0 && second.retryAfterSeconds <= 60);
  });
});

describe('ensureProfile signup abuse limits', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('rejects a disposable email before writing a profile', async () => {
    await H.rejectsWith(
      fns.ensureProfile.run(withIp('d1', {
        username: 'disposable', email: 'burner@mailinator.com', termsAccepted: true, ...WEB,
      }, '203.0.113.10', { email: 'burner@mailinator.com' })),
      'invalid-argument',
      'permanent email address',
    );
    assert.equal(await H.getDoc(db, 'users/d1'), null);
    const log = await db.collection('abuse_log').get();
    assert.ok(log.docs.some((d) => d.data().reason === 'disposable_email'));
  });

  it('claims the normalized email once', async () => {
    await fns.ensureProfile.run(withIp('a', {
      username: 'alpha', email: 'A.B+1@gmail.com', termsAccepted: true, ...WEB,
    }, '203.0.113.11', { email: 'A.B+1@gmail.com' }));
    await H.rejectsWith(
      fns.ensureProfile.run(withIp('b', {
        username: 'beta', email: 'ab@gmail.com', termsAccepted: true, ...WEB,
      }, '203.0.113.12', { email: 'ab@gmail.com' })),
      'already-exists',
      'already exists',
    );
  });

  it('limits account creation to 3 per hour per IP', async () => {
    const ip = '203.0.113.20';
    for (let i = 0; i < 3; i += 1) {
      await fns.ensureProfile.run(withIp(`h${i}`, {
        username: `hour${i}`, email: `hour${i}@t.co`, termsAccepted: true, ...WEB,
      }, ip, { email: `hour${i}@t.co` }));
    }
    await H.rejectsWith(
      fns.ensureProfile.run(withIp('h3', {
        username: 'hour3', email: 'hour3@t.co', termsAccepted: true, ...WEB,
      }, ip, { email: 'hour3@t.co' })),
      'resource-exhausted',
      'Too many accounts',
    );
    assert.equal(await H.getDoc(db, 'users/h3'), null);
  });

  it('drops a referral when the invitee shares the referrer device', async () => {
    await fns.ensureProfile.run(withIp('ref', {
      username: 'referrer', email: 'ref@t.co', deviceId: 'device-x', termsAccepted: true, ...WEB,
    }, '203.0.113.30', { email: 'ref@t.co' }));
    await fns.ensureProfile.run(withIp('inv', {
      username: 'invitee', email: 'inv@t.co', deviceId: 'device-x',
      referredBy: 'ref', termsAccepted: true, ...WEB,
    }, '203.0.113.31', { email: 'inv@t.co' }));
    const invitee = await H.getDoc(db, 'users/inv');
    assert.equal(invitee.referredBy, undefined);
  });
});

describe('ensureProfile terms acceptance', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    ctx.authUsers.clear();
  });

  it('refuses a new profile unless termsAccepted is true', async () => {
    for (const [uid, termsAccepted] of [['t0', undefined], ['t1', false]]) {
      const err = await H.rejectsWith(
        fns.ensureProfile.run(withIp(uid, {
          username: `terms${uid}`, email: `${uid}@t.co`, termsAccepted, ...WEB,
        }, '203.0.113.40', { email: `${uid}@t.co` })),
        'failed-precondition',
        'Accept the Terms',
      );
      assert.equal(err.details?.reason, 'terms_not_accepted');
      assert.equal(await H.getDoc(db, `users/${uid}`), null);
    }
  });

  it('stores termsAcceptedAt and the server-stamped termsVersion on accept', async () => {
    await fns.ensureProfile.run(withIp('acc', {
      username: 'accepted', email: 'acc@t.co', termsAccepted: true,
      termsVersion: 'client-forged', ...WEB,
    }, '203.0.113.41', { email: 'acc@t.co' }));
    const user = await H.getDoc(db, 'users/acc');
    assert.ok(user.termsAcceptedAt, 'termsAcceptedAt is stamped');
    assert.equal(typeof user.termsVersion, 'string');
    assert.ok(user.termsVersion.length > 0, 'termsVersion is non-empty');
    assert.notEqual(user.termsVersion, 'client-forged', 'the client cannot choose the version');
  });
});
