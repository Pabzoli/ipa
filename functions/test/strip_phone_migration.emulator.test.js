// functions/test/strip_phone_migration.emulator.test.js — ONE-OFF phone-strip
// migration (scripts/strip_phone_fields.js) against the Auth + Firestore
// emulators. Skipped unless BOTH FIRESTORE_EMULATOR_HOST and
// FIREBASE_AUTH_EMULATOR_HOST are set, so the default `node --test` run stays
// green. Runs under its own demo project id, so it never shares data with
// rules.test.js (the emulators isolate data per project).
'use strict';
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const migration = require('../../scripts/strip_phone_fields.js');

const FS_HOST = process.env.FIRESTORE_EMULATOR_HOST;
const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST;
const SKIP = FS_HOST && AUTH_HOST
  ? false
  : 'needs FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST';
const PROJECT = migration.EMULATOR_PROJECT_ID;
const PW = 'test-only-password-1';

const U_EMAIL_ONLY = 'mig_email_only';
const U_EMAIL_PHONE = 'mig_email_phone';
const U_EMAIL_PHONE_NODOC = 'mig_email_phone_nodoc';
const U_PHONE_ONLY = 'mig_phone_only';
const PHONE_EP = '+2348011110001';
const PHONE_EPN = '+2348011110002';
const PHONE_PO = '+2348022220003';

const PHONE_FIELDS = migration.PHONE_USER_FIELDS;

// Seeded user docs. Phone fields and non-phone fields are both present so the
// test can prove the migration removes only the phone keys.
const USER_DOCS = {
  [U_EMAIL_ONLY]: {
    username: 'emailonly', animeCoins: 120, weeklyPoints: 30,
    email: 'email.only@example.test',
  },
  [U_EMAIL_PHONE]: {
    username: 'emailphone', animeCoins: 50, weeklyPoints: 7,
    phoneNumber: PHONE_EP, phoneVerified: true,
    phoneVerifiedAt: new Date('2026-01-02T00:00:00Z'),
    phoneVerifiedSource: 'otp', phoneVerifiedBy: 'system', phoneVerifiedNote: 'legacy',
  },
  [U_PHONE_ONLY]: {
    username: 'phoneonly', animeCoins: 5, weeklyPoints: 0,
    phoneNumber: PHONE_PO, phoneVerified: true,
    phoneVerifiedAt: new Date('2026-01-03T00:00:00Z'), phoneVerifiedSource: 'otp',
  },
};

const CLAIMS = {
  [PHONE_EP]: { uid: U_EMAIL_PHONE },
  [PHONE_EPN]: { uid: U_EMAIL_PHONE_NODOC },
  [PHONE_PO]: { uid: U_PHONE_ONLY },
};

let c = null;

// Project-scoped emulator wipe. Only touches PROJECT, never another suite.
async function clearEmulatorProject() {
  const r1 = await fetch(
    `http://${FS_HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`,
    { method: 'DELETE' });
  const r2 = await fetch(
    `http://${AUTH_HOST}/emulator/v1/projects/${PROJECT}/accounts`,
    { method: 'DELETE' });
  assert.ok(r1.ok && r2.ok, `emulator wipe failed: firestore=${r1.status} auth=${r2.status}`);
}

async function seed(cl) {
  await cl.auth.createUser({
    uid: U_EMAIL_ONLY, email: 'email.only@example.test', password: PW, emailVerified: true,
  });
  await cl.auth.createUser({
    uid: U_EMAIL_PHONE, email: 'email.phone@example.test', password: PW,
    emailVerified: true, phoneNumber: PHONE_EP,
  });
  await cl.auth.createUser({
    uid: U_EMAIL_PHONE_NODOC, email: 'nodoc@example.test', password: PW,
    emailVerified: true, phoneNumber: PHONE_EPN,
  });
  await cl.auth.createUser({ uid: U_PHONE_ONLY, phoneNumber: PHONE_PO });

  for (const [uid, data] of Object.entries(USER_DOCS)) {
    await cl.db.collection('users').doc(uid).set(data);
  }
  for (const [id, data] of Object.entries(CLAIMS)) {
    await cl.db.collection('phoneNumbers').doc(id).set(data);
  }
}

function withoutPhone(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    if (!PHONE_FIELDS.includes(k)) out[k] = v;
  }
  return out;
}

function providerIds(user) {
  return (user.providerData || []).map((p) => p.providerId).sort();
}

