#!/usr/bin/env node
/**
 * Seed / verify the server-only anti-cheat configuration.
 *
 * WHY THIS EXISTS
 *   The fraud scorer and the security switches read server_config/**
 *   (server_config/antifraud, server_config/security). If those docs are
 *   absent the functions silently fall back to the hardcoded defaults, which
 *   makes the effective policy invisible. This script writes the full default
 *   documents (merging any existing app_config copies and any already-tuned
 *   server_config values), and can verify them without writing.
 *
 * TARGET DOCUMENTS
 *   server_config/antifraud
 *     soloDailyCap : 100
 *     fraud        : { ...all FRAUD_DEFAULTS weights/thresholds... }
 *   server_config/security
 *     enforceAppCheck     : false   (monitor mode; flip after App Check soak)
 *     requireAdSession    : false   (legacy build tolerance; flip with minBuild)
 *   server_config/play_integrity
 *     packageName              : com.animequiz.app
 *     certificateSha256Digest  : [ pinned APK signing cert, base64url ]
 *     allowedDeviceVerdicts    : MEETS_DEVICE_INTEGRITY / MEETS_STRONG_INTEGRITY
 *     enforce                  : false  (log-only; flip after the new build)
 *     logOnly                  : true
 *
 * MERGE ORDER (never silently lowers a tuned value)
 *   hardcoded defaults  ->  legacy app_config/{name}  ->  existing server_config/{name}
 *   `--force` writes only the hardcoded defaults.
 *
 * USAGE
 *   node scripts/seed_server_config.js                 # dry run, no creds
 *   node scripts/seed_server_config.js --commit        # create/merge both docs
 *   node scripts/seed_server_config.js --check         # verify (creds required)
 *   node scripts/seed_server_config.js --force --commit
 *   node scripts/seed_server_config.js --key=/path/to/key.json --commit
 *
 * CREDENTIALS
 *   Same convention as set_android_config.js / seed_questions.js:
 *     --key=<path>  >  GOOGLE_APPLICATION_CREDENTIALS  >  scripts/.service-account-key-path
 */

'use strict';

const path = require('path');
const fs = require('fs');

const PROJECT_ID = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', '.firebaserc'), 'utf8')
).projects.default;

const ANTIFRAUD_DEFAULT = {
  soloDailyCap: 100,
  fraud: {
    wCadence: 25,
    rapidGapMs: 3000,
    rapidFullRatio: 0.5,
    mechMinGaps: 15,
    mechMaxCV: 0.15,
    wVolume: 10,
    volumeFullPerDay: 100,
    volumeMinPerDay: 40,
    wPair: 25,
    pairFullCount: 5,
    pairMinCount: 3,
    funnelMinGames: 4,
    funnelMinWinRate: 0.8,
    wIp: 15,
    wAge: 15,
    newbornDays: 7,
    newbornWP: 1500,
    youngDays: 14,
    youngWP: 2000,
    toddlerDays: 3,
    toddlerWP: 500,
    wWinRate: 20,
    stakeMinGames: 10,
    stakeHighRate: 0.9,
    stakeMidRate: 0.8,
    baselineQmRate: 0.65,
    qmMinGames: 5,
    bandModerate: 30,
    bandHigh: 60,
  },
};

const SECURITY_DEFAULT = {
  enforceAppCheck: false,
  requireAdSession: false,
};

// SHA-256 of the release signing certificate for animequiz-4.apk, base64url.
// Sideloaded APKs are expected: the cert pin is the trust anchor, not Play
// recognition. Rotate this only with a new signing key.
const PLAY_INTEGRITY_DEFAULT = {
  packageName: 'com.animequiz.app',
  certificateSha256Digest: ['6edYv6JkZWefkzNwgx-1zO4Kh22eBnjQuHvRqp5r8QE'],
  allowedDeviceVerdicts: ['MEETS_DEVICE_INTEGRITY', 'MEETS_STRONG_INTEGRITY'],
  enforce: false,
  logOnly: true,
};

const TARGETS = [
  { name: 'antifraud', defaults: ANTIFRAUD_DEFAULT },
  { name: 'security', defaults: SECURITY_DEFAULT },
  { name: 'play_integrity', defaults: PLAY_INTEGRITY_DEFAULT },
];

function requireFromFunctions(subpath) {
  return require(require.resolve(subpath, {
    paths: [path.join(__dirname, '..', 'functions')],
  }));
}

function loadAdmin() {
  try {
    return requireFromFunctions('firebase-admin/app');
  } catch (e) {
    throw new Error(
      'Could not load firebase-admin from functions/. Run `npm install` inside functions/.'
    );
  }
}

function resolveServiceAccountPath(opts) {
  if (opts.key) return opts.key;
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    return process.env.GOOGLE_APPLICATION_CREDENTIALS;
  }
  const pointer = path.join(__dirname, '.service-account-key-path');
  if (fs.existsSync(pointer)) {
    const p = fs.readFileSync(pointer, 'utf8').trim();
    if (p) return path.isAbsolute(p) ? p : path.join(__dirname, p);
  }
  return null;
}

