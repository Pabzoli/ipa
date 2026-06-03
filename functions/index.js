const { onSchedule }         = require('firebase-functions/v2/scheduler');
const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentUpdated }  = require('firebase-functions/v2/firestore');
const { initializeApp }      = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');

// ─── Manual test secret ───────────────────────────────────────────────────────
const RESET_SECRET = 'animequiz-manual-reset-2025';

// ─── Weekly WP cap (launch protection) ─────────────────────────────────────
const WP_WEEKLY_CAP = 2000;
const WP_CAP_ACTIVE = true;  // set to false manually after Week 4

// ─── Non-QM challenge WP rewards ────────────────────────────────────────────
// betAmount is always 0 for new challenges (legacy-compat sentinel), so WP is
// awarded as flat values rather than betAmount-derived amounts.
const CHALLENGE_WIN_WP  = 50;
const CHALLENGE_DRAW_WP = 25;

// ─── Challenge constants ──────────────────────────────────────────────────────
const ACTIVE_CHALLENGE_STATUSES = [
  'waiting',
  'opponent_joined',
  'creator_submitted',
  'opponent_submitted',
];

initializeApp();
const db = getFirestore();

// ── _generateCode ─────────────────────────────────────────────────────────────
function _generateCode() {
  const CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  let code = '';
  for (let i = 0; i < 6; i++) {
    code += CHARS.charAt(Math.floor(Math.random() * CHARS.length));
  }
  return code;
}

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

  const BATCH_SIZE  = 200;
  const MAX_BATCHES = 500;

  if (WP_CAP_ACTIVE) {
    let capLastDoc  = null;
    let capBatchNum = 0;
    let capCount    = 0;

    console.log(`[weeklyReset] WP cap pass starting (cap=${WP_WEEKLY_CAP})`);

    do {
      if (capBatchNum >= MAX_BATCHES) {
        console.warn(`[weeklyReset] WP cap pass hit MAX_BATCHES (${MAX_BATCHES}). Stopping. ${capCount} users clamped so far.`);
        break;
      }

      let capQuery = db.collection('users')
        .where('weeklyPoints', '>', WP_WEEKLY_CAP)
        .orderBy('weeklyPoints', 'desc')
        .limit(BATCH_SIZE);

      if (capLastDoc) capQuery = capQuery.startAfter(capLastDoc);

      const capSnap = await capQuery.get();
      if (capSnap.empty) break;

      const capBatch = db.batch();
      capSnap.docs.forEach(doc => {
        capBatch.update(doc.ref, { weeklyPoints: WP_WEEKLY_CAP });
      });

      await capBatch.commit();
      capCount    += capSnap.size;
      capLastDoc   = capSnap.docs[capSnap.docs.length - 1];
      capBatchNum++;

      console.log(`[weeklyReset] Cap batch ${capBatchNum}: clamped ${capSnap.size} users (total so far: ${capCount})`);

    } while (true);

    console.log(`[weeklyReset] WP cap pass complete. ${capCount} users clamped to ${WP_WEEKLY_CAP}.`);
  }

  const topSnap = await db
    .collection('users')
    .orderBy('weeklyPoints', 'desc')
    .limit(3)
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
        weeklyPoints:                  0,
        weeklyReset:                   FieldValue.serverTimestamp(),
        lastStreakWPMilestoneAwarded:   0,
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
// ─── SECTION 2: STAKE CHALLENGE ECONOMY ──────────────────────────────────────
// =============================================================================

exports.createChallenge = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const { animeTitle, stakeAmount, opponentUid = null } = request.data;

    if (typeof animeTitle !== 'string' || !animeTitle.trim()) {
      throw new HttpsError('invalid-argument', 'invalid_anime_title');
    }

    if (typeof stakeAmount !== 'number' || !Number.isInteger(stakeAmount)) {
      throw new HttpsError('invalid-argument', 'invalid_stake_amount');
    }
    if (stakeAmount < 50) {
      throw new HttpsError('invalid-argument', 'stake_below_minimum');
    }
    if (stakeAmount % 50 !== 0) {
      throw new HttpsError('invalid-argument', 'stake_not_multiple_of_50');
    }

    const userSnap = await db.collection('users').doc(uid).get();
    const userData = userSnap.data() || {};
    const maxStake = userData.premiumActive === true ? 2500 : 1000;
    if (stakeAmount > maxStake) {
      throw new HttpsError('invalid-argument', 'stake_exceeds_limit');
    }

    const questionsSnap = await db.collection('questions')
      .where('animeTitle', '==', animeTitle)
      .get();
    if (questionsSnap.empty) {
      throw new HttpsError('not-found', 'no_questions_for_anime');
    }
    const allIds      = questionsSnap.docs.map(d => d.id);
    const shuffled    = [...allIds].sort(() => Math.random() - 0.5);
    const questionIds = shuffled.slice(0, Math.min(10, allIds.length));

    const [asCreator, asOpponent] = await Promise.all([
      db.collection('challenges')
        .where('creatorUid', '==', uid)
        .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)
        .get(),
      db.collection('challenges')
        .where('opponentUid', '==', uid)
        .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)
        .get(),
    ]);
    if (asCreator.size + asOpponent.size >= 2) {
      throw new HttpsError('resource-exhausted', 'too_many_active_challenges');
    }

    const now        = new Date();
    const todayWAT   = _watDateString(now);
    const expiresAt  = Timestamp.fromDate(new Date(now.getTime() + 48 * 60 * 60 * 1000));
    let shareCode;
    let codeSnap;
    do {
      shareCode = _generateCode();
      codeSnap  = await db.collection('challenges').doc(shareCode).get();
    } while (codeSnap.exists);

    const challengeRef = db.collection('challenges').doc(shareCode);
    const userRef      = db.collection('users').doc(uid);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      const animeCoins = data.animeCoins || 0;
      if (animeCoins < stakeAmount) {
        throw new HttpsError('resource-exhausted', 'insufficient_coins');
      }

      const createdDate  = data.challengesCreatedDate || '';
      let   createdToday = (createdDate === todayWAT)
        ? (data.challengesCreatedToday || 0)
        : 0;

      if (createdToday >= 3) {
        throw new HttpsError('resource-exhausted', 'daily_challenge_limit_reached');
      }

      const balanceAfter = animeCoins - stakeAmount;

      tx.update(userRef, {
        animeCoins:              FieldValue.increment(-stakeAmount),
        challengesCreatedToday:  createdToday + 1,
        challengesCreatedDate:   todayWAT,
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        'spend_challenge_stake',
        delta:       -stakeAmount,
        balanceAfter,
        timestamp:   FieldValue.serverTimestamp(),
      });

      tx.set(challengeRef, {
        creatorUid:      uid,
        creatorUsername: data.username || 'Anonymous',
        opponentUid:     opponentUid || null,
        stakeAmount,
        betAmount:       0,
        animeTitle,
        questionIds,
        status:          'waiting',
        isQuickMatch:    false,
        expiresAt,
        createdAt:       FieldValue.serverTimestamp(),
      });
    });

    console.log(
      `[createChallenge] uid=${uid} | anime=${animeTitle}` +
      ` | stake=${stakeAmount} AC | challengeId=${challengeRef.id}`
    );

    return { challengeId: challengeRef.id, questionIds };
  }
);

