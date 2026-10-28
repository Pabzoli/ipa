// scripts/upload_questions_rest.js — Firestore upload without a service-account key.
// Uses a user OAuth token (gcloud auth print-access-token) via the REST API.
//
// Usage:
//   $env:FIRESTORE_TOKEN = gcloud auth print-access-token   # PowerShell
//   node scripts/upload_questions_rest.js                    # dry run
//   node scripts/upload_questions_rest.js --commit           # upload + seed catalog docs
//
// What --commit does:
//   1. Lists existing questions/ (animeTitle+question only) via REST.
//   2. Dedups data/questions_input.json against live docs, batchWrites the new ones.
//   3. Seeds app_config/anime_catalog {titles: [...32]} and an initial
//      app_config/featured_rotation shelf (the scheduler takes over after).
// The token is read from the env and NEVER printed.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PROJECT_ID = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', '.firebaserc'), 'utf8')
).projects.default;
const DB = '(default)';
const BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/${DB}/documents`;

const TITLES = [
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
const INTERVALS = [6, 12, 18, 24, 48];

function enc(v) {
  if (v === null || v === undefined) return { nullValue: null };
  if (typeof v === 'string') return { stringValue: v };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(enc) } };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === 'object') {
    const fields = {};
    for (const [k, x] of Object.entries(v)) fields[k] = enc(x);
    return { mapValue: { fields } };
  }
  return { stringValue: String(v) };
}
function dec(v) {
  if (!v) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('nullValue' in v) return null;
  if ('timestampValue' in v) return v.timestampValue;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(dec);
  if ('mapValue' in v) {
    const o = {};
    for (const [k, x] of Object.entries(v.mapValue.fields || {})) o[k] = dec(x);
    return o;
  }
  return null;
}

let TOKEN = null;
async function req(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`${method} ${url.split('?')[0].slice(-60)} -> ${res.status}: ${t.slice(0, 300)}`);
  }
  return res.json();
}

async function listExistingKeys() {
  const keys = new Set();
  let pageToken = '';
  let total = 0;
  do {
    let url = `${BASE}/questions?pageSize=1000&mask.fieldPaths=animeTitle&mask.fieldPaths=question`;
    if (pageToken) url += `&pageToken=${encodeURIComponent(pageToken)}`;
    const out = await req('GET', url);
    for (const doc of out.documents || []) {
      total++;
      const f = doc.fields || {};
      const a = String(dec(f.animeTitle) || '').trim().toLowerCase();
      const q = String(dec(f.question) || '').toLowerCase().replace(/\s+/g, ' ').trim();
      if (a && q) keys.add(`${a}::${q}`);
    }
    pageToken = out.nextPageToken || '';
  } while (pageToken);
  return { total, keys };
}

const AUTO = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
function autoId() {
  return Array.from(crypto.randomBytes(20)).map((b) => AUTO[b % 62]).join('');
}

async function batchWriteNew(entries) {
  let written = 0;
  for (let i = 0; i < entries.length; i += 400) {
    const chunk = entries.slice(i, i + 400);
    const writes = chunk.map((e) => ({
      update: {
        name: `projects/${PROJECT_ID}/databases/${DB}/documents/questions/${autoId()}`,
        fields: {
          question: enc(e.question),
          options: enc(e.options),
          correctAnswerIndex: enc(e.correctAnswerIndex),
          animeTitle: enc(e.anime),
          difficulty: enc(e.difficulty),
          qVersion: enc(1),
          createdAt: enc(new Date()),
        },
      },
    }));
    await req('POST', `${BASE}:batchWrite`, { writes });
    written += chunk.length;
    console.log(`  uploaded ${written}/${entries.length}`);
  }
  return written;
}

function shuffled(arr) {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = crypto.randomInt(i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

async function main() {
  const commit = process.argv.includes('--commit');
  TOKEN = process.env.FIRESTORE_TOKEN || '';
  if (!TOKEN) {
    console.error('FIRESTORE_TOKEN is empty. Run: $env:FIRESTORE_TOKEN = gcloud auth print-access-token');
    process.exit(1);
  }
  const input = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'data', 'questions_input.json'), 'utf8'));
  console.log(`INPUT: ${input.length} entries`);
  // Local sanity: schema shape identical to seed_questions.js contract.
  let bad = 0;
  for (const [i, e] of input.entries()) {
    const ok =
      typeof e.anime === 'string' && TITLES.includes(e.anime.trim().toLowerCase()) &&
      ['easy', 'medium', 'hard'].includes(String(e.difficulty || '').trim().toLowerCase()) &&
      typeof e.question === 'string' && e.question.trim().length > 0 && e.question.trim().length <= 500 &&
      Array.isArray(e.options) && e.options.length === 4 &&
      e.options.every((o) => typeof o === 'string' && o.trim() !== '') &&
      new Set(e.options.map((o) => o.toLowerCase().trim())).size === 4 &&
      Number.isInteger(e.correctAnswerIndex) && e.correctAnswerIndex >= 0 && e.correctAnswerIndex <= 3;
    if (!ok) {
      bad++;
      if (bad <= 10) console.log(`  BAD entry #${i}: ${JSON.stringify(e).slice(0, 120)}`);
    }
  }
  console.log(`LOCAL VALIDATION: ${bad} bad entries`);
  if (bad) {
    console.error('ABORT: fix input first.');
    process.exit(1);
  }

  console.log('LIVE: listing existing questions...');
  const { total, keys } = await listExistingKeys();
  console.log(`LIVE: ${total} docs in questions/`);
  const fresh = [];
  let dups = 0;
  for (const e of input) {
    const k = `${e.anime.trim().toLowerCase()}::${e.question.toLowerCase().replace(/\s+/g, ' ').trim()}`;
    if (keys.has(k)) dups++;
    else {
      keys.add(k);
      fresh.push({
        anime: e.anime.trim().toLowerCase(),
        difficulty: e.difficulty.trim().toLowerCase(),
        question: e.question.trim(),
        options: e.options.map((o) => o.trim()),
        correctAnswerIndex: e.correctAnswerIndex,
      });
    }
  }
  console.log(`NEW: ${fresh.length} to upload, ${dups} already live (skipped)`);
  if (!commit) {
    console.log('DRY RUN — nothing written. Re-run with --commit.');
    console.log('Would also seed: app_config/anime_catalog (32 titles) + app_config/featured_rotation (initial 9).');
    return;
  }
  if (fresh.length) await batchWriteNew(fresh);
  else console.log('Nothing new to upload.');

  // Catalog doc (live list for clients + function fallback).
  await req(
    'PATCH',
    `${BASE}/app_config/anime_catalog?updateMask.fieldPaths=titles`,
    { fields: { titles: enc(TITLES) } }
  );
  console.log(`Seeded app_config/anime_catalog with ${TITLES.length} titles.`);

  // Initial featured shelf (scheduler rotates from here).
  const shelf = shuffled(TITLES).slice(0, 9);
  const interval = INTERVALS[crypto.randomInt(INTERVALS.length)];
  await req(
    'PATCH',
    `${BASE}/app_config/featured_rotation?updateMask.fieldPaths=titles&updateMask.fieldPaths=intervalHours&updateMask.fieldPaths=rotatesAt&updateMask.fieldPaths=updatedAt`,
    {
      fields: {
        titles: enc(shelf),
        intervalHours: enc(interval),
        rotatesAt: enc(new Date(Date.now() + interval * 3600 * 1000)),
        updatedAt: enc(new Date()),
      },
    }
  );
  console.log(`Seeded featured_rotation: 9 titles, ${interval}h window.`);
  console.log('DONE.');
}

main().catch((e) => {
  console.error('FATAL: ' + (e && e.message ? e.message : e));
  process.exit(1);
});
