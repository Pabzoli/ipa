#!/usr/bin/env node
/**
 * Production verification for the anti-cheat deploy.
 *
 * Checks:
 *   1. server_config/{antifraud,security,play_integrity} exist with required keys.
 *   2. getQuizRun returns sanitized questions (no correctAnswerIndex).
 *   3. The 4th free Gauntlet entry in one WAT day is rejected with
 *      gauntlet_free_entry_limit.
 *
 * It creates a throwaway Auth user + profile, runs the checks, then deletes the
 * test profile and Auth user (unless --keep). It never touches a real player.
 *
 * USAGE
 *   node scripts/verify_anticheat_prod.js --access-token=<gcloud token>
 *   node scripts/verify_anticheat_prod.js --access-token=<token> --keep
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PROJECT_ID = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', '.firebaserc'), 'utf8')
).projects.default;
const API_KEY = 'AIzaSyBTjNAnbxqRVT99MoUhTXkUXaHsA7bx0Fw';
const REGION = 'us-central1';
const BASE = `https://${REGION}-${PROJECT_ID}.cloudfunctions.net`;
const FS_BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents`;

function parseArgs(argv) {
  const opts = { accessToken: null, keep: false, email: null, help: false };
  for (const raw of argv) {
    const m = /^--([^=]+)(?:=(.*))?$/.exec(raw);
    if (!m) continue;
    const [, flag, value] = m;
    switch (flag) {
      case 'access-token': opts.accessToken = value; break;
      case 'keep': opts.keep = true; break;
      case 'email': opts.email = value; break;
      case 'help': opts.help = true; break;
      default: throw new Error(`Unknown flag --${flag}`);
    }
  }
  return opts;
}

async function jsonFetch(url, opts = {}) {
  const res = await fetch(url, opts);
  const text = await res.text();
  let body;
  try { body = text ? JSON.parse(text) : {}; } catch { body = { raw: text }; }
  return { status: res.status, ok: res.ok, body };
}

function encode(v) {
  if (v === null || v === undefined) return { nullValue: null };
  if (typeof v === 'string') return { stringValue: v };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') {
    return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  }
  if (Array.isArray(v)) return { arrayValue: { values: v.map(encode) } };
  if (typeof v === 'object') return { mapValue: { fields: encodeFields(v) } };
  return { stringValue: String(v) };
}
function encodeFields(o) {
  const out = {};
  for (const [k, v] of Object.entries(o)) out[k] = encode(v);
  return out;
}
function decode(v) {
  if (!v) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('nullValue' in v) return null;
  if ('timestampValue' in v) return v.timestampValue;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(decode);
  if ('mapValue' in v) return decodeFields(v.mapValue.fields || {});
  return null;
}
function decodeFields(f) {
  const out = {};
  for (const [k, v] of Object.entries(f || {})) out[k] = decode(v);
  return out;
}

async function fsGet(token, docPath) {
  const r = await jsonFetch(`${FS_BASE}/${docPath}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`Firestore GET ${docPath} ${r.status}`);
  return decodeFields(r.body.fields || {});
}
async function fsPatch(token, docPath, obj, maskFields) {
  const fields = encodeFields(obj);
  const mask = (maskFields || Object.keys(fields))
    .map((k) => `updateMask.fieldPaths=${encodeURIComponent(k)}`)
    .join('&');
  const r = await jsonFetch(`${FS_BASE}/${docPath}?${mask}`, {
    method: 'PATCH',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ fields }),
  });
  if (!r.ok) throw new Error(`Firestore PATCH ${docPath} ${r.status}`);
  return decodeFields(r.body.fields || {});
}
async function fsDelete(token, docPath) {
  await jsonFetch(`${FS_BASE}/${docPath}`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${token}` },
  });
}

async function callable(name, idToken, data) {
  const r = await jsonFetch(`${BASE}/${name}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${idToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ data }),
  });
  return r.body;
}

function assert(cond, message) {
  if (!cond) throw new Error(`VERIFY FAILED: ${message}`);
  console.log(`  OK: ${message}`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0]);
    return;
  }
  if (!opts.accessToken) {
    throw new Error('Pass --access-token=<token> (gcloud auth print-access-token).');
  }
  const token = opts.accessToken;
  const stamp = Date.now();
  const email = opts.email || `anticheat-verify-${stamp}@example.com`;
  const password = `V${stamp}a!9xQ`;

  console.log('project :', PROJECT_ID);
  const stampFields = {
    platform: 'android',
    appBuild: 999,
  };

  // 1. server_config docs ---------------------------------------------------
  console.log('\n[1] server_config');
  const antifraud = await fsGet(token, 'server_config/antifraud');
  assert(antifraud && antifraud.fraud && antifraud.fraud.bandHigh === 60,
    'server_config/antifraud seeded with fraud weights');
  const security = await fsGet(token, 'server_config/security');
  assert(security && security.enforceAppCheck === false,
    'server_config/security seeded (App Check log-only)');
  const integrity = await fsGet(token, 'server_config/play_integrity');
  assert(Array.isArray(integrity?.certificateSha256Digest) &&
    integrity.certificateSha256Digest.length > 0,
    'server_config/play_integrity has a pinned certificate digest');
  assert(integrity.enforce === false && integrity.logOnly === true,
    'Play Integrity is in log-only mode');

  // 2. throwaway user -------------------------------------------------------
  console.log('\n[2] test user');
  const create = await jsonFetch(
    `https://identitytoolkit.googleapis.com/v1/projects/${PROJECT_ID}/accounts`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        'x-goog-user-project': PROJECT_ID,
      },
      body: JSON.stringify({
        email, password, displayName: 'AntiCheat Verify', emailVerified: true,
      }),
    },
  );
  if (!create.ok) {
    throw new Error(`Auth create ${create.status}: ${JSON.stringify(create.body).slice(0, 200)}`);
  }
  const uid = create.body.localId;
  console.log('  test uid:', uid);

  const signIn = await jsonFetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${API_KEY}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password, returnSecureToken: true }),
    },
  );
  if (!signIn.ok || !signIn.body.idToken) {
    throw new Error(`Auth sign-in failed: ${JSON.stringify(signIn.body).slice(0, 200)}`);
  }
  const idToken = signIn.body.idToken;

  await fsPatch(token, `users/${uid}`, {
    username: `verify_${stamp}`,
    email,
    animeCoins: 0,
    weeklyPoints: 0,
    lbEligible: true,
    premiumActive: false,
    createdAt: new Date().toISOString(),
    weeklyReset: new Date().toISOString(),
    stats: {
      gamesPlayed: 0, gamesWon: 0, gamesLost: 0,
      hseWon: 0, hseLost: 0, hseStaked: 0,
    },
  });

  const runIds = [];
  let fourthError = null;

  try {
    // 3. four free Gauntlet entries ----------------------------------------
    console.log('\n[3] getQuizRun sanitization + free Gauntlet entry cap');
    for (let i = 1; i <= 4; i++) {
      const res = await callable('enterDailyGauntlet', idToken, {
        runV2: true, ...stampFields,
      });
      if (i <= 3) {
        if (res.error) {
          throw new Error(`entry ${i} unexpectedly failed: ${res.error.status} ${res.error.message}`);
        }
        const runId = res.result?.runId;
        assert(!!runId, `entry ${i} minted a run`);
        runIds.push(runId);

        if (i === 1) {
          // The run is active; resolve its sanitized questions.
          const qr = await callable('getQuizRun', idToken, {
            mode: 'gauntlet', runId, ...stampFields,
          });
          if (qr.error) {
            throw new Error(`getQuizRun failed: ${qr.error.status} ${qr.error.message}`);
          }
          const questions = qr.result?.questions || [];
          assert(questions.length === 30, 'getQuizRun returned 30 Blitz questions');
          assert(
            questions.every((q) => q.correctAnswerIndex === undefined),
            'getQuizRun response contains no correctAnswerIndex',
          );
        }

        const cancel = await callable('cancelRun', idToken, { runId });
        if (cancel.error) {
          throw new Error(`cancel ${i} failed: ${cancel.error.status} ${cancel.error.message}`);
        }
        const afterCancel = await fsGet(token, `quizRuns/${runId}`);
        const afterUser = await fsGet(token, `users/${uid}`);
        console.log(
          `  debug: run=${runId} state=${afterCancel?.state}` +
          ` activeRunId=${afterUser?.activeRunId || 'none'}`,
        );
      } else {
        fourthError = res.error || null;
      }
    }
    assert(!!fourthError, '4th free entry was rejected');
    assert(
      fourthError.status === 'FAILED_PRECONDITION' &&
      String(fourthError.message).includes('gauntlet_free_entry_limit'),
      `4th entry error is gauntlet_free_entry_limit (got ${fourthError.status} ${fourthError.message})`,
    );
  } finally {
    // 5. cleanup ------------------------------------------------------------
    if (!opts.keep) {
      console.log('\n[5] cleanup test user');
      for (const runId of runIds) {
        await fsDelete(token, `quizRuns/${runId}`).catch(() => {});
      }
      await fsDelete(token, `users/${uid}`).catch(() => {});
      await jsonFetch(
        `https://identitytoolkit.googleapis.com/v1/projects/${PROJECT_ID}/accounts:delete`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
            'x-goog-user-project': PROJECT_ID,
          },
          body: JSON.stringify({ localId: uid }),
        },
      ).catch(() => {});
      console.log('  deleted test user + runs');
    } else {
      console.log('\n[5] kept test user:', uid);
    }
  }
}

main().catch((e) => {
  console.error('\n' + (e && e.message ? e.message : e));
  process.exitCode = 1;
});
