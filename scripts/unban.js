#!/usr/bin/env node
/**
 * Reverse an anti-cheat enforcement action. NEVER deletes accounts or evidence.
 *
 * WHAT IT DOES
 *   - enforcement/{uid}: level 'cleared', decayFactor 1, leaderboardExcluded,
 *     payoutHold and suspended false, with clearedAt/clearedBy/reason.
 *   - flaggedAccounts/{uid}: status 'cleared'; the signal history and actions
 *     are preserved (evidence is not deleted).
 *   - users/{uid}.lbEligible = true.
 *
 * USAGE
 *   node scripts/unban.js --list
 *   node scripts/unban.js --uid=<uid> --reason="manual review"
 *   node scripts/unban.js --uid=<uid> --reason="manual review" --commit
 *
 * CREDENTIALS
 *   --key=<path> > GOOGLE_APPLICATION_CREDENTIALS >
 *   scripts/.service-account-key-path
 *
 * Dry run by default. No account or data deletion, ever.
 */

'use strict';

const path = require('path');
const fs = require('fs');

const PROJECT_ID = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', '.firebaserc'), 'utf8')
).projects.default;

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
    uid: null, reason: null, commit: false, list: false,
    key: null, limit: 25, help: false,
  };
  for (const raw of argv) {
    const m = /^--([^=]+)(?:=(.*))?$/.exec(raw);
    if (!m) continue;
    const [, flag, value] = m;
    switch (flag) {
      case 'uid': opts.uid = value; break;
      case 'reason': opts.reason = value; break;
      case 'commit': opts.commit = true; break;
      case 'list': opts.list = true; break;
      case 'key': opts.key = value; break;
      case 'limit': opts.limit = Number(value) || 25; break;
      case 'help': opts.help = true; break;
      default: throw new Error(`Unknown flag --${flag}`);
    }
  }
  return opts;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0]);
    return;
  }
  if (!opts.list && (!opts.uid || !opts.uid.trim())) {
    throw new Error('Pass --uid=<uid>, or --list.');
  }

  const { initializeApp, cert } = loadAdmin();
  const { getFirestore, FieldValue } = requireFromFunctions('firebase-admin/firestore');
  const keyPath = resolveServiceAccountPath(opts);
  if (!keyPath || !fs.existsSync(keyPath)) {
    throw new Error(
      'Service account key not found. Pass --key=..., set ' +
      'GOOGLE_APPLICATION_CREDENTIALS, or write scripts/.service-account-key-path.'
    );
  }
  const app = initializeApp({
    credential: cert(JSON.parse(fs.readFileSync(keyPath, 'utf8'))),
    projectId: PROJECT_ID,
  });
  const db = getFirestore(app);

  if (opts.list) {
    const snap = await db.collection('flaggedAccounts')
      .orderBy('lastSignalAt', 'desc')
      .limit(Math.max(1, Math.min(100, opts.limit)))
      .get();
    if (snap.empty) {
      console.log('No flagged accounts.');
      return;
    }
    for (const doc of snap.docs) {
      const d = doc.data() || {};
      console.log(
        `${doc.id}  status=${d.status || d.level || 'unknown'}` +
        `  signals=${Array.isArray(d.signals) ? d.signals.length : 0}` +
        `  lastSignal=${d.lastSignalAt?.toDate ? d.lastSignalAt.toDate().toISOString() : 'n/a'}`,
      );
    }
    return;
  }

  const uid = opts.uid.trim();
  const enfRef = db.collection('enforcement').doc(uid);
  const flagRef = db.collection('flaggedAccounts').doc(uid);
  const userRef = db.collection('users').doc(uid);

  const [enfSnap, flagSnap, userSnap] = await Promise.all([
    enfRef.get(), flagRef.get(), userRef.get(),
  ]);
  console.log('project      :', PROJECT_ID);
  console.log('uid          :', uid);
  console.log('enforcement  :', enfSnap.exists ? JSON.stringify(enfSnap.data()) : '(absent)');
  console.log('flagged      :', flagSnap.exists
    ? `status=${flagSnap.data()?.status || flagSnap.data()?.level || 'unknown'}`
    : '(absent)');
  console.log('user         :', userSnap.exists
    ? `lbEligible=${userSnap.data()?.lbEligible !== false}`
    : '(absent)');

  const nextEnf = {
    level: 'cleared',
    decayFactor: 1,
    leaderboardExcluded: false,
    payoutHold: false,
    suspended: false,
    clearedAt: FieldValue.serverTimestamp(),
    clearedBy: 'scripts/unban.js',
    clearReason: opts.reason || 'manual review',
    updatedAt: FieldValue.serverTimestamp(),
  };
  console.log('next         :', JSON.stringify({
    ...nextEnf,
    clearedAt: '<serverTimestamp>',
    updatedAt: '<serverTimestamp>',
  }));

  if (!opts.commit) {
    console.log('\nDRY RUN - nothing written. Re-run with --commit to apply.');
    return;
  }

  await db.runTransaction(async (tx) => {
    const [freshFlag, freshUser] = await Promise.all([
      tx.get(flagRef),
      tx.get(userRef),
    ]);
    tx.set(enfRef, nextEnf, { merge: true });

    const flag = freshFlag.data() || {};
    const actions = Array.isArray(flag.actions) ? [...flag.actions] : [];
    actions.push({
      type: 'cleared',
      at: Date.now(),
      source: 'scripts/unban.js',
      reversible: false,
      reason: opts.reason || 'manual review',
    });
    tx.set(flagRef, {
      status: 'cleared',
      level: 'cleared',
      clearedAt: FieldValue.serverTimestamp(),
      clearedBy: 'scripts/unban.js',
      clearReason: opts.reason || 'manual review',
      actions: actions.slice(-30),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    if (freshUser.exists) {
      tx.update(userRef, { lbEligible: true });
    }
  });

  console.log('\nCLEARED. Evidence retained in flaggedAccounts/' + uid + '.');
}

module.exports = { parseArgs };

if (require.main === module) {
  main().catch((e) => {
    console.error('\n' + (e && e.message ? e.message : e));
    process.exitCode = 1;
  });
}
