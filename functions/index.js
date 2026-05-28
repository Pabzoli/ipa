const { onSchedule }         = require('firebase-functions/v2/scheduler');
const { onCall, onRequest }  = require('firebase-functions/v2/https');
const { onDocumentUpdated }  = require('firebase-functions/v2/firestore');
const { initializeApp }      = require('firebase-admin/app');
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

  const newPoolRef  = db.collection('prize_pool').doc(newWeekId);
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
// ─── SECTION 2: LIVE MULTIPLAYER CHALLENGE LOGIC ─────────────────────────────
// =============================================================================

/**
 * Fires whenever a challenge document is updated.
 *
 * FIX 1 — Match history:
 *   Writes users/{uid}/matches/{auto-id} for BOTH players inside the same
 *   transaction. Includes animeTitle (read from the challenge doc) so the
 *   History tab can display which anime was played on tap-to-expand.
 *
 * FIX 2 — gamesDraw:
 *   On a draw, increments stats.gamesDraw for BOTH players in addition to
 *   stats.gamesPlayed (which was already being incremented).
 *
 * FIX 3 — hseWon / hseLost / hseStaked are per-game maxima:
 *   These fields store the highest single value seen in one game — they must
 *   NEVER use FieldValue.increment(). The function reads each user's current
 *   stats inside a Firestore transaction and overwrites only when the new
 *   betAmount exceeds the stored maximum.
 *
 * FIX 4 — Idempotency guard:
 *   On entry, bails immediately if the challenge document already has
 *   resolved === true (a prior invocation already ran — this is a Cloud
 *   Functions retry or duplicate trigger). At the end of the transaction,
 *   sets resolved = true on the challenge document so any future invocation
 *   is stopped by this guard.
 *
 * ARCHITECTURE:
 *   Uses db.runTransaction() (not db.batch()) because the hse* maxima
 *   require read-then-conditional-write atomicity. All writes — challenge
 *   seal, resolved flag, score/stats, and both match history documents —
 *   are committed in a single atomic operation.
 */
