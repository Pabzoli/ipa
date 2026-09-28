// Usage:
//   node scripts/seed_questions.js                 (dry run: validate only, uploads NOTHING)
//   node scripts/seed_questions.js --execute       (validate + upload accepted entries)
//   Append --key=/path/to/serviceAccountKey.json to override the key path.
//   Append --input=/path/to/file.json to override the input file.
// (Key resolution: --key flag > GOOGLE_APPLICATION_CREDENTIALS > scripts/.service-account-key-path)
//
// Reads data/questions_input.json — entries shaped like:
//   {"anime": "naruto", "difficulty": "easy", "question": "...",
//    "options": ["...", "...", "...", "..."], "correctAnswerIndex": 0}
//
// VALIDATION (all in code — Firestore rules do NOT apply to Admin SDK writes,
// so this script is the enforcement point for the easy/medium/hard contract):
//   - anime must be in KNOWN_TITLES (lowercased/trimmed before checking)
//   - difficulty must be one of easy | medium | hard (lowercased/trimmed)
//   - question must be a non-empty string (max 500 chars)
//   - options must be exactly 4 non-empty strings, no duplicates (case-insensitive)
//   - correctAnswerIndex must be an integer 0..3
//   - dedup within the file AND against existing Firestore docs by
//     normalized question-text hash ("<anime>::<normalized question>")
//
// SAFETY:
//   - Dry run by default. Upload ONLY with --execute.
//   - Prints accepted/rejected/duplicate counts with per-item reasons first.
//   - Uploads via BulkWriter with qVersion + createdAt (server timestamp).
//   - Local admin script. NEVER deployed to Firebase.

const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

const admin = require('firebase-admin');

// ─── Known anime titles ─────────────────────────────────────────────────────
// Mirrors _animeTitles in lib/features/home/home_page.dart.
const KNOWN_TITLES = [
  'attack on titan',
  'demon slayer',
  'jujutsu kaisen',
  'naruto',
  'one piece',
  'one punch man',
  'bleach',
  'dragon ball z',
  'my hero academia',
  'death note',
];

// ─── Difficulty contract ────────────────────────────────────────────────────
// Mirrors kQuestionDifficulties in lib/features/quiz/questions.dart and
// isValidQuestionDifficulty() in firestore.rules. Enforced HERE in code
// because the Admin SDK bypasses security rules.
const ALLOWED_DIFFICULTIES = ['easy', 'medium', 'hard'];

// Stamp applied to every uploaded doc.
const Q_VERSION = 1;

const MAX_QUESTION_CHARS = 500;
const MAX_REJECTION_LINES = 50;

function parseArgs(argv) {
  const args = {};
  for (const raw of argv) {
    if (!raw.startsWith('--')) continue;
    const eq = raw.indexOf('=');
    if (eq === -1) {
      args[raw.slice(2)] = true;
    } else {
      args[raw.slice(2, eq)] = raw.slice(eq + 1);
    }
  }
  return args;
}

// Service-account key path resolution — same convention as purge_users.js:
// never hardcoded, never committed.
function resolveServiceAccountPath(args) {
  if (args.key) return args.key;
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    return process.env.GOOGLE_APPLICATION_CREDENTIALS;
  }
  const configFile = path.join(__dirname, '.service-account-key-path');
  if (fs.existsSync(configFile)) {
    const p = fs.readFileSync(configFile, 'utf8').trim();
    if (p) return path.isAbsolute(p) ? p : path.join(__dirname, p);
  }
  return null;
}

function initAdmin(keyPath) {
  if (!keyPath || !fs.existsSync(keyPath)) {
    throw new Error(
      'Service account key not found. Pass --key=/path/to/key.json, set ' +
      'GOOGLE_APPLICATION_CREDENTIALS, or write the path into ' +
      'scripts/.service-account-key-path'
    );
  }
  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
}

// Normalizes question text for dedup: lowercase, collapse all whitespace
// runs to a single space, trim. Two entries that differ only by casing or
// spacing map to the same key.
function normalizeQuestionText(s) {
  return s.toLowerCase().replace(/\s+/g, ' ').trim();
}

