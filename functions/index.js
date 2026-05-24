const { onSchedule }        = require('firebase-functions/v2/scheduler');
const { onCall, onRequest } = require('firebase-functions/v2/https');
const { initializeApp }     = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

// ─── Manual test secret ───────────────────────────────────────────────────────
// Pass this as the x-reset-secret header when calling triggerWeeklyReset.
// Change before going to production.
const RESET_SECRET = 'animequiz-manual-reset-2025';

initializeApp();
const db = getFirestore();

// ─── Shared reset logic ───────────────────────────────────────────────────────
// Extracted so both weeklyReset (scheduled) and triggerWeeklyReset (manual test
// callable) run identical code. Never duplicate business logic across functions.
async function runWeeklyReset() {
  const weekId    = currentWeekId();
  const newWeekId = nextWeekId();

  console.log(`[weeklyReset] Starting. weekId=${weekId} → newWeekId=${newWeekId}`);

  // ── Idempotency guard ──────────────────────────────────────────────────────
  // If the function is retried (Cloud Scheduler retries on failure), or if you
  // call it manually while it's already mid-run, this prevents double-processing.
  // The only way past this guard is if status is still 'active' (not yet touched).
  const poolRef  = db.collection('prize_pool').doc(weekId);
  const poolSnap = await poolRef.get();
  const poolData = poolSnap.data() || {};

  if (poolData.status && poolData.status !== 'active') {
    console.log(`[weeklyReset] Skipping — pool status is already '${poolData.status}'. Not re-running.`);
    return { skipped: true, reason: `status was ${poolData.status}` };
  }

  const total = poolData.totalNaira || 0;

  // ── STEP 1: Create new week's prize pool doc FIRST ─────────────────────────
  // Do this before anything else so that even if later steps fail, the new week
  // is live and the Flutter app can start accumulating into it immediately.
  // Using { merge: false } intentionally — don't overwrite if it somehow exists.
  const newPoolRef = db.collection('prize_pool').doc(newWeekId);
  const newPoolSnap = await newPoolRef.get();
  if (!newPoolSnap.exists) {
    await newPoolRef.set({
      weekId:      newWeekId,
      totalNaira:  0,
      adViewCount: 0,
      status:      'active',
      createdAt:   FieldValue.serverTimestamp(),
    });
    console.log(`[weeklyReset] New week doc created: ${newWeekId}`);
  } else {
    console.log(`[weeklyReset] New week doc already existed: ${newWeekId}`);
  }

  // ── STEP 2: Snapshot top 10 weekly leaderboard ─────────────────────────────
  const topSnap = await db
    .collection('users')
    .orderBy('weeklyPoints', 'desc')
    .limit(10)
    .get();

  const winners = topSnap.docs.map((doc, i) => {
    const d    = doc.data();
    const rank = i + 1;
    const pct  = prizePct(rank);
    return {
      rank,
      uid:          doc.id,
      username:     d.username     || 'Anonymous',
      university:   d.university   || null,        // include for campus records
      weeklyPoints: d.weeklyPoints || 0,
      prize:        parseFloat((total * pct).toFixed(2)),
      pct:          pct * 100,
      paid:         false,
    };
  });

  console.log(`[weeklyReset] Top ${winners.length} winners snapshotted. Pool: ₦${total}`);

  // ── STEP 3: Write distribution snapshot + mark as calculating ──────────────
  await poolRef.set({
    ...poolData,
    status:     'calculating',
    winners,
    snapshotAt: FieldValue.serverTimestamp(),
    totalNaira: total,
  }, { merge: true });

  // ── STEP 4: Reset weeklyPoints for ALL users in batches of 400 ─────────────
  // 400 not 500: each doc has 2 field writes (weeklyPoints + weeklyReset).
  // Firestore counts field writes toward the 500-operation batch limit,
  // so 400 docs × 2 fields = 800 writes which EXCEEDS the limit.
  // Safe ceiling: 250 docs × 2 fields = 500 writes per batch (exactly at limit).
  // Using 200 for a comfortable margin.
  const BATCH_SIZE  = 200;
  const MAX_BATCHES = 500;   // hard ceiling: 200 × 500 = 100,000 users max
  let lastDoc    = null;
  let resetCount = 0;
  let batchNum   = 0;

  do {
    if (batchNum >= MAX_BATCHES) {
      console.warn(`[weeklyReset] Hit MAX_BATCHES (${MAX_BATCHES}). Stopping pagination. ${resetCount} users reset so far.`);
      break;
    }

    let query = db.collection('users')
      .orderBy('__name__')
      .limit(BATCH_SIZE);

    if (lastDoc) query = query.startAfter(lastDoc);

    const userSnap = await query.get();
    if (userSnap.empty) break;

    const batch = db.batch();
    userSnap.docs.forEach(doc => {
      batch.update(doc.ref, {
        weeklyPoints: 0,
        weeklyReset:  FieldValue.serverTimestamp(),
      });
    });

    await batch.commit();
    resetCount += userSnap.size;
    lastDoc     = userSnap.docs[userSnap.docs.length - 1];
    batchNum++;

    console.log(`[weeklyReset] Batch ${batchNum}: reset ${userSnap.size} users (total so far: ${resetCount})`);

  } while (true);

  console.log(`[weeklyReset] All users reset. Total: ${resetCount}`);

  // ── STEP 5: Mark previous week as pending payment ──────────────────────────
  await poolRef.update({ status: 'pending_payment' });

  console.log(`[weeklyReset] Complete. ${weekId} → pending_payment. ${newWeekId} → active.`);

  return {
    weekId,
    newWeekId,
    total,
    resetCount,
    winnersCount: winners.length,
  };
}

