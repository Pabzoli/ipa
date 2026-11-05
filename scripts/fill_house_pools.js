// scripts/fill_house_pools.js
// Expands the house rotation pools so weekly podium/chasers rotate instead of
// running the same 3+5 UIDs every week (stable UIDs visible via duel
// opponentUids are fingerprintable).
//
// Targets: accountPool = 3 existing podium + 9 new (12 to pick 3 from),
// chaserPool = 5 existing chasers + 7 new (12 to pick 5 from).
// Weekly active-set rotation is already hash-stable in _houseActiveSet, so
// populating the pools is all it takes to get churn.
//
// Also repairs cohort-readable tells on the existing 8 bots (Firestore fields
// only — Auth emails are invisible to players and left alone):
//   * users.{email,emailNormalized} containing 'house' -> plausible gmail
//   * non-canonical universities (ABU vs 'ABU Zaria', UI vs
//     'UI (University of Ibadan)', UNN, LASU) -> canonical values
//
// SAFE-BY-DESIGN: existing scores/WP/stats/ticks untouched; new accounts get
// backdated createdAt (spread over past months, not all today), varied stats,
// canonical universities, plausible emails. Weekly entry left to the hourly
// houseEnsureEntry tick (staggered Monday entries preserved).
//
// Auth: Application Default Credentials, same as ensure_house_accounts.js:
//   $env:GOOGLE_APPLICATION_CREDENTIALS="$env:APPDATA\gcloud\legacy_credentials\<you>\adc.json"
//   node scripts/fill_house_pools.js
'use strict';
const admin = require('firebase-admin');
const crypto = require('crypto');

const PROJECT = 'anime-quiz-1ab1b';

const CANONICAL_UNIS = [
  'UNILAG', 'UI (University of Ibadan)', 'OAU', 'FUTA', 'UNIABUJA',
  'UNIBEN', 'ABU Zaria', 'UNIPORT', 'NOUN', 'Babcock', 'Other',
];
const UNI_FIX = {
  'ABU': 'ABU Zaria',
  'UI': 'UI (University of Ibadan)',
  'UNN': 'NOUN',
  'LASU': 'UNILAG',
};

// 9 podium-pool prospects (strong grinders).
const PODIUM_POOL = [
  { username: 'SeyiPlays', university: 'UNILAG', gp: 118, wr: 0.78, score: 2100, coins: 9800, ageDays: 252 },
  { username: 'TundeWins', university: 'OAU', gp: 96, wr: 0.74, score: 1750, coins: 8400, ageDays: 231 },
  { username: 'ChidiClutch', university: 'UNIBEN', gp: 132, wr: 0.81, score: 2400, coins: 11000, ageDays: 268 },
  { username: 'AdaezeAce', university: 'UNIPORT', gp: 74, wr: 0.7, score: 1250, coins: 6200, ageDays: 189 },
  { username: 'FemiFragz', university: 'FUTA', gp: 88, wr: 0.72, score: 1480, coins: 7100, ageDays: 203 },
  { username: 'NgoziNuke', university: 'UI (University of Ibadan)', gp: 63, wr: 0.68, score: 980, coins: 5400, ageDays: 154 },
  { username: 'EmekaElite', university: 'ABU Zaria', gp: 105, wr: 0.76, score: 1900, coins: 9100, ageDays: 219 },
  { username: 'KemiKombat', university: 'NOUN', gp: 58, wr: 0.69, score: 860, coins: 5000, ageDays: 121 },
  { username: 'TobiTactics', university: 'Babcock', gp: 81, wr: 0.73, score: 1340, coins: 6800, ageDays: 176 },
];

// 7 chaser-pool prospects (mid-board humans).
const CHASER_POOL = [
  { username: 'JideJests', university: 'OAU', gp: 52, wr: 0.6, score: 640, coins: 4800, ageDays: 143 },
  { username: 'FunmiFrags', university: 'UNILAG', gp: 38, wr: 0.55, score: 420, coins: 3600, ageDays: 98 },
  { username: 'AdeAces', university: 'FUTA', gp: 66, wr: 0.63, score: 780, coins: 5600, ageDays: 167 },
  { username: 'BolaBlitz', university: 'UI (University of Ibadan)', gp: 29, wr: 0.52, score: 260, coins: 2800, ageDays: 74 },
  { username: 'NnekaNoScope', university: 'UNIBEN', gp: 47, wr: 0.58, score: 540, coins: 4300, ageDays: 129 },
  { username: 'SegunSweeps', university: 'UNIABUJA', gp: 71, wr: 0.64, score: 850, coins: 6100, ageDays: 184 },
  { username: 'HalimaHits', university: 'ABU Zaria', gp: 33, wr: 0.54, score: 330, coins: 3100, ageDays: 87 },
];

