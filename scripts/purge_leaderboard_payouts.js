// Usage:
//   node scripts/purge_leaderboard_payouts.js                 (dry run: LIST only, deletes nothing)
//   node scripts/purge_leaderboard_payouts.js --execute       (deletes every pendingClaim doc)
//   Append --key=/path/to/serviceAccountKey.json to override the key path.
// (Key resolution: --key flag > GOOGLE_APPLICATION_CREDENTIALS > scripts/.service-account-key-path)
//
// Deletes every per-user payout record at
//   leaderboardCycles/{weekId}/pendingClaim/{uid}
// across ALL weeks, so the leaderboard prize section starts fresh for every
// user ('awaiting payout' / 'my prize' states disappear).
//
// SAFETY:
//   - Dry run by default. Deletion ONLY with --execute.
//   - Prints only non-sensitive fields (weekId, uid, status, hasBank,
//     submittedAt). Account numbers / bank codes are NEVER printed.
//   - leaderboardCycles ranked[] snapshots, prize_pool, payoutDetails and
//     purchase/accounting records are intentionally LEFT INTACT.
//   - Local admin script. NEVER deployed to Firebase.

const path = require('path');
const fs = require('fs');

const admin = require('firebase-admin');

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

function fmtTs(ts) {
  if (!ts) return '';
  if (typeof ts.toDate === 'function') return ts.toDate().toISOString();
  return String(ts);
}

async function listAllPendingClaims(db) {
  const cycles = await db.collection('leaderboardCycles').get();
  const records = [];
  for (const cycle of cycles.docs) {
    const claims = await cycle.ref.collection('pendingClaim').get();
    for (const claim of claims.docs) {
      const d = claim.data() || {};
      records.push({
        weekId: cycle.id,
        uid: claim.id,
        status: d.status || '',
        hasBank: Boolean(d.accountNumber || d.bankCode),
        submittedAt: fmtTs(d.submittedAt),
        ref: claim.ref,
      });
    }
  }
  return { cycleCount: cycles.size, records };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const execute = args.execute === true;
  const keyPath = resolveServiceAccountPath(args);
  initAdmin(keyPath);
  const db = admin.firestore();

  const { cycleCount, records } = await listAllPendingClaims(db);

  console.log(`Leaderboard cycles: ${cycleCount}`);
  console.log(`pendingClaim docs found: ${records.length}`);
  for (const r of records) {
    console.log(
      `  ${execute ? 'DEL' : 'FOUND'} week=${r.weekId} uid=${r.uid} ` +
      `status=${r.status} hasBank=${r.hasBank} submittedAt=${r.submittedAt}`
    );
  }

  if (!execute) {
    console.log('DRY RUN — nothing deleted. Re-run with --execute to delete.');
    return;
  }

  let deleted = 0;
  for (const r of records) {
    await r.ref.delete();
    deleted++;
  }
  console.log(`DONE. pendingClaim docs deleted=${deleted}.`);
}

main().catch((e) => {
  console.error(`FATAL: ${e.message}`);
  process.exit(1);
});