exports.joinChallenge = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const { challengeId } = request.data;
    if (typeof challengeId !== 'string' || !challengeId.trim()) {
      throw new HttpsError('invalid-argument', 'invalid_challenge_id');
    }

    const now          = new Date();
    const todayWAT     = _watDateString(now);
    const challengeRef = db.collection('challenges').doc(challengeId);
    const userRef      = db.collection('users').doc(uid);

    const [asCreator, asOpponent] = await Promise.all([
      db.collection('challenges')
        .where('creatorUid', '==', uid)
        .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)
        .get(),
      db.collection('challenges')
        .where('opponentUid', '==', uid)
        .where('status', 'in', ACTIVE_CHALLENGE_STATUSES)
        .get(),
    ]);
    if (asCreator.size + asOpponent.size >= 2) {
      throw new HttpsError('resource-exhausted', 'too_many_active_challenges');
    }

    let stakeAmount;

    await db.runTransaction(async (tx) => {
      const [challengeSnap, userSnap] = await Promise.all([
        tx.get(challengeRef),
        tx.get(userRef),
      ]);

      if (!challengeSnap.exists) {
        throw new HttpsError('not-found', 'challenge_not_found');
      }

      const challenge = challengeSnap.data();

      if (challenge.creatorUid === uid) {
        throw new HttpsError('invalid-argument', 'cannot_join_own_challenge');
      }
      if (challenge.status !== 'waiting') {
        throw new HttpsError('failed-precondition', 'challenge_not_waiting');
      }

      stakeAmount = challenge.stakeAmount;

      const userData   = userSnap.data() || {};
      const animeCoins = userData.animeCoins || 0;

      if (animeCoins < stakeAmount) {
        throw new HttpsError('resource-exhausted', 'insufficient_coins');
      }

      const joinedDate  = userData.challengesJoinedDate || '';
      let   joinedToday = (joinedDate === todayWAT)
        ? (userData.challengesJoinedToday || 0)
        : 0;

      if (joinedToday >= 3) {
        throw new HttpsError('resource-exhausted', 'daily_challenge_limit_reached');
      }

      const balanceAfter = animeCoins - stakeAmount;

      tx.update(userRef, {
        animeCoins:             FieldValue.increment(-stakeAmount),
        challengesJoinedToday:  joinedToday + 1,
        challengesJoinedDate:   todayWAT,
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        'spend_challenge_stake',
        delta:       -stakeAmount,
        balanceAfter,
        timestamp:   FieldValue.serverTimestamp(),
      });

      tx.update(challengeRef, {
        opponentUid:      uid,
        opponentUsername: userData.username || 'Anonymous',
        status:           'opponent_joined',
      });
    });

    console.log(
      `[joinChallenge] uid=${uid} | challengeId=${challengeId}` +
      ` | stake=${stakeAmount} AC deducted`
    );

    return { success: true, stakeAmount };
  }
);

// =============================================================================
// ─── SECTION 3: LIVE MULTIPLAYER CHALLENGE RESOLUTION ────────────────────────
// =============================================================================