exports.resolveChallengeOutcome = onDocumentUpdated(
  {
    document: 'challenges/{challengeId}',
    region:   'us-central1',
  },
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();

    if (!before || !after) return null;

    // ── FIX 4: Idempotency guard ──────────────────────────────────────────
    // resolved is set to true at the very end of this function's transaction.
    // If it is already true, a prior invocation completed successfully — this
    // is a Cloud Functions retry or a duplicate Firestore trigger. Exit now.
    if (after.resolved === true) {
      console.log(
        `[resolveChallengeOutcome] ${event.params.challengeId} already resolved — skipping.`
      );
      return null;
    }

    // ── Trigger condition ─────────────────────────────────────────────────
    // Only act on the specific write where opponentScore first appears.
    // If opponentScore was already present before this update, this is a
    // different kind of write (e.g. an admin correction) — ignore it.
    if (before.opponentScore !== null && before.opponentScore !== undefined) return null;
    if (after.opponentScore  == null  || after.creatorScore  == null)        return null;

    // ── Destructure challenge fields ──────────────────────────────────────
    const {
      creatorUid,
      opponentUid,
      betAmount,
      creatorScore,
      opponentScore,
      // FIX 1: animeTitle comes from the challenge doc itself.
      animeTitle        = 'Unknown Anime',
      // FIX 4: usernames are also stored on the challenge doc at creation
      // time so we don't need to read user docs just for display names.
      creatorUsername:  rawCreatorUsername,
      opponentUsername: rawOpponentUsername,
    } = after;

    // Warn loudly if the challenge doc was written without username fields —
    // they will fall back to 'Anonymous' but the History tab will show that.
    if (!rawCreatorUsername) {
      console.warn(
        `[resolveChallengeOutcome] ${event.params.challengeId}: ` +
        `creatorUsername is missing from the challenge document. ` +
        `Falling back to 'Anonymous'. Ensure client writes this field at creation time.`
      );
    }
    if (!rawOpponentUsername) {
      console.warn(
        `[resolveChallengeOutcome] ${event.params.challengeId}: ` +
        `opponentUsername is missing from the challenge document. ` +
        `Falling back to 'Anonymous'. Ensure client writes this field when opponent joins.`
      );
    }

    const creatorUsername  = rawCreatorUsername  || 'Anonymous';
    const opponentUsername = rawOpponentUsername || 'Anonymous';

    // ── Outcome (pure computation — no Firestore reads needed) ────────────
    let outcome;

    if      (creatorScore  > opponentScore) outcome = 'creator_wins';
    else if (opponentScore > creatorScore)  outcome = 'opponent_wins';
    else                                    outcome = 'draw';

    const isDraw      = outcome === 'draw';
    const creatorWins = outcome === 'creator_wins';

    // Per-player outcome strings (used in match history docs + stats fields)
    const creatorOutcome  = isDraw ? 'draw' : (creatorWins  ? 'win' : 'lose');
    const opponentOutcome = isDraw ? 'draw' : (!creatorWins ? 'win' : 'lose');

    // Points delta from each player's perspective.
    // Bets are DEDUCTED at challenge creation / join time, so:
    //   win  → +betAmount  (opponent's deducted bet is awarded to winner)
    //   draw → 0           (both bets are returned — net zero change)
    //   lose → -betAmount  (the deducted bet is never returned)
    const creatorPointsChange  = isDraw ? 0 : (creatorWins  ?  betAmount : -betAmount);
    const opponentPointsChange = isDraw ? 0 : (!creatorWins ?  betAmount : -betAmount);

    const creatorRef   = db.collection('users').doc(creatorUid);
    const opponentRef  = db.collection('users').doc(opponentUid);
    const challengeRef = event.data.after.ref;

    // Pre-allocate auto-ID match history refs BEFORE entering the transaction.
    // DocumentReference.doc() with no arguments generates an ID locally —
    // it is safe to call outside a transaction and produces no network call.
    const creatorMatchRef  = creatorRef.collection('matches').doc();
    const opponentMatchRef = opponentRef.collection('matches').doc();

    await db.runTransaction(async (tx) => {

      // ── READS — must all precede writes inside a Firestore transaction ────
      const [cSnap, oSnap] = await Promise.all([
        tx.get(creatorRef),
        tx.get(opponentRef),
      ]);

      // FIX 3: Read current hse* maxima so we can compare before writing.
      const cStats = (cSnap.data() || {}).stats  || {};
      const oStats = (oSnap.data() || {}).stats  || {};

      // ── Build creator update payload ──────────────────────────────────────
      const cUpdate = {
        // FIX 2: gamesPlayed incremented for every outcome (was already done)
        'stats.gamesPlayed': FieldValue.increment(1),
      };

      // Restore points: winner gets their stake back plus the opponent's stake;
      // draw players each get their own stake back; loser gets nothing back.
      if (isDraw || creatorWins) {
        cUpdate.totalScore = FieldValue.increment(isDraw ? betAmount : betAmount * 2);
      }
      // Only the winner's profit counts toward the weekly leaderboard.
      if (creatorWins) {
        cUpdate.weeklyPoints = FieldValue.increment(betAmount);
      }

      // FIX 2: W / L / D counter — gamesDraw is now incremented on draws.
      if      (creatorOutcome === 'win')  cUpdate['stats.gamesWon']  = FieldValue.increment(1);
      else if (creatorOutcome === 'lose') cUpdate['stats.gamesLost'] = FieldValue.increment(1);
      else                                cUpdate['stats.gamesDraw']  = FieldValue.increment(1);

      // FIX 3: hse* fields are per-game maxima — overwrite only when the new
      // value exceeds the current stored maximum. NEVER use FieldValue.increment().
      if (betAmount > (cStats.hseStaked || 0)) {
        cUpdate['stats.hseStaked'] = betAmount;
      }
      if (creatorOutcome === 'win'  && betAmount > (cStats.hseWon  || 0)) {
        cUpdate['stats.hseWon']  = betAmount;
      }
      if (creatorOutcome === 'lose' && betAmount > (cStats.hseLost || 0)) {
        cUpdate['stats.hseLost'] = betAmount;
      }

      // ── Build opponent update payload ─────────────────────────────────────
      const oUpdate = {
        'stats.gamesPlayed': FieldValue.increment(1),
      };

      if (isDraw || !creatorWins) {
        oUpdate.totalScore = FieldValue.increment(isDraw ? betAmount : betAmount * 2);
      }
      if (!isDraw && !creatorWins) {
        oUpdate.weeklyPoints = FieldValue.increment(betAmount);
      }

      // FIX 2: W / L / D counter for opponent.
      if      (opponentOutcome === 'win')  oUpdate['stats.gamesWon']  = FieldValue.increment(1);
      else if (opponentOutcome === 'lose') oUpdate['stats.gamesLost'] = FieldValue.increment(1);
      else                                 oUpdate['stats.gamesDraw']  = FieldValue.increment(1);

      // FIX 3: per-game maxima for opponent.
      if (betAmount > (oStats.hseStaked || 0)) {
        oUpdate['stats.hseStaked'] = betAmount;
      }
      if (opponentOutcome === 'win'  && betAmount > (oStats.hseWon  || 0)) {
        oUpdate['stats.hseWon']  = betAmount;
      }
      if (opponentOutcome === 'lose' && betAmount > (oStats.hseLost || 0)) {
        oUpdate['stats.hseLost'] = betAmount;
      }

      // ── WRITES — all committed atomically in this single transaction ───────

      // 1. Seal the challenge and set resolved = true (FIX 4).
      //    Setting resolved here means any Cloud Functions retry that fires
      //    after this transaction commits will be stopped by the guard above.
      tx.update(challengeRef, {
        outcome,
        status:   'completed',
        resolved: true,           // FIX 4: idempotency sentinel
      });

      // 2. Score + stats for each player (one update call per document).
      tx.update(creatorRef,  cUpdate);
      tx.update(opponentRef, oUpdate);

      // 3. FIX 1: Match history subcollection — one document per player.
      //    Each player sees their own score as playerScore and the other
      //    player's score as opponentScore so the History tab renders correctly.
      tx.set(creatorMatchRef, {
        opponent:      opponentUsername,   // the OTHER player's name
        playerScore:   creatorScore,
        opponentScore: opponentScore,
        betScore:      betAmount,
        outcome:       creatorOutcome,
        pointsChange:  creatorPointsChange,
        animeTitle,                        // FIX 1: needed for History tap-to-expand
        timestamp:     FieldValue.serverTimestamp(),
      });

      tx.set(opponentMatchRef, {
        opponent:      creatorUsername,    // the OTHER player's name
        playerScore:   opponentScore,      // swapped: opponent's score is "mine"
        opponentScore: creatorScore,       // swapped: creator's score is "theirs"
        betScore:      betAmount,
        outcome:       opponentOutcome,
        pointsChange:  opponentPointsChange,
        animeTitle,                        // FIX 1
        timestamp:     FieldValue.serverTimestamp(),
      });
    });

    console.log(
      `[resolveChallengeOutcome] ${event.params.challengeId} → ${outcome}` +
      ` | creator(${creatorUsername}): ${creatorScore}` +
      ` vs opponent(${opponentUsername}): ${opponentScore}` +
      ` | bet: ${betAmount}`
    );

    return null;
  }
);

