// Usage: node scripts/generate_codes.js --type=ac|premium --value=500 --count=5 [--source=admin_test] [--key=/path/to/serviceAccountKey.json]
//        node scripts/generate_codes.js --type=leaderboard_entry --count=5 --buyerEmail=user@example.com [--value=YYYY-MM-DD] [--key=/path/to/serviceAccountKey.json]
//        (--value defaults to the current week ID for leaderboard_entry codes)
// (Alternative to --key: set GOOGLE_APPLICATION_CREDENTIALS, or write the absolute key path into scripts/.service-account-key-path)

const path = require('path');
const fs = require('fs');
const { randomInt } = require('node:crypto');

const admin = require('firebase-admin');
const { FieldValue } = admin.firestore;

// ─── Charset + generator — EXACT copy of functions/index.js (SECTION 14b) ───
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

function _generateCode() {
  let s = '';
  for (let i = 0; i < 12; i++) {
    s += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  }
  return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}`;
}

// ─── Monday-date week ID — EXACT copy of functions/index.js (currentWeekId) ──
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

// ─── Argument parsing (--key=val pairs) ─────────────────────────────────────
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

// Service-account key path resolution — never hardcoded, never committed.
// Order: --key flag > GOOGLE_APPLICATION_CREDENTIALS > scripts/.service-account-key-path
function resolveServiceAccountPath(args) {
  if (args.key) return args.key;
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    return process.env.GOOGLE_APPLICATION_CREDENTIALS;
  }
  const configFile = path.join(__dirname, '.service-account-key-path');
  if (fs.existsSync(configFile)) {
    const p = fs.readFileSync(configFile, 'utf8').trim();
    if (p) return p;
  }
  return null;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  // ─── Validation — same checks as generateRedemptionCodes ──────────────────
  const type = args.type;
  if (type !== 'ac' && type !== 'premium' && type !== 'leaderboard_entry') {
    throw new Error('--type must be "ac", "premium", or "leaderboard_entry"');
  }
  let value;
  let buyerEmail = null;
  if (type === 'leaderboard_entry') {
    // value is a week ID string; defaults to the current week when omitted.
    if (args.value && !/^\d{4}-\d{2}-\d{2}$/.test(String(args.value))) {
      throw new Error('--value must be a YYYY-MM-DD week ID for leaderboard_entry codes');
    }
    value = args.value || currentWeekId();
    buyerEmail = (typeof args.buyerEmail === 'string' && args.buyerEmail.trim())
      ? args.buyerEmail.trim().toLowerCase()
      : '';
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(buyerEmail)) {
      throw new Error('--buyerEmail is required for leaderboard_entry codes');
    }
  } else {
    value = Number(args.value);
    if (typeof value !== 'number' || !Number.isInteger(value) || !(value > 0)) {
      throw new Error('--value must be a positive integer');
    }
  }
  const count = Number(args.count);
  if (typeof count !== 'number' || !Number.isInteger(count) || count < 1 || count > 100) {
    throw new Error('--count must be an integer between 1 and 100');
  }
  const source = (typeof args.source === 'string' && args.source.trim())
    ? args.source.trim()
    : 'admin_test';

  const keyPath = resolveServiceAccountPath(args);
  if (!keyPath) {
    throw new Error(
      'No service account key found. Pass --key=/path/to/serviceAccountKey.json, ' +
        'set GOOGLE_APPLICATION_CREDENTIALS, or create scripts/.service-account-key-path ' +
        'containing the absolute path to your key file.',
    );
  }
  if (!fs.existsSync(keyPath)) {
    throw new Error(`Service account key not found at: ${keyPath}`);
  }

  const serviceAccount = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  const db = admin.firestore();

  // ─── Generate + collision-check — same as generateRedemptionCodes ─────────
  const codes = [];
  while (codes.length < count) {
    const candidate = _generateCode();
    if (codes.includes(candidate)) continue; // dedupe within this run
    const snap = await db.collection('redemptionCodes').doc(candidate).get();
    if (snap.exists) continue; // collides with an existing doc — regenerate
    codes.push(candidate);
  }

  const batch = db.batch();
  for (const code of codes) {
    batch.set(db.collection('redemptionCodes').doc(code), {
      type,
      value,
      status: 'unused',
      source,
      createdAt: FieldValue.serverTimestamp(),
      createdBy: 'admin_script',
      ...(type === 'leaderboard_entry' ? { buyerEmail } : {}),
    });
  }
  await batch.commit();

  console.log(`Generated ${codes.length} ${type} code(s) (value=${value}, source=${source}) — written to redemptionCodes: `);
  for (const code of codes) console.log(`  ${code}`);
}

main().catch((err) => {
  console.error(`ERROR: ${err.message}`);
  process.exit(1);
});