exports.resolveChallengeOutcome = onDocumentUpdated(
  {
    document: 'challenges/{challengeId}',
    region:   'us-central1',
  },
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();

    if (!before || !after) return null;

    // FIX 4: Idempotency guard
    if (after.resolved === true) {
      console.log(
        `[resolveChallengeOutcome] ${event.params.challengeId} already resolved — skipping.`
      );
      return null;
    }

    const bothNow  = after.creatorScore  != null && after.opponentScore != null;
    const bothPrev = before.creatorScore != null && before.opponentScore != null;
    if (!bothNow)  return null;
    if (bothPrev)  return null;

    const {
      creatorUid,
      opponentUid,
      betAmount,
      creatorScore,
      opponentScore,
      animeTitle        = 'Unknown Anime',
      creatorUsername:  rawCreatorUsername,
      opponentUsername: rawOpponentUsername,
    } = after;

    const stake        = after.stakeAmount  || 0;
    const isQuickMatch = after.isQuickMatch === true;

    if (!rawCreatorUsername) {
      console.warn(
        `[resolveChallengeOutcome] ${event.params.challengeId}: ` +
        `creatorUsername missing — falling back to 'Anonymous'.`
      );
    }
    if (!rawOpponentUsername) {
      console.warn(
        `[resolveChallengeOutcome] ${event.params.challengeId}: ` +
        `opponentUsername missing — falling back to 'Anonymous'.`
      );
    }

    const creatorUsername  = rawCreatorUsername  || 'Anonymous';
    const opponentUsername = rawOpponentUsername || 'Anonymous';

    let outcome;
    if      (creatorScore  > opponentScore) outcome = 'creator_wins';
    else if (opponentScore > creatorScore)  outcome = 'opponent_wins';
    else                                    outcome = 'draw';

    const isDraw       = outcome === 'draw';
    const creatorWins  = outcome === 'creator_wins';
    const opponentWins = outcome === 'opponent_wins';

    const creatorOutcome  = isDraw ? 'draw' : (creatorWins  ? 'win' : 'lose');
    const opponentOutcome = isDraw ? 'draw' : (!creatorWins ? 'win' : 'lose');

    const creatorPointsChange  = isDraw ? 0 : (creatorWins  ?  betAmount : -betAmount);
    const opponentPointsChange = isDraw ? 0 : (!creatorWins ?  betAmount : -betAmount);

    const winnerBonus = Math.floor(stake * 0.8);
    const winnerTotal = stake + winnerBonus;
    const drawReturn  = stake - Math.floor(stake * 0.05);
    const houseFee    = isDraw
      ? Math.floor(stake * 0.05) * 2
      : Math.floor(stake * 0.2);

    const creatorRef   = db.collection('users').doc(creatorUid);
    const opponentRef  = db.collection('users').doc(opponentUid);
    const challengeRef = event.data.after.ref;

    const creatorMatchRef   = creatorRef.collection('matches').doc();
    const opponentMatchRef  = opponentRef.collection('matches').doc();
    const creatorCoinTxRef  = creatorRef.collection('coinTransactions').doc();
    const opponentCoinTxRef = opponentRef.collection('coinTransactions').doc();
    const houseFeeRef       = db.collection('house_fees').doc();

    await db.runTransaction(async (tx) => {

      const [cSnap, oSnap] = await Promise.all([
        tx.get(creatorRef),
        tx.get(opponentRef),
      ]);

      const cStats = (cSnap.data() || {}).stats  || {};
      const oStats = (oSnap.data() || {}).stats  || {};

      const cCurrentCoins = (cSnap.data() || {}).animeCoins || 0;
      const oCurrentCoins = (oSnap.data() || {}).animeCoins || 0;

      const cUpdate = {
        'stats.gamesPlayed': FieldValue.increment(1),
      };

      if (isQuickMatch) {
        cUpdate.weeklyPoints = FieldValue.increment(creatorWins ? 35 : (isDraw ? 15 : 5));
      } else {
        if (creatorWins) {
          cUpdate.weeklyPoints = FieldValue.increment(CHALLENGE_WIN_WP);
        } else if (isDraw) {
          cUpdate.weeklyPoints = FieldValue.increment(CHALLENGE_DRAW_WP);
        }
      }

      if      (creatorOutcome === 'win')  cUpdate['stats.gamesWon']  = FieldValue.increment(1);
      else if (creatorOutcome === 'lose') cUpdate['stats.gamesLost'] = FieldValue.increment(1);
      else                                cUpdate['stats.gamesDraw']  = FieldValue.increment(1);

      // FIX: track stake (actual AC wagered), not betAmount (always 0 for new challenges)
      if (stake > (cStats.hseStaked || 0)) cUpdate['stats.hseStaked'] = stake;
      if (creatorOutcome === 'win'  && winnerBonus > (cStats.hseWon  || 0)) cUpdate['stats.hseWon']  = winnerBonus;
      if (creatorOutcome === 'lose' && stake       > (cStats.hseLost || 0)) cUpdate['stats.hseLost'] = stake;

      const oUpdate = {
        'stats.gamesPlayed': FieldValue.increment(1),
      };

      if (isQuickMatch) {
        oUpdate.weeklyPoints = FieldValue.increment(opponentWins ? 35 : (isDraw ? 15 : 5));
      } else {
        if (!isDraw && !creatorWins) {
          oUpdate.weeklyPoints = FieldValue.increment(CHALLENGE_WIN_WP);
        } else if (isDraw) {
          oUpdate.weeklyPoints = FieldValue.increment(CHALLENGE_DRAW_WP);
        }
      }

      if      (opponentOutcome === 'win')  oUpdate['stats.gamesWon']  = FieldValue.increment(1);
      else if (opponentOutcome === 'lose') oUpdate['stats.gamesLost'] = FieldValue.increment(1);
      else                                 oUpdate['stats.gamesDraw']  = FieldValue.increment(1);

      // FIX: track stake (actual AC wagered), not betAmount (always 0 for new challenges)
      if (stake > (oStats.hseStaked || 0)) oUpdate['stats.hseStaked'] = stake;
      if (opponentOutcome === 'win'  && winnerBonus > (oStats.hseWon  || 0)) oUpdate['stats.hseWon']  = winnerBonus;
      if (opponentOutcome === 'lose' && stake       > (oStats.hseLost || 0)) oUpdate['stats.hseLost'] = stake;

      if (isQuickMatch) {
        const cAC = creatorWins  ? 35 : (isDraw ? 15 : 0);
        const oAC = opponentWins ? 35 : (isDraw ? 15 : 0);

        if (cAC > 0) {
          cUpdate.animeCoins = FieldValue.increment(cAC);
        }
        if (oAC > 0) {
          oUpdate.animeCoins = FieldValue.increment(oAC);
        }
      } else if (stake > 0) {
        if (creatorWins) {
          cUpdate.animeCoins = FieldValue.increment(winnerTotal);
        } else if (opponentWins) {
          oUpdate.animeCoins = FieldValue.increment(winnerTotal);
        } else {
          cUpdate.animeCoins = FieldValue.increment(drawReturn);
          oUpdate.animeCoins = FieldValue.increment(drawReturn);
        }
      }

      // 1. Seal the challenge
      tx.update(challengeRef, {
        outcome,
        status:   'completed',
        resolved: true,
      });

      // 2. Stats for each player
      tx.update(creatorRef,  cUpdate);
      tx.update(opponentRef, oUpdate);

      // 3. Coin transaction ledger
      if (isQuickMatch) {
        const cAC = creatorWins  ? 35 : (isDraw ? 15 : 0);
        const oAC = opponentWins ? 35 : (isDraw ? 15 : 0);

        if (cAC > 0) {
          tx.set(creatorCoinTxRef, {
            type:        'earn_quick_match',
            delta:       cAC,
            balanceAfter: cCurrentCoins + cAC,
            timestamp:   FieldValue.serverTimestamp(),
          });
        }
        if (oAC > 0) {
          tx.set(opponentCoinTxRef, {
            type:        'earn_quick_match',
            delta:       oAC,
            balanceAfter: oCurrentCoins + oAC,
            timestamp:   FieldValue.serverTimestamp(),
          });
        }
      } else if (stake > 0) {
        if (creatorWins) {
          tx.set(creatorCoinTxRef, {
            type:        'earn_challenge_win',
            delta:       winnerTotal,
            balanceAfter: cCurrentCoins + winnerTotal,
            timestamp:   FieldValue.serverTimestamp(),
          });
        } else if (opponentWins) {
          tx.set(opponentCoinTxRef, {
            type:        'earn_challenge_win',
            delta:       winnerTotal,
            balanceAfter: oCurrentCoins + winnerTotal,
            timestamp:   FieldValue.serverTimestamp(),
          });
        } else {
          tx.set(creatorCoinTxRef, {
            type:        'earn_challenge_win',
            delta:       drawReturn,
            balanceAfter: cCurrentCoins + drawReturn,
            timestamp:   FieldValue.serverTimestamp(),
          });
          tx.set(opponentCoinTxRef, {
            type:        'earn_challenge_win',
            delta:       drawReturn,
            balanceAfter: oCurrentCoins + drawReturn,
            timestamp:   FieldValue.serverTimestamp(),
          });
        }

        tx.set(houseFeeRef, {
          challengeId: event.params.challengeId,
          houseFee,
          stakeAmount: stake,
          creatorUid,
          opponentUid,
          outcome:     isDraw ? 'draw' : 'win',
          timestamp:   FieldValue.serverTimestamp(),
        });
      }

      // 4. Match history subcollection — now includes isQuickMatch + animeTitle
      tx.set(creatorMatchRef, {
        opponent:      opponentUsername,
        playerScore:   creatorScore,
        opponentScore: opponentScore,
        betScore:      betAmount,
        stakeAmount:   stake,
        outcome:       creatorOutcome,
        pointsChange:  creatorPointsChange,
        animeTitle,
        isQuickMatch,
        timestamp:     FieldValue.serverTimestamp(),
      });

      tx.set(opponentMatchRef, {
        opponent:      creatorUsername,
        playerScore:   opponentScore,
        opponentScore: creatorScore,
        betScore:      betAmount,
        stakeAmount:   stake,
        outcome:       opponentOutcome,
        pointsChange:  opponentPointsChange,
        animeTitle,
        isQuickMatch,
        timestamp:     FieldValue.serverTimestamp(),
      });
    });

    const logQM = isQuickMatch
      ? ` | QM wp=${creatorWins ? 35 : isDraw ? 15 : 5}/${opponentWins ? 35 : isDraw ? 15 : 5}` +
        ` ac=${creatorWins ? 35 : isDraw ? 15 : 0}/${opponentWins ? 35 : isDraw ? 15 : 0}`
      : ` | stake: ${stake} AC | houseFee: ${houseFee} AC`;

    console.log(
      `[resolveChallengeOutcome] ${event.params.challengeId} → ${outcome}` +
      ` | creator(${creatorUsername}): ${creatorScore}` +
      ` vs opponent(${opponentUsername}): ${opponentScore}` +
      logQM
    );

    return null;
  }
);