/**
 * Runs every hour. Finds expired challenges and expires them.
 */
exports.expireOldChallenges = onSchedule(
  {
    schedule: 'every 1 hours',
    region:   'us-central1',
  },
  async () => {
    const now = Timestamp.now();

    const snap = await db
      .collection('challenges')
      .where('status', 'in', ['waiting', 'opponent_joined'])
      .where('expiresAt', '<=', now)
      .get();

    if (snap.empty) return;

    const batch = db.batch();

    for (const doc of snap.docs) {
      const data = doc.data();

      batch.update(doc.ref, { status: 'expired' });

      // Refund creator if opponent never joined (bet was deducted on creation)
      if (!data.opponentUid) {
        batch.update(db.collection('users').doc(data.creatorUid), {
          totalScore: FieldValue.increment(data.betAmount),
        });
      }
    }

    await batch.commit();
    console.log(`[expireOldChallenges] Expired ${snap.size} challenge(s).`);
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

// ── SECTION 4: STREAK MILESTONES ─────────────────────────────────────────────
// Fires whenever a user document is updated.
// If currentStreak just crossed 7 or 30 AND that milestone hasn't been
// awarded yet, increment animeCoins and stamp lastStreakMilestoneAwarded.
exports.awardStreakMilestone = onDocumentUpdated(
  { document: 'users/{uid}', region: 'us-central1' },
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    if (!before || !after) return null;

    const prevStreak = before.currentStreak || 0;
    const newStreak  = after.currentStreak  || 0;
    if (newStreak <= prevStreak) return null; // streak didn't increase

    const lastAwarded = after.lastStreakMilestoneAwarded || 0;

    let award = 0;
    let milestone = 0;

    if (newStreak >= 30 && lastAwarded < 30) {
      award = 60; milestone = 30;
    } else if (newStreak >= 7 && lastAwarded < 7) {
      award = 25; milestone = 7;
    }

    if (!award) return null;

    const uid     = event.params.uid;
    const userRef = db.collection('users').doc(uid);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      // Re-check inside transaction to avoid races
      if ((snap.data().lastStreakMilestoneAwarded || 0) >= milestone) return;
      tx.update(userRef, {
        animeCoins:                  FieldValue.increment(award),
        lastStreakMilestoneAwarded:  milestone,
      });
    });

    console.log(`[awardStreakMilestone] uid=${uid} streak=${newStreak} → +${award} AC (milestone ${milestone})`);
    return null;
  }
);

