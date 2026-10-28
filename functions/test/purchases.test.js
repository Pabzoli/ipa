// functions/test/purchases.test.js — getMyPurchases, the self-serve code history.
//
// What must stay true:
//   • only the CALLER's purchases are returned (the uid comes from the token,
//     never from the request);
//   • a fulfilled purchase reports its code and the code's real status;
//   • purchases minted before the intent carried `code` still resolve via
//     processedTransactions;
//   • a pending checkout is visible but carries no code;
//   • a code doc that no longer exists is reported as unavailable, not as a
//     redeemable string;
//   • newest first, capped at 50.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes, FakeTimestamp } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const PREMIUM = {
  productId: 'AQ_PREM_31',
  amount: 2000,
  currency: 'NGN',
  type: 'premium',
  value: 28,
  title: 'Premium Pass (28 days)',
};

async function seedIntent(txRef, uid, over = {}) {
  await db.collection('paymentIntents').doc(txRef).set({
    productId: over.productId || PREMIUM.productId,
    uid,
    email: over.email || `${uid}@t.co`,
    amount: over.amount ?? PREMIUM.amount,
    currency: over.currency || PREMIUM.currency,
    status: over.status || 'fulfilled',
    createdAt: over.createdAt || FakeTimestamp.now(),
    ...(over.code ? { code: over.code } : {}),
    ...(over.fulfilledAt ? { fulfilledAt: over.fulfilledAt } : {}),
  });
  return txRef;
}

async function seedCode(code, over = {}) {
  await db.collection('redemptionCodes').doc(code).set({
    type: over.type || PREMIUM.type,
    value: over.value ?? PREMIUM.value,
    status: over.status || 'unused',
    source: 'flutterwave_web',
    ...(over.redeemedAt ? { redeemedAt: over.redeemedAt } : {}),
    ...(over.expiresAt ? { expiresAt: over.expiresAt } : {}),
  });
}

async function listFor(uid) {
  const res = await fns.getMyPurchases.run(H.req(uid));
  return res.purchases;
}