exports.expiredChallengeRefund = onSchedule(
  {
    schedule: '0 * * * *',
    region:   'us-central1',
    timeoutSeconds: 300,
    memory:         '256MiB',
  },
  async () => {
    const now = Timestamp.now();
    let processedCount = 0;

    const waitingSnap = await db.collection('challenges')
      .where('status', '==', 'waiting')
      .where('expiresAt', '<=', now)
      .get();

    for (const doc of waitingSnap.docs) {
      const data       = doc.data();
      const stakeAmt   = data.stakeAmount || 0;
      const creatorRef = db.collection('users').doc(data.creatorUid);

      try {
        await db.runTransaction(async (tx) => {
          const creatorSnap = await tx.get(creatorRef);
          const creatorData = creatorSnap.data() || {};

          tx.update(doc.ref, { status: 'expired_refunded' });

          if (stakeAmt > 0) {
            const currentCoins = creatorData.animeCoins || 0;
            tx.update(creatorRef, { animeCoins: FieldValue.increment(stakeAmt) });
            const txLogRef = creatorRef.collection('coinTransactions').doc();
            tx.set(txLogRef, {
              type:        'refund_challenge_stake',
              delta:       stakeAmt,
              balanceAfter: currentCoins + stakeAmt,
              timestamp:   FieldValue.serverTimestamp(),
            });
          }
        });
        processedCount++;
      } catch (err) {
        console.error(`[expiredChallengeRefund] ERROR on waiting challenge ${doc.id}:`, err);
      }
    }

    const joinedSnap = await db.collection('challenges')
      .where('status', '==', 'opponent_joined')
      .where('expiresAt', '<=', now)
      .get();

    for (const doc of joinedSnap.docs) {
      const data        = doc.data();
      const stakeAmt    = data.stakeAmount || 0;
      const creatorRef  = db.collection('users').doc(data.creatorUid);
      const opponentRef = db.collection('users').doc(data.opponentUid);

      try {
        await db.runTransaction(async (tx) => {
          const [creatorSnap, opponentSnap] = await Promise.all([
            tx.get(creatorRef),
            tx.get(opponentRef),
          ]);

          const cData = creatorSnap.data()  || {};
          const oData = opponentSnap.data() || {};

          tx.update(doc.ref, { status: 'expired_refunded' });

          if (stakeAmt > 0) {
            const cCoins = cData.animeCoins || 0;
            const oCoins = oData.animeCoins || 0;

            tx.update(creatorRef,  { animeCoins: FieldValue.increment(stakeAmt) });
            tx.update(opponentRef, { animeCoins: FieldValue.increment(stakeAmt) });

            const cTxRef = creatorRef.collection('coinTransactions').doc();
            tx.set(cTxRef, {
              type:        'refund_challenge_stake',
              delta:       stakeAmt,
              balanceAfter: cCoins + stakeAmt,
              timestamp:   FieldValue.serverTimestamp(),
            });

            const oTxRef = opponentRef.collection('coinTransactions').doc();
            tx.set(oTxRef, {
              type:        'refund_challenge_stake',
              delta:       stakeAmt,
              balanceAfter: oCoins + stakeAmt,
              timestamp:   FieldValue.serverTimestamp(),
            });
          }
        });
        processedCount++;
      } catch (err) {
        console.error(`[expiredChallengeRefund] ERROR on opponent_joined challenge ${doc.id}:`, err);
      }
    }

    const partialSnap = await db.collection('challenges')
      .where('status', 'in', ['creator_submitted', 'opponent_submitted'])
      .where('expiresAt', '<=', now)
      .get();

    for (const doc of partialSnap.docs) {
      const data        = doc.data();
      const stakeAmt    = data.stakeAmount || 0;
      const creatorRef  = db.collection('users').doc(data.creatorUid);
      const opponentRef = db.collection('users').doc(data.opponentUid);

      try {
        await db.runTransaction(async (tx) => {
          const [creatorSnap, opponentSnap] = await Promise.all([
            tx.get(creatorRef),
            tx.get(opponentRef),
          ]);

          const cData = creatorSnap.data()  || {};
          const oData = opponentSnap.data() || {};

          tx.update(doc.ref, { status: 'expired_refunded' });

          if (stakeAmt > 0) {
            const cCoins = cData.animeCoins || 0;
            const oCoins = oData.animeCoins || 0;

            tx.update(creatorRef,  { animeCoins: FieldValue.increment(stakeAmt) });
            tx.update(opponentRef, { animeCoins: FieldValue.increment(stakeAmt) });

            const cTxRef = creatorRef.collection('coinTransactions').doc();
            tx.set(cTxRef, {
              type:        'refund_challenge_stake',
              delta:       stakeAmt,
              balanceAfter: cCoins + stakeAmt,
              timestamp:   FieldValue.serverTimestamp(),
            });

            const oTxRef = opponentRef.collection('coinTransactions').doc();
            tx.set(oTxRef, {
              type:        'refund_challenge_stake',
              delta:       stakeAmt,
              balanceAfter: oCoins + stakeAmt,
              timestamp:   FieldValue.serverTimestamp(),
            });
          }
        });
        processedCount++;
      } catch (err) {
        console.error(`[expiredChallengeRefund] ERROR on ${doc.data().status} challenge ${doc.id}:`, err);
      }
    }

    console.log(
      `[expiredChallengeRefund] Processed ${processedCount} expired challenge(s).` +
      ` (waiting: ${waitingSnap.size}, opponent_joined: ${joinedSnap.size},` +
      ` partial_submitted: ${partialSnap.size})`
    );
  }
);

// =============================================================================
// ─── SECTION 4: HELPERS ──────────────────────────────────────────────────────
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
  const pcts = { 1: 0.50, 2: 0.30, 3: 0.20 };
  return pcts[rank] || 0;
}

function _watDateString(date = new Date()) {
  const wat = new Date(date.getTime() + 60 * 60 * 1000);
  return wat.toISOString().slice(0, 10);
}

function getWATDate(now) {
  const wat = new Date(now.getTime() + 60 * 60 * 1000);
  return wat.toISOString().slice(0, 10);
}

function getWATWindowId(now) {
  const watHour = (now.getUTCHours() + 1) % 24;
  const watDate = getWATDate(now);
  if (watHour >= 7  && watHour < 10) return `morning_${watDate}`;
  if (watHour >= 13 && watHour < 16) return `afternoon_${watDate}`;
  if (watHour >= 19 && watHour < 23) return `night_${watDate}`;
  return null;
}

// ── Helper: apply QM token check and consume inside a transaction ─────────────
// Re-used by both the real-match and ghost-match paths in joinMatchmakingQueue.
// Throws a plain Error with .isTokenError = true when tokens are exhausted so
// the caller can convert it to an HttpsError after leaving the transaction.
async function _consumeQMTokenInTx(tx, userRef, currentWindowId) {
  const uSnap = await tx.get(userRef);
  const uData = uSnap.data() || {};

  let qmWindowId    = uData.qmWindowId   ?? null;
  let qmTokens      = uData.qmTokens     ?? 0;
  let qmAdTokenUsed = uData.qmAdTokenUsed ?? false;

  // Lazy-bootstrap tokens when a new window is detected.
  if (qmWindowId !== currentWindowId) {
    qmTokens      = 3;
    qmAdTokenUsed = false;
    qmWindowId    = currentWindowId;
  }

  if (qmTokens <= 0) {
    const err = new Error('no_qm_tokens');
    err.isTokenError = true;
    throw err;
  }

  qmTokens -= 1;
  tx.update(userRef, { qmWindowId, qmTokens, qmAdTokenUsed });

  return qmTokens; // remaining after decrement
}

// =============================================================================
// ─── SECTION 5: STREAK MILESTONES ────────────────────────────────────────────
// =============================================================================

exports.awardStreakMilestone = onDocumentUpdated(
  { document: 'users/{uid}', region: 'us-central1' },
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();
    if (!before || !after) return null;

    const prevStreak = before.currentStreak || 0;
    const newStreak  = after.currentStreak  || 0;
    if (newStreak <= prevStreak) return null;

    const lastAwarded = after.lastStreakMilestoneAwarded || 0;

    let award = 0;
    let milestone = 0;

    if (newStreak >= 14 && lastAwarded < 14) {
      award = 150; milestone = 14;
    } else if (newStreak >= 7 && lastAwarded < 7) {
      award = 60; milestone = 7;
    } else if (newStreak >= 3 && lastAwarded < 3) {
      award = 25; milestone = 3;
    }

    if (!award) return null;

    const uid     = event.params.uid;
    const userRef = db.collection('users').doc(uid);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const snapData = snap.data();
      if ((snapData.lastStreakMilestoneAwarded || 0) >= milestone) return;

      const currentCoins = snapData.animeCoins || 0;
      const newBalance   = currentCoins + award;

      tx.update(userRef, {
        animeCoins:                  FieldValue.increment(award),
        lastStreakMilestoneAwarded:  milestone,
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        milestone === 14 ? 'earn_streak_14'
                   : milestone === 7  ? 'earn_streak_7'
                   :                    'earn_streak_3',
        delta:       award,
        balanceAfter: newBalance,
        timestamp:   FieldValue.serverTimestamp(),
      });
    });

    console.log(`[awardStreakMilestone] uid=${uid} streak=${newStreak} → +${award} AC (milestone ${milestone})`);
    return null;
  }
);