describe('strip_phone_fields migration (emulator)', { skip: SKIP }, () => {
  const logs = [];
  const log = (line) => logs.push(String(line));
  let dry = null;

  before(async () => {
    await clearEmulatorProject();
    c = migration.getClients();
    await seed(c);
  });

  after(async () => {
    await migration.shutdown();
  });

  it('dry run reports counts, lists the phone-only account, and writes nothing', async () => {
    dry = await migration.run({ execute: false, log });

    assert.equal(dry.executed, false);
    assert.equal(dry.usersScanned, 3);
    assert.equal(dry.userDocsWithPhone, 2);
    assert.equal(dry.claimDocs, 3);
    assert.equal(dry.authScanned, 4);
    assert.equal(dry.authPhoneAccounts, 3);
    assert.equal(dry.unlinkCandidates, 2);
    assert.deepEqual(dry.phoneOnlyUids, [U_PHONE_ONLY]);
    assert.ok(logs[0].startsWith('[emulator] '), `header not tagged: ${logs[0]}`);
    assert.ok(logs.some((l) => l.includes(`uid=${U_PHONE_ONLY}`)), 'phone-only uid not listed');
    assert.ok(!logs.some((l) => l.includes(PHONE_PO)), 'full phone number leaked into output');
    assert.ok(!logs.some((l) => l.includes('example.test')), 'full email leaked into output');

    const docs = await c.db.collection('users').doc(U_EMAIL_PHONE).get();
    assert.equal(docs.data().phoneNumber, PHONE_EP, 'dry run modified a user doc');
    assert.equal((await c.db.collection('phoneNumbers').get()).size, 3, 'dry run deleted claims');
    const ep = await c.auth.getUser(U_EMAIL_PHONE);
    assert.ok(providerIds(ep).includes('phone'), 'dry run unlinked a phone provider');
  });

  it('execute strips phone fields, deletes claims, unlinks phone only where another provider remains', async () => {
    const first = await migration.run({ execute: true, log });

    assert.equal(first.executed, true);
    assert.equal(first.userDocsUpdated, 2);
    assert.equal(first.claimDocsDeleted, 3);
    assert.equal(first.authUnlinked, 2);
    assert.equal(first.authErrors, 0);
    assert.deepEqual(first.phoneOnlyUids, [U_PHONE_ONLY]);

    for (const [uid, before] of Object.entries(USER_DOCS)) {
      const snap = await c.db.collection('users').doc(uid).get();
      assert.deepEqual(snap.data(), withoutPhone(before), `user doc ${uid} wrong after execute`);
      for (const f of PHONE_FIELDS) {
        assert.equal(Object.prototype.hasOwnProperty.call(snap.data(), f), false, `${uid}.${f} survived`);
      }
    }

    assert.equal((await c.db.collection('phoneNumbers').get()).size, 0, 'claims not emptied');

    const ep = await c.auth.getUser(U_EMAIL_PHONE);
    assert.deepEqual(providerIds(ep), ['password'], 'email+phone account lost its email provider or kept phone');
    assert.equal(ep.email, 'email.phone@example.test', 'email changed');
    assert.equal(ep.emailVerified, true, 'emailVerified changed');
    assert.ok(!ep.phoneNumber, 'phone number still on the email+phone account');

    const epn = await c.auth.getUser(U_EMAIL_PHONE_NODOC);
    assert.deepEqual(providerIds(epn), ['password'], 'nodoc email+phone not unlinked');
    assert.equal(epn.email, 'nodoc@example.test', 'nodoc email changed');

    const eo = await c.auth.getUser(U_EMAIL_ONLY);
    assert.deepEqual(providerIds(eo), ['password'], 'email-only account changed');
    assert.equal(eo.email, 'email.only@example.test');

    const po = await c.auth.getUser(U_PHONE_ONLY);
    assert.ok(providerIds(po).includes('phone'), 'phone-only account lost its phone provider');
    assert.equal(po.phoneNumber, PHONE_PO, 'phone-only account was unlinked');

    const all = await c.auth.listUsers(1000);
    assert.equal(all.users.length, 4, 'an Auth account was deleted');
  });

  it('a second execute reports zero work (idempotent)', async () => {
    const second = await migration.run({ execute: true, log });

    assert.equal(second.userDocsWithPhone, 0);
    assert.equal(second.claimDocs, 0);
    assert.equal(second.unlinkCandidates, 0);
    assert.equal(second.userDocsUpdated, 0);
    assert.equal(second.claimDocsDeleted, 0);
    assert.equal(second.authUnlinked, 0);
    assert.equal(second.authErrors, 0);
    assert.deepEqual(second.phoneOnlyUids, [U_PHONE_ONLY]);
  });
});
