// scripts/rename_house_to_pool.js
// Renames any house bot whose username is NOT in HOUSE_NAME_POOL_BASE to the
// first unused pool tag. Same swap semantics as _houseRotateNames in
// functions/index.js (usernames doc swap in a transaction + friendLinks
// refresh), but deterministic instead of random so every bot lands in-pool.
// Usage: node scripts/rename_house_to_pool.js
const admin = require('firebase-admin');

admin.initializeApp({ projectId: 'anime-quiz-1ab1b' });
const db = admin.firestore();

const POOL_BASE = [
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

const POOL = (() => {
  const out = [];
  const seen = new Set();
  for (const n of POOL_BASE) {
    const k = String(n).toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(n);
  }
  return out;
})();

const UIDS = [
  'ZVuA2tYZPvQtF7jq2U8xuQHEg6p2',
  'f4ScrlqjCvNhOGgpPDNPr8eg2sI2',
  'kRGMr2AszFhMvdvkltLH7iTD2OK2',
  'C8pyZQWzMQScvT1BuZvRNO1Goo52',
  '465CW8sr5cYsoDuHLhh3wqZt8782',
  'TV0iVOfYnCVdirOJMgvPUlAyobz1',
  'J2JLETQ2ECSmkyvy3IDxtLyFmAS2',
  'E24vazIahLQRpRkQqyTnWLyHcqi2',
];

const key = (s) => String(s).trim().toLowerCase();
const poolKeys = new Set(POOL.map((n) => key(n)));

async function main() {
  const usedSnap = await db.collection('usernames').get().catch(() => null);
  const used = new Set((usedSnap?.docs || []).map((d) => String(d.id).toLowerCase()));
  const poolCursor = { i: 0 };
  const nextFree = () => {
    while (poolCursor.i < POOL.length) {
      const cand = POOL[poolCursor.i++];
      if (!used.has(key(cand))) {
        used.add(key(cand));
        return cand;
      }
    }
    return null;
  };

  const mapping = [];
  for (const uid of UIDS) {
    const meSnap = await db.collection('users').doc(uid).get().catch(() => null);
    const cur = meSnap?.exists ? String(meSnap.data()?.username || '') : '';
    if (cur && poolKeys.has(key(cur))) {
      mapping.push({ uid, from: cur, to: cur, kept: true });
      continue;
    }
    const pick = nextFree();
    if (!pick) {
      mapping.push({ uid, from: cur, to: null, error: 'pool_exhausted' });
      continue;
    }
    const oldKey = cur ? key(cur) : '';
    const newKey = key(pick);
    await db.runTransaction(async (tx) => {
      if (oldKey) {
        const oldSnap = await tx.get(db.collection('usernames').doc(oldKey));
        if (oldSnap.exists && oldSnap.data()?.uid === uid) tx.delete(db.collection('usernames').doc(oldKey));
      }
      tx.set(db.collection('usernames').doc(newKey), { uid, username: pick });
      tx.set(db.collection('users').doc(uid), { username: pick }, { merge: true });
    });
    used.delete(oldKey);
    used.add(newKey);
    try {
      const links = await db.collectionGroup('friendLinks').where('otherUid', '==', uid).limit(500).get();
      if (!links.empty) {
        const batch = db.batch();
        for (const doc of links.docs) batch.set(doc.ref, { username: pick }, { merge: true });
        await batch.commit();
      }
    } catch (e) {
      console.error(`friendLinks refresh skipped for ${uid.slice(0, 6)}: ${e.message || e}`);
    }
    mapping.push({ uid, from: cur, to: pick, kept: false });
  }
  console.log(JSON.stringify({ mapping }, null, 2));
}

main().then(() => process.exit(0)).catch((e) => { console.error(`FAILED: ${e.message}`); process.exit(1); });
