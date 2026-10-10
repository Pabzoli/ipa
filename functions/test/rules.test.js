// functions/test/rules.test.js — REAL firestore.rules coverage against the
// Firestore emulator (127.0.0.1:8080). Table-driven may/may-not assertions.
//
// This is the ONLY suite that talks to an emulator; money/friends/gate use the
// in-memory fake Admin SDK so they run without one.
'use strict';
const { test, describe, it, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const rt = require('@firebase/rules-unit-testing');

const RULES = fs.readFileSync(
  path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8');

const ALICE = 'uid_alice';
const BOB = 'uid_bob';
const CAROL = 'uid_carol';
const ADMIN = 'owMNkXmb6QSzO0xfHkSgMlx0zSJ3';

// ── Seeded fixtures ────────────────────────────────────────────────────────
const WEEK = '2026-10-05';

const seed = {
  [`users/${ALICE}`]: {
    username: 'alice', animeCoins: 500, weeklyPoints: 500,
    premiumActive: false, university: 'UNILAG',
    leaderboardEntryWeekId: WEEK,
    friendCode: 'AAAAA', friendCount: 2,
    outgoingReqDate: '', outgoingReqCount: 0,
    rivalCooldowns: {},
  },
  [`users/${BOB}`]: {
    username: 'bob', animeCoins: 300, weeklyPoints: 400,
    premiumActive: false, university: 'UNILAG',
    leaderboardEntryWeekId: WEEK,
  },
  [`users/${CAROL}`]: {
    username: 'carol', animeCoins: 900, weeklyPoints: 100,
    premiumActive: false, university: 'OAU',
    // DIFFERENT week → must be treated as a stranger to alice/bob
    leaderboardEntryWeekId: '2019-01-07',
  },
  'challenges/ch1': {
    creatorUid: ALICE, opponentUid: BOB, opponentUsername: 'bob',
    animeTitle: 'testanime', stakeAmount: 50, wpStake: 20,
    challengeType: 'rival', status: 'opponent_joined',
    questionIds: ['q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7', 'q8', 'q9', 'q10'],
  },
  'challenges/ch_settled': {
    creatorUid: ALICE, opponentUid: BOB, opponentUsername: 'bob',
    animeTitle: 'testanime', stakeAmount: 50, wpStake: 20,
    challengeType: 'rival', status: 'completed',
    creatorScore: 8, opponentScore: 4, resolved: true, outcome: 'creator_wins',
    questionIds: ['q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7', 'q8', 'q9', 'q10'],
  },
  'challenges/ch_code': {
    creatorUid: ALICE, opponentUid: null, opponentUsername: null,
    animeTitle: 'testanime', stakeAmount: 50, wpStake: 20,
    challengeType: 'code', status: 'waiting', shareCode: 'ABC123',
    questionIds: ['q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7', 'q8', 'q9', 'q10'],
  },
  'friendships/uid_alice_uid_bob': {
    aUid: ALICE, bUid: BOB, status: 'active', requestedBy: ALICE,
    sparWinsCount: 0,
  },
  'rivalries/uid_alice_uid_bob': {
    aUid: ALICE, bUid: BOB, status: 'active', seriesNo: 1, winsA: 0, winsB: 0,
  },
  'questions/q1': { animeTitle: 'testanime', difficulty: 'easy' },
  'prize_pool/2026-10-05': { amount: 1000 },
  'telemetry/user_blocks/events/ev1': { blockedBy: ALICE, blockedUid: BOB },
  'app_config/android': { minBuild: 2, latestBuild: 3, apkUrl: 'https://x.test/a.apk' },
  'friendCodes/AAAAAAAAAA': { uid: BOB },
};

// Partitioned into paths usable directly as collection/doc refs.
function makeSeeder() {
  const t = rt.initializeTestEnvironment({
    projectId: 'demo-quiz-rules-test',
    firestore: { host: '127.0.0.1', port: 8080, rules: RULES },
  });
  return t;
}

// ── Assertion helpers ────────────────────────────────────────────────────────
async function denied(promise) {
  await assert.rejects(promise, (err) => {
    // The compat SDK throws a FirebaseError with code 'permission-denied'.
    // Its message varies by request type: writes surface
    // "Missing or insufficient permissions." while document gets surface the
    // raw rules denial reason (e.g. "false for 'get' @ L7"), so match on BOTH
    // the code and the message.
    const msg = String(err?.message ?? err);
    const code = String(err?.code ?? '');
    assert.ok(
      code === 'permission-denied' ||
        /permission|PERMISSION_DENIED|denied|false for ['"]|No matching allow/i.test(msg),
      `expected permission-denied, got code=${code} msg=${msg}`);
    return true;
  }, 'expected a permission-denied failure');
}
async function allowed(promise, label = '') {
  try { await promise; }
  catch (e) {
    assert.fail(`${label} expected to succeed, failed: ${String(e?.message || e)}`);
  }
}

// Compat-SDK paths.
const doc = (db, p) => db.doc(p);
const col = (db, p) => db.collection(p);

describe('firestore.rules against the emulator', () => {
  let env;
  before(async () => {
    try {
      env = await makeSeeder();
    } catch (e) {
      throw new Error(
        'Firestore emulator not reachable on 127.0.0.1:8080. This suite is ' +
        'the project\u2019s only real rules coverage and needs it. Start it with ' +
        '`firebase emulators:exec --only firestore "node --test functions/test/rules.test.js"` ' +
        `or run the cached JAR directly. Underlying error: ${e?.message || e}`);
    }
    // Deterministic start: the emulator is a long-lived process, so data from a
    // previous run (a creatorScore written by an earlier suite) would make the
    // write-once test order-dependent. Wipe, then re-seed.
    await env.clearFirestore();
    await env.withSecurityRulesDisabled(async (ctx) => {
      const fdb = ctx.firestore();
      for (const [p, data] of Object.entries(seed)) {
        await doc(fdb, p).set(data);
      }
      // friendLinks
      await doc(fdb, `users/${ALICE}/friendLinks/${BOB}`)
        .set({ status: 'friend', otherUid: BOB, username: 'bob', since: 0 });
      // Alice's ledger entries (owner + append-only semantics)
      await doc(fdb, `users/${ALICE}/coinTransactions/tx1`)
        .set({ type: 'earn_quiz', delta: 10, balanceAfter: 510, timestamp: 0 });
      await doc(fdb, `users/${ALICE}/wpTransactions/wtx1`)
        .set({ type: 'earn_challenge_win', delta: 100, balanceAfter: 600, timestamp: 0 });
      await doc(fdb, `users/${ALICE}/matches/m1`)
        .set({ outcome: 'win' });
    });
  });

  after(async () => {
    // Required: the compat SDK keeps gRPC channels open, which would keep the
    // test process alive forever after the suite passes.
    await env.cleanup();
  });

  beforeEach(async () => {
    // Fresh reads are enough: rules are deterministic given fixture pointers.
  });

  // ── challenges ────────────────────────────────────────────────────────────
  describe('challenges', () => {
    it('authenticated user may read a challenge', async () => {
      const db = env.authenticatedContext(CAROL).firestore();
      await allowed(doc(db, 'challenges/ch1').get(), 'carol read challenge');
    });

    it('unauthenticated may not read a challenge', async () => {
      const db = env.unauthenticatedContext().firestore();
      await denied(doc(db, 'challenges/ch1').get());
    });

    it('client may NOT create a challenge (server-authoritative)', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await denied(doc(db, 'challenges/handmade').set({
        creatorUid: ALICE, opponentUid: BOB, animeTitle: 'x', stakeAmount: 999,
        wpStake: 999, challengeType: 'rival', status: 'waiting',
      }));
    });

    it('participant may write ONLY their own score, once', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await allowed(
        doc(db, 'challenges/ch1').update({ creatorScore: 7 }),
        'alice writes own score');
    });

    it('opponent may write only their own score', async () => {
      const db = env.authenticatedContext(BOB).firestore();
      await allowed(
        doc(db, 'challenges/ch1').update({ opponentScore: 4 }),
        'bob writes own score');
    });

    it('participant may NOT write the OTHER side score', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await denied(
        doc(db, 'challenges/ch1').update({ opponentScore: 10 }));
    });

    it('score cannot exceed the question count', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      // ch1 has 10 questions → 11 is out of range, 10 is in range.
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: 11 }));
    });

    it('score must be an int (no bool/string/double sneaking in)', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: '7' }));
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: 7.5 }));
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: true }));
    });

    it('score may not be negative', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: -1 }));
    });

    it('no mass-assignment: status alongside own score is denied', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: 7, status: 'completed' }));
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: 7, resolved: true }));
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: 7, outcome: 'creator_wins' }));
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: 7, stakeAmount: 0 }));
    });

    it('opponentUid-claim branch is gone (joins are CF-only)', async () => {
      const db = env.authenticatedContext(CAROL).firestore();
      await denied(doc(db, 'challenges/ch_code').update({ opponentUid: CAROL }));
    });

    it('score is write-once: a second write is denied', async () => {
      // ch1 now has creatorScore=7 from an earlier test (rules enforce live).
      const db = env.authenticatedContext(ALICE).firestore();
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: 9 }));
    });

    it('non-participant may not write anything', async () => {
      const db = env.authenticatedContext(CAROL).firestore();
      await denied(doc(db, 'challenges/ch1').update({ creatorScore: 7 }));
      await denied(doc(db, 'challenges/ch1').update({ opponentScore: 7 }));
    });

    it('challenge deletes are impossible for clients', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await denied(doc(db, 'challenges/ch1').delete());
    });
  });

  // ── users ─────────────────────────────────────────────────────────────────
  describe('users', () => {
    it('owner may read own doc', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await allowed(doc(db, `users/${ALICE}`).get(), 'alice reads self');
    });

    it('same-week entrant may read another same-week entrant', async () => {
      const db = env.authenticatedContext(BOB).firestore();
      await allowed(doc(db, `users/${ALICE}`).get(), 'bob reads alice');
    });

    it('different-week entrant may NOT read a same-week entrant', async () => {
      const db = env.authenticatedContext(CAROL).firestore();
      await denied(doc(db, `users/${ALICE}`).get());
    });

    it('no entry week matches nobody', async () => {
      const db = env.authenticatedContext(BOB).firestore();
      await denied(doc(db, 'users/uid_nobody').get());
    });

    it('unauthenticated may not list or read users', async () => {
      const db = env.unauthenticatedContext().firestore();
      await denied(doc(db, `users/${ALICE}`).get());
      await denied(col(db, 'users').get());
    });

    it('self-update cannot touch economy / entitlement fields', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      for (const f of [
        'animeCoins', 'weeklyPoints', 'premiumActive', 'stats', 'totalScore',
        'friendCode', 'friendCount', 'outgoingReqCount', 'outgoingReqDate',
        'failedCodeCount', 'failedCodeDate',
        'leaderboardEntryWeekId', 'wpStakedToday', 'wpEarnedToday',
        'qmTokens', 'qmAvgScore', 'qmAvgCount',
        'sparsCreatedToday', 'sparsCreatedDate', 'sparsJoinedToday', 'sparsJoinedDate',
        'rivalCooldowns', 'lastRivalUid', 'lastRivalChallenge',
        'achievementsGranted', 'ownedCosmetics', 'dailyAdWatched',
        'unlockedCategories', 'phoneVerified', 'leaderboardEntryEmail',
      ]) {
        await denied(
          doc(db, `users/${ALICE}`).update({ [f]: 1 }),
          `self-update of ${f}`);
      }
    });

    it('self-update CAN change cosmetic-free display fields', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await allowed(
        doc(db, `users/${ALICE}`).update({ username: 'alice2', university: 'OAU' }),
        'alice updates username/university');
    });

    it('new-user create must NOT seed economy fields', async () => {
      const db = env.authenticatedContext('uid_new').firestore();
      await denied(doc(db, 'users/uid_new').set({
        username: 'new', animeCoins: 100000, weeklyPoints: 100000,
      }));
      await denied(doc(db, 'users/uid_new2').set({
        username: 'new', premiumActive: true,
      }));
      await denied(doc(db, 'users/uid_new3').set({
        username: 'new', friendCode: 'AAAAAA', friendCount: 50,
      }));
    });

    it('new-user create of a clean minimal profile is allowed', async () => {
      const db = env.authenticatedContext('uid_clean').firestore();
      await allowed(doc(db, 'users/uid_clean').set({ username: 'clean' }));
    });

    it('cannot create or update another user doc', async () => {
      const db = env.authenticatedContext(ALICE).firestore();
      await denied(doc(db, 'users/uid_bob').update({ username: 'hacked' }));
      await denied(doc(db, 'users/uid_impersonate').set({ username: 'x' }));
    });

    it('admin sees every player regardless of week', async () => {
      const db = env.authenticatedContext(ADMIN).firestore();
      await allowed(doc(db, `users/${CAROL}`).get(), 'admin reads stale-week carol');
      await allowed(doc(db, `users/${ALICE}`).get(), 'admin reads alice');
    });
  });

  // ── friends graph ─────────────────────────────────────────────────────────
  describe('friends graph', () => {
    it('friendCodes is a sealed collection (no enumeration oracle)', async () => {
      const alice = env.authenticatedContext(ALICE).firestore();
      await denied(doc(alice, 'friendCodes/AAAAAAAAAA').get());
      await denied(col(alice, 'friendCodes').get());
      await denied(doc(alice, 'friendCodes/ZZZZZZZZZZ').set({ uid: ALICE }));
      const anon = env.unauthenticatedContext().firestore();
      await denied(doc(anon, 'friendCodes/AAAAAAAAAA').get());
    });

    it('friendship pair doc: participants read, everyone else denied', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const b = env.authenticatedContext(BOB).firestore();
      const c = env.authenticatedContext(CAROL).firestore();
      await allowed(doc(a, 'friendships/uid_alice_uid_bob').get(), 'alice reads pair');
      await allowed(doc(b, 'friendships/uid_alice_uid_bob').get(), 'bob reads pair');
      await denied(doc(c, 'friendships/uid_alice_uid_bob').get());
      await denied(env.unauthenticatedContext().firestore()
        .doc('friendships/uid_alice_uid_bob').get());
    });

    it('friendship pair docs are CF-only for writes', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const path_ = 'friendships/uid_alice_uid_carol';
      await denied(doc(a, path_).set({
        aUid: ALICE, bUid: CAROL, status: 'active', requestedBy: ALICE,
      }));
      await denied(doc(a, 'friendships/uid_alice_uid_bob').update({ status: 'blocked' }));
      await denied(doc(a, 'friendships/uid_alice_uid_bob')
        .update({ sparWinsDate: 'x', sparWinsCount: 99 }));
      await denied(doc(a, 'friendships/uid_alice_uid_bob').delete());
    });

    it('friendLinks: owner reads, writes are CF-only', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const b = env.authenticatedContext(BOB).firestore();
      const p = `users/${ALICE}/friendLinks/${CAROL}`;
      await allowed(doc(a, `users/${ALICE}/friendLinks/${BOB}`).get(), 'owner read');
      // Carol cannot read Alice's friend list.
      await denied(doc(env.authenticatedContext(CAROL).firestore(),
        `users/${ALICE}/friendLinks/${BOB}`).get());
      // Owner herself cannot forge a friendship doc.
      await denied(doc(a, p).set({ status: 'friend', username: 'carol' }));
      await denied(doc(a, p).set({ status: 'blocked', username: 'carol' }));
      await denied(doc(a, `users/${ALICE}/friendLinks/${BOB}`)
        .update({ status: 'blocked' }));
      await denied(doc(a, `users/${ALICE}/friendLinks/${BOB}`).delete());
      // Bob cannot write into Alice's subcollection at all.
      await denied(doc(b, p).set({ status: 'friend', username: 'x' }));
    });

    it('rivalries: participants read, writes CF-only', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const b = env.authenticatedContext(BOB).firestore();
      const c = env.authenticatedContext(CAROL).firestore();
      await allowed(doc(a, 'rivalries/uid_alice_uid_bob').get(), 'alice reads rivalry');
      await allowed(doc(b, 'rivalries/uid_alice_uid_bob').get(), 'bob reads rivalry');
      await denied(doc(c, 'rivalries/uid_alice_uid_bob').get());
      await denied(doc(a, 'rivalries/uid_alice_uid_bob').update({ winsA: 4 }));
      await denied(doc(a, 'rivalries/uid_alice_uid_bob').delete());
      await denied(doc(a, 'rivalries/uid_alice_uid_bob')
        .set({ aUid: ALICE, bUid: BOB, status: 'active' }));
    });
  });

  // ── ledgers + misc collections ────────────────────────────────────────────
  describe('ledgers and reads', () => {
    it('coinTransactions: owner appends with a whitelisted type, no updates', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const base = 'users/uid_alice/coinTransactions';
      await allowed(doc(a, `${base}/ok`).set({
        type: 'earn_quiz', delta: 5, balanceAfter: 505, timestamp: 0,
      }), 'whitelisted coin tx');
      await denied(doc(a, `${base}/bad`).set({
        type: 'earn_admin_cheat', delta: 999999, balanceAfter: 999999, timestamp: 0,
      }));
      await denied(doc(a, `${base}/ok`).update({ delta: 999999 }));
      await denied(doc(a, `${base}/ok`).delete());
      await denied(doc(a, `${base}/bad2`).set({ delta: 5, balanceAfter: 1 }));
    });

    it('wpTransactions: owner appends with a whitelisted type only', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const base = 'users/uid_alice/wpTransactions';
      await allowed(doc(a, `${base}/ok`).set({
        type: 'earn_challenge_win', delta: 100, balanceAfter: 600, timestamp: 0,
      }), 'whitelisted wp tx');
      await denied(doc(a, `${base}/bad`).set({
        type: 'earn_challenge_win_legacy', delta: 1, balanceAfter: 1, timestamp: 0,
      }));
      await denied(doc(a, `${base}/ok`).update({ delta: 1 }));
    });

    it('matches subcollection: owner read only, no client writes', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const b = env.authenticatedContext(BOB).firestore();
      await allowed(doc(a, 'users/uid_alice/matches/m1').get(), 'owner reads own match');
      await denied(doc(b, 'users/uid_alice/matches/m1').get());
      await denied(doc(a, 'users/uid_alice/matches/handmade')
        .set({ outcome: 'win' }));
    });

    it('questions: authenticated read, write denied', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const anon = env.unauthenticatedContext().firestore();
      await allowed(doc(a, 'questions/q1').get());
      await denied(doc(anon, 'questions/q1').get());
      await denied(doc(a, 'questions/handmade').set({ difficulty: 'easy' }));
      await denied(doc(a, 'questions/q1').update({ difficulty: 'hard' }));
    });

    it('prize_pool: authenticated read, write denied', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      await allowed(doc(a, 'prize_pool/2026-10-05').get());
      await denied(doc(a, 'prize_pool/2026-10-05').update({ amount: 99999 }));
      await denied(doc(a, 'prize_pool/forged').set({ amount: 1 }));
    });

    it('telemetry is sealed both ways', async () => {
      const a = env.authenticatedContext(ALICE).firestore();
      const anon = env.unauthenticatedContext().firestore();
      await denied(doc(a, 'telemetry/user_blocks/events/ev1').get());
      await denied(doc(anon, 'telemetry/user_blocks/events/ev1').get());
      await denied(doc(a, 'telemetry/user_blocks/events/ev1')
        .set({ blockedBy: 'x' }));
      await denied(doc(a, 'telemetry/any/deep/path').set({ x: 1 }));
    });

    it('app_config/android: publicly readable, admin-only writable', async () => {
      const alice = env.authenticatedContext(ALICE).firestore();
      const anon = env.unauthenticatedContext().firestore();
      const admin = env.authenticatedContext(ADMIN).firestore();
      // Public read is REQUIRED so the update wall can render pre-sign-in.
      await allowed(doc(anon, 'app_config/android').get(), 'anonymous reads gate config');
      await allowed(doc(alice, 'app_config/android').get());
      // A client must never be able to lower its own gate.
      await denied(doc(alice, 'app_config/android').update({ minBuild: 1 }));
      await denied(doc(anon, 'app_config/android').update({ minBuild: 1 }));
      await allowed(doc(admin, 'app_config/android').update({ minBuild: 3 }),
        'admin arms the gate');
    });

    it('other app_config docs require auth and are not client-writable', async () => {
      const alice = env.authenticatedContext(ALICE).firestore();
      const anon = env.unauthenticatedContext().firestore();
      await denied(doc(anon, 'app_config/antifraud').get());
      await denied(doc(alice, 'app_config/antifraud').update({ x: 1 }));
    });
  });
});
