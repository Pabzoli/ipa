// functions/test/house_social.test.js
// House social humanizer: decision helpers only (no Firestore needed).
// Run with: npm test -- house_social (NODE_ENV=test seam).

'use strict';

const assert = require('node:assert');
const { describe, it } = require('node:test');

process.env.NODE_ENV = 'test';
const fns = require('../index.js');
const H = fns._testHelpers || {};

describe('house social helpers', () => {
  it('exposes social seams', () => {
    assert.equal(typeof H._houseTargetScore, 'function');
    assert.equal(typeof H._houseIsHighStake, 'function');
    assert.equal(typeof H._houseSocialNum, 'function');
    assert.equal(typeof H._houseMaybeNudge, 'function');
    assert.equal(typeof H._housePruneFriends, 'function');
    assert.equal(typeof H._houseMaybeOutgoingFriendRequest, 'function');
    assert.equal(typeof H._houseEnsureFriendCode, 'function');
  });

  it('flags high stakes for risk takes', () => {
    assert.equal(H._houseIsHighStake(2000, 0), true);
    assert.equal(H._houseIsHighStake(100, 200), true);
    assert.equal(H._houseIsHighStake(100, 50), false);
  });

  it('clamps social config numbers', () => {
    assert.equal(H._houseSocialNum({}, 'duelAcceptRate', 70, 0, 100), 70);
    assert.equal(H._houseSocialNum({ duelAcceptRate: 1000 }, 'duelAcceptRate', 70, 0, 100), 100);
    assert.equal(H._houseSocialNum({ duelAcceptRate: 'x' }, 'duelAcceptRate', 70, 0, 100), 70);
  });

  it('targets plausible scores (blind: wins 7-10, losses 1-6 with tilt)', () => {
    for (let i = 0; i < 50; i++) {
      const win = H._houseTargetScore(null, true);
      const lose = H._houseTargetScore(null, false);
      assert.ok(win >= 7 && win <= 10, `win blind ${win}`);
      assert.ok(lose >= 1 && lose <= 6, `lose blind ${lose}`);
    }
  });

  it('wins ~against known opponent scores without exceeding 10', () => {
    for (let i = 0; i < 50; i++) {
      const w = H._houseTargetScore(7, true);
      assert.ok(w >= 8 && w <= 10, `win vs 7 -> ${w}`);
      const l = H._houseTargetScore(7, false);
      assert.ok(l >= 0 && l < 7, `lose vs 7 -> ${l}`);
    }
    assert.equal(H._houseTargetScore(10, true), 10);
  });

  it('peer backoff isolates refusers without hanging the queue', () => {
    const now = Date.now();
    assert.equal(H._houseBackedOff({ peerBackoff: { P1: now + 3600000 } }, 'P1', now), true);
    assert.equal(H._houseBackedOff({ peerBackoff: { P1: now - 1000 } }, 'P1', now), false);
    assert.equal(H._houseBackedOff({ peerBackoff: {} }, 'P2', now), false);
    assert.equal(H._houseBackedOff({}, 'P2', now), false);
  });
});
