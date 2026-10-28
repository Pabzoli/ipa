// functions/test/success_page.test.js — runs the REAL <script> from
// public/success.html in a stubbed DOM and checks the buyer-facing outcome of
// every redirect shape the Flutterwave hosted checkout can hand back:
//
//   A. ?email=…&status=successful&tx_ref=…   (params appended with &)
//   B. ?email=…?status=successful&tx_ref=…   (appended with a 2nd ?)
//   C. ?status=successful&tx_ref=…           (original query replaced)
//   plus failed / cancelled / missing-reference, the late-webhook retry, and
//   the auth gate (signed out → sign-in card, expired session → sign-in card).
//
// The page now retrieves codes by ACCOUNT, not by a typed email: the stub
// ShopAuth below stands in for the Firebase Auth compat SDK and the assertions
// check that every fetch carries a bearer token and no email in the body.
'use strict';
const { test, describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const HTML = fs.readFileSync(
  path.join(__dirname, '..', '..', 'public', 'success.html'), 'utf8');

// `HTML.match(/<script>([\s\S]*?)<\/script>/)` finds the first PLAIN script tag.
// The SDK tags are `<script src=...>`, so they are skipped and this is still the
// page's own inline script.
const SCRIPT = HTML.match(/<script>([\s\S]*?)<\/script>/)[1];

// ── Stub DOM ────────────────────────────────────────────────────────────────
function makeEl(id) {
  const listeners = {};
  const classes = new Set();
  const el = {
    id,
    textContent: '',
    innerHTML: '',
    value: '',
    disabled: false,
    style: {},
    dataset: {},
    children: [],
    classList: {
      add: (...c) => c.forEach((x) => classes.add(x)),
      remove: (...c) => c.forEach((x) => classes.delete(x)),
      contains: (c) => classes.has(c),
      toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)),
    },
    addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
    appendChild: (child) => el.children.push(child),
    click: () => (listeners.click || []).forEach((fn) => fn({ target: el })),
    input: () => (listeners.input || []).forEach((fn) => fn({ target: el })),
    keydown: (key) => (listeners.keydown || []).forEach((fn) => fn({ key, preventDefault() {} })),
    focus: () => {},
    scrollIntoView: () => {},
    // No querySelector: addBackLink() must cope with a minimal DOM.
  };
  return el;
}

const EMAIL = 'buyer@example.com';
const TXREF = 'AQ-PREM31-123e4567-e89b-12d3-a456-426614174000';

// ── Stub ShopAuth (stands in for public/assets/shop-auth.js) ───────────────
function makeAuth(initialUser) {
  let current = initialUser;
  const listeners = [];
  const emit = () => listeners.forEach((fn) => fn(current));
  return {
    user: () => current,
    isSignedIn: () => !!current,
    getIdToken: async () => (current ? `token-${current.uid}` : null),
    signIn: async (email) => {
      current = { uid: 'buyer', email };
      emit();
    },
    signOut: async () => { current = null; emit(); },
    sendReset: async () => {},
    errorMessage: () => 'Email or password is incorrect.',
    onChange: (fn) => { listeners.push(fn); fn(current); },
  };
}

const BUYER = { uid: 'buyer', email: EMAIL };

function loadPage(search, { fetchImpl, user = BUYER } = {}) {
  const els = {};
  const ids = [
    'title', 'sub', 'pending', 'codeSection', 'code', 'copyBtn',
    'copyLabel', 'copyIcon', 'authSection', 'email', 'password',
    'signInBtn', 'resetBtn', 'recoverSection', 'signedInAs', 'getBtn',
    'signOutBtn', 'msg',
  ];
  for (const id of ids) els[id] = makeEl(id);
  // Mirror the classes the real markup ships with, so "is it hidden?" means
  // what it means in a browser.
  for (const id of ['pending', 'codeSection', 'authSection', 'recoverSection']) {
    els[id].classList.add('hidden');
  }

  const fetchCalls = [];
  // Collapse the 3s poll wait to one immediate, then drain the async chain.
  const settle = async (turns = 40) => {
    for (let i = 0; i < turns; i++) await new Promise((r) => setImmediate(r));
  };

  const auth = makeAuth(user);

  const sandbox = {
    console,
    URLSearchParams,
    setTimeout: (fn) => setImmediate(fn),
    fetch: async (url, opts) => {
      fetchCalls.push({
        url,
        body: JSON.parse(opts.body),
        authorization: opts.headers && opts.headers.Authorization,
      });
      return fetchImpl(fetchCalls.length);
    },
    navigator: { clipboard: { writeText: async () => {} } },
  };
  sandbox.window = { location: { search }, ShopAuth: auth };
  sandbox.document = {
    getElementById: (id) => els[id],
    createElement: () => makeEl('created'),
    addEventListener: () => {},
  };
  vm.createContext(sandbox);
  vm.runInContext(SCRIPT, sandbox);
  return { els, fetchCalls, settle, auth };
}

function codeResponse() {
  return { ok: true, status: 200, json: async () => ({ success: true, code: 'ABCD-EFGH-IJKL' }) };
}
function errorResponse(status, error) {
  return { ok: false, status, json: async () => ({ error }) };
}
const HIDDEN = 'hidden';