// =============================================================================
// ─── SECTION 6: REFERRAL CODE ────────────────────────────────────────────────
// =============================================================================

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

      const userData     = userSnap.data()     || {};
      const referrerData = referrerSnap.data() || {};

      if (userData.referralBonusClaimed === true) return;
      if (!referrerSnap.exists) return;
      if (referredBy === uid) return;

      const userBalanceAfter     = (userData.animeCoins     || 0) + 50;
      const referrerBalanceAfter = (referrerData.animeCoins || 0) + 100;

      tx.update(userRef, {
        firstQuizCompleted:   true,
        referralBonusClaimed: true,
        referredBy:           referredBy,
        animeCoins:           FieldValue.increment(50),
      });

      const userTxRef = userRef.collection('coinTransactions').doc();
      tx.set(userTxRef, {
        type:         'earn_referral',
        delta:        50,
        balanceAfter: userBalanceAfter,
        timestamp:    FieldValue.serverTimestamp(),
      });

      tx.update(referrerRef, {
        animeCoins: FieldValue.increment(100),
      });

      const referrerTxRef = referrerRef.collection('coinTransactions').doc();
      tx.set(referrerTxRef, {
        type:         'earn_referral',
        delta:        100,
        balanceAfter: referrerBalanceAfter,
        timestamp:    FieldValue.serverTimestamp(),
      });
    });

    console.log(`[claimReferralBonus] uid=${uid} → referrer=${referredBy} +100 AC`);
    return { success: true };
  }
);

// =============================================================================
// ─── SECTION 7: REWARDED AD — COIN AWARD ─────────────────────────────────────
// =============================================================================

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

      const todayWAT       = _watDateString();
      const lastWatchField = data.lastAdWatchDate;
      const lastWatchStr   = lastWatchField?.toDate
        ? _watDateString(lastWatchField.toDate())
        : null;

      let dailyAdWatched = (lastWatchStr === todayWAT)
        ? (data.dailyAdWatched || 0)
        : 0;

      if (dailyAdWatched >= 10) {
        result = { success: false, error: 'daily_limit_reached' };
        return;
      }

      const currentCoins   = data.animeCoins || 0;
      const newBalance     = currentCoins + 15;
      const newDailyCount  = dailyAdWatched + 1;

      tx.update(userRef, {
        animeCoins:      FieldValue.increment(15),
        dailyAdWatched:  newDailyCount,
        lastAdWatchDate: FieldValue.serverTimestamp(),
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        'earn_ad',
        delta:       15,
        balanceAfter: newBalance,
        timestamp:   FieldValue.serverTimestamp(),
      });

      result = {
        success:        true,
        coinsAwarded:   15,
        newBalance,
        dailyAdWatched: newDailyCount,
      };
    });

    if (result.success) {
      console.log(
        `[recordAdWatch] uid=${uid} +15 AC` +
        ` | dailyAdWatched=${result.dailyAdWatched}/10`
      );
    } else {
      console.log(`[recordAdWatch] uid=${uid} → daily_limit_reached`);
    }

    return result;
  }
);

exports.recordDailyLogin = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new Error('Unauthenticated');

    const userRef  = db.collection('users').doc(uid);
    const todayWAT = _watDateString();

    const yesterdayWAT = new Date(
      new Date(todayWAT + 'T00:00:00Z').getTime() - 24 * 60 * 60 * 1000
    ).toISOString().slice(0, 10);

    let coinsAwarded = 0;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      if (data.lastLoginDate === todayWAT) return;

      const currentCoins = data.animeCoins    || 0;
      const newBalance   = currentCoins + 20;

      const prevStreak = data.currentStreak || 0;
      const newStreak  = (data.lastLoginDate === yesterdayWAT)
        ? prevStreak + 1
        : 1;

      tx.update(userRef, {
        animeCoins:    FieldValue.increment(20),
        lastLoginDate: todayWAT,
        currentStreak: newStreak,
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:         'earn_daily',
        delta:        20,
        balanceAfter: newBalance,
        timestamp:    FieldValue.serverTimestamp(),
      });

      coinsAwarded = 20;
    });

    console.log(`[recordDailyLogin] uid=${uid} coinsAwarded=${coinsAwarded}`);
    return { coinsAwarded };
  }
);

// =============================================================================
// ─── SECTION 8: SPEND COINS ──────────────────────────────────────────────────
// =============================================================================

exports.spendCoins = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new Error('Unauthenticated');

    const { amount, type } = request.data;

    const validTypes = [
      'spend_hint', 'spend_cooldown', 'spend_retry',
      'spend_unlock', 'spend_shield', 'spend_timer',
    ];

    if (typeof amount !== 'number' || amount <= 0) {
      throw new Error('Invalid amount');
    }
    if (!validTypes.includes(type)) {
      throw new Error('Invalid spend type');
    }

    const userRef = db.collection('users').doc(uid);
    let result;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};
      const current = data.animeCoins || 0;

      if (current < amount) {
        result = { success: false, error: 'insufficient_coins', balance: current };
        return;
      }

      const newBalance = current - amount;

      tx.update(userRef, {
        animeCoins: FieldValue.increment(-amount),
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type,
        delta:       -amount,
        balanceAfter: newBalance,
        timestamp:   FieldValue.serverTimestamp(),
      });

      result = { success: true, newBalance };
    });

    console.log(`[spendCoins] uid=${uid} type=${type} -${amount} AC → ${JSON.stringify(result)}`);
    return result;
  }
);

// =============================================================================
// ─── SECTION 8b: REWARDED INTERSTITIAL — ANALYTICS ONLY ─────────────────────
// =============================================================================

exports.recordRewardedInterstitialWatch = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error('Unauthenticated');
    }

    const COINS_AWARDED = 0;

    if (COINS_AWARDED === 0) {
      console.log(`[recordRewardedInterstitialWatch] uid=${uid} COINS_AWARDED=0 — skipping Firestore writes`);
      return { success: true, coinsAwarded: 0, newBalance: null };
    }

    const userRef = db.collection('users').doc(uid);
    let newBalance;

    await db.runTransaction(async (tx) => {
      const snap    = await tx.get(userRef);
      const data    = snap.data() || {};
      const current = data.animeCoins || 0;

      newBalance = current + COINS_AWARDED;

      tx.update(userRef, {
        animeCoins: FieldValue.increment(COINS_AWARDED),
      });

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:         'earn_ad',
        delta:        COINS_AWARDED,
        balanceAfter: newBalance,
        timestamp:    FieldValue.serverTimestamp(),
      });
    });

    console.log(`[recordRewardedInterstitialWatch] uid=${uid} +${COINS_AWARDED} AC → newBalance=${newBalance}`);
    return { success: true, coinsAwarded: COINS_AWARDED, newBalance };
  }
);

// =============================================================================
// ─── SECTION 9: SUBMIT QUIZ ANSWERS ──────────────────────────────────────────
// =============================================================================