// ─── Weekly Reset (scheduled) ─────────────────────────────────────────────────
// Runs every Sunday at 23:00 UTC (= midnight WAT, West Africa Time = UTC+1).
exports.weeklyReset = onSchedule(
  {
    schedule:       '0 23 * * 0',
    timeZone:       'UTC',
    region:         'us-central1',
    timeoutSeconds: 540,    // 9 minutes — v2 scheduled max is 60 min but 9 is plenty
    memory:         '512MiB',
  },
  async () => {
    try {
      const result = await runWeeklyReset();
      console.log('[weeklyReset] Scheduled run finished:', JSON.stringify(result));
    } catch (err) {
      // Log the full error so it shows up in Cloud Logging with ERROR severity,
      // which triggers an alert if you set up log-based alerting.
      console.error('[weeklyReset] FATAL ERROR:', err);
      throw err; // re-throw so Cloud Scheduler marks the job as failed and retries
    }
  }
);

// ─── Manual Test Trigger ──────────────────────────────────────────────────────
// Plain HTTP function — easier to call than onCall from terminal/curl.
// Protected by a simple secret header so random requests can't trigger it.
//
// After deploying, call it from PowerShell:
//
//   Invoke-WebRequest -Uri "https://us-central1-anime-quiz-1ab1b.cloudfunctions.net/triggerWeeklyReset" `
//     -Method POST `
//     -Headers @{"x-reset-secret"="animequiz-manual-reset-2025"}
//
// Or from any terminal with curl:
//
//   curl -X POST \
//     https://us-central1-anime-quiz-1ab1b.cloudfunctions.net/triggerWeeklyReset \
//     -H "x-reset-secret: animequiz-manual-reset-2025"
//
// IMPORTANT: Delete or disable this function after you're done testing.
exports.triggerWeeklyReset = onRequest(
  {
    region:         'us-central1',
    timeoutSeconds: 540,
    memory:         '512MiB',
  },
  async (req, res) => {
    const secret = req.headers['x-reset-secret'];
    if (secret !== RESET_SECRET) {
      console.warn('[triggerWeeklyReset] Unauthorized attempt');
      return res.status(401).json({ error: 'Unauthorized' });
    }

    console.log('[triggerWeeklyReset] Manually triggered');

    try {
      const result = await runWeeklyReset();
      return res.json({ success: true, ...result });
    } catch (err) {
      console.error('[triggerWeeklyReset] ERROR:', err);
      return res.status(500).json({ error: err.message });
    }
  }
);

// ─── Increment Prize Pool ─────────────────────────────────────────────────────
// Called from the Flutter app after every completed rewarded-video ad.
// data: { nairaAmount: number }
exports.incrementPrizePool = onCall(
  { region: 'us-central1' },
  async (request) => {
    const { nairaAmount } = request.data;

    if (typeof nairaAmount !== 'number' || nairaAmount <= 0) {
      throw new Error('Invalid nairaAmount');
    }

    // Cap per call at ₦10 to prevent abuse
    const safeAmount = Math.min(nairaAmount, 10);
    const weekId     = currentWeekId();
    const ref        = db.collection('prize_pool').doc(weekId);

    await ref.set({
      totalNaira:  FieldValue.increment(safeAmount),
      adViewCount: FieldValue.increment(1),
      weekId,
      status:      'active',
    }, { merge: true });

    return { success: true, added: safeAmount };
  }
);

// ─── Helpers ──────────────────────────────────────────────────────────────────
function currentWeekId() {
  const now    = new Date();
  const utcNow = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()
  ));
  const day    = utcNow.getUTCDay(); // 0 = Sun, 1 = Mon … 6 = Sat
  const diff   = day === 0 ? -6 : 1 - day;
  const monday = new Date(utcNow);
  monday.setUTCDate(utcNow.getUTCDate() + diff);
  return monday.toISOString().slice(0, 10); // e.g. "2025-05-19"
}

function nextWeekId() {
  const now    = new Date();
  const utcNow = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()
  ));
  const day    = utcNow.getUTCDay();
  const diff   = day === 0 ? -6 : 1 - day;
  const monday = new Date(utcNow);
  monday.setUTCDate(utcNow.getUTCDate() + diff + 7); // next Monday
  return monday.toISOString().slice(0, 10);
}

// Prize percentage per rank (top 5 only, ranks 6-10 get 0%)
function prizePct(rank) {
  const pcts = { 1: 0.40, 2: 0.25, 3: 0.15, 4: 0.10, 5: 0.10 };
  return pcts[rank] || 0;
}