describe('getMyPurchases', () => {
  beforeEach(async () => {
    await H.clearDb(db);
  });

  it('requires an authenticated caller', async () => {
    await H.rejectsWith(
      fns.getMyPurchases.run(H.req(null)),
      'unauthenticated',
      'Unauthenticated',
    );
  });

  it('returns only the caller\'s purchases', async () => {
    await seedIntent('AQ-PREM31-a', 'alice', { code: 'AAAA-BBBB-CCCC' });
    await seedCode('AAAA-BBBB-CCCC');
    await seedIntent('AQ-PREM31-b', 'bob', { code: 'BBBB-CCCC-DDDD' });
    await seedCode('BBBB-CCCC-DDDD');

    const alice = await listFor('alice');
    assert.equal(alice.length, 1);
    assert.equal(alice[0].txRef, 'AQ-PREM31-a');

    const bob = await listFor('bob');
    assert.equal(bob.length, 1);
    assert.equal(bob[0].txRef, 'AQ-PREM31-b');
  });

  it('reports the code, product and unused status for a fulfilled purchase', async () => {
    await seedIntent('AQ-PREM31-u', 'alice', { code: 'AAAA-BBBB-CCCC' });
    await seedCode('AAAA-BBBB-CCCC');

    const [row] = await listFor('alice');
    assert.equal(row.txRef, 'AQ-PREM31-u');
    assert.equal(row.productId, 'AQ_PREM_31');
    assert.equal(row.productTitle, PREMIUM.title);
    assert.equal(row.status, 'fulfilled');
    assert.equal(row.amount, 2000);
    assert.equal(row.currency, 'NGN');
    assert.equal(row.code, 'AAAA-BBBB-CCCC');
    assert.equal(row.codeStatus, 'unused');
    assert.equal(row.type, 'premium');
    assert.equal(row.value, 28);
    assert.ok(row.createdAt, 'createdAt is an ISO string');
    assert.equal(row.redeemedAt, null);
  });

  it('reports a redeemed code with its redemption time', async () => {
    const redeemedAt = FakeTimestamp.fromDate(new Date('2026-03-02T10:00:00Z'));
    await seedIntent('AQ-PREM31-r', 'alice', { code: 'RRRR-RRRR-RRRR' });
    await seedCode('RRRR-RRRR-RRRR', { status: 'redeemed', redeemedAt });

    const [row] = await listFor('alice');
    assert.equal(row.codeStatus, 'redeemed');
    assert.equal(row.redeemedAt, '2026-03-02T10:00:00.000Z');
  });

  it('resolves the code for a purchase minted before intents carried it', async () => {
    // Legacy shape: the intent has no `code`; processedTransactions does.
    await seedIntent('AQ-AC300-l', 'alice', {
      productId: 'AQ_AC_300', amount: 500,
    });
    await db.collection('processedTransactions').doc('flw-77').set({
      productId: 'AQ_AC_300',
      tx_ref: 'AQ-AC300-l',
      flwTxnId: '77',
      code: 'LLLL-LLLL-LLLL',
      buyerEmail: 'alice@t.co',
      status: 'fulfilled',
    });
    await seedCode('LLLL-LLLL-LLLL', { type: 'ac', value: 500 });

    const [row] = await listFor('alice');
    assert.equal(row.code, 'LLLL-LLLL-LLLL');
    assert.equal(row.codeStatus, 'unused');
    assert.equal(row.type, 'ac');
    assert.equal(row.value, 500);
  });

  it('shows a pending checkout without inventing a code', async () => {
    await seedIntent('AQ-PREM31-p', 'alice', { status: 'pending' });

    const [row] = await listFor('alice');
    assert.equal(row.status, 'pending');
    assert.equal(row.code, null);
    assert.equal(row.codeStatus, null);
  });

  it('hides an abandoned checkout older than a day', async () => {
    await seedIntent('AQ-PREM31-stale', 'alice', {
      status: 'pending',
      createdAt: FakeTimestamp.fromDate(
        new Date(Date.now() - 48 * 60 * 60 * 1000)),
    });
    await seedIntent('AQ-PREM31-fresh', 'alice', {
      status: 'pending',
      createdAt: FakeTimestamp.now(),
    });

    const rows = await listFor('alice');
    assert.deepEqual(rows.map((r) => r.txRef), ['AQ-PREM31-fresh']);
  });

  it('unlinks the account from retained purchase records on deletion', async () => {
    await H.mkUser(db, 'alice', { username: 'alice' });
    await seedIntent('AQ-PREM31-d', 'alice', { code: 'DDDD-DDDD-DDDD' });
    await seedCode('DDDD-DDDD-DDDD');
    await db.collection('processedTransactions').doc('flw-99').set({
      productId: 'AQ_PREM_31',
      tx_ref: 'AQ-PREM31-d',
      flwTxnId: '99',
      code: 'DDDD-DDDD-DDDD',
      buyerEmail: 'alice@t.co',
      status: 'fulfilled',
      uid: 'alice',
    });

    await fns.deleteAccount.run(H.req('alice'));

    const intent = await H.getDoc(db, 'paymentIntents/AQ-PREM31-d');
    assert.equal(intent.uid, null, 'the account link is removed');
    assert.equal(intent.code, 'DDDD-DDDD-DDDD', 'the accounting record is kept');

    const processed = await H.getDoc(db, 'processedTransactions/flw-99');
    assert.equal(processed.uid, null);
  });

  it('reports a missing code doc as unavailable instead of dangling', async () => {
    await seedIntent('AQ-PREM31-x', 'alice', { code: 'XXXX-XXXX-XXXX' });
    // No redemptionCodes/XXXX-XXXX-XXXX doc.

    const [row] = await listFor('alice');
    assert.equal(row.code, null);
    assert.equal(row.codeStatus, null);
    assert.equal(row.status, 'fulfilled');
  });

  it('orders newest first', async () => {
    await seedIntent('AQ-PREM31-old', 'alice', {
      createdAt: FakeTimestamp.fromDate(new Date('2026-01-01T00:00:00Z')),
    });
    await seedIntent('AQ-PREM31-new', 'alice', {
      createdAt: FakeTimestamp.fromDate(new Date('2026-03-01T00:00:00Z')),
    });
    await seedIntent('AQ-PREM31-mid', 'alice', {
      createdAt: FakeTimestamp.fromDate(new Date('2026-02-01T00:00:00Z')),
    });

    const rows = await listFor('alice');
    assert.deepEqual(
      rows.map((r) => r.txRef),
      ['AQ-PREM31-new', 'AQ-PREM31-mid', 'AQ-PREM31-old'],
    );
  });

  it('caps the list at the 50 most recent', async () => {
    const base = Date.parse('2026-01-01T00:00:00Z');
    for (let i = 0; i < 51; i++) {
      await seedIntent(`AQ-AC300-${String(i).padStart(2, '0')}`, 'alice', {
        productId: 'AQ_AC_300',
        amount: 500,
        createdAt: FakeTimestamp.fromMillis(base + i * 60000),
      });
    }

    const rows = await listFor('alice');
    assert.equal(rows.length, 50);
    // The oldest (i=0) is the one dropped; the newest is first.
    assert.equal(rows[0].txRef, 'AQ-AC300-50');
    assert.equal(rows.some((r) => r.txRef === 'AQ-AC300-00'), false);
  });
});
