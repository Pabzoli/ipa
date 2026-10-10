#!/usr/bin/env node
/**
 * Seed or update the Android forced-update gate config document.
 *
 * Target document: app_config/android
 *   minBuild     { number }  lowest Android versionCode allowed to keep working
 *   latestBuild  { number }  versionCode currently published to users
 *   apkUrl       { string }  download URL for the latest build
 *
 * ROLLOUT DISCIPLINE
 *   When a new build ships, latestBuild moves first and minBuild stays put.
 *   The gate is only "armed" once minBuild is raised to the previous
 *   latestBuild, which strands the older install and forces the update.
 *
 *   Example, shipping build 2:
 *     publish: latestBuild=2, minBuild=1   -> nobody is forced yet (safe)
 *     arm:     minBuild=2,  latestBuild=2  -> build 1 is walled (the point)
 *
 *   Currently shipping build 3 (animequiz-3.apk, pubspec 1.1.0+3), not armed.
 *
 *   Every real write requires --commit. Without it the script is a read-only
 *   dry run, so it is safe to invoke at any time.
 *
 * CREDENTIALS
 *   Resolved with the same convention as generate_codes.js / purge_users.js /
 *   seed_questions.js:
 *     1. --key=<path>
 *     2. GOOGLE_APPLICATION_CREDENTIALS
 *     3. scripts/.service-account-key-path (a file holding the key's path)
 *   Bare `initializeApp()` from functions/index.js is NOT enough here: on a
 *   developer machine there are no ambient credentials, so this script fails
 *   loudly with setup instructions instead of a bare "Could not load the
 *   default credentials".
 *
 * USAGE
 *   node scripts/set_android_config.js --show
 *   node scripts/set_android_config.js --min-build=1 --latest-build=2
 *   node scripts/set_android_config.js --min-build=2 --latest-build=2 --commit
 *   node scripts/set_android_config.js --min-build=1 --latest-build=2 --check-url --commit
 */

'use strict';

const path = require('path');
const fs = require('fs');
const https = require('https');

const PROJECT_ID = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', '.firebaserc'), 'utf8')
).projects.default;
const DOC_PATH = 'app_config/android';
const COLLECTION = 'app_config';
const DOC_ID = 'android';

// Points straight at the APK, not /download.html: the user tapping "Download
// the update" on the in-app wall is already blocked from playing and wants the
// file, not a page. Keep this filename, and the build numbers below, in step
// with public/downloads/latest.json and the shipped pubspec version whenever a
// new build is published -- a stale filename here is a dead download for
// exactly the users who most need it. --check-url catches that before you
// arm the gate.
const DEFAULT_APK_URL = 'https://anime-quiz-1ab1b.web.app/downloads/animequiz-3.apk';

/**
 * Resolve firebase-admin by PACKAGE NAME from the functions/ tree.
 *
 * A path-style require such as
 *   require('../functions/node_modules/firebase-admin/app')
 * fails on purpose: firebase-admin v13 exposes subpaths only through its
 * package.json "exports" map (app -> lib/esm/app), and the real files are not
 * at the package root, so a direct filesystem path cannot reach them. Name
 * resolution with an explicit base directory is the only thing that works from
 * outside functions/, since scripts/ has no node_modules of its own.
 */
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

function parseArgs(argv) {
  const opts = {
    // Build 3 is published and not yet enforced: latestBuild tracks what users
    // can download, minBuild stays at 1 until we deliberately strand the older
    // install. Same publish-then-arm order as the ROLLOUT DISCIPLINE note above.
    minBuild: 1,
    latestBuild: 3,
    apkUrl: DEFAULT_APK_URL,
    key: null,
    commit: false,
    show: false,
    checkUrl: false,
  };
  for (const raw of argv) {
    const m = /^--([^=]+)(?:=(.*))?$/.exec(raw);
    if (!m) continue;
    const [, flag, value] = m;
    switch (flag) {
      case 'min-build':    opts.minBuild = Number(value); break;
      case 'latest-build': opts.latestBuild = Number(value); break;
      case 'apk-url':      opts.apkUrl = value; break;
      case 'key':          opts.key = value; break;
      case 'commit':       opts.commit = true; break;
      case 'show':         opts.show = true; break;
      case 'check-url':    opts.checkUrl = true; break;
      case 'help':         opts.help = true; break;
      default:
        throw new Error(`Unknown flag --${flag}`);
    }
  }
  return opts;
}

/** Guards that prevent shipping a self-defeating or unusable config. */
function validate(o) {
  const errs = [];
  if (!Number.isInteger(o.minBuild) || o.minBuild < 1) {
    errs.push(`min-build must be an integer >= 1 (got ${o.minBuild})`);
  }
  if (!Number.isInteger(o.latestBuild) || o.latestBuild < 1) {
    errs.push(`latest-build must be an integer >= 1 (got ${o.latestBuild})`);
  }
  if (Number.isInteger(o.minBuild) && Number.isInteger(o.latestBuild)
      && o.minBuild > o.latestBuild) {
    errs.push(
      `min-build (${o.minBuild}) is above latest-build (${o.latestBuild}); ` +
      'that strands EVERY user, including up-to-date ones'
    );
  }
  if (!/^https:\/\//.test(o.apkUrl)) {
    errs.push(`apk-url must be an https:// URL (got ${o.apkUrl})`);
  }
  if (errs.length) {
    throw new Error('Refusing to write an invalid gate config:\n  - ' + errs.join('\n  - '));
  }
}

