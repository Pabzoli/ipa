// scripts/trim_podium_pool.js
// Takes the podium pool prospects OFF the board and renames them from the
// gamer-tag pool, so only the top-3 podium bots ever appear.
//
// Usage:
//   node scripts/trim_podium_pool.js            (LIST only, deletes nothing)
//   node scripts/trim_podium_pool.js --execute (rename + scrub + empty pool)
//
// Auth: Application Default Credentials:
//   $env:GOOGLE_APPLICATION_CREDENTIALS="$env:APPDATA\gcloud\legacy_credentials\<you>\adc.json"
//
// WHAT IT DOES (--execute):
//   - Renames every house_config/global.accountPool uid to an unused gamer tag
//     (same pool the engine uses; skips uids already carrying a pool name).
//   - Scrubs this week's board presence for those uids (clears
//     leaderboardEntryWeekId, zeroes weeklyPoints) so they vanish immediately
//     instead of sitting frozen until Monday.
//   - Sets house_config/global.accountPool = [] so the engine falls back to
//     the 3 permanent podium accounts. The prospect accounts themselves are
//     left intact (off-board, dormant).
//
// SAFETY: list by default; --execute only. Never touches house_config/global.accounts.
// Local admin script. NEVER deployed to Firebase.
'use strict';

const path = require('path');
const fs = require('fs');
const admin = require('firebase-admin');

const PROJECT_ID = 'anime-quiz-1ab1b';

// Same gamer-tag pool as functions/index.js HOUSE_NAME_POOL_BASE.
const HOUSE_NAME_POOL_BASE = [
  'Velo', 'Krypt', 'Sync', 'Aero', 'Xenon', 'Raze', 'Lethal', 'Apex', 'Void',
  'Blitz', 'Nova', 'Zephyr', 'Onyx', 'Pixel', 'Turbo', 'Vex', 'Jolt', 'Fable',
  'Drift', 'Havoc', 'Ozone', 'Flux', 'Nyx', 'Rogue', 'Sable', 'Talon',
  'Nx_Clutch', 'Fz_Echo', 'Vn_Chrono', 'Op_Slayer', 'Rv_Ghost', 'Tx_Reaper',
  'Alpha_1', 'Sc_Scope', 'Qz_Fury', 'Zx_Vandal', 'Ky_Strike', 'Wx_Havoc',
  'Dx_Onyx', 'Jx_Mirage', 'Px_Nova', 'Vx_Pulse',
  'Phantom', 'Specter', 'Viper', 'ShadowOps', 'DoomBringer', 'Grim',
  'Nightmare', 'Shinigami', 'Wraith', 'Revenant', 'Oblivion', 'Dread',
  'Hex', 'Noctis', 'Umbra', 'Vandal',
  'Kenji', 'Akira', 'Zenith', 'Ryu', 'Kage', 'Sora', 'Yami', 'Ronin',
  'Gojo', 'Itachi', 'Eren', 'Mikasa', 'Tanjiro', 'Killua', 'Madara',
  'Zoro', 'Levi', 'Nezuko', 'Sasuke', 'Obito',
  'LagosKing', 'NaijaStar', 'UnilagBoy', 'IbadanFinest', 'AbujaPlug',
  'PHCityBoy', 'BeninVibes', 'JosChill', 'KanoAce', 'EnuguFlame',
  'OwerriHeat', 'AkureWolf', 'IlorinAce', 'CalabarRay', 'SokotoStorm',
  'QuietStorm', 'Lowkey', 'NoCap', 'Steady', 'ClutchGod', 'OTG',
  'DayOne', 'LastPick', 'FirstBlood', 'GGOnly', 'TryHard', 'CasualX',
  'NightOwl', 'EarlyBird', 'LunchBreak', 'NightShift', 'WeekendWar',
  'FormGuy', 'VibesOnly', 'OnGod', 'Sheesh', 'BabaGod', 'Alhaji',
  'MamaPut', 'SuyaSpice', 'JollofKing', 'DanfoDrift', 'OkadaRun',
  'TrophyHunt', 'PointChase', 'RankUp', 'EloHell', 'Smurf', 'MainChar',
  'SideQuest', 'BossFight', 'Speedrun', 'NoScope', 'Headshot', 'FragOut',
];
const HOUSE_NAME_POOL = (() => {
  const out = [];
  const seen = new Set();
  for (const n of HOUSE_NAME_POOL_BASE) {
    const k = String(n).toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(n);
  }
  return out;
})();

function currentWeekId() {
  const now = new Date();
  const utcNow = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const day = utcNow.getUTCDay();
  const diff = day === 0 ? -6 : 1 - day;
  const monday = new Date(utcNow);
  monday.setUTCDate(utcNow.getUTCDate() + diff);
  return monday.toISOString().slice(0, 10);
}

function usernameKey(raw) {
  let s = String(raw).trim();
  try { s = s.normalize('NFKC'); } catch (_) { /* keep raw */ }
  return s.toLowerCase();
}