function dedupKey(anime, question) {
  const raw = `${anime}::${normalizeQuestionText(question)}`;
  return crypto.createHash('sha1').update(raw, 'utf8').digest('hex');
}

function isInt(n) {
  return typeof n === 'number' && Number.isInteger(n);
}

// Returns { ok, anime, difficulty, question, options, correctAnswerIndex, errors[] }.
function validateEntry(entry, index) {
  const errors = [];
  const label = `entry #${index}`;

  if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
    return { ok: false, errors: [`${label}: not an object`] };
  }

  // ── anime ──
  let anime = '';
  if (typeof entry.anime !== 'string' || entry.anime.trim() === '') {
    errors.push('anime must be a non-empty string');
  } else {
    anime = entry.anime.trim().toLowerCase();
    if (!KNOWN_TITLES.includes(anime)) {
      errors.push(`unknown anime "${entry.anime}" (must be one of: ${KNOWN_TITLES.join(', ')})`);
    }
  }

  // ── difficulty (enforced here — rules don't cover Admin SDK writes) ──
  let difficulty = '';
  if (typeof entry.difficulty !== 'string' || entry.difficulty.trim() === '') {
    errors.push('difficulty must be one of: easy, medium, hard');
  } else {
    difficulty = entry.difficulty.trim().toLowerCase();
    if (!ALLOWED_DIFFICULTIES.includes(difficulty)) {
      errors.push(`invalid difficulty "${entry.difficulty}" (must be one of: easy, medium, hard)`);
    }
  }

  // ── question ──
  let question = '';
  if (typeof entry.question !== 'string' || entry.question.trim() === '') {
    errors.push('question must be a non-empty string');
  } else {
    question = entry.question.trim();
    if (question.length > MAX_QUESTION_CHARS) {
      errors.push(`question too long (${question.length} chars, max ${MAX_QUESTION_CHARS})`);
    }
  }

  // ── options ──
  let options = [];
  if (!Array.isArray(entry.options)) {
    errors.push('options must be an array of exactly 4 strings');
  } else if (entry.options.length !== 4) {
    errors.push(`options must have exactly 4 entries (got ${entry.options.length})`);
  } else {
    const bad = entry.options.filter((o) => typeof o !== 'string' || o.trim() === '');
    if (bad.length > 0) {
      errors.push('options must all be non-empty strings');
    } else {
      options = entry.options.map((o) => o.trim());
      const lowered = options.map((o) => o.toLowerCase());
      if (new Set(lowered).size !== 4) {
        errors.push('options contains duplicates (case-insensitive)');
      }
    }
  }

  // ── correctAnswerIndex ──
  let correctAnswerIndex = -1;
  if (!isInt(entry.correctAnswerIndex)) {
    errors.push('correctAnswerIndex must be an integer 0..3');
  } else if (entry.correctAnswerIndex < 0 || entry.correctAnswerIndex > 3) {
    errors.push(`correctAnswerIndex out of range (${entry.correctAnswerIndex}, must be 0..3)`);
  } else {
    correctAnswerIndex = entry.correctAnswerIndex;
  }

  if (errors.length > 0) {
    return { ok: false, errors: errors.map((e) => `${label}: ${e}`) };
  }
  return { ok: true, anime, difficulty, question, options, correctAnswerIndex, errors: [] };
}

