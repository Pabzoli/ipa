// Usage:
//   node scripts/purge_admin_from_economy.js               (dry run: LIST only, writes nothing)
//   node scripts/purge_admin_from_economy.js --execute     (apply the cleanup)
//   Append --key=/path/to/serviceAccountKey.json to override the key path.
//   (Key resolution: --key flag > GOOGLE_APPLICATION_CREDENTIALS > scripts/.service-account-key-path)
//
// Takes ADMIN accounts fully out of the player economy. Admin accounts are
// GHOSTS: they must never be ranked, counted, paid or shown. Future weekly
// resets already exclude them (functions/index.js), but an admin that bought a
// weekly entry code BEFORE this fix can still be sitting in:
//   * users/{admin}.leaderboardEntryWeekId  (makes client COUNTs include it)
//   * leaderboardCycles/{week}.ranked[]     (a rank + prize share)
//   * leaderboardCycles/{week}/pendingClaim/{admin}  (a "winner to pay" row)
//
// WHAT THIS DOES (only with --execute):
//   1. Clears the admin's leaderboard entry fields and zeroes weeklyPoints.
//   2. Removes UNPAID admin rows from every cycle's ranked[] and rewrites
//      eligibleCount. A PAID admin row is reported and LEFT ALONE — a settled
//      payout needs a human to reconcile, not a silent rewrite.
//   3. Deletes each cycle's pendingClaim/{admin} doc.
//
// SAFETY:
//   - Dry run by default. Writes ONLY with --execute.
//   - Never prints account numbers — hasBank is a boolean, nothing more.
//   - prize_pool.winners[] snapshots are REPORTED only, never rewritten.
//   - Local admin script. NEVER deployed to Firebase.

const path = require('path');
const fs = require('fs');

const admin = require('firebase-admin');

// Must mirror ADMIN_UIDS in functions/index.js and isPayoutAdmin() in
// firestore.rules. Update all three together.
const ADMIN_UIDS = ['owMNkXmb6QSzO0xfHkSgMlx0zSJ3'];
const ADMIN_UID_SET = new Set(ADMIN_UIDS);

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

// Service-account key path resolution — same convention as the other scripts:
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
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
}

function isAdmin(uid) {
  return ADMIN_UID_SET.has(uid);
}

// ─── 1. Admin user docs ─────────────────────────────────────────────────────
async function cleanAdminUsers(db, execute) {
  for (const uid of ADMIN_UIDS) {
    const ref = db.collection('users').doc(uid);
    const snap = await ref.get();
    if (!snap.exists) {
      console.log(`  user ${uid}: NOT FOUND (nothing to clear)`);
      continue;
    }
    const d = snap.data() || {};
    const entry = d.leaderboardEntryWeekId;
    const wp = d.weeklyPoints || 0;
    if (entry === undefined && !wp) {
      console.log(`  user ${uid}: already clean`);
      continue;
    }
    console.log(
      `  ${execute ? 'CLEAN' : 'FOUND'} user ${uid} ` +
      `entryWeek=${entry ?? '-'} weeklyPoints=${wp}`
    );
    if (execute) {
      const patch = { weeklyPoints: 0 };
      if (entry !== undefined) {
        patch.leaderboardEntryWeekId = admin.firestore.FieldValue.delete();
      }
      if (d.leaderboardEntryEmail !== undefined) {
        patch.leaderboardEntryEmail = admin.firestore.FieldValue.delete();
      }
      await ref.update(patch);
    }
  }
}

// ─── 2. Leaderboard cycles ──────────────────────────────────────────────────
async function cleanCycles(db, execute) {
  const cycles = await db.collection('leaderboardCycles').get();
  let touched = 0;

  for (const cycle of cycles.docs) {
    const data = cycle.data() || {};
    const ranked = Array.isArray(data.ranked) ? data.ranked : [];
    const adminRows = ranked.filter((r) => r && isAdmin(r.uid));

    if (adminRows.length > 0) {
      for (const r of adminRows) {
        const paid = r.paid === true;
        console.log(
          `  cycle ${cycle.id}: rank=${r.rank ?? '-'} uid=${r.uid} ` +
          `share=${Number(r.share) || 0} paid=${paid}` +
          (paid ? '  <-- PAID: LEFT ALONE (reconcile by hand)' : '')
        );
      }

      const removable = adminRows.filter((r) => r.paid !== true);
      if (removable.length > 0) {
        const kept = ranked.filter((r) => !(r && isAdmin(r.uid) && r.paid !== true));
        console.log(
          `  ${execute ? 'PATCH' : 'WOULD PATCH'} cycle ${cycle.id}: ` +
          `ranked ${ranked.length} -> ${kept.length}`
        );
        if (execute) {
          await cycle.ref.set(
            { ranked: kept, eligibleCount: kept.length },
            { merge: true }
          );
          touched++;
        }
      }
    }

    // Winner-to-pay row for an admin (never legitimate).
    const claimRef = cycle.ref.collection('pendingClaim');
    for (const uid of ADMIN_UIDS) {
      const claimSnap = await claimRef.doc(uid).get();
      if (!claimSnap.exists) continue;
      const c = claimSnap.data() || {};
      console.log(
        `  cycle ${cycle.id}: pendingClaim/${uid} status=${c.status || ''} ` +
        `hasBank=${Boolean(c.accountNumber || c.bankCode)}`
      );
      if (execute) {
        await claimSnap.ref.delete();
        touched++;
      }
    }
  }

  console.log(`  leaderboardCycles scanned: ${cycles.size}`);
  return touched;
}

// ─── 3. Historical prize_pool.winners[] (report only) ───────────────────────
async function reportPrizePoolWinners(db) {
  const pools = await db.collection('prize_pool').get();
  let found = 0;
  for (const pool of pools.docs) {
    const winners = (pool.data() || {}).winners;
    if (!Array.isArray(winners)) continue;
    const adminWinners = winners.filter((w) => w && isAdmin(w.uid));
    if (adminWinners.length > 0) {
      found++;
      for (const w of adminWinners) {
        console.log(
          `  prize_pool ${pool.id}: admin winner rank=${w.rank ?? '-'} ` +
          `uid=${w.uid} prize=${Number(w.prize) || 0} paid=${w.paid === true}`
        );
      }
    }
  }
  console.log(`  prize_pool docs with an admin winner: ${found} (REPORT ONLY)`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const execute = args.execute === true;
  const keyPath = resolveServiceAccountPath(args);
  initAdmin(keyPath);
  const db = admin.firestore();

  console.log(`Admin UIDs: ${ADMIN_UIDS.join(', ')}`);
  console.log(`Mode: ${execute ? 'EXECUTE' : 'DRY RUN'}\n`);

  console.log('1) Admin user docs');
  await cleanAdminUsers(db, execute);

  console.log('\n2) Leaderboard cycles');
  const touched = await cleanCycles(db, execute);

  console.log('\n3) prize_pool winners snapshots');
  await reportPrizePoolWinners(db);

  if (!execute) {
    console.log('\nDRY RUN — nothing written. Re-run with --execute to apply.');
  } else {
    console.log(`\nDONE. documents written/deleted: ${touched}`);
  }
}

main().catch((e) => {
  console.error(`FATAL: ${e.message}`);
  process.exit(1);
});