async function main() {
  const execute = process.argv.includes('--execute');
  if (!process.env.GOOGLE_APPLICATION_CREDENTIALS || !fs.existsSync(process.env.GOOGLE_APPLICATION_CREDENTIALS)) {
    throw new Error('Missing credentials. Set GOOGLE_APPLICATION_CREDENTIALS (see header).');
  }
  admin.initializeApp({ projectId: PROJECT_ID });
  const db = admin.firestore();
  const weekId = currentWeekId();
  console.log(`weekId=${weekId}`);

  const gref = db.collection('house_config').doc('global');
  const gsnap = await gref.get();
  const g = gsnap.exists ? (gsnap.data() || {}) : {};
  const accounts = (Array.isArray(g.accounts) ? g.accounts : []).map(String);
  const pool = (Array.isArray(g.accountPool) ? g.accountPool : []).map(String);
  // Prospects = pool members that are NOT permanent podium accounts.
  // The 3 accounts are never renamed or scrubbed, only dropped from the pool list.
  const accountSet = new Set(accounts);
  const prospects = pool.filter((uid) => !accountSet.has(uid));

  console.log(`Podium accounts (${accounts.length}, untouched):`);
  for (const uid of accounts) {
    const s = await db.collection('users').doc(uid).get().catch(() => null);
    const d = s && s.exists ? (s.data() || {}) : {};
    console.log(`  KEEP uid=${uid} username=${d.username || ''} weeklyPoints=${Number(d.weeklyPoints) || 0}`);
  }

  console.log(`Pool prospects (${prospects.length}, off-board + rename):`);
  const usedNames = new Set();
  const allUsers = await db.collection('users').select().get().catch(() => null);
  // Collect taken username keys via the usernames collection (authoritative).
  const takenKeys = new Set();
  const nameDocs = await db.collection('usernames').select().get().catch(() => null);
  for (const d of (nameDocs?.docs || [])) takenKeys.add(d.id);
  void allUsers;

  const infos = [];
  for (const uid of prospects) {
    const s = await db.collection('users').doc(uid).get().catch(() => null);
    const d = s && s.exists ? (s.data() || {}) : {};
    const info = {
      uid,
      exists: !!(s && s.exists),
      username: d.username || '',
      weeklyPoints: Number(d.weeklyPoints) || 0,
      entryWeek: d.leaderboardEntryWeekId || '',
    };
    infos.push(info);
    console.log(
      `  POOL uid=${uid} username=${info.username} weeklyPoints=${info.weeklyPoints} ` +
      `entryWeek=${info.entryWeek} onBoard=${info.entryWeek === weekId || info.weeklyPoints !== 0}`
    );
  }

  if (!execute) {
    console.log('DRY RUN — nothing changed. Re-run with --execute.');
    return;
  }
  if (!prospects.length) {
    console.log('No prospects to trim.');
    // Still ensure the pool holds only the permanent accounts... actually the
    // goal is top-3 only, so empty it regardless.
  }

  // 1. Rename prospects to unused gamer tags (skip ones already pool-styled).
  let renamed = 0;
  for (const info of infos) {
    if (!info.exists) continue;
    if (HOUSE_NAME_POOL.includes(info.username)) {
      console.log(`  skip rename ${info.uid}: already pool-styled (${info.username})`);
      continue;
    }
    let pick = '';
    for (const cand of HOUSE_NAME_POOL) {
      const k = usernameKey(cand);
      if (takenKeys.has(k)) continue;
      if (cand === info.username) continue;
      pick = cand;
      break;
    }
    if (!pick) {
      console.log(`  !! no free pool name for ${info.uid}, leaving as ${info.username}`);
      continue;
    }
    const oldKey = info.username ? usernameKey(info.username) : '';
    await db.runTransaction(async (tx) => {
      if (oldKey) {
        const oldSnap = await tx.get(db.collection('usernames').doc(oldKey));
        if (oldSnap.exists && oldSnap.data()?.uid === info.uid) {
          tx.delete(db.collection('usernames').doc(oldKey));
        }
      }
      tx.set(db.collection('usernames').doc(usernameKey(pick)), { uid: info.uid, username: pick });
      tx.set(db.collection('users').doc(info.uid), { username: pick }, { merge: true });
    });
    takenKeys.delete(oldKey);
    takenKeys.add(usernameKey(pick));
    try {
      const links = await db.collectionGroup('friendLinks').where('otherUid', '==', info.uid).limit(500).get();
      if (!links.empty) {
        const batch = db.batch();
        for (const doc of links.docs) batch.set(doc.ref, { username: pick }, { merge: true });
        await batch.commit();
      }
    } catch (e) {
      console.log(`  friendLinks refresh skipped for ${info.uid}: ${e.message}`);
    }
    console.log(`  renamed ${info.uid}: ${info.username} -> ${pick}`);
    renamed++;
  }

  // 2. Scrub this week's board presence so they vanish now, not Monday.
  let scrubbed = 0;
  for (const info of infos) {
    if (!info.exists) continue;
    const s = await db.collection('users').doc(info.uid).get();
    const d = s.data() || {};
    if ((d.leaderboardEntryWeekId || '') !== weekId && (Number(d.weeklyPoints) || 0) === 0) continue;
    await db.collection('users').doc(info.uid).set({
      leaderboardEntryWeekId: admin.firestore.FieldValue.delete(),
      weeklyPoints: 0,
      wpEarnedToday: 0,
    }, { merge: true });
    console.log(`  scrubbed board presence: ${info.uid} (was ${Number(d.weeklyPoints) || 0} WP)`);
    scrubbed++;
  }

  // 3. Empty the pool so the engine falls back to the 3 podium accounts.
  await gref.set({
    accountPool: [],
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedBy: 'trim_podium_pool',
  }, { merge: true });
  console.log(`Pool emptied (${prospects.length} prospect(s) retired, ${accounts.length} podium kept).`);
  console.log(`Retired prospect uids (for record): ${prospects.join(', ')}`);
  console.log(`DONE. renamed=${renamed} scrubbed=${scrubbed}.`);
}

main().catch((e) => {
  console.error(`FATAL: ${e.message}`);
  process.exit(1);
});
