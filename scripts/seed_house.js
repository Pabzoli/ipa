// scripts/seed_house.js
// Seeds house top-3 engine: node scripts/seed_house.js <uid1> <uid2> <uid3> [--commit]
// Dry-run by default. --commit writes house_config/global + premium + personas.
const admin = require('firebase-admin');

if (process.argv.includes('--commit')) {
  admin.initializeApp();
} else {
  admin.initializeApp({ projectId: 'demo-seed' });
}

const db = admin.firestore();
const DRY = !process.argv.includes('--commit');
const uids = process.argv.slice(2).filter((a) => !a.startsWith('--'));

async function main() {
  if (uids.length !== 3) {
    console.log('Usage: node scripts/seed_house.js <uid1> <uid2> <uid3> [--commit]');
    process.exit(1);
  }
  const personas = [
    { archetype: 'grinder', university: 'UNILAG', windows: 'night' },
    { archetype: 'social', university: 'UI', windows: 'mixed' },
    { archetype: 'clutch', university: 'ABU', windows: 'evening' },
  ];
  const patch = {
    enabled: true,
    neverLose: true,
    mode: 'steady',
    maxDailyRaw: 350,
    reserve: 180,
    gap1: 95,
    gap2: 75,
    gap3: 70,
    paused: [],
    accounts: uids,
    personas: Object.fromEntries(uids.map((u, i) => [u, personas[i]])),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  console.log(JSON.stringify({ dryRun: DRY, patch }, null, 2));
  if (DRY) return;
  await db.collection('house_config').doc('global').set(patch, { merge: true });
  for (let i = 0; i < uids.length; i++) {
    await db.collection('users').doc(uids[i]).set({
      premiumActive: true,
      university: personas[i].university,
    }, { merge: true });
    await db.collection('house_state').doc(uids[i]).set({
      targetTotal: 0, deficit: 0, lastTick: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  console.log('seeded house_config/global + 3 premium houses');
}

main().catch((e) => { console.error(e); process.exit(1); });
