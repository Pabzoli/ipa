// functions/test/featured.test.js — global homepage shelf rotation.
// Same 9 titles for every user; next window drawn from {6,12,18,24,48}h.
'use strict';
process.env.NODE_ENV = 'test';
const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { installFakes } = require('./_fakes');
const ctx = installFakes();
const fns = require('../index.js');
const { db } = ctx;
const H = require('./helpers');

const CATALOG = [
  'attack on titan', 'berserk', 'black clover', 'bleach', 'blue lock',
  'chainsaw man', 'classroom of the elite', 'death note', 'demon slayer',
  'dragon ball z', 'dr stone', 'fairy tail', 'fire force', "hell's paradise",
  'hunter x hunter', "jojo's bizarre adventure", 'jujutsu kaisen',
  "kuroko's basketball", 'mushoku tensei', 'my hero academia', 'naruto',
  'one piece', 'one punch man', 're zero', 'solo leveling',
  'sword art online', 'that time i got reincarnated as a slime',
  'tokyo ghoul', 'tokyo revengers', 'tower of god', 'vinland saga',
  'wind breaker',
];

const rotateCore = () =>
  globalThis.__featuredForTest.rotateCore(db, Date.now());
const seam = globalThis.__featuredForTest;

describe('featured rotation', () => {
  beforeEach(async () => {
    await H.clearDb(db);
    await db.collection('app_config').doc('anime_catalog').set({ titles: CATALOG });
  });

  it('seeds the shelf on first tick: 9 known titles, interval in set', async () => {
    const res = await rotateCore();
    assert.equal(res.rotated, true);
    assert.equal(res.titles.length, 9);
    assert.ok(seam.intervals.includes(res.intervalHours));
    for (const t of res.titles) assert.ok(CATALOG.includes(t));
    const doc = await H.getDoc(db, 'app_config/featured_rotation');
    assert.equal(doc.titles.length, 9);
    assert.ok(seam.intervals.includes(doc.intervalHours));
    assert.ok(doc.rotatesAt, 'rotatesAt set');
  });

  it('does not rotate before rotatesAt', async () => {
    const first = await rotateCore();
    const second = await globalThis.__featuredForTest.rotateCore(db, Date.now());
    assert.equal(second.rotated, false);
    assert.deepEqual(second.titles, first.titles);
  });

  it('rotates after expiry with a valid new shelf', async () => {
    const first = await rotateCore();
    const doc = await H.getDoc(db, 'app_config/featured_rotation');
    const expiryMs = doc.rotatesAt.ms ?? doc.rotatesAt.toMillis?.();
    const later = expiryMs + 1000;
    const res = await globalThis.__featuredForTest.rotateCore(db, later);
    assert.equal(res.rotated, true);
    assert.equal(res.titles.length, seam.shelfSize);
    assert.ok(seam.intervals.includes(res.intervalHours));
    void first;
  });

  it('falls back to bundled catalog when the live doc is absent', async () => {
    await H.clearDb(db);
    const res = await rotateCore();
    assert.equal(res.rotated, true);
    assert.equal(res.titles.length, 9);
  });
});
