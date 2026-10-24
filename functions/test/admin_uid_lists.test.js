// functions/test/admin_uid_lists.test.js — the admin UID list must be identical
// everywhere it is declared.
//
// The list is duplicated in four places because none of them can import the
// others: the Dart client (admin_accounts.dart), the Cloud Functions
// (index.js), the security rules (firestore.rules) and the local purge script
// (scripts/purge_admin_from_economy.js). A silent drift between them is a
// security hole — e.g. the rules still treating a rotated admin as an admin
// while the server no longer does, or vice versa. This test is the single guard
// that keeps them in lockstep; update the list in all four files together.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

function parseAdminUids(src, label) {
  const m = src.match(/ADMIN_UIDS\s*=\s*\[([^\]]*)\]/);
  assert.ok(m, `could not find ADMIN_UIDS = [...] in ${label}`);
  return [...m[1].matchAll(/'([^']+)'|"([^"]+)"/g)]
    .map((x) => x[1] || x[2])
    .sort();
}

test('admin UID lists are identical across client, server, rules and script', () => {
  const server = parseAdminUids(read('functions/index.js'), 'functions/index.js');
  const script = parseAdminUids(
    read('scripts/purge_admin_from_economy.js'),
    'scripts/purge_admin_from_economy.js');

  const dartSrc = read('lib/core/constants/admin_accounts.dart');
  const dartMatch = dartSrc.match(/kAdminUids\s*=\s*<String>\[([\s\S]*?)\]/);
  assert.ok(dartMatch, 'could not find kAdminUids = <String>[...] in admin_accounts.dart');
  const dart = [...dartMatch[1].matchAll(/'([^']+)'/g)].map((x) => x[1]).sort();

  const rulesSrc = read('firestore.rules');
  const rulesMatch = rulesSrc.match(/function\s+isPayoutAdmin\(\)\s*\{[\s\S]*?\}/);
  assert.ok(rulesMatch, 'could not find isPayoutAdmin() in firestore.rules');
  const rules = [...rulesMatch[0].matchAll(/request\.auth\.uid\s*==\s*'([^']+)'/g)]
    .map((x) => x[1])
    .sort();

  assert.ok(server.length > 0, 'server ADMIN_UIDS is empty');

  assert.deepEqual(dart, server,
    'admin_accounts.dart kAdminUids has drifted from ADMIN_UIDS in functions/index.js');
  assert.deepEqual(rules, server,
    'firestore.rules isPayoutAdmin() has drifted from ADMIN_UIDS in functions/index.js');
  assert.deepEqual(script, server,
    'scripts/purge_admin_from_economy.js ADMIN_UIDS has drifted from functions/index.js');
});