function parseArgs(argv) {
  const opts = {
    commit: false, force: false, check: false,
    key: null, accessToken: null, help: false,
  };
  for (const raw of argv) {
    const m = /^--([^=]+)(?:=(.*))?$/.exec(raw);
    if (!m) continue;
    const [, flag, value] = m;
    switch (flag) {
      case 'commit': opts.commit = true; break;
      case 'force': opts.force = true; break;
      case 'check': opts.check = true; break;
      case 'key': opts.key = value; break;
      case 'access-token': opts.accessToken = value; break;
      case 'help': opts.help = true; break;
      default: throw new Error(`Unknown flag --${flag}`);
    }
  }
  return opts;
}

function mergeDefaults(defaults, ...layers) {
  const out = { ...defaults };
  for (const layer of layers) {
    if (!layer || typeof layer !== 'object') continue;
    for (const [k, v] of Object.entries(layer)) {
      if (k === 'fraud' && v && typeof v === 'object') {
        out.fraud = { ...(out.fraud || {}), ...v };
      } else {
        out[k] = v;
      }
    }
  }
  return out;
}

function missingKeys(defaults, actual) {
  const missing = [];
  for (const [k, v] of Object.entries(defaults)) {
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      for (const [sk] of Object.entries(v)) {
        if (!actual || !actual[k] || actual[k][sk] === undefined) missing.push(`${k}.${sk}`);
      }
    } else if (!actual || actual[k] === undefined) {
      missing.push(k);
    }
  }
  return missing;
}

// ── REST fallback (user access token, no service-account key) ─────────────
// firebase-admin refuses a bare OAuth token for Firestore, so `--access-token`
// uses the Firestore REST API. Same merge/check semantics as the SDK path.
function encodeValue(v) {
  if (v === null || v === undefined) return { nullValue: null };
  if (typeof v === 'string') return { stringValue: v };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') {
    return Number.isInteger(v)
      ? { integerValue: String(v) }
      : { doubleValue: v };
  }
  if (Array.isArray(v)) return { arrayValue: { values: v.map(encodeValue) } };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === 'object') return { mapValue: { fields: encodeFields(v) } };
  return { stringValue: String(v) };
}
function encodeFields(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj)) out[k] = encodeValue(v);
  return out;
}
function decodeValue(v) {
  if (!v) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('nullValue' in v) return null;
  if ('timestampValue' in v) return v.timestampValue;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(decodeValue);
  if ('mapValue' in v) return decodeFields(v.mapValue.fields || {});
  return null;
}
function decodeFields(fields) {
  const out = {};
  for (const [k, v] of Object.entries(fields || {})) out[k] = decodeValue(v);
  return out;
}
async function restGet(token, docPath) {
  const url = 'https://firestore.googleapis.com/v1/projects/' + PROJECT_ID +
    '/databases/(default)/documents/' + docPath;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 404) return null;
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`Firestore GET ${docPath} ${res.status}: ${t.slice(0, 200)}`);
  }
  const body = await res.json();
  return decodeFields(body.fields || {});
}
async function restPatch(token, docPath, obj) {
  const fields = encodeFields(obj);
  const mask = Object.keys(fields)
    .map((k) => `updateMask.fieldPaths=${encodeURIComponent(k)}`)
    .join('&');
  const url = 'https://firestore.googleapis.com/v1/projects/' + PROJECT_ID +
    '/databases/(default)/documents/' + docPath + '?' + mask;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ fields }),
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`Firestore PATCH ${docPath} ${res.status}: ${t.slice(0, 200)}`);
  }
  const body = await res.json();
  return decodeFields(body.fields || {});
}

