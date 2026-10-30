// scripts/create_house_accounts.js
// Creates 3 house Auth users + player docs + house_config/global.
// Usage: GOOGLE_APPLICATION_CREDENTIALS=<key> node scripts/create_house_accounts.js
const admin = require('firebase-admin');
admin.initializeApp({ projectId: 'anime-quiz-1ab1b' });
const db = admin.firestore();
const auth = admin.auth();

const HOUSES = [
  { email: 'house.grinder.ng@gmail.com', username: 'LagosLegend', university: 'UNILAG', pwd: 'Hous3Grinder!9x' },
  { email: 'house.social.ng@gmail.com', username: 'NaijaBrain', university: 'UI', pwd: 'Hous3Social!9x' },
  { email: 'house.clutch.ng@gmail.com', username: 'BlitzBossNG', university: 'ABU', pwd: 'Hous3Clutch!9x' },
];

async function main() {
  const uids = [];
  for (const h of HOUSES) {
    let user;
    try {
      user = await auth.getUserByEmail(h.email);
      console.log(`exists ${h.email} -> ${user.uid}`);
    } catch {
      user = await auth.createUser({
        email: h.email, password: h.pwd, displayName: h.username, emailVerified: true,
      });
      console.log(`created ${h.email} -> ${user.uid}`);
    }
    uids.push(user.uid);
    const key = h.username.toLowerCase();
    await db.collection('usernames').doc(key).set({
      uid: user.uid, username: h.username, createdAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    await db.collection('users').doc(user.uid).set({
      username: h.username, email: h.email, emailVerified: true,
      accountStatus: 'active', totalScore: 500, animeCoins: 2000,
      weeklyPoints: 0, weeklyReset: admin.firestore.FieldValue.serverTimestamp(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      stats: { gamesPlayed: 40, gamesWon: 24, gamesLost: 16, hseWon: 0, hseLost: 0, hseStaked: 0 },
      university: h.university, premiumActive: true,
    }, { merge: true });
  }
  await db.collection('house_config').doc('global').set({
    enabled: true, neverLose: true, mode: 'steady',
    maxDailyRaw: 350, reserve: 180, gap1: 95, gap2: 75, gap3: 70,
    paused: [], accounts: uids,
    personas: Object.fromEntries(uids.map((u, i) => [u, { archetype: ['grinder', 'social', 'clutch'][i] }])),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  const week = '2026-10-26';
  for (const uid of uids) {
    await db.collection('users').doc(uid).set({
      leaderboardEntryWeekId: week,
      leaderboardEntryEmail: 'house-' + uid.slice(0, 6) + '@local',
      premiumActive: true,
    }, { merge: true });
    await db.collection('users').doc(uid).collection('leaderboardReceipts').doc(week).set({
      weekId: week, source: 'house', at: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  for (const uid of uids) {
    await db.collection('house_state').doc(uid).set({
      targetTotal: 0, deficit: 0, lastTick: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  console.log(JSON.stringify({ uids }));
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message); process.exit(1); });
