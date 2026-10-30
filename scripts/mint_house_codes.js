// scripts/mint_house_codes.js
// Mints friend codes for the 3 house accounts.
const admin = require('firebase-admin');
admin.initializeApp({ projectId: 'anime-quiz-1ab1b' });
const db = admin.firestore();
const CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const pick = () => {
  let s = '';
  for (let i = 0; i < 6; i++) s += CHARS[Math.floor(Math.random() * CHARS.length)];
  return s;
};
async function main() {
  const snap = await db.collection('house_config').doc('global').get();
  const uids = (snap.data() || {}).accounts || [];
  if (!uids.length) throw new Error('no house accounts configured');
  for (const uid of uids) {
    const uref = db.collection('users').doc(uid);
    const u = await uref.get();
    const cur = u.data()?.friendCode;
    if (typeof cur === 'string' && cur.length === 6) {
      console.log(`${uid} -> ${cur} (existing)`);
      continue;
    }
    for (let i = 0; i < 5; i++) {
      const code = pick();
      const cref = db.collection('friendCodes').doc(code);
      const c = await cref.get();
      if (c.exists) continue;
      await cref.set({ uid, createdAt: admin.firestore.FieldValue.serverTimestamp() });
      await uref.set({ friendCode: code }, { merge: true });
      console.log(`${uid} -> ${code}`);
      break;
    }
  }
}
main().then(() => process.exit(0)).catch((e) => { console.error(e.message); process.exit(1); });
