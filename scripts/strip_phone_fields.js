// Usage:
//   node scripts/strip_phone_fields.js                 (dry run: counts + lists, writes nothing)
//   node scripts/strip_phone_fields.js --execute       (applies the migration)
//   Append --key=/path/to/serviceAccountKey.json to override the key path.
// (Key resolution: --key flag > GOOGLE_APPLICATION_CREDENTIALS > scripts/.service-account-key-path)
//
// ONE-OFF migration: phone verification is being removed from the app. It
// strips every stored phone artifact and nothing else:
//   a. users/{uid}: phoneNumber, phoneVerified, phoneVerifiedAt,
//      phoneVerifiedSource, phoneVerifiedBy, phoneVerifiedNote (only those keys,
//      only when present, via FieldValue.delete()).
//   b. phoneNumbers/{E164} uniqueness-claim docs: all deleted.
//   c. Firebase Auth accounts with a 'phone' providerData entry AND at least one
//      other provider: the phone provider is unlinked (updateUser phoneNumber:null)
//      and verified afterwards (other providers and email must still be there).
//   d. Phone-ONLY accounts are NOT unlinked (that would leave no sign-in method).
//      They are listed so the operator decides. No account is ever deleted.
//
// SAFETY:
//   - Dry run by default. Writes happen ONLY with --execute.
//   - Never touches email, emailVerified, other providers, or other user fields.
//   - Idempotent: a second --execute reports zero work.
//   - Prints uids and masked phone/email only. Full phone numbers and emails are
//     never printed.
//   - Emulator mode: when FIRESTORE_EMULATOR_HOST AND FIREBASE_AUTH_EMULATOR_HOST
//     are both set, the emulator is used, no credentials are needed, and the
//     header is tagged [emulator]. Setting only one of the two is refused.
//   - Live mode: --execute is refused unless the key's project_id is the
//     .firebaserc default project. Every Firestore and Auth call uses the app
//     initialised with that project id.
//   - Local admin script. NEVER deployed to Firebase.

'use strict';

const path = require('path');
const fs = require('fs');

const PHONE_USER_FIELDS = [
  'phoneNumber',
  'phoneVerified',
  'phoneVerifiedAt',
  'phoneVerifiedSource',
  'phoneVerifiedBy',
  'phoneVerifiedNote',
];
const PHONE_CLAIMS = 'phoneNumbers';
const PHONE_PROVIDER = 'phone';
const BATCH_SIZE = 400;
const PAGE_SIZE = 400;
const EMULATOR_PROJECT_ID = 'demo-quiz-migration';

let clients = null;

// Same name-resolution trick as set_android_config.js: firebase-admin's
// "exports" map makes path-style requires fail.
function requireFromFunctions(subpath) {
  return require(require.resolve(subpath, {
    paths: [path.join(__dirname, '..', 'functions')],
  }));
}

function loadAdmin() {
  try {
    return requireFromFunctions('firebase-admin/app');
  } catch (e) {
    throw new Error(
      'Could not load firebase-admin from functions/. Run `npm install` inside functions/.'
    );
  }
}

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

function emulatorMode() {
  const firestoreSet = !!process.env.FIRESTORE_EMULATOR_HOST;
  const authSet = !!process.env.FIREBASE_AUTH_EMULATOR_HOST;
  if (firestoreSet !== authSet) {
    throw new Error(
      'Set BOTH FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST, or neither. ' +
      'A split target would mix emulator and live services.'
    );
  }
  return firestoreSet;
}