function plausibleEmail(username, salt) {
  const h = crypto.createHash('sha256').update(`pool:${salt}`).digest('hex');
  const a = 1000 + (parseInt(h.slice(0, 4), 16) % 9000);
  const base = username.toLowerCase().replace(/[^a-z0-9]/g, '');
  return `${base}.${a}@gmail.com`;
}

function statsFor(p) {
  const won = Math.round(p.gp * p.wr);
  return {
    gamesPlayed: p.gp, gamesWon: won, gamesLost: p.gp - won,
    hseWon: Math.round(won * 0.3), hseLost: Math.round((p.gp - won) * 0.3),
    hseStaked: p.gp,
  };
}

async function ensurePoolUser(auth, db, p, isPremium) {
  const email = plausibleEmail(p.username, p.username);
  let user;
  try {
    user = await auth.getUserByEmail(email);
  } catch (e) {
    if (e.code !== 'auth/user-not-found') throw e;
    const pwd = crypto.randomBytes(24).toString('base64url');
    user = await auth.createUser({
      email, password: pwd, displayName: p.username, emailVerified: true,
    });
  }
  const key = p.username.toLowerCase();
  await db.collection('usernames').doc(key).set({
    uid: user.uid, username: p.username,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  const uref = db.collection('users').doc(user.uid);
  const usnap = await uref.get();
  if (!usnap.exists) {
    const createdAt = admin.firestore.Timestamp.fromDate(
      new Date(Date.now() - p.ageDays * 24 * 3600 * 1000),
    );
    await uref.set({
      username: p.username, email, emailNormalized: email.toLowerCase(),
      emailVerified: true, accountStatus: 'active',
      totalScore: p.score, animeCoins: p.coins,
      weeklyPoints: 0, weeklyReset: admin.firestore.FieldValue.serverTimestamp(),
      createdAt, stats: statsFor(p), university: p.university,
      premiumActive: isPremium,
    }, { merge: true });
  }
  const sref = db.collection('house_state').doc(user.uid);
  if (!(await sref.get()).exists) {
    await sref.set({
      targetTotal: 0, deficit: 0,
      lastTick: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  return user.uid;
}

async function repairExisting(db, uids) {
  let repaired = 0;
  for (const uid of uids) {
    const ref = db.collection('users').doc(uid);
    const snap = await ref.get().catch(() => null);
    if (!snap || !snap.exists) continue;
    const d = snap.data() || {};
    const patch = {};
    for (const f of ['email', 'emailNormalized']) {
      if (typeof d[f] === 'string' && d[f].toLowerCase().includes('house')) {
        const base = String(d.username || 'player').toLowerCase().replace(/[^a-z0-9]/g, '') || 'player';
        const h = crypto.createHash('sha256').update(`repair:${uid}:${f}`).digest('hex');
        const a = 1000 + (parseInt(h.slice(0, 4), 16) % 9000);
        patch[f] = `${base}.${a}@gmail.com`;
      }
    }
    if (typeof d.university === 'string' && !CANONICAL_UNIS.includes(d.university)) {
      const fixed = UNI_FIX[d.university];
      if (fixed) patch.university = fixed;
    }
    if (Object.keys(patch).length) {
      await ref.set(patch, { merge: true });
      repaired++;
    }
  }
  return repaired;
}

async function main() {
  admin.initializeApp({ projectId: PROJECT });
  const db = admin.firestore();
  const auth = admin.auth();

  const gref = db.collection('house_config').doc('global');
  const gsnap = await gref.get();
  if (!gsnap.exists) throw new Error('house_config/global missing — run ensure_house_accounts.js first');
  const cur = gsnap.data() || {};
  const accounts = (cur.accounts || []).map(String);
  const chasers = (cur.chasers || []).map(String);

  const repaired = await repairExisting(db, [...accounts, ...chasers]);

  const podiumUids = [];
  for (const p of PODIUM_POOL) podiumUids.push(await ensurePoolUser(auth, db, p, false));
  const chaserUids = [];
  for (const p of CHASER_POOL) chaserUids.push(await ensurePoolUser(auth, db, p, false));

  const accountPool = [...(cur.accountPool || []).map(String)];
  for (const u of [...accounts, ...podiumUids]) if (!accountPool.includes(u)) accountPool.push(u);
  const chaserPool = [...(cur.chaserPool || []).map(String)];
  for (const u of [...chasers, ...chaserUids]) if (!chaserPool.includes(u)) chaserPool.push(u);

  await gref.set({
    accountPool: accountPool.slice(0, 15),
    chaserPool: chaserPool.slice(0, 15),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  console.log(JSON.stringify({
    repairedExisting: repaired,
    podiumPoolAdded: podiumUids.length,
    chaserPoolAdded: chaserUids.length,
    accountPoolSize: Math.min(accountPool.length, 15),
    chaserPoolSize: Math.min(chaserPool.length, 15),
  }, null, 2));
}

main().then(() => process.exit(0)).catch((e) => { console.error(`FAILED: ${e.message}`); process.exit(1); });
