// scripts/merge_new_questions.js — merge data/batches/batch_*.json into
// data/questions_input.json with the SAME contract as seed_questions.js.
// Dry run by default; writes only with --execute.
//
// Checks per entry: anime in KNOWN_TITLES (lowercased), difficulty in
// easy|medium|hard, question non-empty <=500 chars, options exactly 4
// non-empty unique (case-insensitive), correctAnswerIndex 0..3,
// rotation 0,1,2,3 cycling within each anime-difficulty block,
// no duplicate question text (in-file + against existing input).
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.join(__dirname, '..');
const INPUT = path.join(ROOT, 'data', 'questions_input.json');
const BATCH_DIR = path.join(ROOT, 'data', 'batches');

const KNOWN = new Set([
  'attack on titan', 'berserk', 'black clover', 'bleach', 'blue lock',
  'chainsaw man', 'classroom of the elite', 'death note', 'demon slayer',
  'dragon ball z', 'dr stone', 'fairy tail', 'fire force', "hell's paradise",
  'hunter x hunter', "jojo's bizarre adventure", 'jujutsu kaisen',
  "kuroko's basketball", 'mushoku tensei', 'my hero academia', 'naruto',
  'one piece', 'one punch man', 're zero', 'solo leveling',
  'sword art online', 'that time i got reincarnated as a slime',
  'tokyo ghoul', 'tokyo revengers', 'tower of god', 'vinland saga',
  'wind breaker',
]);
const DIFF = new Set(['easy', 'medium', 'hard']);

const normQ = (s) => s.toLowerCase().replace(/\s+/g, ' ').trim();
const key = (a, q) => crypto.createHash('sha1').update(`${a}::${normQ(q)}`, 'utf8').digest('hex');

function validate(e, label) {
  const errs = [];
  if (!e || typeof e !== 'object' || Array.isArray(e)) return [`${label}: not an object`];
  const anime = typeof e.anime === 'string' ? e.anime.trim().toLowerCase() : '';
  if (!KNOWN.has(anime)) errs.push(`${label}: unknown anime ${JSON.stringify(e.anime)}`);
  const diff = typeof e.difficulty === 'string' ? e.difficulty.trim().toLowerCase() : '';
  if (!DIFF.has(diff)) errs.push(`${label}: bad difficulty ${JSON.stringify(e.difficulty)}`);
  if (typeof e.question !== 'string' || !e.question.trim()) errs.push(`${label}: empty question`);
  else if (e.question.trim().length > 500) errs.push(`${label}: question too long`);
  else if (!e.question.trim().endsWith('?')) errs.push(`${label}: question must end with ?`);
  if (!Array.isArray(e.options) || e.options.length !== 4) errs.push(`${label}: options must be 4`);
  else {
    const opts = e.options.map((o) => (typeof o === 'string' ? o.trim() : ''));
    if (opts.some((o) => !o)) errs.push(`${label}: empty option`);
    if (new Set(opts.map((o) => o.toLowerCase())).size !== 4) errs.push(`${label}: duplicate options`);
  }
  if (!Number.isInteger(e.correctAnswerIndex) || e.correctAnswerIndex < 0 || e.correctAnswerIndex > 3) {
    errs.push(`${label}: bad correctAnswerIndex ${JSON.stringify(e.correctAnswerIndex)}`);
  }
  return errs;
}

function main() {
  const execute = process.argv.includes('--execute');
  const existing = JSON.parse(fs.readFileSync(INPUT, 'utf8'));
  const seenKeys = new Set(existing.map((e) => key(
    String(e.anime || '').trim().toLowerCase(), String(e.question || ''))));
  const files = fs.readdirSync(BATCH_DIR).filter((f) => /^batch_[a-f]\.json$/.test(f)).sort();
  if (!files.length) {
    console.error('No batch files found in data/batches.');
    process.exit(1);
  }
  let fresh = [];
  let errors = [];
  for (const f of files) {
    const arr = JSON.parse(fs.readFileSync(path.join(BATCH_DIR, f), 'utf8'));
    if (!Array.isArray(arr)) {
      errors.push(`${f}: not an array`);
      continue;
    }
    arr.forEach((e, i) => {
      errors.push(...validate(e, `${f}#${i}`));
      const a = typeof e?.anime === 'string' ? e.anime.trim().toLowerCase() : '';
      const k = key(a, String(e?.question || ''));
      if (seenKeys.has(k)) errors.push(`${f}#${i}: duplicate question "${String(e?.question || '').slice(0, 60)}"`);
      else seenKeys.add(k);
      fresh.push({ file: f, index: i, anime: a, difficulty: String(e?.difficulty || '').trim().toLowerCase(), correctAnswerIndex: e?.correctAnswerIndex });
    });
  }
  // Rotation check: 0,1,2,3 cycle within each anime-difficulty block (file order).
  const blocks = new Map();
  for (const e of fresh) {
    const k = `${e.anime}/${e.difficulty}`;
    if (!blocks.has(k)) blocks.set(k, []);
    blocks.get(k).push(e);
  }
  for (const [k, list] of blocks) {
    list.forEach((e, i) => {
      if (e.correctAnswerIndex !== i % 4) {
        errors.push(`rotation ${k}: position ${i} has ${e.correctAnswerIndex}, want ${i % 4} (${e.file}#${e.index})`);
      }
    });
  }
  const counts = {};
  for (const e of fresh) {
    const k = `${e.anime}/${e.difficulty}`;
    counts[k] = (counts[k] || 0) + 1;
  }
  console.log(`BATCH FILES: ${files.join(', ')}`);
  console.log(`EXISTING: ${existing.length} entries`);
  console.log(`NEW: ${fresh.length} entries`);
  for (const [k, n] of Object.entries(counts).sort()) console.log(`  ${k}: ${n}`);
  console.log(`ERRORS: ${errors.length}`);
  for (const line of errors.slice(0, 60)) console.log(`  - ${line}`);
  if (errors.length > 60) console.log(`  ...and ${errors.length - 60} more`);
  if (errors.length) {
    console.error('ABORT: fix errors before merging.');
    process.exit(1);
  }
  const EXPECTED = { per: 30, anime: 22 };
  const bad = Object.entries(counts).filter(([, n]) => n !== 30);
  if (bad.length || blocks.size !== 22 * 3) {
    console.error(`ABORT: expected 22 anime x 3 difficulties x 30, got ${blocks.size} blocks. Off: ${JSON.stringify(bad)}`);
    process.exit(1);
  }
  if (!execute) {
    console.log('DRY RUN — nothing written. Re-run with --execute.');
    return;
  }
  const merged = existing.concat(fresh.map(({ file, index, ...rest }) => ({
    anime: rest.anime,
    difficulty: rest.difficulty,
    question: undefined, // placeholder replaced below
  })));
  // Rebuild cleanly from source arrays to avoid key-order drift.
  const out = existing.slice();
  for (const f of files) {
    const arr = JSON.parse(fs.readFileSync(path.join(BATCH_DIR, f), 'utf8'));
    for (const e of arr) {
      out.push({
        anime: e.anime.trim().toLowerCase(),
        difficulty: e.difficulty.trim().toLowerCase(),
        question: e.question.trim(),
        options: e.options.map((o) => o.trim()),
        correctAnswerIndex: e.correctAnswerIndex,
      });
    }
  }
  void merged;
  fs.writeFileSync(INPUT, JSON.stringify(out, null, 2) + '\n');
  console.log(`DONE. Wrote ${out.length} entries to data/questions_input.json.`);
}

main();
