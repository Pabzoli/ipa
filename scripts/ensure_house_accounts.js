// scripts/ensure_house_accounts.js
// Idempotent provisioner for the 3 podium + 5 chaser house bots.
// Reuses the exact emails/usernames/passwords from create_house_accounts.js
// and create_chaser_accounts.js so existing tooling keeps working.
//
// SAFE-BY-DESIGN: merges ONLY {accounts, chasers, chaserEnabled, updatedAt}
// into house_config/global. It never touches gaps/reserve/personas or any
// other tuning. Existing users keep their scores/WP/stats untouched; only
// brand-new users get a fresh player doc. house_state docs are created only
// when missing so live tick targets are never reset. Weekly leaderboard
// entry is left to the hourly houseEnsureEntry tick (enters current week).
//
// Auth: Application Default Credentials. This session reuses the gcloud
// legacy ADC file, e.g.:
//   $env:GOOGLE_APPLICATION_CREDENTIALS="$env:APPDATA\gcloud\legacy_credentials\<you>\adc.json"
//   node scripts/ensure_house_accounts.js
const admin = require('firebase-admin');

const HOUSES = [
  { email: 'house.grinder.ng@gmail.com', username: 'LagosLegend', university: 'UNILAG', pwd: 'Hous3Grinder!9x' },
  { email: 'house.social.ng@gmail.com', username: 'NaijaBrain', university: 'UI', pwd: 'Hous3Social!9x' },
  { email: 'house.clutch.ng@gmail.com', username: 'BlitzBossNG', university: 'ABU', pwd: 'Hous3Clutch!9x' },
];

const CHASERS = [
  { email: 'house.chaser1.ng@gmail.com', username: 'CampusGrind', university: 'OAU', pwd: 'Chas3rOne!7q' },
  { email: 'house.chaser2.ng@gmail.com', username: 'QuizHustler', university: 'UNN', pwd: 'Chas3rTwo!7q' },
  { email: 'house.chaser3.ng@gmail.com', username: 'NaijaScholar', university: 'FUTA', pwd: 'Chas3rThree!7q' },
  { email: 'house.chaser4.ng@gmail.com', username: 'BrainDrain9', university: 'LASU', pwd: 'Chas3rFour!7q' },
  { email: 'house.chaser5.ng@gmail.com', username: 'LastBencher', university: 'UNIBEN', pwd: 'Chas3rFive!7q' },
];

async function ensureUser(auth, db, h, freshStats, isPremium) {
  let user;
  let created = false;
  try {
    user = await auth.getUserByEmail(h.email);
  } catch (e) {
    if (e.code !== 'auth/user-not-found') throw e;
    user = await auth.createUser({
      email: h.email, password: h.pwd, displayName: h.username, emailVerified: true,
    });
    created = true;
  }
  const key = h.username.toLowerCase();
  await db.collection('usernames').doc(key).set({
    uid: user.uid, username: h.username, createdAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  const uref = db.collection('users').doc(user.uid);
  const usnap = await uref.get();
  if (!usnap.exists) {
    await uref.set({
      username: h.username, email: h.email, emailVerified: true,
      accountStatus: 'active', totalScore: freshStats.totalScore, animeCoins: freshStats.coins,
      weeklyPoints: 0, weeklyReset: admin.firestore.FieldValue.serverTimestamp(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      stats: freshStats.stats, university: h.university, premiumActive: isPremium,
    }, { merge: true });
  } else {
    // Role-based premium: podium true, chasers false. Managed here so a
    // re-run converges existing docs instead of re-premiuming everyone.
    const patch = { premiumActive: isPremium };
    if (!usnap.data()?.university) patch.university = h.university;
    await uref.set(patch, { merge: true });
  }
  const sref = db.collection('house_state').doc(user.uid);
  const ssnap = await sref.get();
  if (!ssnap.exists) {
    await sref.set({
      targetTotal: 0, deficit: 0, lastTick: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  return { email: h.email, uid: user.uid, created };
}

async function main() {
  admin.initializeApp({ projectId: 'anime-quiz-1ab1b' });
  const db = admin.firestore();
  const auth = admin.auth();

  const houses = [];
  for (const h of HOUSES) {
    houses.push(await ensureUser(auth, db, h, {
      totalScore: 500, coins: 2000,
      stats: { gamesPlayed: 40, gamesWon: 24, gamesLost: 16, hseWon: 0, hseLost: 0, hseStaked: 0 },
    }, true));
  }
  const chasers = [];
  for (const h of CHASERS) {
    chasers.push(await ensureUser(auth, db, h, {
      totalScore: 120, coins: 3500,
      stats: { gamesPlayed: 18, gamesWon: 9, gamesLost: 9, hseWon: 0, hseLost: 0, hseStaked: 0 },
    }, false));
  }

  const gref = db.collection('house_config').doc('global');
  const gsnap = await gref.get();
  const cur = gsnap.exists ? (gsnap.data() || {}) : {};
  const houseUids = houses.map((h) => h.uid);
  const mergedChasers = [...(cur.chasers || [])];
  for (const c of chasers) if (!mergedChasers.includes(c.uid)) mergedChasers.push(c.uid);
  await gref.set({
    accounts: houseUids,
    chasers: mergedChasers.slice(0, 5),
    chaserEnabled: true,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  const verify = (await gref.get()).data() || {};

  console.log(JSON.stringify({
    houses, chasers,
    global: {
      accounts: verify.accounts || [],
      chasers: verify.chasers || [],
      chaserEnabled: verify.chaserEnabled !== false,
      enabled: verify.enabled !== false,
    },
  }, null, 2));
}

main().then(() => process.exit(0)).catch((e) => { console.error(`FAILED: ${e.message}`); process.exit(1); });