describe('public/success.html buyer delivery', () => {
  it('A: appended-with-& redirect auto-delivers to the signed-in account', async () => {
    const page = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}&transaction_id=99`,
      { fetchImpl: () => codeResponse() });
    await page.settle();

    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL');
    assert.equal(page.els.codeSection.classList.contains(HIDDEN), false);
    assert.equal(page.els.pending.classList.contains(HIDDEN), true);

    // The body carries only the reference; identity is the bearer token.
    assert.deepEqual(page.fetchCalls[0].body, { tx_ref: TXREF });
    assert.equal(page.fetchCalls[0].authorization, 'Bearer token-buyer');
  });

  it('B: a second "?" merge must still reach the buyer', async () => {
    const page = loadPage(`?email=${EMAIL}?status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => codeResponse() });
    await page.settle();
    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL',
      'buyer did not get their code on the second-? merge shape');
  });

  it('C: a replaced query still delivers (the token, not the email param, is the identity)', async () => {
    const page = loadPage(`?status=successful&tx_ref=${TXREF}`, { fetchImpl: () => codeResponse() });
    await page.settle();
    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL');
    assert.equal(page.els.authSection.classList.contains(HIDDEN), true);
  });

  it('a signed-out buyer is asked to sign in instead of typing an email', async () => {
    const page = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => codeResponse(), user: null });
    await page.settle();

    assert.equal(page.fetchCalls.length, 0, 'must not call the server without a session');
    assert.equal(page.els.authSection.classList.contains(HIDDEN), false);
    assert.equal(page.els.recoverSection.classList.contains(HIDDEN), true);
    assert.equal(page.els.email.value, EMAIL, 'checkout email is prefilled for convenience');

    // Signing in resumes the fetch with a token.
    page.els.password.value = 'secret';
    page.els.signInBtn.click();
    await page.settle();
    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL');
    assert.equal(page.fetchCalls[0].authorization, 'Bearer token-buyer');
  });

  it('retries while the webhook is in flight, then falls back to the retry button', async () => {
    let n = 0;
    const page = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => (++n < 3 ? errorResponse(404, 'not yet') : codeResponse()) });
    await page.settle();
    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL');
    assert.equal(page.fetchCalls.length, 3);

    // Now the code never arrives: after the retry budget the retry panel opens.
    const dead = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => errorResponse(404, 'not yet') });
    await dead.settle();
    assert.equal(dead.els.recoverSection.classList.contains(HIDDEN), false);
    assert.equal(dead.els.pending.classList.contains(HIDDEN), true);
    assert.match(dead.els.msg.textContent, /longer than expected/);

    // And pressing it once more still uses the account, not a typed email.
    dead.els.getBtn.click();
    await dead.settle();
    assert.equal(dead.fetchCalls[dead.fetchCalls.length - 1].authorization, 'Bearer token-buyer');
  });

  it('a terminal 402 stops at once instead of retrying the full budget', async () => {
    // Case-B shape with a payment that never succeeded: the status param was
    // lost, so the page must learn "no code" from the server and stop fast.
    const page = loadPage(`?email=${EMAIL}?status=failed&tx_ref=${TXREF}`,
      { fetchImpl: () => errorResponse(402, 'This payment was not successful - no code was issued') });
    await page.settle();
    assert.equal(page.fetchCalls.length, 1, 'must not burn the retry budget on a terminal result');
    assert.match(page.els.title.textContent, /not completed/i);
    assert.match(page.els.sub.textContent, /not successful/i);
    assert.equal(page.els.pending.classList.contains(HIDDEN), true);
    assert.equal(page.els.recoverSection.classList.contains(HIDDEN), false);
  });

  it('an expired session (401) drops back to the sign-in card', async () => {
    const page = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => errorResponse(401, 'Sign in to see your purchase') });
    await page.settle();
    assert.equal(page.fetchCalls.length, 1, 'a 401 is terminal, not retryable');
    assert.equal(page.els.authSection.classList.contains(HIDDEN), false);
    assert.equal(page.els.codeSection.classList.contains(HIDDEN), true);
    assert.equal(page.auth.isSignedIn(), false);
    assert.match(page.els.msg.textContent, /expired/i);
  });

  it('a code bound to another account is reported without leaking it', async () => {
    const page = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => errorResponse(403, 'This purchase belongs to another account') });
    await page.settle();
    assert.equal(page.els.codeSection.classList.contains(HIDDEN), true);
    assert.equal(page.els.recoverSection.classList.contains(HIDDEN), false);
    assert.match(page.els.msg.textContent, /another account/i);
    assert.equal(page.els.msg.textContent.includes('ABCD'), false);
  });

  it('cancelled / failed / missing-reference never mint or fetch', async () => {
    const cancelled = loadPage(`?status=cancelled&tx_ref=${TXREF}`, { fetchImpl: () => codeResponse() });
    await cancelled.settle();
    assert.match(cancelled.els.title.textContent, /cancelled/i);
    assert.equal(cancelled.fetchCalls.length, 0);

    const failed = loadPage(`?status=failed&tx_ref=${TXREF}`, { fetchImpl: () => codeResponse() });
    await failed.settle();
    assert.match(failed.els.title.textContent, /failed/i);
    assert.equal(failed.fetchCalls.length, 0);

    const bare = loadPage('?status=successful', { fetchImpl: () => codeResponse() });
    await bare.settle();
    assert.match(bare.els.sub.textContent, /No transaction reference/i);
    assert.equal(bare.fetchCalls.length, 0);
  });
});