async function loadExistingKeys(db) {
  // Field-mask select keeps this cheap: only the two dedup fields are read.
  const snap = await db.collection('questions').select('animeTitle', 'question').get();
  const keys = new Set();
  for (const doc of snap.docs) {
    const d = doc.data() || {};
    if (typeof d.animeTitle === 'string' && typeof d.question === 'string') {
      keys.add(dedupKey(d.animeTitle.trim().toLowerCase(), d.question));
    }
  }
  return { count: snap.size, keys };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const execute = args.execute === true;
  const inputPath = args.input
    ? (path.isAbsolute(args.input) ? args.input : path.join(process.cwd(), args.input))
    : path.join(__dirname, '..', 'data', 'questions_input.json');

  if (!fs.existsSync(inputPath)) {
    throw new Error(`Input file not found: ${inputPath}`);
  }
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  } catch (e) {
    throw new Error(`Input file is not valid JSON: ${e.message}`);
  }
  if (!Array.isArray(raw)) {
    throw new Error('Input file must contain a JSON array of question entries.');
  }

  const keyPath = resolveServiceAccountPath(args);
  initAdmin(keyPath);
  const db = admin.firestore();

  console.log(`INPUT: ${raw.length} entries from ${inputPath}`);
  const { count: existingCount, keys: existingKeys } = await loadExistingKeys(db);
  console.log(`FIRESTORE: ${existingCount} existing docs in questions/`);

  // ── Phase 1: field validation ──
  const fieldValid = [];
  const rejected = [];
  raw.forEach((entry, i) => {
    const res = validateEntry(entry, i);
    if (res.ok) {
      fieldValid.push({ index: i, ...res });
    } else {
      rejected.push(...res.errors);
    }
  });

  // ── Phase 2: dedup within file ──
  const seenInFile = new Set();
  const deduped = [];
  let dupInFile = 0;
  for (const v of fieldValid) {
    const key = dedupKey(v.anime, v.question);
    if (seenInFile.has(key)) {
      dupInFile++;
      rejected.push(`entry #${v.index}: duplicate-in-file (same anime + question text as an earlier entry)`);
    } else {
      seenInFile.add(key);
      deduped.push({ key, ...v });
    }
  }

  // ── Phase 3: dedup against Firestore ──
  const accepted = [];
  let dupInFirestore = 0;
  for (const v of deduped) {
    if (existingKeys.has(v.key)) {
      dupInFirestore++;
      rejected.push(`entry #${v.index}: duplicate-in-firestore (same anime + question text already uploaded)`);
    } else {
      accepted.push(v);
    }
  }

  // ── Summary ──
  const byAnimeDiff = {};
  for (const v of accepted) {
    const k = `${v.anime} / ${v.difficulty}`;
    byAnimeDiff[k] = (byAnimeDiff[k] || 0) + 1;
  }

  console.log('────────────────────────────────────────');
  console.log(`ACCEPTED: ${accepted.length}`);
  for (const [k, n] of Object.entries(byAnimeDiff).sort()) {
    console.log(`  ${k}: ${n}`);
  }
  console.log(`REJECTED: ${rejected.length} (${raw.length - accepted.length} input entries affected)`);
  console.log(`  duplicates-in-file: ${dupInFile}, duplicates-in-firestore: ${dupInFirestore}`);
  const lines = rejected.slice(0, MAX_REJECTION_LINES);
  for (const line of lines) console.log(`  - ${line}`);
  if (rejected.length > MAX_REJECTION_LINES) {
    console.log(`  …and ${rejected.length - MAX_REJECTION_LINES} more`);
  }
  console.log('────────────────────────────────────────');

  if (!execute) {
    console.log('DRY RUN — nothing uploaded. Re-run with --execute to upload.');
    return;
  }

  if (accepted.length === 0) {
    console.error('ABORT: --execute given but 0 entries accepted. Nothing uploaded.');
    process.exit(1);
  }

  // ── Upload via BulkWriter ──
  const col = db.collection('questions');
  const writer = db.bulkWriter();
  let queued = 0;
  writer.onWriteError((err) => {
    console.error(`  write error (retrying unless fatal): ${err.message}`);
    return false; // retry per BulkWriter default policy
  });
  for (const v of accepted) {
    const ref = col.doc();
    writer.set(ref, {
      question: v.question,
      options: v.options,
      correctAnswerIndex: v.correctAnswerIndex,
      animeTitle: v.anime,
      difficulty: v.difficulty,
      qVersion: Q_VERSION,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    queued++;
  }
  await writer.close();
  console.log(`DONE. Uploaded ${queued} questions (qVersion=${Q_VERSION}).`);
}

main().catch((e) => {
  console.error(`FATAL: ${e.message}`);
  process.exit(1);
});
