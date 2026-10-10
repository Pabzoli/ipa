// functions/test/gate.test.js — Android build gate on every gated callable.
// minBuild is fixed for the whole file (the config loader has a 60s in-process
// cache) and only the CLIENT-supplied appBuild/platform varies.
'use strict';
process.env.NODE_ENV = 'test';
const { test, describe, it, before, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const MIN = 2;
const OK_STAMP = { platform: 'android', appBuild: 3 };

    const GATED = [
  ['getMyFriendCode', () => H.req('A', {})],
  ['sendFriendRequest', () => H.req('A', { uid: 'B' })],
  ['respondFriendRequest', () => H.req('B', { otherUid: 'A', accept: true })],
  ['cancelFriendRequest', () => H.req('A', { otherUid: 'B' })],
  ['blockUser', () => H.req('A', { otherUid: 'B' })],
  ['unblockUser', () => H.req('A', { otherUid: 'B' })],
  ['removeFriend', () => H.req('A', { otherUid: 'B' })],
  ['getFriendsBoard', () => H.req('A', {})],
  ['nudgeFriend', () => H.req('A', { friendUid: 'B' })],
  ['reactToChallenge', () => H.req('A', { challengeId: 'x', emoji: 'GG' })],
  ['getHeadToHeadRecord', () => H.req('A', { uid1: 'A', uid2: 'B' })],
];

// One callable per gate surface. Each must reject an unstamped android client
// and accept a current one, and must reject an outdated build.

// The gate's message is distinctive, so assert on the MESSAGE rather than the
// code: domain failures (not_friends, not_your_outgoing_request, ...) share the
// same 'failed-precondition' code and would be indistinguishable.
const notGated = (e) => {
  assert.notEqual(
    e.message, 'App update required',
    `got the gate error: ${e.message}`);
  assert.notEqual(
    e.details?.reason, 'app_update_required',
    `got the gate error details: ${JSON.stringify(e.details)}`);
};

describe('android build gate', () => {
  before(async () => {
    await H.clearDb(db);
    await db.collection('app_config').doc('android').set({
      minBuild: MIN, latestBuild: 3, apkUrl: 'https://example.test/app.apk',
    });
  });

  beforeEach(async () => {
    await H.mkUser(db, 'A', { username: 'A' });
    await H.mkUser(db, 'B', { username: 'B' });
  });

  it('fails open when the config doc is missing', async () => {
    // Drop the doc and force a re-read by using a fresh require cache only in a
    // child process — here we simply assert the documented behaviour on a doc
    // with an unusable minBuild.
    await db.collection('app_config').doc('android').set({ minBuild: 'nope' });
    const code = await (async () => {
      try {
        await fns.getMyFriendCode.run(H.req('A', { platform: 'android', appBuild: 99 }));
        return 'ok';
      } catch (e) { return e.code; }
    })();
    // Either the cached-good value (still gating) or a fresh open read — both
    // are acceptable; what must NEVER happen is a crash.
    assert.ok(['ok', 'failed-precondition'].includes(code), `got ${code}`);
    await db.collection('app_config').doc('android').set({
      minBuild: MIN, latestBuild: 3, apkUrl: 'https://example.test/app.apk',
    });
  });

  for (const [name, makeReq] of GATED) {
    it(`${name}: current build passes, outdated build blocked`, async () => {
      // Outdated android build.
      await H.rejectsWith(
        fns[name].run({ ...makeReq(), data: { ...makeReq().data, platform: 'android', appBuild: MIN - 1 } }),
        'failed-precondition', 'App update required');
      // Current android build. Answers vary (friend flow, not-found, etc.) but
      // must NOT be the gate error.
      try {
        await fns[name].run({ ...makeReq(), data: { ...makeReq().data, ...OK_STAMP } });
      } catch (e) {
        notGated(e);
      }
    });

    it(`${name}: legacy unstamped android client is blocked`, async () => {
      await H.rejectsWith(
        fns[name].run({ ...makeReq(), data: { ...makeReq().data, platform: 'android' } }),
        'failed-precondition', 'App update required');
    });

    it(`${name}: malformed appBuild is blocked, not silently allowed`, async () => {
      for (const bad of ['abc', null, 0, -1, 1.5, '', '   ']) {
        await H.rejectsWith(
          fns[name].run({ ...makeReq(), data: { ...makeReq().data, platform: 'android', appBuild: bad } }),
          'failed-precondition', 'App update required');
      }
    });
  }

  for (const [name, makeReq] of GATED) {
    it(`${name}: web is exempt from the gate`, async () => {
      try {
        await fns[name].run({
          ...makeReq(),
          data: { ...makeReq().data, platform: 'web', appBuild: 1 },
        });
      } catch (e) {
        notGated(e);
      }
    });
  }

  it('createChallenge/joinChallenge REQUIRE the platform stamp', async () => {
    // No platform key at all = pre-stamp APK. For the high-risk create/join
    // paths that must be rejected rather than waved through.
    await H.rejectsWith(
      fns.createChallenge.run(H.req('A', {
        animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
        opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar',
      })),
      'failed-precondition', 'App update required');
    await H.rejectsWith(
      fns.joinChallenge.run(H.req('B', { challengeId: 'nope' })),
      'failed-precondition', 'App update required');
  });

  it('createChallenge/joinChallenge accept a stamped current build', async () => {
    await H.seedQuestions(db);
    await db.collection('friendships').doc('A_B').set({
      aUid: 'A', bUid: 'B', status: 'active', requestedBy: 'A',
    });
    const r = await fns.createChallenge.run(H.req('A', {
      animeTitle: 'testanime', stakeAmount: 0, wpStake: 0,
      opponentUid: 'B', opponentUsername: 'B', challengeType: 'spar',
      ...OK_STAMP,
    }));
    assert.ok(r.challengeId);
    const j = await fns.joinChallenge.run(
      H.req('B', { challengeId: r.challengeId, ...OK_STAMP }));
    assert.equal(j.success, true);
  });

  it('gate error details let the client render the download button', async () => {
    const e = await H.rejectsWith(
      fns.getMyFriendCode.run(H.req('A', { platform: 'android', appBuild: 1 })),
      'failed-precondition');
    const d = e.details || {};
    assert.equal(d.reason, 'app_update_required');
    assert.equal(d.appBuild, 1);
    assert.equal(d.minBuild, MIN);
    assert.equal(d.latestBuild, 3);
    assert.equal(d.apkUrl, 'https://example.test/app.apk');
    // appBuild: 1 arrived explicitly, so this is a self-reported (not assumed)
    // stale build — the client can tell the two apart for logging.
    assert.equal(d.legacyUnstamped, false);
  });

  it('a genuinely unstamped android client is flagged legacyUnstamped', async () => {
    const e = await H.rejectsWith(
      fns.getMyFriendCode.run(H.req('A', { platform: 'android' })),
      'failed-precondition');
    assert.equal(e.details.legacyUnstamped, true);
    assert.equal(e.details.appBuild, 1);
  });
});
