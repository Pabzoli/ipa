// Usage:
//   node scripts/purge_users.js                 (dry run: LIST only, deletes nothing)
//   node scripts/purge_users.js --execute       (deletes everything except KEEP_UIDS)
//   Append --key=/path/to/serviceAccountKey.json to override the key path.
// (Key resolution: --key flag > GOOGLE_APPLICATION_CREDENTIALS > scripts/.service-account-key-path)
//
// Deletes whole ACCOUNTS except the keepers below: the Firebase Auth user AND
// the entire users/{uid} document tree (recursive: matches, transactions,
// payoutDetails, receipts, ...).
//
// SAFETY:
//   - Dry run by default. Deletion ONLY with --execute.
//   - KEEP_UIDS is hardcoded and can never be deleted by this script.
//   - Prints only non-sensitive fields (uid, username, weeklyPoints,
//     leaderboardEntryWeekId). Emails/phones are never printed.
//   - Historical payout audit data (leaderboardCycles ranked[] snapshots,
//     payouts subcollections at cycle level, payoutLedger) is intentionally
//     LEFT INTACT — board presence comes only from users/{uid} docs.
//   - Local admin script. NEVER deployed to Firebase.

const path = require('path');
const fs = require('fs');

const admin = require('firebase-admin');

// ─── Keepers — the ONLY accounts that survive. Never delete these. ──────────
const KEEP_UIDS = [
  'owMNkXmb6QSzO0xfHkSgMlx0zSJ3',
  'pu4QTjHTijer7DLlqLU3w0npUUL2',
];

function parseArgs(argv) {
  const args = {};
  for (const raw of argv) {
    if (!raw.startsWith('--')) continue;
    const eq = raw.indexOf('=');
    if (eq === -1) {
      args[raw.slice(2)] = true;
    } else {
      args[raw.slice(2, eq)] = raw.slice(eq + 1);
    }
  }
  return args;
}

// Service-account key path resolution — same convention as generate_codes.js:
// never hardcoded, never committed.
function resolveServiceAccountPath(args) {
  if (args.key) return args.key;
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
      'scripts/.service-account-key-path'
    );
  }
  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
}

async function listAllAuthUids() {
  const uids = [];
  let pageToken = undefined;
  for (;;) {
    const res = await admin.auth().listUsers(1000, pageToken);
    for (const u of res.users) uids.push(u.uid);
    if (!res.pageToken) break;
    pageToken = res.pageToken;
  }
  return uids;
}

async function listAllUserDocs(db) {
  const snap = await db.collection('users').select().get();
  const docs = [];
  for (const doc of snap.docs) {
    // select() returns empty data; fetch the few display fields per doc.
    // (Small pre-launch user base — one extra get per user is fine.)
    let username = '';
    let weeklyPoints = 0;
    let entryWeek = '';
    try {
      const full = await doc.ref.get();
      const d = full.data() || {};
      username = d.username || '';
      weeklyPoints = d.weeklyPoints || 0;
      entryWeek = d.leaderboardEntryWeekId || '';
    } catch (e) {
      username = `<unreadable: ${e.message}>`;
    }
    docs.push({ uid: doc.id, username, weeklyPoints, entryWeek });
  }
  return docs;
}

async function recursiveDeleteDoc(db, docRef) {
  if (typeof db.recursiveDelete === 'function') {
    await db.recursiveDelete(docRef);
    return;
  }
  // Fallback for older Admin SDKs: manual depth-first delete.
  const collections = await docRef.listCollections();
  for (const col of collections) {
    for (;;) {
      const snap = await col.limit(400).get();
      if (snap.empty) break;
      const batch = db.batch();
      snap.docs.forEach((d) => batch.delete(d.ref));
      await batch.commit();
      for (const d of snap.docs) {
        await recursiveDeleteDoc(db, d.ref);
      }
    }
  }
  await docRef.delete();
}

async function main() {
  if (!Array.isArray(KEEP_UIDS) || KEEP_UIDS.length === 0) {
    throw new Error('KEEP_UIDS is empty — refusing to run.');
  }
  const args = parseArgs(process.argv.slice(2));
  const execute = args.execute === true;
  const keyPath = resolveServiceAccountPath(args);
  initAdmin(keyPath);
  const db = admin.firestore();

  const [authUids, userDocs] = await Promise.all([
    listAllAuthUids(),
    listAllUserDocs(db),
  ]);
  const docIds = new Set(userDocs.map((d) => d.uid));
  const allIds = new Set([...authUids, ...docIds]);
  const doomed = [...allIds].filter((uid) => !KEEP_UIDS.includes(uid));
  const kept = [...allIds].filter((uid) => KEEP_UIDS.includes(uid));

  console.log(`Auth users: ${authUids.length}, users docs: ${docIds.size}`);
  console.log(`KEEP (${kept.length}):`);
  for (const uid of kept) {
    const doc = userDocs.find((d) => d.uid === uid);
    console.log(
      `  KEEP uid=${uid} inAuth=${authUids.includes(uid)} ` +
      `hasDoc=${docIds.has(uid)} username=${doc ? doc.username : ''}`
    );
  }
  console.log(`DOOMED (${doomed.length}):`);
  for (const uid of doomed) {
    const doc = userDocs.find((d) => d.uid === uid);
    console.log(
      `  DEL uid=${uid} inAuth=${authUids.includes(uid)} ` +
      `hasDoc=${docIds.has(uid)} username=${doc ? doc.username : ''} ` +
      `weeklyPoints=${doc ? doc.weeklyPoints : ''} entryWeek=${doc ? doc.entryWeek : ''}`
    );
  }

  if (!execute) {
    console.log('DRY RUN — nothing deleted. Re-run with --execute to delete.');
    return;
  }

  // Final guard: re-assert keepers immediately before deleting.
  const targets = doomed.filter((uid) => !KEEP_UIDS.includes(uid));
  let authDeleted = 0;
  const authTargets = targets.filter((uid) => authUids.includes(uid));
  if (authTargets.length > 0) {
    const res = await admin.auth().deleteUsers(authTargets);
    authDeleted = res.successCount;
    console.log(`Auth deleted: ${authDeleted}, failed: ${res.failureCount}`);
    for (const e of res.errors || []) {
      console.log(`  auth delete error index=${e.index} reason=${e.error}`);
    }
  }
  let docsDeleted = 0;
  for (const uid of targets) {
    if (!docIds.has(uid)) continue;
    await recursiveDeleteDoc(db, db.collection('users').doc(uid));
    docsDeleted++;
    console.log(`  doc tree deleted: users/${uid}`);
  }
  console.log(
    `DONE. authDeleted=${authDeleted} docTreesDeleted=${docsDeleted} ` +
    `keepers untouched (${KEEP_UIDS.length}).`
  );
}

main().catch((e) => {
  console.error(`FATAL: ${e.message}`);
  process.exit(1);
});