// Service-account key path resolution, same convention as purge_users.js.
function resolveServiceAccountPath(key) {
  if (key) return key;
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

function readServiceAccount(keyPath) {
  if (!keyPath || !fs.existsSync(keyPath)) {
    throw new Error(
      'No emulator env and no service account key found. Pass --key=/path/to/key.json, ' +
      'set GOOGLE_APPLICATION_CREDENTIALS, or write the path into ' +
      'scripts/.service-account-key-path. Nothing was read or written.'
    );
  }
  return JSON.parse(fs.readFileSync(keyPath, 'utf8'));
}

function firebasercProject() {
  return JSON.parse(
    fs.readFileSync(path.join(__dirname, '..', '.firebaserc'), 'utf8')
  ).projects.default;
}

function getClients(opts = {}) {
  if (clients) return clients;
  const { initializeApp, cert } = loadAdmin();
  const { getFirestore, FieldValue, FieldPath } = requireFromFunctions('firebase-admin/firestore');
  const { getAuth } = requireFromFunctions('firebase-admin/auth');

  const emulator = emulatorMode();
  let app;
  if (emulator) {
    app = initializeApp({ projectId: EMULATOR_PROJECT_ID });
  } else {
    const sa = readServiceAccount(resolveServiceAccountPath(opts.key));
    if (!sa.project_id) {
      throw new Error('Service account key has no project_id. Refusing to run.');
    }
    app = initializeApp({ credential: cert(sa), projectId: sa.project_id });
  }
  const projectId = app.options.projectId;
  if (!projectId) throw new Error('Could not resolve a project id. Refusing to run.');

  clients = {
    app,
    projectId,
    emulator,
    db: getFirestore(app),
    auth: getAuth(app),
    FieldValue,
    FieldPath,
  };
  return clients;
}

async function shutdown() {
  if (!clients) return;
  const app = clients.app;
  clients = null;
  await app.delete();
}

function maskPhone(p) {
  if (!p) return '(none)';
  const digits = String(p).replace(/\D/g, '');
  return '+' + '*'.repeat(Math.max(0, digits.length - 4)) + digits.slice(-4);
}

function maskEmail(e) {
  if (!e) return '(none)';
  const [local, domain] = String(e).split('@');
  const tld = domain && domain.includes('.') ? domain.split('.').pop() : '';
  return (local || '').slice(0, 1) + '***@***' + (tld ? '.' + tld : '');
}

async function scanUsers(c) {
  const docs = [];
  let last = null;
  for (;;) {
    let q = c.db.collection('users').orderBy(c.FieldPath.documentId()).limit(PAGE_SIZE);
    if (last) q = q.startAfter(last);
    const snap = await q.get();
    docs.push(...snap.docs);
    if (snap.size < PAGE_SIZE) break;
    last = snap.docs[snap.docs.length - 1].id;
  }
  return docs;
}

async function listAllAuthUsers(auth) {
  const users = [];
  let pageToken;
  do {
    const res = await auth.listUsers(1000, pageToken);
    users.push(...res.users);
    pageToken = res.pageToken;
  } while (pageToken);
  return users;
}

async function plan(c) {
  const userDocs = await scanUsers(c);
  const userDocIds = new Set(userDocs.map((d) => d.id));
  const userDocsWithPhone = [];
  for (const d of userDocs) {
    const data = d.data() || {};
    const fields = PHONE_USER_FIELDS.filter((f) => Object.prototype.hasOwnProperty.call(data, f));
    if (fields.length) userDocsWithPhone.push({ ref: d.ref, uid: d.id, fields });
  }

  const claims = await c.db.collection(PHONE_CLAIMS).select().get();

  const authUsers = await listAllAuthUsers(c.auth);
  const authPhoneAccounts = [];
  const unlinkCandidates = [];
  const phoneOnly = [];
  for (const u of authUsers) {
    const providers = u.providerData || [];
    const phoneEntry = providers.find((p) => p.providerId === PHONE_PROVIDER);
    if (!phoneEntry) continue;
    const others = providers
      .filter((p) => p.providerId !== PHONE_PROVIDER)
      .map((p) => p.providerId);
    const entry = {
      uid: u.uid,
      phone: maskPhone(phoneEntry.phoneNumber || u.phoneNumber),
      email: u.email || null,
      others,
      hasUserDoc: userDocIds.has(u.uid),
    };
    authPhoneAccounts.push(entry);
    if (others.length) unlinkCandidates.push(entry);
    else phoneOnly.push(entry);
  }

  return {
    usersScanned: userDocs.length,
    userDocsWithPhone,
    claimDocs: claims.size,
    authScanned: authUsers.length,
    authPhoneAccounts,
    unlinkCandidates,
    phoneOnly,
  };
}

function printPlan(p, log) {
  log(`Users scanned (users/*): ${p.usersScanned}`);
  log(`User docs with phone fields: ${p.userDocsWithPhone.length}`);
  log(`phoneNumbers claim docs: ${p.claimDocs}`);
  log(`Auth accounts scanned: ${p.authScanned}`);
  log(`Auth accounts with a phone provider: ${p.authPhoneAccounts.length}`);
  log(`  unlink candidates (phone + another provider): ${p.unlinkCandidates.length}`);
  for (const a of p.unlinkCandidates) {
    log(`    uid=${a.uid} phone=${a.phone} email=${maskEmail(a.email)} keep=[${a.others.join(',')}]`);
  }
  log(`  phone-ONLY accounts (NOT unlinked, operator decides): ${p.phoneOnly.length}`);
  for (const a of p.phoneOnly) {
    log(`    uid=${a.uid} phone=${a.phone} userDoc=${a.hasUserDoc ? 'yes' : 'no'}`);
  }
}

function chunks(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

async function deleteAllClaims(c) {
  let deleted = 0;
  for (;;) {
    const snap = await c.db.collection(PHONE_CLAIMS).limit(BATCH_SIZE).get();
    if (snap.empty) break;
    const batch = c.db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    deleted += snap.size;
  }
  return deleted;
}

async function execute(c, p, log) {
  const result = {
    userDocsUpdated: 0,
    claimDocsDeleted: 0,
    authUnlinked: 0,
    authErrors: 0,
  };

  for (const group of chunks(p.userDocsWithPhone, BATCH_SIZE)) {
    const batch = c.db.batch();
    for (const d of group) {
      const data = {};
      for (const f of d.fields) data[f] = c.FieldValue.delete();
      batch.update(d.ref, data);
    }
    await batch.commit();
    result.userDocsUpdated += group.length;
  }
  log(`users/* phone fields stripped from ${result.userDocsUpdated} doc(s)`);

  result.claimDocsDeleted = await deleteAllClaims(c);
  log(`phoneNumbers claim docs deleted: ${result.claimDocsDeleted}`);

  for (const a of p.unlinkCandidates) {
    try {
      await c.auth.updateUser(a.uid, { phoneNumber: null });
      const after = await c.auth.getUser(a.uid);
      const afterIds = (after.providerData || []).map((x) => x.providerId);
      const ok = !afterIds.includes(PHONE_PROVIDER)
        && a.others.every((id) => afterIds.includes(id))
        && (after.email || null) === a.email;
      if (ok) {
        result.authUnlinked++;
        log(`  unlinked phone uid=${a.uid} remaining=[${afterIds.join(',')}]`);
      } else {
        result.authErrors++;
        log(`  VERIFY FAILED uid=${a.uid} remaining=[${afterIds.join(',')}]`);
      }
    } catch (e) {
      result.authErrors++;
      log(`  auth unlink error uid=${a.uid} code=${e.code || 'unknown'}`);
    }
  }
  log(`Auth phone providers unlinked: ${result.authUnlinked}, errors: ${result.authErrors}`);
  log(`Phone-only accounts kept untouched (listed above): ${p.phoneOnly.length}`);

  return result;
}

async function run({ execute: doExecute = false, key = null, log = console.log } = {}) {
  const c = getClients({ key });
  const tag = c.emulator ? '[emulator] ' : '';
  log(`${tag}strip_phone_fields: ${doExecute ? 'EXECUTE (writes)' : 'DRY RUN (no writes)'}`);
  log(`project: ${c.projectId}`);

  if (doExecute && !c.emulator && c.projectId !== firebasercProject()) {
    throw new Error(
      `Refusing --execute: key project "${c.projectId}" is not the .firebaserc default ` +
      `"${firebasercProject()}".`
    );
  }

  const p = await plan(c);
  printPlan(p, log);

  const summary = {
    executed: doExecute,
    usersScanned: p.usersScanned,
    userDocsWithPhone: p.userDocsWithPhone.length,
    claimDocs: p.claimDocs,
    authScanned: p.authScanned,
    authPhoneAccounts: p.authPhoneAccounts.length,
    unlinkCandidates: p.unlinkCandidates.length,
    phoneOnlyUids: p.phoneOnly.map((a) => a.uid),
    userDocsUpdated: 0,
    claimDocsDeleted: 0,
    authUnlinked: 0,
    authErrors: 0,
  };

  if (!doExecute) {
    log('DRY RUN - nothing written. Re-run with --execute to apply.');
    return summary;
  }

  const r = await execute(c, p, log);
  Object.assign(summary, r);
  log(
    `DONE. userDocsUpdated=${r.userDocsUpdated} claimDocsDeleted=${r.claimDocsDeleted} ` +
    `authUnlinked=${r.authUnlinked} authErrors=${r.authErrors} accountsDeleted=0`
  );
  return summary;
}

if (require.main === module) {
  const args = parseArgs(process.argv.slice(2));
  run({
    execute: args.execute === true,
    key: typeof args.key === 'string' ? args.key : null,
  })
    .catch((e) => {
      console.error(`FATAL: ${e.message}`);
      process.exitCode = 1;
    })
    .finally(() => shutdown());
}

module.exports = {
  run,
  plan,
  getClients,
  shutdown,
  PHONE_USER_FIELDS,
  PHONE_CLAIMS,
  PHONE_PROVIDER,
  EMULATOR_PROJECT_ID,
  BATCH_SIZE,
};
