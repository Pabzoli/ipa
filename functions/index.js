const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onCall, onRequest } = require('firebase-functions/v2/https');
const { onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');

// ─── Manual test secret ───────────────────────────────────────────────────────
const RESET_SECRET = 'animequiz-manual-reset-2025';

initializeApp();
const db = getFirestore();

// =============================================================================
// ─── SECTION 1: WEEKLY RESET & PRIZE POOL LOGIC ──────────────────────────────
// =============================================================================

async function runWeeklyReset() {
  const weekId    = currentWeekId();
  const newWeekId = nextWeekId();

  console.log(`[weeklyReset] Starting. weekId=${weekId} → newWeekId=${newWeekId}`);

  const poolRef  = db.collection('prize_pool').doc(weekId);
  const poolSnap = await poolRef.get();
  const poolData = poolSnap.data() || {};

  if (poolData.status && poolData.status !== 'active') {
    console.log(`[weeklyReset] Skipping — pool status is already '${poolData.status}'. Not re-running.`);
    return { skipped: true, reason: `status was ${poolData.status}` };
  }

  const total = poolData.totalNaira || 0;

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
      university:   d.university   || null,
      weeklyPoints: d.weeklyPoints || 0,
      prize:        parseFloat((total * pct).toFixed(2)),
      pct:          pct * 100,
      paid:         false,
    };
  });

  console.log(`[weeklyReset] Top ${winners.length} winners snapshotted. Pool: ₦${total}`);

  await poolRef.set({
    ...poolData,
    status:     'calculating',
    winners,
    snapshotAt: FieldValue.serverTimestamp(),
    totalNaira: total,
  }, { merge: true });

  const BATCH_SIZE  = 200;
  const MAX_BATCHES = 500; 
  let lastDoc     = null;
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

exports.weeklyReset = onSchedule(
  {
    schedule:       '0 23 * * 0',
    timeZone:       'UTC',
    region:         'us-central1',
    timeoutSeconds: 540,
    memory:         '512MiB',
  },
  async () => {
    try {
      const result = await runWeeklyReset();
      console.log('[weeklyReset] Scheduled run finished:', JSON.stringify(result));
    } catch (err) {
      console.error('[weeklyReset] FATAL ERROR:', err);
      throw err;
    }
  }
);

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

exports.incrementPrizePool = onCall(
  { region: 'us-central1' },
  async (request) => {
    const { nairaAmount } = request.data;

    if (typeof nairaAmount !== 'number' || nairaAmount <= 0) {
      throw new Error('Invalid nairaAmount');
    }

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

// =============================================================================
// ─── SECTION 2: LIVE MULTIPLAYER CHALLENGE LOGIC ────────────────────────────
// =============================================================================

/**
 * Fires whenever a challenge document is updated.
 * Explicitly deployed to us-central1 to align infrastructure and clear Eventarc permissions errors.
 */
exports.resolveChallengeOutcome = onDocumentUpdated(
  {
    document: "challenges/{challengeId}",
    region: "us-central1"
  },
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();

    if (!before || !after) return null;

    // Only act when opponentScore is being written for the first time
    if (before.opponentScore !== null && before.opponentScore !== undefined) {
      return null;
    }
    if (after.opponentScore === null || after.opponentScore === undefined) {
      return null;
    }
    if (after.creatorScore === null || after.creatorScore === undefined) {
      return null;
    }
    if (after.status === "completed") {
      return null; // already resolved — idempotency guard
    }

    const {
      creatorUid,
      opponentUid,
      betAmount,
      creatorScore,
      opponentScore,
    } = after;

    let outcome;
    let winnerUid = null;

    if (creatorScore > opponentScore) {
      outcome   = "creator_wins";
      winnerUid = creatorUid;
    } else if (opponentScore > creatorScore) {
      outcome   = "opponent_wins";
      winnerUid = opponentUid;
    } else {
      outcome = "draw";
    }

    const batch = db.batch();

    batch.update(event.data.after.ref, {
      outcome,
      status: "completed",
    });

    if (outcome === "draw") {
      // Refund both players
      batch.update(db.collection("users").doc(creatorUid), {
        totalScore: FieldValue.increment(betAmount),
      });
      batch.update(db.collection("users").doc(opponentUid), {
        totalScore: FieldValue.increment(betAmount),
      });
    } else {
      // Winner gets both bets back
      batch.update(db.collection("users").doc(winnerUid), {
        totalScore: FieldValue.increment(betAmount * 2),
      });
    }

    await batch.commit();
    console.log(`Challenge ${event.params.challengeId} resolved: ${outcome}`);
    return null;
  }
);

/**
 * Runs every hour. Finds expired challenges and expires them.
 */
exports.expireOldChallenges = onSchedule(
  {
    schedule: "every 1 hours",
    region: "us-central1",
  },
  async () => {
    const now = Timestamp.now();

    const snap = await db
      .collection("challenges")
      .where("status", "in", ["waiting", "opponent_joined"])
      .where("expiresAt", "<=", now)
      .get();

    if (snap.empty) return;

    const batch = db.batch();

    for (const doc of snap.docs) {
      const data = doc.data();

      batch.update(doc.ref, { status: "expired" });

      // Refund creator if opponent never joined (bet was deducted on creation)
      if (!data.opponentUid) {
        batch.update(db.collection("users").doc(data.creatorUid), {
          totalScore: FieldValue.increment(data.betAmount),
        });
      }
    }

    await batch.commit();
    console.log(`Expired ${snap.size} challenge(s).`);
  }
);

// =============================================================================
// ─── SECTION 3: HELPERS ──────────────────────────────────────────────────────
// =============================================================================

function currentWeekId() {
  const now    = new Date();
  const utcNow = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()
  ));
  const day    = utcNow.getUTCDay();
  const diff   = day === 0 ? -6 : 1 - day;
  const monday = new Date(utcNow);
  monday.setUTCDate(utcNow.getUTCDate() + diff);
  return monday.toISOString().slice(0, 10);
}

function nextWeekId() {
  const now    = new Date();
  const utcNow = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()
  ));
  const day    = utcNow.getUTCDay();
  const diff   = day === 0 ? -6 : 1 - day;
  const monday = new Date(utcNow);
  monday.setUTCDate(utcNow.getUTCDate() + diff + 7);
  return monday.toISOString().slice(0, 10);
}

function prizePct(rank) {
  const pcts = { 1: 0.40, 2: 0.25, 3: 0.15, 4: 0.10, 5: 0.10 };
  return pcts[rank] || 0;
}