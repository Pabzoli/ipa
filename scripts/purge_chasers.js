// scripts/purge_chasers.js
// Deletes every chaser bot so only the top-3 podium bots remain.
//
// Usage:
//   node scripts/purge_chasers.js            (LIST only: prints podium + chaser inventory, deletes nothing)
//   node scripts/purge_chasers.js --execute  (deletes everything listed, except protected podium UIDs)
//   node scripts/purge_chasers.js --auth-only --uids=<csv>
//     (deletes Firebase Auth users only; for retrying auth deletion when the
//     main run's Firestore purge already succeeded. Requires
//     GOOGLE_CLOUD_QUOTA_PROJECT to be set — see header.)
//
// Auth: Application Default Credentials:
//   $env:GOOGLE_APPLICATION_CREDENTIALS="$env:APPDATA\gcloud\legacy_credentials\<you>\adc.json"
//
// WHAT IT DELETES (chasers + chaserPool UIDs only, never podium):
//   - Firebase Auth user
//   - users/{uid} document tree (recursive: matches, transactions, friendLinks, receipts, ...)
//   - house_state/{uid}
//   - friendCodes docs pointing at the uid
//   - usernames claims pointing at the uid
//   - friendships pairs involving the uid (+ peer friendLinks entry, peer friendCount -1)
//   - rivalries docs involving the uid
//   - OPEN challenges involving the uid, settled with refunds to the REAL peer first:
//       * chaser invited but never joined  -> declined (creator refunded, mirrors _houseDeclineTx)
//       * chaser created, nobody joined    -> expired_refunded (only the chaser staked; nothing real at risk)
//       * in-play (joined/submitted)        -> both stakes refunded (mirrors expiredChallengeRefund), expired_refunded
//   - house_config/global: chasers=[], chaserPool=[], chaser* keys removed,
//     personas entries for deleted uids removed. Podium keys untouched.
//
// LEFT INTACT (audit trail, like purge_users.js):
//   - completed / already-settled challenge docs (real players' history)
//   - leaderboardCycles snapshots
//
// SAFETY:
//   - List mode by default. Deletion ONLY with --execute.
//   - Targets = (chasers + chaserPool) MINUS (accounts + accountPool).
//     Podium UIDs can never be deleted by this script, even if misconfigured.
//   - Prints only non-sensitive fields. Emails/passwords are never printed.
//   - Local admin script. NEVER deployed to Firebase.
'use strict';

const path = require('path');
const fs = require('fs');
const admin = require('firebase-admin');

const PROJECT_ID = 'anime-quiz-1ab1b';
const OPEN_STATUSES = new Set([
  'waiting', 'opponent_joined', 'creator_submitted', 'opponent_submitted',
]);
const SETTLED_STATUSES = new Set([
  'completed', 'declined', 'expired', 'expired_refunded',
]);

function parseArgs(argv) {
  const args = {};
  for (const raw of argv) {
    if (!raw.startsWith('--')) continue;
    const eq = raw.indexOf('=');
    if (eq === -1) args[raw.slice(2)] = true;
    else args[raw.slice(2, eq)] = raw.slice(eq + 1);
  }
  return args;
}

function initAdmin() {
  const keyPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  if (!keyPath || !fs.existsSync(keyPath)) {
    throw new Error(
      'Missing credentials. Set GOOGLE_APPLICATION_CREDENTIALS to your ' +
      'gcloud application-default adc.json (see header).'
    );
  }
  admin.initializeApp({ projectId: PROJECT_ID });
}