exports.submitQuizAnswers = onCall(
  { region: 'us-central1' },
  async (request) => {

    const uid = request.auth?.uid;
    if (!uid) {
      throw new Error('Unauthenticated');
    }

    const { sessionId, questionIds, selectedAnswers, timings, isDailyChallenge } = request.data;

    if (typeof sessionId !== 'string' || !sessionId.trim()) {
      throw new Error('invalid_session_id');
    }

    if (
      !Array.isArray(questionIds)           ||
      questionIds.length !== 10             ||
      !questionIds.every(id => typeof id === 'string' && id.length > 0)
    ) {
      throw new Error('invalid_question_ids');
    }

    if (new Set(questionIds).size !== 10) {
      throw new Error('duplicate_question_id');
    }

    if (
      !Array.isArray(selectedAnswers)     ||
      selectedAnswers.length !== 10       ||
      !selectedAnswers.every(
        a => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3))
      )
    ) {
      throw new Error('invalid_selected_answers');
    }

    if (
      !Array.isArray(timings)  ||
      timings.length !== 10    ||
      !timings.every(t => typeof t === 'number')
    ) {
      throw new Error('invalid_timings');
    }

    const sessionRef  = db.collection('users').doc(uid)
                          .collection('quizSessions').doc(sessionId);
    const sessionSnap = await sessionRef.get();

    if (sessionSnap.exists) {
      console.log(
        `[submitQuizAnswers] uid=${uid} sessionId=${sessionId}` +
        ` — cache hit, returning stored result`
      );
      return sessionSnap.data().result;
    }

    const CHUNK_SIZE   = 10;
    const questionDocs = [];

    for (let i = 0; i < questionIds.length; i += CHUNK_SIZE) {
      const chunk = questionIds.slice(i, i + CHUNK_SIZE);
      const refs  = chunk.map(id => db.collection('questions').doc(id));
      const snaps = await db.getAll(...refs);
      questionDocs.push(...snaps);
    }

    for (const snap of questionDocs) {
      if (!snap.exists) {
        console.warn(`[submitQuizAnswers] uid=${uid} — unknown questionId: ${snap.id}`);
        throw new Error('invalid_question_id');
      }
    }

    const questionMap = {};
    for (const snap of questionDocs) {
      questionMap[snap.id] = snap.data();
    }

    let correctCount = 0;
    let baseWP       = 0;

    for (let i = 0; i < 10; i++) {
      const question  = questionMap[questionIds[i]];
      const isCorrect = selectedAnswers[i] === question.correctAnswerIndex;

      if (isCorrect) {
        correctCount++;
        baseWP += (timings[i] >= 5) ? 15 : 10;
      }
    }

    const completionWP = 20;
    const isPerfect    = correctCount === 10;
    const acEarned     = 8;
    const todayWAT     = _watDateString();

    let totalWP;
    let result;
    let isDailyEligible = false;

    const userRef = db.collection('users').doc(uid);

    await db.runTransaction(async (tx) => {

      const [sessionCheck, userSnap] = await Promise.all([
        tx.get(sessionRef),
        tx.get(userRef),
      ]);

      if (sessionCheck.exists) return;

      const userData     = userSnap.data() || {};
      const currentCoins = userData.animeCoins || 0;
      const balanceAfter = currentCoins + acEarned;

      if (isDailyChallenge) {
        const storedDate = userData.dailyChallengeDate || '';
        const storedUsed = userData.dailyChallengeUsed === true;
        isDailyEligible  = (storedDate !== todayWAT || !storedUsed);
      }

      const applyMultiplier = isDailyEligible;
      totalWP = applyMultiplier
        ? Math.round((baseWP + completionWP) * 1.5)
        : (baseWP + completionWP);

      result = { correctCount, totalWP, acEarned, isPerfect };

      const userUpdateFields = {
        weeklyPoints: FieldValue.increment(totalWP),
        animeCoins:   FieldValue.increment(acEarned),
      };

      if (isDailyEligible) {
        userUpdateFields.dailyChallengeDate = todayWAT;
        userUpdateFields.dailyChallengeUsed = true;
      }

      tx.update(userRef, userUpdateFields);

      const txLogRef = userRef.collection('coinTransactions').doc();
      tx.set(txLogRef, {
        type:        'earn_quiz',
        delta:       acEarned,
        balanceAfter,
        timestamp:   FieldValue.serverTimestamp(),
      });

      tx.set(sessionRef, {
        result,
        timestamp: FieldValue.serverTimestamp(),
      });
    });

    console.log(
      `[submitQuizAnswers] uid=${uid} sessionId=${sessionId}` +
      ` | correct=${correctCount}/10 baseWP=${baseWP} totalWP=${totalWP}` +
      ` isPerfect=${isPerfect} dailyEligible=${isDailyEligible} isDailyChallenge=${!!isDailyChallenge} +${acEarned} AC`
    );

    return result;
  }
);

// =============================================================================
// ─── SECTION 10: LOGIN STREAK — WEEKLY POINTS MILESTONES ─────────────────────
// =============================================================================

exports.awardLoginStreakWP = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new Error('Unauthenticated');

    const MILESTONES = [
      { streak: 14, wp: 200 },
      { streak:  7, wp: 100 },
      { streak:  3, wp:  30 },
    ];

    const userRef = db.collection('users').doc(uid);
    let result;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      const currentStreak = data.currentStreak                 || 0;
      const lastAwarded   = data.lastStreakWPMilestoneAwarded  || 0;

      const hit = MILESTONES.find(
        ({ streak }) => currentStreak >= streak && lastAwarded < streak
      );

      if (!hit) {
        result = { awarded: false };
        return;
      }

      tx.update(userRef, {
        weeklyPoints:                 FieldValue.increment(hit.wp),
        lastStreakWPMilestoneAwarded: hit.streak,
      });

      result = { awarded: true, wpAwarded: hit.wp, milestone: hit.streak };
    });

    if (result.awarded) {
      console.log(
        `[awardLoginStreakWP] uid=${uid}` +
        ` streak milestone=${result.milestone} → +${result.wpAwarded} WP`
      );
    } else {
      console.log(`[awardLoginStreakWP] uid=${uid} → no milestone reached`);
    }

    return result;
  }
);

// =============================================================================
// ─── SECTION 11: QUICK MATCH (RANDOM MATCHMAKING) ────────────────────────────
// =============================================================================

// ── consumeQMToken ────────────────────────────────────────────────────────────
// Kept for backward-compatibility and the ad-token flow. The Flutter client no
// longer calls this before searching — token deduction is now performed
// server-side inside joinMatchmakingQueue when a match is actually created.
exports.consumeQMToken = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const now             = new Date();
    const currentWindowId = getWATWindowId(now);

    if (!currentWindowId) {
      throw new HttpsError('failed-precondition', 'outside_qm_window');
    }

    const userRef = db.collection('users').doc(uid);
    let tokensRemaining;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      let qmWindowId    = data.qmWindowId   ?? null;
      let qmTokens      = data.qmTokens     ?? 0;
      let qmAdTokenUsed = data.qmAdTokenUsed ?? false;

      if (qmWindowId !== currentWindowId) {
        qmTokens      = 3;
        qmAdTokenUsed = false;
        qmWindowId    = currentWindowId;
      }

      if (qmTokens <= 0) {
        throw new HttpsError('resource-exhausted', 'no_qm_tokens');
      }

      qmTokens -= 1;
      tokensRemaining = qmTokens;

      tx.update(userRef, { qmWindowId, qmTokens, qmAdTokenUsed });
    });

    console.log(
      `[consumeQMToken] uid=${uid} | windowId=${currentWindowId}` +
      ` | tokensRemaining=${tokensRemaining}`
    );
    return { success: true, tokensRemaining, windowId: currentWindowId };
  }
);

exports.grantAdQMToken = onCall(
  { region: 'us-central1' },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Unauthenticated');

    const userRef = db.collection('users').doc(uid);
    let tokensRemaining;

    await db.runTransaction(async (tx) => {
      const now             = new Date();
      const currentWindowId = getWATWindowId(now);

      if (!currentWindowId) {
        throw new HttpsError('failed-precondition', 'outside_qm_window');
      }

      const snap = await tx.get(userRef);
      const data = snap.data() || {};

      let qmWindowId    = data.qmWindowId   ?? null;
      let qmTokens      = data.qmTokens     ?? 0;
      let qmAdTokenUsed = data.qmAdTokenUsed ?? false;

      if (qmWindowId !== currentWindowId) {
        qmTokens      = 3;
        qmAdTokenUsed = false;
        qmWindowId    = currentWindowId;
      }

      if (qmAdTokenUsed === true) {
        throw new HttpsError('resource-exhausted', 'ad_token_already_used');
      }

      if (qmTokens >= 4) {
        throw new HttpsError('resource-exhausted', 'already_at_max_tokens');
      }

      qmTokens     += 1;
      qmAdTokenUsed = true;
      tokensRemaining = qmTokens;

      tx.update(userRef, { qmWindowId, qmTokens, qmAdTokenUsed });
    });

    console.log(`[grantAdQMToken] uid=${uid} | tokensRemaining=${tokensRemaining}`);
    return { success: true, tokensRemaining };
  }
);

// ── joinMatchmakingQueue ──────────────────────────────────────────────────────
//
// Token deduction model (revised):
//   Tokens are only consumed when a match is actually created (real or ghost).
//   If no match is found (no opponent, no ghost session), NO token is deducted —
//   the caller can retry without penalty.  This replaces the old pre-call to
//   consumeQMToken in the Flutter client.
//
//   Window validation still rejects calls outside QM hours.