// ── SECTION 5: REFERRAL CODE ──────────────────────────────────────────────────
// Called from the client when a new user enters a referral code during signup.
// Looks up the referrer by their referralCode field and writes referredBy
// to the caller's user doc. The actual +80 AC payout is handled client-side
// in UserDataProvider.claimReferralBonusIfEligible() after first quiz.
exports.claimReferralBonus = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new Error('Unauthenticated');

    const { referredBy } = request.data;
    if (typeof referredBy !== 'string' || !referredBy.trim()) {
      throw new Error('Invalid referredBy uid');
    }

    const userRef     = db.collection('users').doc(uid);
    const referrerRef = db.collection('users').doc(referredBy);

    await db.runTransaction(async (tx) => {
      const [userSnap, referrerSnap] = await Promise.all([
        tx.get(userRef),
        tx.get(referrerRef),
      ]);

      const userData = userSnap.data() || {};

      // Idempotency guards — bail if already claimed or referrer doesn't exist.
      if (userData.referralBonusClaimed === true) return;
      if (!referrerSnap.exists) return;
      if (referredBy === uid) return; // no self-referral

      // Mark the new user's doc as claimed.
      tx.update(userRef, {
        firstQuizCompleted:  true,
        referralBonusClaimed: true,
      });

      // Credit the referrer — Admin SDK bypasses Firestore rules legally.
      tx.update(referrerRef, {
        animeCoins: FieldValue.increment(80),
      });
    });

    console.log(`[claimReferralBonus] uid=${uid} → referrer=${referredBy} +80 AC`);
    return { success: true };
  }
);

// ─── P-04 ADDITION: Append everything below to the bottom of your existing index.js ───

// =============================================================================
// ─── SECTION 6: REWARDED AD — COIN AWARD (P-04) ──────────────────────────────
// =============================================================================
//
// recordAdWatch  — HTTPS callable, authenticated.
//
// Atomically:
//   1. Resets dailyAdWatched to 0 if lastAdWatchDate is from a prior WAT day.
//   2. Rejects if dailyAdWatched >= 10 (daily cap).
//   3. Increments animeCoins +10 and dailyAdWatched +1.
//   4. Stamps lastAdWatchDate with a server timestamp.
//   5. Appends a coinTransactions record (type = 'earn_ad').
//
// Returns:
//   { success: true,  coinsAwarded: 10, newBalance: int, dailyAdWatched: int }
//   { success: false, error: 'daily_limit_reached' }
//
// POLICY: This function awards Anime Coins ONLY. It has no connection
// to the prize pool or naira — per AdMob §2.1 and app design rules.

exports.recordAdWatch = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error('Unauthenticated');
    }

    const userRef = db.collection('users').doc(uid);

    let result;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      // ── Daily reset check (WAT = UTC+1) ────────────────────────────────
      const todayWAT       = _watDateString();
      const lastWatchField = data.lastAdWatchDate; // Firestore Timestamp or null
      const lastWatchStr   = lastWatchField?.toDate
        ? _watDateString(lastWatchField.toDate())
        : null;

      let dailyAdWatched = (lastWatchStr === todayWAT)
        ? (data.dailyAdWatched || 0)
        : 0; // new day → reset

      // ── Daily cap check ─────────────────────────────────────────────────
      if (dailyAdWatched >= 10) {
        result = { success: false, error: 'daily_limit_reached' };
        return; // exit transaction without writing
      }

      // ── Compute new values ───────────────────────────────────────────────
      const currentCoins   = data.animeCoins || 0;
      const newBalance     = currentCoins + 10;
      const newDailyCount  = dailyAdWatched + 1;

      // ── Writes ───────────────────────────────────────────────────────────
      tx.update(userRef, {
        animeCoins:      FieldValue.increment(10),
        dailyAdWatched:  newDailyCount,
        lastAdWatchDate: FieldValue.serverTimestamp(),
      });

      // Coin transaction log — matches coinTransactions Firestore rules.
      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        'earn_ad',
        delta:       10,
        balanceAfter: newBalance,
        timestamp:   FieldValue.serverTimestamp(),
      });

      result = {
        success:        true,
        coinsAwarded:   10,
        newBalance,
        dailyAdWatched: newDailyCount,
      };
    });

    if (result.success) {
      console.log(
        `[recordAdWatch] uid=${uid} +10 AC` +
        ` | dailyAdWatched=${result.dailyAdWatched}/10`
      );
    } else {
      console.log(`[recordAdWatch] uid=${uid} → daily_limit_reached`);
    }

    return result;
  }
);

// ── Helper: WAT (UTC+1) date string ─────────────────────────────────────────
// Shared by recordAdWatch. Returns 'YYYY-MM-DD' in West Africa Time.
function _watDateString(date = new Date()) {
  const wat = new Date(date.getTime() + 60 * 60 * 1000);
  return wat.toISOString().slice(0, 10);
}