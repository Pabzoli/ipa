// scripts/create_chaser_accounts.js
// Creates 5 chaser Auth users + player docs, appends to house_config/global.chasers.
// Usage: GOOGLE_APPLICATION_CREDENTIALS=<key> node scripts/create_chaser_accounts.js
const admin = require('firebase-admin');
admin.initializeApp({ projectId: 'anime-quiz-1ab1b' });
const db = admin.firestore();
const auth = admin.auth();

const CHASERS = [
  { email: 'house.chaser1.ng@gmail.com', username: 'CampusGrind', university: 'OAU', pwd: 'Chas3rOne!7q' },
  { email: 'house.chaser2.ng@gmail.com', username: 'QuizHustler', university: 'UNN', pwd: 'Chas3rTwo!7q' },
  { email: 'house.chaser3.ng@gmail.com', username: 'NaijaScholar', university: 'FUTA', pwd: 'Chas3rThree!7q' },
  { email: 'house.chaser4.ng@gmail.com', username: 'BrainDrain9', university: 'LASU', pwd: 'Chas3rFour!7q' },
  { email: 'house.chaser5.ng@gmail.com', username: 'LastBencher', university: 'UNIBEN', pwd: 'Chas3rFive!7q' },
];

async function main() {
  const uids = [];
  for (const h of CHASERS) {
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
    // Modest mid-pack stats (unlike podium 40/24) so profiles read human.
    await db.collection('users').doc(user.uid).set({
      username: h.username, email: h.email, emailVerified: true,
      accountStatus: 'active', totalScore: 120, animeCoins: 3500,
      weeklyPoints: 0, weeklyReset: admin.firestore.FieldValue.serverTimestamp(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      stats: { gamesPlayed: 18, gamesWon: 9, gamesLost: 9, hseWon: 0, hseLost: 0, hseStaked: 0 },
      university: h.university, premiumActive: true,
    }, { merge: true });
  }
  const ref = db.collection('house_config').doc('global');
  const snap = await ref.get();
  const cur = snap.exists ? (snap.data() || {}) : {};
  const merged = [...(cur.chasers || [])];
  for (const u of uids) if (!merged.includes(u)) merged.push(u);
  await ref.set({
    chaserEnabled: true, chaserDailyMax: 650, chaserGap: 40, chaserMax: 1100,
    chasers: merged.slice(0, 5),
    personas: {
      ...(cur.personas || {}),
      ...Object.fromEntries(uids.map((u, i) => [u, {
        dailyMaxFactor: [0.22, 0.20, 0.24, 0.18, 0.21][i],
        skip: [45, 50, 42, 55, 48][i],
        weeklyGoal: 600 + i * 110,
      }])),
    },
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  const week = '2026-10-26';
  for (const uid of uids) {
    await db.collection('users').doc(uid).set({
      leaderboardEntryWeekId: week,
      leaderboardEntryEmail: 'house-chaser-' + uid.slice(0, 6) + '@local',
      premiumActive: true,
    }, { merge: true });
    await db.collection('users').doc(uid).collection('leaderboardReceipts').doc(week).set({
      weekId: week, source: 'house_chaser', at: admin.firestore.FieldValue.serverTimestamp(),
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