async function runWithRest(opts) {
  let failed = false;
  for (const t of TARGETS) {
    const serverPath = `server_config/${t.name}`;
    const legacyPath = `app_config/${t.name}`;
    const [existing, legacy] = await Promise.all([
      restGet(opts.accessToken, serverPath),
      restGet(opts.accessToken, legacyPath),
    ]);

    if (opts.check) {
      if (!existing) {
        console.error(`\nMISSING: server_config/${t.name} (fraud/security will fall back to defaults)`);
        failed = true;
        continue;
      }
      const missing = missingKeys(t.defaults, existing);
      if (missing.length) {
        console.error(`\nINCOMPLETE: server_config/${t.name} missing ${missing.join(', ')}`);
        failed = true;
      } else {
        console.log(`\nOK: server_config/${t.name} has every required key.`);
      }
      continue;
    }

    const next = opts.force
      ? mergeDefaults(t.defaults)
      : mergeDefaults(t.defaults, legacy, existing);
    if (t.name === 'play_integrity' && next.enforce === true &&
        (!Array.isArray(next.certificateSha256Digest) ||
         next.certificateSha256Digest.length === 0)) {
      console.error('\nREFUSING: play_integrity.enforce=true with no pinned certificate digest.');
      failed = true;
      continue;
    }
    next.seededAt = new Date().toISOString();
    next.seededBy = 'scripts/seed_server_config.js';

    console.log(`\nserver_config/${t.name}`);
    console.log('  current:', existing ? JSON.stringify(existing) : '(absent)');
    console.log('  legacy :', legacy ? JSON.stringify(legacy) : '(absent)');
    console.log('  next   :', JSON.stringify(next));

    const after = await restPatch(opts.accessToken, serverPath, next);
    const missing = missingKeys(t.defaults, after);
    if (missing.length) {
      console.error(`  WROTE but still missing: ${missing.join(', ')}`);
      failed = true;
    } else {
      console.log('  WROTE and verified all required keys.');
    }
  }
  if (failed) process.exitCode = 1;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0]);
    return;
  }

  console.log('project :', PROJECT_ID);
  for (const t of TARGETS) {
    console.log(`target  : server_config/${t.name}`);
  }

  if (!opts.commit && !opts.check) {
    for (const t of TARGETS) {
      console.log(`\n--- server_config/${t.name} (defaults) ---`);
      console.log(JSON.stringify(t.defaults, null, 2));
    }
    console.log('\nDRY RUN - nothing read or written. Re-run with --commit to apply, or --check to verify the live docs.');
    return;
  }

  // User-token environments (e.g. `gcloud auth print-access-token`) cannot
  // initialize the Firestore Admin SDK; use the REST path instead.
  if (opts.accessToken) {
    await runWithRest(opts);
    return;
  }

  const { initializeApp, cert } = loadAdmin();
  const { getFirestore, FieldValue } = requireFromFunctions('firebase-admin/firestore');
  const keyPath = resolveServiceAccountPath(opts);
  if (!keyPath || !fs.existsSync(keyPath)) {
    throw new Error(
      'Service account key not found. Pass --key=/path/to/key.json, set ' +
      'GOOGLE_APPLICATION_CREDENTIALS, write the path into ' +
      'scripts/.service-account-key-path, or pass --access-token=<token>\n\n' +
      '  This reads/writes the LIVE database. Never commit the key/token.'
    );
  }
  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  const app = initializeApp({ credential: cert(serviceAccount), projectId: PROJECT_ID });
  const db = getFirestore(app);

  let failed = false;

  for (const t of TARGETS) {
    const serverRef = db.collection('server_config').doc(t.name);
    const legacyRef = db.collection('app_config').doc(t.name);
    const [serverSnap, legacySnap] = await Promise.all([
      serverRef.get(),
      legacyRef.get(),
    ]);
    const existing = serverSnap.exists ? (serverSnap.data() || {}) : null;
    const legacy = legacySnap.exists ? (legacySnap.data() || {}) : null;

    if (opts.check) {
      if (!existing) {
        console.error(`\nMISSING: server_config/${t.name} (fraud/security will fall back to defaults)`);
        failed = true;
        continue;
      }
      const missing = missingKeys(t.defaults, existing);
      if (missing.length) {
        console.error(`\nINCOMPLETE: server_config/${t.name} missing ${missing.join(', ')}`);
        failed = true;
      } else {
        console.log(`\nOK: server_config/${t.name} has every required key.`);
      }
      continue;
    }

    const next = opts.force
      ? mergeDefaults(t.defaults)
      : mergeDefaults(t.defaults, legacy, existing);
    if (t.name === 'play_integrity' && next.enforce === true &&
        (!Array.isArray(next.certificateSha256Digest) ||
         next.certificateSha256Digest.length === 0)) {
      console.error('\nREFUSING: play_integrity.enforce=true with no pinned certificate digest.');
      failed = true;
      continue;
    }
    next.seededAt = FieldValue.serverTimestamp();
    next.seededBy = 'scripts/seed_server_config.js';

    console.log(`\nserver_config/${t.name}`);
    console.log('  current:', existing ? JSON.stringify(existing) : '(absent)');
    console.log('  legacy :', legacy ? JSON.stringify(legacy) : '(absent)');
    console.log('  next   :', JSON.stringify({ ...next, seededAt: '<serverTimestamp>' }));

    await serverRef.set(next, { merge: true });
    const after = await serverRef.get();
    const afterData = after.data() || {};
    const missing = missingKeys(t.defaults, afterData);
    if (missing.length) {
      console.error(`  WROTE but still missing: ${missing.join(', ')}`);
      failed = true;
    } else {
      console.log('  WROTE and verified all required keys.');
    }
  }

  if (failed) process.exitCode = 1;
}

module.exports = {
  ANTIFRAUD_DEFAULT,
  SECURITY_DEFAULT,
  PLAY_INTEGRITY_DEFAULT,
  mergeDefaults,
  missingKeys,
};

if (require.main === module) {
  main().catch((e) => {
    console.error('\n' + (e && e.message ? e.message : e));
    process.exitCode = 1;
  });
}
