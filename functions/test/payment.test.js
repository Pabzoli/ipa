// functions/test/payment.test.js — the whole website purchase pipeline with the
// REAL handlers, a fake Firestore and a stubbed Flutterwave API:
//
//   requestPaymentLink → paymentIntents
//   flutterwaveWebhook → redemptionCodes + processedTransactions (idempotent)
//   getPurchasedCode   → code delivery + self-heal mint
//   redeemCode         → in-app grant (premium / ac / leaderboard_entry)
//
// No emulator, no network, no real secrets.
'use strict';
process.env.NODE_ENV = 'test';
const { test, describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const Module = require('module');
const { createHmac, randomUUID } = require('node:crypto');

const { installFakes } = require('./_fakes');
const ctx = installFakes();
const db = ctx.db;
const H = require('./helpers');

// ── Secrets (index.js reads them through defineSecret().value()) ───────────
const SECRETS = {
  FLW_SECRET_KEY: 'FLWSECK_TEST-key',
  FLW_SECRET_HASH: 'whsec-test-hash',
  RESET_SECRET: 'reset-secret',
};
function intercept(requestPath, exportsObj) {
  const resolved = Module.createRequire(path.join(__dirname, '..', 'index.js')).resolve(requestPath);
  require.cache[resolved] = { id: resolved, filename: resolved, loaded: true, exports: exportsObj };
}
// Replace the value()-throws fake with usable test secrets.
intercept('firebase-functions/params', {
  defineSecret: (name) => ({ value: () => SECRETS[name] }),
});

const fns = require('../index.js');

const FLW_PAYMENTS = 'https://api.flutterwave.com/v3/payments';
const FLW_TRANSACTIONS = 'https://api.flutterwave.com/v3/transactions';

// ── Stubbed Flutterwave HTTP surface ────────────────────────────────────────
let flwCheckoutCalls = [];
let verifyHandler = async () => [];
function flwJson(obj, status = 200) {
  return { ok: status >= 200 && status < 300, status, json: async () => obj };
}
globalThis.fetch = async (url, opts = {}) => {
  if (url === FLW_PAYMENTS) {
    flwCheckoutCalls.push({ url, body: JSON.parse(opts.body || '{}') });
    return flwJson({ status: 'success', data: { link: 'https://checkout.flutterwave.com/v3/hosted/pay/testlink' } });
  }
  if (String(url).startsWith(FLW_TRANSACTIONS)) {
    return flwJson({ status: 'success', data: await verifyHandler(String(url)) });
  }
  throw new Error('unexpected fetch ' + url);
};

// ── Express-shaped req/res ──────────────────────────────────────────────────
function mkReqRes({ method = 'POST', body, headers = {}, ip } = {}) {
  const out = { status: 0, headers: {}, body: undefined };
  const res = {
    status(c) { out.status = c; return res; },
    set(h) { out.headers = { ...out.headers, ...h }; return res; },
    json(b) { out.body = b; return res; },
    send() { out.sent = true; return res; },
  };
  return { req: { method, headers, body, ip }, res, out };
}

function runRequest(fn, init) {
  const { req, res, out } = mkReqRes(init);
  return fn.run(req, res).then(() => out);
}

// ── Flutterwave webhook helpers ─────────────────────────────────────────────
function webhookPayload({
  flwTxnId, txRef, amount, currency = 'NGN', status = 'successful',
  eventType = 'CARD_TRANSACTION', email = 'buyer@example.com',
}) {
  // v3 FLAT shape for this account (no data wrapper), per the live logs cited
  // in the handler comments.
  return {
    id: flwTxnId, txRef, amount, currency, status,
    'event.type': eventType,
    customer: { email },
  };
}

function signedWebhook(payload, { signature } = {}) {
  const raw = JSON.stringify(payload);
  const headers = { 'content-type': 'application/json' };
  headers['flutterwave-signature'] = signature !== undefined
    ? signature
    : createHmac('sha256', SECRETS.FLW_SECRET_HASH).update(raw).digest('base64');
  return { method: 'POST', body: payload, headers, rawBody: raw };
}

// ── Pipeline helpers ───────────────────────────────────────────────────────
// Server-side amount table (mirrors FLUTTERWAVE_PRODUCTS in index.js).
const PRODUCTS = {
  AQ_AC_300:   { txToken: 'AC300',  type: 'ac',                 value: 300,   amount: 500,  currency: 'NGN' },
  AQ_AC_1100:  { txToken: 'AC1100', type: 'ac',                 value: 990,   amount: 1500, currency: 'NGN' },
  AQ_AC_3600:  { txToken: 'AC3600', type: 'ac',                 value: 2880,  amount: 4000, currency: 'NGN' },
  AQ_PREM_31:  { txToken: 'PREM31', type: 'premium',            value: 28,    amount: 2000, currency: 'NGN' },
  AQ_LB_WEEK:  { txToken: 'LBWK',   type: 'leaderboard_entry',  value: 0,     amount: 500,  currency: 'NGN' },
};

let ipSeq = 0;
function nextIp() { return `10.9.0.${++ipSeq}`; }

function newTxRef(productId) {
  const p = PRODUCTS[productId];
  if (!p) throw new Error('unknown product ' + productId);
  return `AQ-${p.txToken}-${randomUUID()}`;
}

async function createIntent(txRef, { productId, email, status = 'pending' }) {
  const p = PRODUCTS[productId];
  await db.collection('paymentIntents').doc(txRef).set({
    productId,
    email: String(email).trim().toLowerCase(),
    amount: p.amount,
    currency: p.currency,
    status,
    createdAt: Date.now(),
  });
}

async function deliverWebhook(txRef, over = {}) {
  const productId = over.productId
    || Object.keys(PRODUCTS).find((k) => txRef.startsWith('AQ-' + PRODUCTS[k].txToken + '-'));
  const p = PRODUCTS[productId];
  const mode = over.mode ?? 'v4';
  const payload = webhookPayload({
    flwTxnId: over.flwTxnId ?? 400000 + Math.floor(Math.random() * 99999),
    txRef,
    amount: p.amount,
    currency: p.currency,
    status: over.status ?? 'successful',
    eventType: over.eventType ?? 'CARD_TRANSACTION',
    email: over.email ?? 'buyer@example.com',
  });
  const raw = JSON.stringify(payload);
  const headers = { 'content-type': 'application/json' };
  if (mode === 'v4') {
    headers['flutterwave-signature'] = createHmac('sha256', SECRETS.FLW_SECRET_HASH)
      .update(raw).digest('base64');
  } else {
    headers['verif-hash'] = SECRETS.FLW_SECRET_HASH;
  }
  const { req, res, out } = mkReqRes({ method: 'POST', body: payload, headers });
  req.rawBody = raw;
  await fns.flutterwaveWebhook.run(req, res);
  return out;
}

async function fetchCode(txRef, email, { ip } = {}) {
  return runRequest(fns.getPurchasedCode, {
    body: { tx_ref: txRef, email },
    headers: { 'x-forwarded-for': ip || nextIp() },
  });
}

function allCodes() {
  return [...db.store.docs.entries()]
    .filter(([p]) => p.startsWith('redemptionCodes/'))
    .map(([p, d]) => ({ code: p.split('/')[1], ...d }));
}

function processedDocs() {
  return [...db.store.docs.entries()]
    .filter(([p]) => p.startsWith('processedTransactions/'))
    .map(([, d]) => d);
}

const DAY_MS = 24 * 60 * 60 * 1000;
const CODE_RE = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$/;

// The fake Firestore keeps FieldValue.increment() sentinels raw inside
// merge-set writes; unwrap { n } so assertions read the accumulated value.
function incValue(v) {
  return (v && typeof v === 'object' && 'n' in v) ? v.n : v;
}

describe('website purchase pipeline', () => {
  beforeEach(() => {
    H.clearDb(db);
    flwCheckoutCalls = [];
    verifyHandler = async () => [];
    ipSeq = 0;
  });

  // ── requestPaymentLink ───────────────────────────────────────────────────
  it('creates the checkout link, records the intent and sends the SERVER price', async () => {
    const out = await runRequest(fns.requestPaymentLink, {
      body: { productId: 'AQ_PREM_31', email: 'Buyer@Example.com', amount: 1, currency: 'USD' },
      headers: { 'x-forwarded-for': nextIp(), origin: 'https://anime-quiz-1ab1b.web.app' },
    });
    assert.equal(out.status, 200);
    assert.match(out.body.link, /^https:\/\/checkout\.flutterwave\.com/);
    assert.match(out.body.tx_ref, /^AQ-PREM31-[0-9a-f-]{36}$/);

    // The buyer's tampered price/currency must never reach Flutterwave.
    const sent = flwCheckoutCalls[0].body;
    assert.equal(sent.amount, '2000');
    assert.equal(sent.currency, 'NGN');
    assert.equal(sent.tx_ref, out.body.tx_ref);
    assert.equal(sent.meta.product_id, 'AQ_PREM_31');
    assert.ok(sent.redirect_url.includes('success.html?email=buyer%40example.com'), sent.redirect_url);

    const intent = await H.getDoc(db, `paymentIntents/${out.body.tx_ref}`);
    assert.equal(intent.status, 'pending');
    assert.equal(intent.productId, 'AQ_PREM_31');
    assert.equal(intent.email, 'buyer@example.com');
    assert.equal(intent.amount, 2000);
  });

  it('rejects unknown products, invalid emails, GET, and foreign origins', async () => {
    const ip = nextIp();
    const unknown = await runRequest(fns.requestPaymentLink, {
      body: { productId: 'AQ_FREE_MONEY', email: 'buyer@example.com' },
      headers: { 'x-forwarded-for': ip },
    });
    assert.equal(unknown.status, 400);

    const badEmail = await runRequest(fns.requestPaymentLink, {
      body: { productId: 'AQ_PREM_31', email: 'not-an-email' },
      headers: { 'x-forwarded-for': ip },
    });
    assert.equal(badEmail.status, 400);

    const get = await runRequest(fns.requestPaymentLink, {
      method: 'GET', body: { productId: 'AQ_PREM_31', email: 'buyer@example.com' },
      headers: { 'x-forwarded-for': ip },
    });
    assert.equal(get.status, 405);

    const foreign = await runRequest(fns.requestPaymentLink, {
      body: { productId: 'AQ_PREM_31', email: 'buyer@example.com' },
      headers: { 'x-forwarded-for': ip, origin: 'https://evil.example.com' },
    });
    assert.equal(foreign.status, 403);
    assert.equal(flwCheckoutCalls.length, 0);
  });

  // ── flutterwaveWebhook ───────────────────────────────────────────────────
  it('mints a code on a v4-HMAC signed successful charge and fulfills the intent', async () => {
    const txRef = newTxRef('AQ_PREM_31');
    await createIntent(txRef, { productId: 'AQ_PREM_31', email: 'buyer@example.com' });

    const out = await deliverWebhook(txRef, { flwTxnId: 99001 });
    assert.equal(out.status, 200);
    assert.equal(out.body.minted, true);
    assert.match(out.body.code, CODE_RE);

    const codes = allCodes();
    assert.equal(codes.length, 1);
    const doc = codes[0];
    assert.equal(doc.type, 'premium');
    assert.equal(doc.value, 28);
    assert.equal(doc.status, 'unused');
    assert.equal(doc.source, 'flutterwave_web');
    assert.equal(doc.buyerEmail, 'buyer@example.com');
    assert.equal(doc.paidAmount, 2000);
    // The webhook stringifies Flutterwave's id before keying the audit doc.
    assert.equal(doc.flwTxnId, '99001');
    assert.equal(doc.productId, 'AQ_PREM_31');

    // Audit + idempotency records.
    assert.deepEqual(processedDocs().map((d) => d.code), [doc.code]);
    assert.equal(processedDocs()[0].buyerEmail, 'buyer@example.com');
    assert.equal((await H.getDoc(db, `paymentIntents/${txRef}`)).status, 'fulfilled');
  });

  it('also accepts the v3 verif-hash header', async () => {
    const txRef = newTxRef('AQ_AC_300');
    await createIntent(txRef, { productId: 'AQ_AC_300', email: 'buyer@example.com' });
    const out = await deliverWebhook(txRef, { mode: 'v3' });
    assert.equal(out.status, 200);
    assert.equal(out.body.minted, true);
    assert.equal(allCodes()[0].type, 'ac');
    assert.equal(allCodes()[0].value, 300);
  });

  it('rejects a bad signature without minting', async () => {
    const txRef = newTxRef('AQ_PREM_31');
    await createIntent(txRef, { productId: 'AQ_PREM_31', email: 'buyer@example.com' });
    const payload = webhookPayload({ flwTxnId: 9001, txRef, amount: 2000, currency: 'NGN' });

    const forged = mkReqRes({
      method: 'POST', body: payload,
      headers: { 'flutterwave-signature': createHmac('sha256', 'wrong-key').update(JSON.stringify(payload)).digest('base64') },
    });
    forged.req.rawBody = JSON.stringify(payload);
    await fns.flutterwaveWebhook.run(forged.req, forged.res);
    assert.equal(forged.out.status, 401);

    const unsigned = mkReqRes({ method: 'POST', body: payload, headers: {} });
    unsigned.req.rawBody = JSON.stringify(payload);
    await fns.flutterwaveWebhook.run(unsigned.req, unsigned.res);
    assert.equal(unsigned.out.status, 401);

    // v3 hash header must equal the configured secret exactly.
    const wrongHash = mkReqRes({ method: 'POST', body: payload, headers: { 'verif-hash': 'not-the-hash' } });
    wrongHash.req.rawBody = JSON.stringify(payload);
    await fns.flutterwaveWebhook.run(wrongHash.req, wrongHash.res);
    assert.equal(wrongHash.out.status, 401);

    assert.equal(allCodes().length, 0);
    assert.equal(processedDocs().length, 0);
  });

  it('ignores non-success statuses and non-charge events', async () => {
    const txRef = newTxRef('AQ_PREM_31');
    await createIntent(txRef, { productId: 'AQ_PREM_31', email: 'buyer@example.com' });
    const failed = await deliverWebhook(txRef, { status: 'failed', flwTxnId: 1 });
    assert.equal(failed.status, 200);
    assert.equal(failed.body.ignored, 'failed');

    const pending = await deliverWebhook(txRef, { status: 'pending', eventType: 'charge.completed', flwTxnId: 2 });
    assert.equal(pending.body.ignored, 'pending');

    const otherEvent = await deliverWebhook(txRef, { eventType: 'transfer.completed', flwTxnId: 3 });
    assert.equal(otherEvent.body.ignored, 'transfer.completed');
    assert.equal(allCodes().length, 0);
  });

  it('refuses price-tampered charges and unknown product references', async () => {
    const txRef = newTxRef('AQ_PREM_31');
    await createIntent(txRef, { productId: 'AQ_PREM_31', email: 'buyer@example.com' });
    const tamper = await runRequest(fns.flutterwaveWebhook, signedWebhook(webhookPayload({
      flwTxnId: 700, txRef, amount: 100, currency: 'NGN',   // paid ₦100 for a ₦2,000 item
    })));
    assert.equal(tamper.status, 400);
    assert.match(tamper.body.error, /mismatch/);

    const unknown = await runRequest(fns.flutterwaveWebhook, signedWebhook(webhookPayload({
      flwTxnId: 701, txRef: 'AQ-NOPE-' + randomUUID(), amount: 2000, currency: 'NGN',
    })));
    assert.equal(unknown.status, 400);
    assert.match(unknown.body.error, /Unknown product/);
    assert.equal(allCodes().length, 0);
  });

  it('is idempotent: a retried delivery never mints a second code', async () => {
    const txRef = newTxRef('AQ_AC_3600');
    await createIntent(txRef, { productId: 'AQ_AC_3600', email: 'buyer@example.com' });
    const first = await deliverWebhook(txRef, { flwTxnId: 888 });
    assert.equal(first.body.minted, true);
    const code = first.body.code;

    const second = await deliverWebhook(txRef, { flwTxnId: 888 });
    assert.equal(second.status, 200);
    assert.equal(second.body.minted, false);
    assert.equal(second.body.code, code);
    assert.equal(allCodes().length, 1);
    assert.equal(processedDocs().length, 1);
  });

  it('falls back to the Flutterwave customer email when the intent is missing', async () => {
    // requestPaymentLink's Firestore write failed/raced — a CONFIRMED payment
    // must still deliver a code (see _mintCharge).
    const txRef = newTxRef('AQ_AC_300');
    const out = await deliverWebhook(txRef, { flwTxnId: 512, email: 'flw-buyer@example.com' });
    assert.equal(out.body.minted, true);
    assert.equal(allCodes()[0].buyerEmail, 'flw-buyer@example.com');
  });

  it('refuses to mint when no trusted buyer email exists at all', async () => {
    const txRef = newTxRef('AQ_AC_300');
    const out = await deliverWebhook(txRef, { flwTxnId: 513, email: '' });
    assert.equal(out.status, 200);
    assert.equal(out.body.minted, false);
    assert.match(out.body.rejected, /no verified buyer email/);
    assert.equal(allCodes().length, 0);
  });

  // ── getPurchasedCode ─────────────────────────────────────────────────────
  it('delivers the code to the buyer email on the fast path', async () => {
    const txRef = newTxRef('AQ_PREM_31');
    await createIntent(txRef, { productId: 'AQ_PREM_31', email: 'buyer@example.com' });
    const minted = await deliverWebhook(txRef, { flwTxnId: 600 });

    const out = await fetchCode(txRef, 'Buyer@Example.com');
    assert.equal(out.status, 200);
    assert.equal(out.body.code, minted.body.code);
    assert.equal(out.body.type, 'premium');
    assert.equal(out.body.value, 28);
  });

  it('never leaks a code to a different email', async () => {
    const txRef = newTxRef('AQ_PREM_31');
    await createIntent(txRef, { productId: 'AQ_PREM_31', email: 'buyer@example.com' });
    await deliverWebhook(txRef, { flwTxnId: 601 });

    const out = await fetchCode(txRef, 'someone-else@example.com');
    assert.equal(out.status, 403);
    assert.equal(out.body.code, undefined);
  });

  it('self-heals a payment whose webhook never arrived', async () => {
    const txRef = newTxRef('AQ_AC_1100');
    await createIntent(txRef, { productId: 'AQ_AC_1100', email: 'buyer@example.com' });
    // Flutterwave says this reference completed successfully...
    verifyHandler = async () => [{
      id: 777, tx_ref: txRef, amount: 1500, currency: 'NGN', status: 'successful',
      customer: { email: 'buyer@example.com' },
    }];

    const out = await fetchCode(txRef, 'buyer@example.com');
    assert.equal(out.status, 200);
    assert.match(out.body.code, CODE_RE);
    assert.equal(out.body.type, 'ac');
    assert.equal(out.body.value, 990);
    // And it is idempotent with the webhook path.
    const again = await fetchCode(txRef, 'buyer@example.com');
    assert.equal(again.body.code, out.body.code);
    assert.equal(allCodes().length, 1);
  });

  it('self-heal refuses an email that matches neither the intent nor Flutterwave', async () => {
    const txRef = newTxRef('AQ_AC_1100');
    await createIntent(txRef, { productId: 'AQ_AC_1100', email: 'buyer@example.com' });
    verifyHandler = async () => [{
      id: 778, tx_ref: txRef, amount: 1500, currency: 'NGN', status: 'successful',
      customer: { email: 'buyer@example.com' },
    }];
    const out = await fetchCode(txRef, 'attacker@example.com');
    assert.equal(out.status, 403);
    assert.equal(allCodes().length, 0);
  });

  it('self-heal reports failed as 402 and still-pending as 404', async () => {
    const failedRef = newTxRef('AQ_AC_300');
    await createIntent(failedRef, { productId: 'AQ_AC_300', email: 'buyer@example.com' });
    verifyHandler = async () => [{ id: 1, amount: 500, currency: 'NGN', status: 'failed' }];
    const failed = await fetchCode(failedRef, 'buyer@example.com');
    assert.equal(failed.status, 402);

    const pendingRef = newTxRef('AQ_AC_300');
    await createIntent(pendingRef, { productId: 'AQ_AC_300', email: 'buyer@example.com' });
    verifyHandler = async () => [{ id: 2, amount: 500, currency: 'NGN', status: 'pending' }];
    const pending = await fetchCode(pendingRef, 'buyer@example.com');
    assert.equal(pending.status, 404);
    assert.equal(allCodes().length, 0);
  });

  it('validates tx_ref/email and answers CORS preflight', async () => {
    const noRef = await fetchCode('', 'buyer@example.com');
    assert.equal(noRef.status, 400);

    const options = await runRequest(fns.getPurchasedCode, {
      method: 'OPTIONS', headers: { origin: 'https://anime-quiz-1ab1b.web.app' },
    });
    assert.equal(options.status, 204);
    assert.equal(options.headers['Access-Control-Allow-Origin'], 'https://anime-quiz-1ab1b.web.app');

    const foreign = await runRequest(fns.getPurchasedCode, {
      body: { tx_ref: 'AQ-PREM31-x', email: 'buyer@example.com' },
      headers: { origin: 'https://evil.example.com' },
    });
    assert.equal(foreign.status, 403);
  });

  it('rejects an underpaid self-heal charge', async () => {
    const txRef = newTxRef('AQ_PREM_31');
    await createIntent(txRef, { productId: 'AQ_PREM_31', email: 'buyer@example.com' });
    verifyHandler = async () => [{
      id: 779, tx_ref: txRef, amount: 100, currency: 'NGN', status: 'successful',
      customer: { email: 'buyer@example.com' },
    }];
    const out = await fetchCode(txRef, 'buyer@example.com');
    assert.equal(out.status, 400);
    assert.equal(allCodes().length, 0);
  });
});

describe('in-app redemption (redeemCode)', () => {
  beforeEach(async () => {
    H.clearDb(db);
    await H.mkUser(db, 'buyer');
    flwCheckoutCalls = [];
    verifyHandler = async () => [];
    ipSeq = 0;
  });

  // Full path: website checkout → webhook → code delivery → in-app grant.
  async function buy(productId, { email = 'buyer@example.com', flwTxnId } = {}) {
    const txRef = newTxRef(productId);
    await createIntent(txRef, { productId, email });
    const minted = await deliverWebhook(txRef, { flwTxnId });
    return (await fetchCode(txRef, email)).body.code;
  }

  it('activates Premium for 28 days and writes the receipt', async () => {
    const code = await buy('AQ_PREM_31');
    const before = Date.now();
    const result = await fns.redeemCode.run(H.req('buyer', { code, platform: 'web' }));
    assert.deepEqual(result, { success: true, type: 'premium', value: 28 });

    const user = await H.getDoc(db, 'users/buyer');
    assert.equal(user.premiumActive, true);

    const receipts = await db.collection('users').doc('buyer')
      .collection('premiumReceipts').get();
    assert.equal(receipts.size, 1);
    const receipt = receipts.docs[0].data();
    assert.equal(receipt.uid, 'buyer');
    const days = (receipt.expiresAt.toMillis() - before) / DAY_MS;
    assert.ok(days > 27.9 && days <= 28.001, `expiresAt off: ${days} days`);

    const codeDoc = await H.getDoc(db, `redemptionCodes/${code}`);
    assert.equal(codeDoc.status, 'redeemed');
    assert.equal(codeDoc.redeemedBy, 'buyer');
    assert.ok(codeDoc.redeemedAt);
  });

  it('cannot be redeemed twice', async () => {
    const code = await buy('AQ_PREM_31');
    await fns.redeemCode.run(H.req('buyer', { code, platform: 'web' }));
    await H.rejectsWith(
      fns.redeemCode.run(H.req('buyer', { code, platform: 'web' })),
      'invalid-argument', 'Invalid or expired code');
    // And a second user cannot steal it either.
    await H.mkUser(db, 'thief');
    await H.rejectsWith(
      fns.redeemCode.run(H.req('thief', { code, platform: 'web' })),
      'invalid-argument', 'Invalid or expired code');
  });

  it('credits Anime Coins with a transaction log entry', async () => {
    const code = await buy('AQ_AC_1100');
    const result = await fns.redeemCode.run(H.req('buyer', { code, platform: 'web' }));
    assert.deepEqual(result, { success: true, type: 'ac', value: 990, newBalance: 1990 });

    const user = await H.getDoc(db, 'users/buyer');
    assert.equal(user.animeCoins, 1990);

    const logs = await db.collection('users').doc('buyer').collection('coinTransactions').get();
    assert.equal(logs.size, 1);
    assert.equal(logs.docs[0].data().type, 'earn_redemption');
    assert.equal(logs.docs[0].data().delta, 990);
    assert.equal(logs.docs[0].data().balanceAfter, 1990);
  });

  it('activates the weekly leaderboard entry and accrues pool revenue once', async () => {
    const weekId = H.thisWeekId();
    const code = await buy('AQ_LB_WEEK');
    const result = await fns.redeemCode.run(H.req('buyer', { code, platform: 'web' }));
    assert.equal(result.weekId, weekId);

    const user = await H.getDoc(db, 'users/buyer');
    assert.equal(user.leaderboardEntryWeekId, weekId);

    const pool = await H.getDoc(db, `prize_pool/${weekId}`);
    assert.equal(incValue(pool.entryCodeRevenue), 500);

    const receipts = await db.collection('users').doc('buyer')
      .collection('leaderboardReceipts').get();
    assert.equal(receipts.size, 1);
    assert.equal(receipts.docs[0].data().buyerEmail, 'buyer@example.com');

    // A second paid code for the same week is refused, and no double revenue.
    const second = await buy('AQ_LB_WEEK');
    await H.rejectsWith(
      fns.redeemCode.run(H.req('buyer', { code: second, platform: 'web' })),
      'invalid-argument', 'Invalid or expired code');
    assert.equal(incValue((await H.getDoc(db, `prize_pool/${weekId}`)).entryCodeRevenue), 500);
  });

  it('normalises lowercase / padded user input', async () => {
    const code = await buy('AQ_AC_300');
    const result = await fns.redeemCode.run(
      H.req('buyer', { code: `  ${code.toLowerCase()}  `, platform: 'web' }));
    assert.equal(result.value, 300);
  });

  it('rejects an unknown code and unauthenticated callers', async () => {
    await H.rejectsWith(
      fns.redeemCode.run(H.req('buyer', { code: 'ZZZZ-ZZZZ-ZZZZ', platform: 'web' })),
      'invalid-argument', 'Invalid or expired code');
    await H.rejectsWith(fns.redeemCode.run(H.req(null, { code: 'AAAA-BBBB-CCCC' })),
      'unauthenticated');
  });

  it('locks redemption after five failed attempts and never explains why', async () => {
    for (let i = 0; i < 5; i++) {
      await H.rejectsWith(
        fns.redeemCode.run(H.req('buyer', {
          code: `ZZZZ-ZZZZ-ZZZ${i}`, platform: 'web',
        })),
        'invalid-argument', 'Invalid or expired code');
    }
    // Locked out: even a well-formed new attempt is refused before any lookup.
    await H.rejectsWith(
      fns.redeemCode.run(H.req('buyer', {
        code: 'ABCD-EFGH-JKLM', platform: 'web',
      })),
      'resource-exhausted');
    const attempts = await H.getDoc(db, 'redeemAttempts/buyer');
    assert.equal(attempts.failCount, 5);
    assert.ok(attempts.lockedUntil);
  });

  it('refuses an outdated Android client but lets web through', async () => {
    // Arm the forced-update gate.
    await H.setDoc(db, 'app_config/android', { minBuild: 5, latestBuild: 7 });
    const code = await buy('AQ_PREM_31');

    await H.rejectsWith(
      fns.redeemCode.run(H.req('buyer', { code, platform: 'android', appBuild: 3 })),
      'failed-precondition', 'App update required');

    // The code was NOT consumed by the rejected attempt.
    const codeDoc = await H.getDoc(db, `redemptionCodes/${code}`);
    assert.equal(codeDoc.status, 'unused');

    const result = await fns.redeemCode.run(H.req('buyer', { code, platform: 'web' }));
    assert.equal(result.success, true);
  });

  it('mints codes in the documented XXXX-XXXX-XXXX unambiguous-alphabet format', async () => {
    const seen = new Set();
    for (let i = 0; i < 25; i++) {
      const code = await buy('AQ_AC_300');
      assert.match(code, CODE_RE, `bad code format: ${code}`);
      assert.ok(!seen.has(code), 'collision: duplicate code minted');
      seen.add(code);
    }
  });
});
