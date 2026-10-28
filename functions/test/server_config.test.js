// functions/test/server_config.test.js — the seeding script must write exactly
// the same defaults the functions use as their fallback, or the effective
// fraud/security policy would silently differ depending on whether the doc
// exists.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
installFakes();
const fns = require('../index.js');
const seed = require('../../scripts/seed_server_config.js');

describe('server_config seeding parity', () => {
  it('antifraud defaults match the function fallbacks', () => {
    assert.deepEqual(
      seed.ANTIFRAUD_DEFAULT.fraud,
      fns._testHelpers.FRAUD_DEFAULTS,
      'scripts/seed_server_config.js drifted from FRAUD_DEFAULTS',
    );
    assert.equal(
      seed.ANTIFRAUD_DEFAULT.soloDailyCap,
      fns._testHelpers.SOLO_DECAY_THRESHOLD_DEFAULT,
    );
  });

  it('security defaults keep App Check and ad sessions in monitor mode', () => {
    assert.equal(seed.SECURITY_DEFAULT.enforceAppCheck, false);
    assert.equal(seed.SECURITY_DEFAULT.requireAdSession, false);
  });

  it('play_integrity defaults pin the APK certificate and stay log-only', () => {
    assert.equal(seed.PLAY_INTEGRITY_DEFAULT.packageName, 'com.animequiz.app');
    assert.deepEqual(
      seed.PLAY_INTEGRITY_DEFAULT.certificateSha256Digest,
      ['6edYv6JkZWefkzNwgx-1zO4Kh22eBnjQuHvRqp5r8QE'],
    );
    assert.equal(seed.PLAY_INTEGRITY_DEFAULT.enforce, false);
    assert.equal(seed.PLAY_INTEGRITY_DEFAULT.logOnly, true);
  });

  it('merge never drops a tuned server value', () => {
    const merged = seed.mergeDefaults(
      { fraud: { wCadence: 25, bandHigh: 60 }, soloDailyCap: 100 },
      { fraud: { wCadence: 10 } },
      { fraud: { bandHigh: 80 }, soloDailyCap: 150 },
    );
    assert.equal(merged.fraud.bandHigh, 80, 'existing server value wins');
    assert.equal(merged.fraud.wCadence, 10, 'legacy value fills a missing server key');
    assert.equal(merged.soloDailyCap, 150);
  });
});