exports.joinMatchmakingQueue = onCall(
  { region: 'us-central1' },
  async (request) => {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new Error('Unauthenticated');

      const now             = new Date();
      const currentWindowId = getWATWindowId(now);

      if (!currentWindowId) {
        throw new HttpsError('failed-precondition', 'outside_qm_window');
      }

      const userRef  = db.collection('users').doc(uid);
      const userSnap = await userRef.get();
      const username = (userSnap.data() || {}).username || 'Anonymous';

      // ── All QM players queue as 'random' — anime is assigned by the server ──
      const queueRef = db.collection('matchmaking_queue').doc(uid);
      await queueRef.set({
        uid,
        animeTitle: 'random',
        joinedAt: FieldValue.serverTimestamp(),
        username,
      });

      const cutoff    = Timestamp.fromDate(new Date(Date.now() - 60 * 1000));
      const queueSnap = await db.collection('matchmaking_queue')
        .where('animeTitle', '==', 'random')
        .where('joinedAt',   '>=', cutoff)
        .limit(2)
        .get();

      const matchDoc = queueSnap.docs.find(doc => doc.id !== uid);

      if (matchDoc) {
        const matchedUid       = matchDoc.id;
        const opponentUsername = (matchDoc.data() || {}).username || 'Anonymous';

        // ── Pick a random anime that has ghost sessions (guarantees questions) ──
        const ghostTitlesSnap = await db.collection('ghost_sessions').limit(30).get();
        const availableTitles = ghostTitlesSnap.docs
          .filter(d => ((d.data().sessions) || []).length > 0)
          .map(d => d.id);

        if (availableTitles.length === 0) {
          // No anime available at all — clean up and bail
          await queueRef.delete();
          return { matched: false, isGhost: false };
        }

        const chosenAnime = availableTitles[Math.floor(Math.random() * availableTitles.length)];

        const questionsSnap = await db.collection('questions')
          .where('animeTitle', '==', chosenAnime)
          .get();

        if (questionsSnap.empty) {
          await queueRef.delete();
          return { matched: false, isGhost: false };
        }

        const allIds      = questionsSnap.docs.map(d => d.id);
        const shuffled    = [...allIds].sort(() => Math.random() - 0.5);
        const questionIds = shuffled.slice(0, 10);

        const expiresAt    = Timestamp.fromDate(new Date(Date.now() + 48 * 60 * 60 * 1000));
        const challengeRef = db.collection('challenges').doc();

        let txSuccess = false;
        try {
          await db.runTransaction(async (tx) => {
            const opponentSlot = await tx.get(matchDoc.ref);
            if (!opponentSlot.exists) throw new Error('match_taken');

            await _consumeQMTokenInTx(tx, userRef, currentWindowId);

            tx.delete(queueRef);
            tx.delete(matchDoc.ref);
            tx.set(challengeRef, {
              creatorUid:      uid,
              opponentUid:     matchedUid,
              creatorUsername: username,
              opponentUsername,
              animeTitle:      chosenAnime,
              betAmount:       0,
              stakeAmount:     0,
              status:          'opponent_joined',
              isQuickMatch:    true,
              questionIds,
              expiresAt,
              createdAt: FieldValue.serverTimestamp(),
            });
          });
          txSuccess = true;
        } catch (txErr) {
          if (txErr.isTokenError) {
            throw new HttpsError('resource-exhausted', 'no_qm_tokens');
          }
          if (txErr.message !== 'match_taken') throw txErr;
        }

        if (txSuccess) {
          console.log(
            `[joinMatchmakingQueue] REAL uid=${uid} vs ${matchedUid}` +
            ` | anime=${chosenAnime} | challengeId=${challengeRef.id}`
          );
          return {
            matched:     true,
            challengeId: challengeRef.id,
            questionIds,
            animeTitle:  chosenAnime,       // ← new: client needs this
            isCreator:   true,
            opponentUsername,
          };
        }
      }

      // ── Ghost match — pick random title that has sessions ─────────────────
      const ghostTitlesSnap = await db.collection('ghost_sessions').limit(30).get();
      const titlesWithSessions = ghostTitlesSnap.docs.filter(d =>
        ((d.data().sessions) || []).length > 0
      );

      if (titlesWithSessions.length > 0) {
        const titleDoc     = titlesWithSessions[Math.floor(Math.random() * titlesWithSessions.length)];
        const chosenAnime  = titleDoc.id;
        const sessions     = titleDoc.data().sessions;
        const chosen       = sessions[Math.floor(Math.random() * sessions.length)];
        const expiresAt    = Timestamp.fromDate(new Date(Date.now() + 60 * 60 * 1000));
        const challengeRef = db.collection('challenges').doc();

        try {
          await db.runTransaction(async (tx) => {
            await _consumeQMTokenInTx(tx, userRef, currentWindowId);
            tx.set(challengeRef, {
              creatorUid:     uid,
              opponentUid:    'ghost',
              ghostSessionId: chosen.sessionId,
              ghostUsername:  chosen.username,
              ghostScore:     chosen.score,
              animeTitle:     chosenAnime,
              betAmount:      0,
              stakeAmount:    0,
              status:         'ghost',
              isQuickMatch:   true,
              questionIds:    chosen.questionIds,
              expiresAt,
              createdAt: FieldValue.serverTimestamp(),
            });
          });
        } catch (txErr) {
          if (txErr.isTokenError) {
            throw new HttpsError('resource-exhausted', 'no_qm_tokens');
          }
          throw txErr;
        }

        console.log(
          `[joinMatchmakingQueue] GHOST uid=${uid}` +
          ` | ghost=${chosen.sessionId} | anime=${chosenAnime}` +
          ` | challengeId=${challengeRef.id}`
        );
        return {
          matched:       false,
          isGhost:       true,
          challengeId:   challengeRef.id,
          questionIds:   chosen.questionIds,
          animeTitle:    chosenAnime,        // ← new
          ghostUsername: chosen.username,
        };
      }

      // ── No match, no ghost ────────────────────────────────────────────────
      await queueRef.delete();
      console.log(`[joinMatchmakingQueue] NO MATCH uid=${uid} (token preserved)`);
      return { matched: false, isGhost: false };

    } catch (err) {
      console.error('[joinMatchmakingQueue] ERROR:', err);
      throw err;
    }
  }
);

exports.leaveMatchmakingQueue = onCall(
  { region: 'us-central1' },
  async (request) => {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new Error('Unauthenticated');

      await db.collection('matchmaking_queue').doc(uid).delete();

      console.log(`[leaveMatchmakingQueue] uid=${uid}`);
      return { success: true };

    } catch (err) {
      console.error('[leaveMatchmakingQueue] ERROR:', err);
      throw err;
    }
  }
);