/**
 * Service-account key path resolution — the same convention as
 * generate_codes.js / purge_users.js / seed_questions.js:
 *   --key flag  >  GOOGLE_APPLICATION_CREDENTIALS  >  scripts/.service-account-key-path
 * Never hardcoded, never committed. That pointer file and
 * *serviceAccountKey*.json are already in .gitignore; inventing a different
 * location here (e.g. scripts/service-account.json) would NOT be ignored and
 * would risk committing a private key.
 */
function resolveServiceAccountPath(o) {
  if (o.key) return o.key;
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    return process.env.GOOGLE_APPLICATION_CREDENTIALS;
  }
  const configFile = path.join(__dirname, '.service-account-key-path');
  if (fs.existsSync(configFile)) {
    const p = fs.readFileSync(configFile, 'utf8').trim();
    if (p) return path.isAbsolute(p) ? p : path.join(__dirname, p);
  }
  return null;
}

function initAdmin(keyPath) {
  if (!keyPath || !fs.existsSync(keyPath)) {
    throw new Error(
      'Service account key not found. Pass --key=/path/to/key.json, set ' +
      'GOOGLE_APPLICATION_CREDENTIALS, or write the path into ' +
      'scripts/.service-account-key-path\n\n' +
      '  This writes to the LIVE database, and a developer machine has no ' +
      'ambient credentials, so the bare initializeApp() that ' +
      'functions/index.js uses on Cloud Functions cannot be reused here.\n\n' +
      '  To get a key: Firebase console -> Project settings -> Service ' +
      'accounts -> "Generate new private key". It only needs ' +
      'roles/datastore.user (or broader). Never commit it.'
    );
  }
  return JSON.parse(fs.readFileSync(keyPath, 'utf8'));
}

function headUrl(url) {
  return new Promise(resolve => {
    const req = https.request(url, { method: 'HEAD', timeout: 15000 }, res => {
      res.resume();
      resolve({ status: res.statusCode, type: res.headers['content-type'] || null });
    });
    req.on('timeout', () => { req.destroy(); resolve({ status: null, type: null, err: 'timeout' }); });
    req.on('error', e => resolve({ status: null, type: null, err: e.message }));
    req.end();
  });
}

(async () => {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(require('fs').readFileSync(__filename, 'utf8').split('*/')[0]);
    return;
  }

  // Guard before any credential or network work, so a typo cannot half-run.
  if (!opts.show) validate(opts);

  const next = {
    minBuild: opts.minBuild,
    latestBuild: opts.latestBuild,
    apkUrl: opts.apkUrl,
  };
  const arming = next.minBuild >= next.latestBuild;

  // ---- Credential-free plan: this is exactly what --commit would write. ----
  console.log('project      :', PROJECT_ID);
  console.log('document     :', DOC_PATH);

  if (opts.checkUrl) {
    const r = await headUrl(opts.apkUrl);
    console.log('apkUrl check :',
      r.status === 200
        ? `HTTP ${r.status} content-type=${r.type}`
        : `HTTP ${r.status}${r.err ? ' err=' + r.err : ''} (host the APK before arming the gate)`);
  }

  // The exact document that would be written:
  console.log('next         :', JSON.stringify(next));
  if (arming) {
    console.log('*** ARMING: builds below ' + next.minBuild +
                ' will be blocked, with no bypass. ***');
  } else {
    console.log('not armed: builds below ' + next.minBuild +
                ' are still served normally; only a stale ' + next.minBuild +
                ' is warned about.');
  }

  // A dry run prints the plan and stops here: no credentials, no writes.
  if (!opts.commit) {
    console.log('\nDRY RUN - nothing written. Re-run with --commit to apply.');
    return;
  }

  // ---- Commit path: credentials are required only to read current + write. ----
  const { initializeApp, cert } = loadAdmin();
  const { getFirestore } = requireFromFunctions('firebase-admin/firestore');
  const keyPath = resolveServiceAccountPath(opts);
  const serviceAccount = initAdmin(keyPath);
  const app = initializeApp({
    credential: cert(serviceAccount),
    projectId: PROJECT_ID,
  });
  const db = getFirestore(app);
  const ref = db.collection(COLLECTION).doc(DOC_ID);

  const snap = await ref.get();
  const current = snap.exists ? snap.data() : null;
  console.log('current      :', current ? JSON.stringify(current) : '(absent)');

  await ref.set(next, { merge: true });
  const after = await ref.get();
  console.log('\nWROTE       :', JSON.stringify(after.data()));
  console.log('Gate is now', arming ? 'ARMED.' : 'staged (not yet forcing updates).');
})().catch(e => {
  console.error('\n' + (e && e.message ? e.message : e));
  process.exitCode = 1;
});
