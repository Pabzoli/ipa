#!/usr/bin/env node
/**
 * Backfill the referral-cashout qualification marker.
 *
 * A referral qualifies for the NGN 5,000 cashout when the invitee signed up
 * with the referrer's code AND activated a leaderboard-entry code on that
 * account. New activations write the marker in redeemCode; this script repairs
 * accounts that activated BEFORE that marker shipped (or whose best-effort
 * marker write failed).
 *
 * Target: users/{inviter}/referrals/{inviteeUid}
 *   leaderboardEntryPurchased     true
 *   leaderboardEntryWeekId        the invitee's current entry week
 *   leaderboardEntryBuyerEmail    lowercased buyer email, when known
 *   leaderboardEntryPurchasedAt   server timestamp
 *
 * SOURCE OF TRUTH
 *   Only the invitee's own `users/{uid}.leaderboardEntryWeekId` is read. The
 *   reward itself is still re-checked by the claimReferralCashout callable, so
 *   this script can never mint a claim — it only saves the next claim call from
 *   re-reading invitee docs.
 *
 * SAFETY
 *   Dry run by default. Writes only with --execute.
 *   Idempotent: already-marked rows are skipped, never reset.
 *
 * USAGE
 *   node scripts/backfill_referral_cashout_markers.js            (dry run)
 *   node scripts/backfill_referral_cashout_markers.js --execute  (write)
 *   node scripts/backfill_referral_cashout_markers.js --execute --key=...
 */

'use strict';

const path = require('path');
const fs = require('fs');

const PROJECT_ID = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', '.firebaserc'), 'utf8')
).projects.default;

const PAGE = 400;

function parseArgs(argv) {
  const opts = { execute: false, key: null, limit: null };
  for (const raw of argv) {
    const m = /^--([^=]+)(?:=(.*))?$/.exec(raw);
    if (!m) continue;
    const [, flag, value] = m;
    if (flag === 'execute') opts.execute = true;
    else if (flag === 'key') opts.key = value;
    else if (flag === 'limit') opts.limit = Number(value);
    else throw new Error(`Unknown flag --${flag}`);
  }
  return opts;
}

function requireFromFunctions(subpath) {
  return require(require.resolve(subpath, {
    paths: [path.join(__dirname, '..', 'functions')],
  }));
}

function resolveServiceAccountPath(opts) {
  if (opts.key) return opts.key;
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

function loadKey(keyPath) {
  if (!keyPath || !fs.existsSync(keyPath)) {
    throw new Error(
      'Service account key not found. Pass --key=/path/to/key.json, set ' +
      'GOOGLE_APPLICATION_CREDENTIALS, or write the path into ' +
      'scripts/.service-account-key-path'
    );
  }
  return JSON.parse(fs.readFileSync(keyPath, 'utf8'));
}

async function resolveReferrerUid(db, raw) {
  const value = typeof raw === 'string' ? raw.trim() : '';
  if (!value || value.includes('/')) return null;

  const byUid = await db.collection('users').doc(value).get();
  if (byUid.exists) return value;
  if (value.length !== 6) return null;

  const codeSnap = await db.collection('referralCodes')
    .doc(value.toUpperCase()).get();
  const uid = codeSnap.exists ? (codeSnap.data() || {}).uid : null;
  if (!uid) return null;
  const userSnap = await db.collection('users').doc(uid).get();
  return userSnap.exists ? uid : null;
}

(async () => {
  const opts = parseArgs(process.argv.slice(2));

  console.log('project  :', PROJECT_ID);
  console.log('mode     :', opts.execute ? 'EXECUTE (writes)' : 'DRY RUN (no writes)');
  console.log('source   : users.leaderboardEntryWeekId (invitee accounts)');

  if (!opts.execute) {
    console.log('\nDRY RUN - nothing written. Re-run with --execute to apply.');
    // A dry run still needs the database to count candidates, so warn instead
    // of silently doing nothing when credentials are absent.
  }

  const { initializeApp, cert } = requireFromFunctions('firebase-admin/app');
  const { getFirestore, FieldValue } = requireFromFunctions('firebase-admin/firestore');

  const serviceAccount = loadKey(resolveServiceAccountPath(opts));
  const app = initializeApp({
    credential: cert(serviceAccount),
    projectId: PROJECT_ID,
  });
  const db = getFirestore(app);

  let scanned = 0;
  let candidates = 0;
  let marked = 0;
  let missingRecord = 0;
  let alreadyMarked = 0;
  let sameUser = 0;
  let cursor = null;

  for (;;) {
    let query = db.collection('users')
      .where('leaderboardEntryWeekId', '>', '')
      .orderBy('leaderboardEntryWeekId')
      .limit(PAGE);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) break;
    cursor = snap.docs[snap.docs.length - 1];

    for (const doc of snap.docs) {
      scanned++;
      if (opts.limit && scanned > opts.limit) break;

      const invitee = doc.data() || {};
      const weekId = typeof invitee.leaderboardEntryWeekId === 'string'
        ? invitee.leaderboardEntryWeekId
        : '';
      if (!weekId) continue;

      const referrerUid = await resolveReferrerUid(db, invitee.referredBy);
      if (!referrerUid) continue;
      if (referrerUid === doc.id) {
        sameUser++;
        continue;
      }

      const referralRef = db.collection('users').doc(referrerUid)
        .collection('referrals').doc(doc.id);
      const referralSnap = await referralRef.get();
      if (!referralSnap.exists) {
        missingRecord++;
        continue;
      }
      if (referralSnap.data()?.leaderboardEntryPurchased === true) {
        alreadyMarked++;
        continue;
      }

      candidates++;
      const buyerEmail = typeof invitee.leaderboardEntryEmail === 'string'
        ? invitee.leaderboardEntryEmail.trim().toLowerCase()
        : '';
      console.log(
        `  ${opts.execute ? 'MARK' : 'would mark'} ` +
        `users/${referrerUid}/referrals/${doc.id} week=${weekId}` +
        (buyerEmail ? ` buyer=${buyerEmail}` : '')
      );

      if (opts.execute) {
        await referralRef.set({
          leaderboardEntryPurchased: true,
          leaderboardEntryWeekId: weekId,
          leaderboardEntryBuyerEmail: buyerEmail || null,
          leaderboardEntryPurchasedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        marked++;
      }
    }

    if (opts.limit && scanned >= opts.limit) break;
    if (snap.size < PAGE) break;
  }

  console.log('\nscanned           :', scanned);
  console.log('qualifying        :', candidates);
  console.log(opts.execute ? 'marked            :' : 'would mark       :',
    opts.execute ? marked : candidates);
  console.log('already marked    :', alreadyMarked);
  console.log('no referral record:', missingRecord);
  console.log('self-referrals    :', sameUser);

  if (!opts.execute) {
    console.log('\nDRY RUN - nothing written. Re-run with --execute to apply.');
  }
})().catch((e) => {
  console.error('\n' + (e && e.message ? e.message : e));
  process.exitCode = 1;
});
