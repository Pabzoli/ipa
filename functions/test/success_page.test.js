// functions/test/success_page.test.js �?runs the REAL <script> from
// public/success.html in a stubbed DOM and checks the buyer-facing outcome of
// every redirect shape the Flutterwave hosted checkout can hand back:
//
//   A. ?email=�?status=successful&tx_ref=�?          (params appended with &)
//   B. ?email=�?status=successful&tx_ref=�?          (appended with a 2nd ?)
//   C. ?status=successful&tx_ref=�?                  (original query replaced)
//   plus failed / cancelled / missing-reference and the late-webhook retry.
'use strict';
const { test, describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const HTML = fs.readFileSync(
  path.join(__dirname, '..', '..', 'public', 'success.html'), 'utf8');

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
    },
    addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
    appendChild: (child) => el.children.push(child),
    click: () => (listeners.click || []).forEach((fn) => fn({ target: el })),
    input: () => (listeners.input || []).forEach((fn) => fn({ target: el })),
    focus: () => {},
    scrollIntoView: () => {},
  };
  return el;
}

function loadPage(search, { fetchImpl }) {
  const els = {};
  const ids = ['title', 'sub', 'pending', 'codeSection', 'code', 'copyBtn',
    'copyLabel', 'copyIcon', 'recoverSection', 'email', 'getBtn', 'msg'];
  for (const id of ids) els[id] = makeEl(id);

  const fetchCalls = [];
  // Collapse the 3s poll wait to one immediate, then drain the async chain.
  const settle = async (turns = 40) => {
    for (let i = 0; i < turns; i++) await new Promise((r) => setImmediate(r));
  };

  const sandbox = {
    console,
    URLSearchParams,
    setTimeout: (fn) => setImmediate(fn),
    fetch: async (url, opts) => {
      fetchCalls.push({ url, body: JSON.parse(opts.body) });
      return fetchImpl(fetchCalls.length);
    },
    navigator: { clipboard: { writeText: async () => {} } },
  };
  sandbox.window = { location: { search } };
  sandbox.document = {
    getElementById: (id) => els[id],
    createElement: () => makeEl('created'),
    addEventListener: () => {},
  };
  vm.createContext(sandbox);
  vm.runInContext(SCRIPT, sandbox);
  return { els, fetchCalls, settle };
}

function codeResponse() {
  return { ok: true, status: 200, json: async () => ({ success: true, code: 'ABCD-EFGH-IJKL' }) };
}
function errorResponse(status, error) {
  return { ok: false, status, json: async () => ({ error }) };
}
const TXREF = 'AQ-PREM31-123e4567-e89b-12d3-a456-426614174000';
const EMAIL = 'buyer@example.com';
const HIDDEN = 'hidden';

describe('public/success.html buyer delivery', () => {
  it('A: appended-with-& redirect auto-delivers the code', async () => {
    const page = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}&transaction_id=99`,
      { fetchImpl: () => codeResponse() });
    await page.settle();
    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL');
    assert.equal(page.els.codeSection.classList.contains(HIDDEN), false);
    assert.equal(page.els.pending.classList.contains(HIDDEN), true);
    assert.deepEqual(page.fetchCalls[0].body, { tx_ref: TXREF, email: EMAIL });
  });

  it('C: query-replaced redirect still lets the buyer recover manually', async () => {
    const page = loadPage(`?status=successful&tx_ref=${TXREF}`, { fetchImpl: () => codeResponse() });
    await page.settle();
    assert.equal(page.els.recoverSection.classList.contains(HIDDEN), false);
    // No auto-fetch fired (no email to attribute against) �?buyer types it.
    assert.equal(page.fetchCalls.length, 0);

    page.els.email.value = EMAIL;
    page.els.getBtn.click();
    await page.settle();
    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL');
  });

  it('B: a second "?" merge must still reach the buyer', async () => {
    const page = loadPage(`?email=${EMAIL}?status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => codeResponse() });
    await page.settle();
    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL',
      'buyer did not get their code on the second-? merge shape');
  });

  it('retries while the webhook is in flight, then falls back to manual entry', async () => {
    let n = 0;
    const page = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => (++n < 3 ? errorResponse(404, 'not yet') : codeResponse()) });
    await page.settle();
    assert.equal(page.els.code.textContent, 'ABCD-EFGH-IJKL');
    assert.equal(page.fetchCalls.length, 3);

    // Now the code never arrives: after the retry budget the manual form opens.
    const dead = loadPage(`?email=${EMAIL}&status=successful&tx_ref=${TXREF}`,
      { fetchImpl: () => errorResponse(404, 'not yet') });
    await dead.settle();
    assert.equal(dead.els.recoverSection.classList.contains(HIDDEN), false);
    assert.equal(dead.els.pending.classList.contains(HIDDEN), true);
    assert.match(dead.els.msg.textContent, /longer than expected/);
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