async function recursiveDeleteDoc(db, docRef) {
  if (typeof db.recursiveDelete === 'function') {
    await db.recursiveDelete(docRef);
    return;
  }
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

async function loadHouseConfig(db) {
  const snap = await db.collection('house_config').doc('global').get();
  const d = snap.exists ? (snap.data() || {}) : {};
  const str = (v) => (Array.isArray(v) ? v.map(String).filter(Boolean) : []);
  return {
    raw: d,
    accounts: str(d.accounts).slice(0, 3),
    accountPool: str(d.accountPool),
    chasers: str(d.chasers),
    chaserPool: str(d.chaserPool),
    personas: d.personas && typeof d.personas === 'object' ? d.personas : {},
  };
}

async function describeUser(db, uid) {
  try {
    const snap = await db.collection('users').doc(uid).get();
    if (!snap.exists) return { uid, exists: false };
    const d = snap.data() || {};
    return {
      uid,
      exists: true,
      username: d.username || '',
      weeklyPoints: Number(d.weeklyPoints) || 0,
      entryWeek: d.leaderboardEntryWeekId || '',
    };
  } catch (e) {
    return { uid, exists: false, error: e.message };
  }
}

async function countRelated(db, uid) {
  const [asCreator, asOpponent, pairsA, pairsB, rivalsA, rivalsB, state] =
    await Promise.all([
      db.collection('challenges').where('creatorUid', '==', uid).limit(100).get().catch(() => null),
      db.collection('challenges').where('opponentUid', '==', uid).limit(100).get().catch(() => null),
      db.collection('friendships').where('aUid', '==', uid).limit(100).get().catch(() => null),
      db.collection('friendships').where('bUid', '==', uid).limit(100).get().catch(() => null),
      db.collection('rivalries').where('aUid', '==', uid).limit(100).get().catch(() => null),
      db.collection('rivalries').where('bUid', '==', uid).limit(100).get().catch(() => null),
      db.collection('house_state').doc(uid).get().catch(() => null),
    ]);
  const open = [...(asCreator?.docs || []), ...(asOpponent?.docs || [])].filter((d) => {
    const c = d.data() || {};
    return c.resolved !== true && !SETTLED_STATUSES.has(c.status);
  }).length;
  return {
    openChallenges: open,
    friendships: (pairsA?.size || 0) + (pairsB?.size || 0),
    rivalries: (rivalsA?.size || 0) + (rivalsB?.size || 0),
    hasHouseState: !!(state && state.exists),
  };
}

// Settle one OPEN challenge involving a chaser being deleted. Refunds go to
// the REAL peer; the chaser doc still exists at this point (deleted later).
async function settleOpenChallenge(db, doc) {
  const c = doc.data() || {};
  const stakeAmt = Number(c.stakeAmount) || 0;
  const wpStake = Number(c.wpStake) || 0;
  const creatorUid = String(c.creatorUid || '');
  const opponentUid = String(c.opponentUid || '');
  const now = admin.firestore.FieldValue.serverTimestamp();

  const refund = (tx, userRef, uData, amt, wps) => {
    if (amt > 0) {
      tx.update(userRef, { animeCoins: admin.firestore.FieldValue.increment(amt) });
      tx.set(userRef.collection('coinTransactions').doc(), {
        type: 'refund_challenge_stake', delta: amt,
        balanceAfter: (Number(uData.animeCoins) || 0) + amt,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    if (wps > 0) {
      tx.update(userRef, { weeklyPoints: admin.firestore.FieldValue.increment(wps) });
      tx.set(userRef.collection('wpTransactions').doc(), {
        type: 'refund_challenge_stake', delta: wps,
        balanceAfter: (Number(uData.weeklyPoints) || 0) + wps,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  };

  // Case 1: chaser is the invited opponent who never joined -> decline,
  // refund the creator (mirrors _houseDeclineTx).
  if (opponentUid && !c.joinedAt && (c.status === 'waiting' || c.status === 'creator_submitted')) {
    const creatorRef = db.collection('users').doc(creatorUid);
    await db.runTransaction(async (tx) => {
      const [freshSnap, creatorSnap] = await Promise.all([tx.get(doc.ref), tx.get(creatorRef)]);
      if (!freshSnap.exists || freshSnap.data()?.status !== c.status) return;
      tx.update(doc.ref, { status: 'declined', declinedAt: now, declinedBy: opponentUid });
      refund(tx, creatorRef, creatorSnap.exists ? creatorSnap.data() : {}, stakeAmt, wpStake);
    });
    return 'declined-refunded-creator';
  }

  // Case 2: chaser created it and nobody joined -> only the chaser staked,
  // nothing real at risk. Close it out.
  if (!c.joinedAt && c.status === 'waiting' && !opponentUid) {
    await doc.ref.set({ status: 'expired_refunded', resolved: true }, { merge: true });
    return 'expired-unjoined';
  }

  // Case 3: in-play (joined and/or submitted) -> refund both stakes like the
  // hourly expiredChallengeRefund sweep, then close.
  if (OPEN_STATUSES.has(c.status)) {
    const creatorRef = db.collection('users').doc(creatorUid);
    const oppRef = opponentUid ? db.collection('users').doc(opponentUid) : null;
    await db.runTransaction(async (tx) => {
      const gets = [tx.get(doc.ref), tx.get(creatorRef)];
      if (oppRef) gets.push(tx.get(oppRef));
      const [freshSnap, creatorSnap, oppSnap] = await Promise.all(gets);
      if (!freshSnap.exists || !OPEN_STATUSES.has(freshSnap.data()?.status)) return;
      tx.update(doc.ref, { status: 'expired_refunded', resolved: true });
      refund(tx, creatorRef, creatorSnap.exists ? creatorSnap.data() : {}, stakeAmt, wpStake);
      if (oppRef && c.joinedAt && opponentUid && opponentUid !== 'ghost') {
        refund(tx, oppRef, oppSnap && oppSnap.exists ? oppSnap.data() : {}, stakeAmt, wpStake);
      }
    });
    return 'refunded-both-expired';
  }

  return 'skipped';
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const execute = args.execute === true;
  initAdmin();

  // Auth-only retry mode: config lists are already emptied, so the uids to
  // delete come from --uids. Needs GOOGLE_CLOUD_QUOTA_PROJECT set (user ADC
  // has no quota project by default for identitytoolkit).
  if (args['auth-only'] === true) {
    const uids = String(args.uids || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!uids.length) throw new Error('Pass --uids=<csv> with --auth-only.');
    try {
      const res = await admin.auth().deleteUsers(uids);
      console.log(`Auth deleted: ${res.successCount}, failed: ${res.failureCount}`);
      for (const e of res.errors || []) console.log(`  auth delete error: ${e.error}`);
    } catch (e) {
      console.log(`Auth batch delete failed (${e.message}); trying one by one.`);
      let n = 0;
      for (const uid of uids) {
        try { await admin.auth().deleteUser(uid); n++; }
        catch (err) { console.log(`  auth delete ${uid} failed: ${err.message}`); }
      }
      console.log(`Auth deleted one-by-one: ${n}/${uids.length}.`);
    }
    return;
  }

  const db = admin.firestore();

  const house = await loadHouseConfig(db);
  const podium = new Set([...house.accounts, ...house.accountPool]);
  const chaserIds = new Set([...house.chasers, ...house.chaserPool]);
  const targets = [...chaserIds].filter((uid) => !podium.has(uid));
  const protectedOverlap = [...chaserIds].filter((uid) => podium.has(uid));

  console.log(`Podium (PROTECTED, never touched):`);
  for (const uid of podium) {
    const info = await describeUser(db, uid);
    console.log(`  KEEP uid=${uid} username=${info.username || ''} weeklyPoints=${info.weeklyPoints ?? ''}`);
  }
  if (protectedOverlap.length) {
    console.log(`  (!!) ${protectedOverlap.length} uid(s) appear in BOTH podium and chaser lists — kept as podium.`);
  }

  console.log(`Chaser targets (${targets.length}):`);
  const counts = {};
  for (const uid of targets) {
    const [info, rel] = await Promise.all([describeUser(db, uid), countRelated(db, uid)]);
    counts[uid] = rel;
    console.log(
      `  DEL uid=${uid} username=${info.username || ''} exists=${info.exists} ` +
      `weeklyPoints=${info.weeklyPoints ?? ''} entryWeek=${info.entryWeek || ''} ` +
      `openChallenges=${rel.openChallenges} friendships=${rel.friendships} ` +
      `rivalries=${rel.rivalries} houseState=${rel.hasHouseState}`
    );
  }

  if (!execute) {
    console.log('DRY RUN — nothing deleted. Re-run with --execute to delete.');
    return;
  }
  if (!targets.length) {
    console.log('Nothing to delete.');
    return;
  }

  // 0. Final guard: re-read config and re-assert podium protection.
  const fresh = await loadHouseConfig(db);
  const freshPodium = new Set([...fresh.accounts, ...fresh.accountPool]);
  const finalTargets = targets.filter((uid) => ![...freshPodium].includes(uid));
  if (finalTargets.length !== targets.length) {
    throw new Error('Podium set changed mid-run — aborting.');
  }

  // 1. Settle open challenges BEFORE deleting user docs (refunds need them).
  let settled = 0;
  for (const uid of finalTargets) {
    const [asCreator, asOpponent] = await Promise.all([
      db.collection('challenges').where('creatorUid', '==', uid).limit(100).get(),
      db.collection('challenges').where('opponentUid', '==', uid).limit(100).get(),
    ]);
    for (const d of [...asCreator.docs, ...asOpponent.docs]) {
      const c = d.data() || {};
      if (c.resolved === true || SETTLED_STATUSES.has(c.status)) continue;
      const how = await settleOpenChallenge(db, d);
      settled++;
      console.log(`  challenge ${d.id}: ${how}`);
    }
  }
  console.log(`Settled ${settled} open challenge(s).`);

  // 2. Friendships: delete pairs, clear peer links, decrement peer counts.
  let pairsDeleted = 0;
  for (const uid of finalTargets) {
    const [pairsA, pairsB] = await Promise.all([
      db.collection('friendships').where('aUid', '==', uid).get(),
      db.collection('friendships').where('bUid', '==', uid).get(),
    ]);
    for (const pdoc of [...pairsA.docs, ...pairsB.docs]) {
      const p = pdoc.data() || {};
      const peer = String(p.aUid) === uid ? String(p.bUid || '') : String(p.aUid || '');
      await pdoc.ref.delete();
      pairsDeleted++;
      if (peer && !finalTargets.includes(peer)) {
        const peerRef = db.collection('users').doc(peer);
        await peerRef.collection('friendLinks').doc(uid).delete().catch(() => {});
        await peerRef.set(
          { friendCount: admin.firestore.FieldValue.increment(-1) },
          { merge: true }
        ).catch(() => {});
      }
    }
  }
  console.log(`Deleted ${pairsDeleted} friendship pair(s).`);

  // 3. Rivalries involving deleted chasers.
  let rivalriesDeleted = 0;
  for (const uid of finalTargets) {
    const [rA, rB] = await Promise.all([
      db.collection('rivalries').where('aUid', '==', uid).get(),
      db.collection('rivalries').where('bUid', '==', uid).get(),
    ]);
    for (const rdoc of [...rA.docs, ...rB.docs]) {
      await rdoc.ref.delete().catch(() => {});
      rivalriesDeleted++;
    }
  }
  console.log(`Deleted ${rivalriesDeleted} rivalr(ies).`);

  // 4. friendCodes + usernames claims pointing at deleted chasers.
  let codesDeleted = 0;
  let namesDeleted = 0;
  for (const uid of finalTargets) {
    const [codes, names] = await Promise.all([
      db.collection('friendCodes').where('uid', '==', uid).get(),
      db.collection('usernames').where('uid', '==', uid).get(),
    ]);
    for (const d of codes.docs) { await d.ref.delete().catch(() => {}); codesDeleted++; }
    for (const d of names.docs) { await d.ref.delete().catch(() => {}); namesDeleted++; }
  }
  console.log(`Deleted ${codesDeleted} friend code(s), ${namesDeleted} username claim(s).`);

  // 5. house_state docs.
  for (const uid of finalTargets) {
    await db.collection('house_state').doc(uid).delete().catch(() => {});
  }

  // 6. users/{uid} trees.
  let docsDeleted = 0;
  for (const uid of finalTargets) {
    const snap = await db.collection('users').doc(uid).get().catch(() => null);
    if (!snap || !snap.exists) continue;
    await recursiveDeleteDoc(db, db.collection('users').doc(uid));
    docsDeleted++;
    console.log(`  doc tree deleted: users/${uid}`);
  }

  // 7. Auth users.
  let authDeleted = 0;
  try {
    const res = await admin.auth().deleteUsers(finalTargets);
    authDeleted = res.successCount;
    console.log(`Auth deleted: ${authDeleted}, failed: ${res.failureCount}`);
    for (const e of res.errors || []) console.log(`  auth delete error: ${e.error}`);
  } catch (e) {
    console.log(`Auth batch delete failed (${e.message}); trying one by one.`);
    for (const uid of finalTargets) {
      try { await admin.auth().deleteUser(uid); authDeleted++; }
      catch (err) { console.log(`  auth delete ${uid} failed: ${err.message}`); }
    }
  }

  // 8. Config cleanup: empty chaser lists/keys, drop their personas.
  const personas = { ...(fresh.personas || {}) };
  for (const uid of finalTargets) delete personas[uid];
  const cfgPatch = {
    chasers: [],
    chaserPool: [],
    chaserEnabled: admin.firestore.FieldValue.delete(),
    chaserDailyMax: admin.firestore.FieldValue.delete(),
    chaserGap: admin.firestore.FieldValue.delete(),
    chaserMax: admin.firestore.FieldValue.delete(),
    chaserGoalMin: admin.firestore.FieldValue.delete(),
    chaserGoalMax: admin.firestore.FieldValue.delete(),
    personas,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedBy: 'purge_chasers',
  };
  await db.collection('house_config').doc('global').set(cfgPatch, { merge: true });
  console.log('Config cleaned: chasers/chaserPool emptied, chaser keys removed.');

  console.log(
    `DONE. settled=${settled} pairs=${pairsDeleted} rivalries=${rivalriesDeleted} ` +
    `codes=${codesDeleted} names=${namesDeleted} docTrees=${docsDeleted} auth=${authDeleted}.`
  );
}

main().catch((e) => {
  console.error(`FATAL: ${e.message}`);
  process.exit(1);
});