exports.submitQuickMatchResult = onCall(
  { region: 'us-central1' },
  async (request) => {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new Error('Unauthenticated');

      const {
        challengeId,
        questionIds,
        selectedAnswers,
        timings,
      } = request.data;

      if (typeof challengeId !== 'string' || !challengeId.trim()) {
        throw new Error('invalid_challenge_id');
      }

      if (
        !Array.isArray(questionIds)   ||
        questionIds.length !== 10     ||
        !questionIds.every(id => typeof id === 'string' && id.length > 0)
      ) {
        throw new Error('invalid_question_ids');
      }

      if (new Set(questionIds).size !== 10) {
        throw new Error('duplicate_question_id');
      }

      if (
        !Array.isArray(selectedAnswers) ||
        selectedAnswers.length !== 10   ||
        !selectedAnswers.every(
          a => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3))
        )
      ) {
        throw new Error('invalid_selected_answers');
      }

      if (
        !Array.isArray(timings) ||
        timings.length !== 10   ||
        !timings.every(t => typeof t === 'number')
      ) {
        throw new Error('invalid_timings');
      }

      const CHUNK_SIZE   = 10;
      const questionDocs = [];

      for (let i = 0; i < questionIds.length; i += CHUNK_SIZE) {
        const chunk = questionIds.slice(i, i + CHUNK_SIZE);
        const refs  = chunk.map(id => db.collection('questions').doc(id));
        const snaps = await db.getAll(...refs);
        questionDocs.push(...snaps);
      }

      for (const snap of questionDocs) {
        if (!snap.exists) throw new Error('invalid_question_id');
      }

      const questionMap = {};
      for (const snap of questionDocs) questionMap[snap.id] = snap.data();

      let correctCount = 0;
      let baseWP       = 0;

      for (let i = 0; i < 10; i++) {
        const question  = questionMap[questionIds[i]];
        const isCorrect = selectedAnswers[i] === question.correctAnswerIndex;
        if (isCorrect) {
          correctCount++;
          baseWP += (timings[i] >= 5) ? 15 : 10;
        }
      }

      const completionWP = 20;
      const totalWP = baseWP + completionWP;

      const challengeRef  = db.collection('challenges').doc(challengeId);
      const challengeSnap = await challengeRef.get();
      if (!challengeSnap.exists) throw new Error('challenge_not_found');

      const challenge = challengeSnap.data();

      if (!challenge.isQuickMatch) throw new Error('not_a_quick_match');

      const isCreator  = challenge.creatorUid  === uid;
      const isOpponent = challenge.opponentUid === uid;
      if (!isCreator && !isOpponent) throw new Error('not_a_participant');

      const ghostMatch = challenge.opponentUid === 'ghost';

      if (ghostMatch) {
        if (challenge.status === 'completed') {
          console.log(
            `[submitQuickMatchResult] GHOST uid=${uid}` +
            ` challengeId=${challengeId} — already completed, skipping`
          );
          return {
            correctCount,
            isGhost:  true,
            outcome:  challenge.outcome || 'lose',
            wpEarned: 0,
            acEarned: 0,
          };
        }

        const ghostScore  = challenge.ghostScore ?? 0;
        const animeTitle  = challenge.animeTitle || 'Unknown Anime';
        const ghostUsername = challenge.ghostUsername || 'Ghost Opponent';

        let outcome, wpEarned, acEarned;
        if      (correctCount > ghostScore)  { outcome = 'win';  wpEarned = 35; acEarned = 35; }
        else if (correctCount === ghostScore) { outcome = 'draw'; wpEarned = 15; acEarned = 15; }
        else                                 { outcome = 'lose'; wpEarned = 5;  acEarned = 0;  }

        const userRef    = db.collection('users').doc(uid);
        const matchRef   = userRef.collection('matches').doc();

        await db.runTransaction(async (tx) => {
          const userSnap     = await tx.get(userRef);
          const currentCoins = (userSnap.data() || {}).animeCoins || 0;
          const newBalance   = currentCoins + acEarned;

          tx.update(challengeRef, {
            status:       'completed',
            outcome,
            creatorScore: correctCount,
            resolved:     true,
          });

          const userUpdate = {
            weeklyPoints:        FieldValue.increment(wpEarned),
            'stats.gamesPlayed': FieldValue.increment(1),
          };

          // Update win/loss/draw counter
          if      (outcome === 'win')  userUpdate['stats.gamesWon']  = FieldValue.increment(1);
          else if (outcome === 'draw') userUpdate['stats.gamesDraw']  = FieldValue.increment(1);
          else                         userUpdate['stats.gamesLost'] = FieldValue.increment(1);

          if (acEarned > 0) {
            userUpdate.animeCoins = FieldValue.increment(acEarned);
          }
          tx.update(userRef, userUpdate);

          if (acEarned > 0) {
            const txLogRef = userRef.collection('coinTransactions').doc();
            tx.set(txLogRef, {
              type:        'earn_quick_match',
              delta:       acEarned,
              balanceAfter: newBalance,
              timestamp:   FieldValue.serverTimestamp(),
            });
          }

          // Match history write for ghost QM
          tx.set(matchRef, {
            opponent:      ghostUsername,
            playerScore:   correctCount,
            opponentScore: ghostScore,
            betScore:      0,
            stakeAmount:   0,
            outcome,
            pointsChange:  0,
            animeTitle,
            isQuickMatch:  true,
            timestamp:     FieldValue.serverTimestamp(),
          });
        });

        console.log(
          `[submitQuickMatchResult] GHOST uid=${uid}` +
          ` | challengeId=${challengeId}` +
          ` | correct=${correctCount}/10 ghostScore=${ghostScore}` +
          ` | outcome=${outcome} +${wpEarned} WP +${acEarned} AC`
        );
        return { correctCount, isGhost: true, outcome, wpEarned, acEarned, opponentScore: ghostScore };
      }

      const scoreField = isCreator ? 'creatorScore' : 'opponentScore';

      if (challenge[scoreField] != null) {
        console.log(
          `[submitQuickMatchResult] REAL uid=${uid}` +
          ` | challengeId=${challengeId}` +
          ` | ${scoreField} already set — skipping`
        );
        return { correctCount, isGhost: false };
      }

      await challengeRef.update({ [scoreField]: correctCount });

      console.log(
        `[submitQuickMatchResult] REAL uid=${uid}` +
        ` | challengeId=${challengeId}` +
        ` | wrote ${scoreField}=${correctCount} (formula totalWP=${totalWP})`
      );
      return { correctCount, isGhost: false };

    } catch (err) {
      console.error('[submitQuickMatchResult] ERROR:', err);
      throw err;
    }
  }
);

exports.saveGhostSession = onCall(
  { region: 'us-central1' },
  async (request) => {
    try {
      const uid = request.auth?.uid;
      if (!uid) throw new Error('Unauthenticated');

      const { animeTitle, questionIds, answers, score, username } = request.data;

      if (typeof animeTitle !== 'string' || !animeTitle.trim()) {
        throw new Error('invalid_anime_title');
      }

      if (
        !Array.isArray(questionIds)  ||
        questionIds.length !== 10    ||
        !questionIds.every(id => typeof id === 'string' && id.length > 0)
      ) {
        throw new Error('invalid_question_ids');
      }

      if (
        !Array.isArray(answers)    ||
        answers.length !== 10      ||
        !answers.every(a => Number.isInteger(a) && (a === -1 || (a >= 0 && a <= 3)))
      ) {
        throw new Error('invalid_answers');
      }

      if (!Number.isInteger(score) || score < 0 || score > 10) {
        throw new Error('invalid_score');
      }

      const MIN_GHOST_SCORE = 6;
      if (score < MIN_GHOST_SCORE) {
      console.log(`[saveGhostSession] uid=${uid} score=${score} below threshold — not saved`);
      return { success: true, saved: false };
      }

      const sessionId = db.collection('ghost_sessions').doc().id;
      const ghostRef  = db.collection('ghost_sessions').doc(animeTitle);

      await db.runTransaction(async (tx) => {
        const snap     = await tx.get(ghostRef);
        const data     = snap.data() || {};
        const sessions = Array.isArray(data.sessions) ? [...data.sessions] : [];

        if (sessions.length >= 20) sessions.shift();

        sessions.push({
          sessionId,
          uid,
          username: typeof username === 'string' && username.trim()
            ? username.trim()
            : 'Anonymous',
          questionIds,
          answers,
          score,
          recordedAt: Timestamp.now(),
        });

        tx.set(ghostRef, { sessions }, { merge: true });
      });

      console.log(
        `[saveGhostSession] uid=${uid}` +
        ` | anime=${animeTitle}` +
        ` | sessionId=${sessionId}` +
        ` | score=${score}/10`
      );
      return { success: true };

    } catch (err) {
      console.error('[saveGhostSession] ERROR:', err);
      throw err;
    }
  }
);