// functions/test/_fakes.js
//
// In-memory fakes for the Firebase Admin + Functions SDKs, pre-installed into
// require.cache BEFORE index.js is loaded. Lets the REAL callable handlers run
// with a fake Firestore: no emulator, no network, one command, <2 minutes.
//
// Usage (first lines of every test file):
//   const { installFakes } = require('./_fakes');
//   const ctx = installFakes();
//   const fns = require('../index.js');
//   const db = ctx.db; // in-memory Firestore
'use strict';

const path = require('path');
const Module = require('module');

// ─── Sentinels ──────────────────────────────────────────────────────────────
class Inc {
  constructor(n) { this.n = n; }
}
class ServerTs {}
class Del {}
class ArrUnion {
  constructor(items) { this.items = items; }
}
const FieldValue = {
  increment: (n) => new Inc(n),
  serverTimestamp: () => new ServerTs(),
  delete: () => new Del(),
  arrayUnion: (...items) => new ArrUnion(items),
};

class FakeTimestamp {
  constructor(ms) { this.ms = ms; }
  toDate() { return new Date(this.ms); }
  toMillis() { return this.ms; }
  isEqual(o) { return o instanceof FakeTimestamp && o.ms === this.ms; }
  static fromDate(d) { return new FakeTimestamp(d.getTime()); }
  static now() { return new FakeTimestamp(Date.now()); }
  static fromMillis(ms) { return new FakeTimestamp(ms); }
}
const Timestamp = FakeTimestamp;
const FieldPath = { documentId: () => ({ __docIdMarker: true }) };
const isDocId = (v) => !!(v && v.__docIdMarker);

// ─── Value helpers ──────────────────────────────────────────────────────────
function clone(v) {
  if (v instanceof FakeTimestamp) return new FakeTimestamp(v.ms);
  if (v instanceof Date) return new Date(v.getTime());
  if (Array.isArray(v)) return v.map(clone);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v)) o[k] = clone(v[k]);
    return o;
  }
  return v;
}
function deepEq(a, b) {
  return JSON.stringify(norm(a)) === JSON.stringify(norm(b));
}
function norm(v) {
  if (v instanceof FakeTimestamp) return { __ts: v.ms };
  if (v instanceof Date) return { __date: v.getTime() };
  if (Array.isArray(v)) return v.map(norm);
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v).sort()) o[k] = norm(v[k]);
    return o;
  }
  return v;
}
function cmpVals(a, b) {
  const na = numOf(a);
  const nb = numOf(b);
  if (na !== null && nb !== null) return na < nb ? -1 : na > nb ? 1 : 0;
  const sa = strOf(a);
  const sb = strOf(b);
  return sa < sb ? -1 : sa > sb ? 1 : 0;
}
function numOf(v) {
  if (typeof v === 'number') return v;
  if (v instanceof FakeTimestamp) return v.ms;
  if (v instanceof Date) return v.getTime();
  return null;
}
function strOf(v) {
  if (typeof v === 'string') return v;
  if (v instanceof FakeTimestamp) return 'ts:' + v.ms;
  if (v instanceof Date) return 'd:' + v.getTime();
  return JSON.stringify(norm(v));
}
function getPath(obj, dotted) {
  const parts = dotted.split('.');
  let cur = obj;
  for (const p of parts) {
    if (cur == null || typeof cur !== 'object') return undefined;
    cur = cur[p];
  }
  return cur;
}
function setPath(obj, dotted, val, isDelete) {
  const parts = dotted.split('.');
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    if (cur[parts[i]] == null || typeof cur[parts[i]] !== 'object') {
      cur[parts[i]] = {};
    }
    cur = cur[parts[i]];
  }
  if (isDelete) delete cur[parts[parts.length - 1]];
  else cur[parts[parts.length - 1]] = val;
}
function resolveWrite(val) {
  if (val instanceof ServerTs) return FakeTimestamp.now();
  if (val instanceof Del) return val; // handled by caller
  if (val instanceof Inc) return val; // handled by caller
  if (val instanceof ArrUnion) return val; // handled by caller
  if (Array.isArray(val)) return val.map((x) => (x instanceof ServerTs ? FakeTimestamp.now() : clone(x)));
  if (val && typeof val === 'object' && !(val instanceof FakeTimestamp) && !(val instanceof Date)) {
    const o = {};
    for (const k of Object.keys(val)) {
      const r = resolveWrite(val[k]);
      if (!(r instanceof Del)) o[k] = r;
    }
    return o;
  }
  return clone(val);
}

// ─── Snapshots ──────────────────────────────────────────────────────────────
class Snap {
  constructor(ref, data) {
    this.ref = ref;
    this.id = ref.id;
    this.exists = data !== undefined;
    this._data = data;
  }
  data() {
    return this.exists ? clone(this._data) : undefined;
  }
  get(f) {
    return this.exists ? clone(getPath(this._data, f)) : undefined;
  }
}

// ─── Store ──────────────────────────────────────────────────────────────────
class Store {
  constructor() {
    this.docs = new Map(); // fullPath -> data object
    this.autoId = 0;
  }
  reset() {
    this.docs.clear();
    this.autoId = 0;
  }
}

class DocRef {
  constructor(db, colPath, id) {
    this._db = db;
    this._col = colPath;
    this.id = id;
  }
  get path() {
    return `${this._col}/${this.id}`;
  }
  collection(sub) {
    return new ColRef(this._db, `${this.path}/${sub}`);
  }
  async get() {
    const d = this._db.store.docs.get(this.path);
    return new Snap(this, d === undefined ? undefined : d);
  }
  async set(data, opts) {
    const cur = this._db.store.docs.get(this.path);
    const fresh = resolveWrite(data);
    if (opts && opts.merge && cur !== undefined) {
      const merged = clone(cur);
      for (const k of Object.keys(fresh)) {
        if (fresh[k] instanceof ArrUnion) {
          merged[k] = unionArr(merged[k], fresh[k].items);
        } else {
          merged[k] = fresh[k];
        }
      }
      this._db.store.docs.set(this.path, merged);
    } else {
      const out = {};
      for (const k of Object.keys(fresh)) {
        out[k] = fresh[k] instanceof ArrUnion ? unionArr(undefined, fresh[k].items) : fresh[k];
      }
      this._db.store.docs.set(this.path, out);
    }
  }
  async update(data) {
    let cur = this._db.store.docs.get(this.path);
    if (cur === undefined) throw new Error(`NOT_FOUND update ${this.path}`);
    cur = clone(cur);
    for (const k of Object.keys(data)) {
      const v = data[k];
      if (v instanceof Del) {
        setPath(cur, k, null, true);
      } else if (v instanceof Inc) {
        const base = getPath(cur, k);
        setPath(cur, k, (typeof base === 'number' ? base : 0) + v.n);
      } else if (v instanceof ArrUnion) {
        setPath(cur, k, unionArr(getPath(cur, k), v.items));
      } else {
        setPath(cur, k, resolveWrite(v));
      }
    }
    this._db.store.docs.set(this.path, cur);
  }
  async delete() {
    this._db.store.docs.delete(this.path);
  }
}
function unionArr(base, items) {
  const out = Array.isArray(base) ? base.map(clone) : [];
  for (const it of items.map(clone)) {
    if (!out.some((e) => deepEq(e, it))) out.push(it);
  }
  return out;
}

function matchFilter(data, id, f) {
  const val = f.field === '__id__' ? id : getPath(data, f.field);
  switch (f.op) {
    case '==': return deepEq(val, f.value);
    case '!=': return !deepEq(val, f.value);
    case 'in': return Array.isArray(f.value) && f.value.some((x) => deepEq(val, x));
    case 'not-in': return Array.isArray(f.value) && !f.value.some((x) => deepEq(val, x));
    case '<': return cmpVals(val, f.value) < 0;
    case '<=': return cmpVals(val, f.value) <= 0;
    case '>': return cmpVals(val, f.value) > 0;
    case '>=': return cmpVals(val, f.value) >= 0;
    case 'array-contains': return Array.isArray(val) && val.some((x) => deepEq(x, f.value));
    default: throw new Error('unsupported where op ' + f.op);
  }
}

class Query {
  constructor(db, colPath, filters = [], orders = [], lim = null, startAfterId = null) {
    this._db = db;
    this._col = colPath;
    this._filters = filters;
    this._orders = orders;
    this._lim = lim;
    this._startAfterId = startAfterId;
  }
  where(field, op, value) {
    const f = isDocId(field) ? '__id__' : field;
    return new Query(this._db, this._col, [...this._filters, { field: f, op, value: clone(value) }], this._orders, this._lim, this._startAfterId);
  }
  orderBy(field, dir) {
    const f = isDocId(field) ? '__id__' : field;
    return new Query(this._db, this._col, this._filters, [...this._orders, { field: f, dir: dir === 'desc' ? -1 : 1 }], this._lim, this._startAfterId);
  }
  limit(n) {
    return new Query(this._db, this._col, this._filters, this._orders, n, this._startAfterId);
  }
  startAfter(snap) {
    return new Query(this._db, this._col, this._filters, this._orders, this._lim, snap.id);
  }
  _all() {
    const prefix = this._col + '/';
    const out = [];
    for (const [p, data] of this._db.store.docs) {
      if (!p.startsWith(prefix)) continue;
      if (p.slice(prefix.length).includes('/')) continue; // direct children only
      const id = p.slice(prefix.length);
      if (!this._filters.every((f) => matchFilter(data, id, f))) continue;
      out.push({ id, data });
    }
    if (this._orders.length) {
      out.sort((a, b) => {
        for (const o of this._orders) {
          const av = o.field === '__id__' ? a.id : getPath(a.data, o.field);
          const bv = o.field === '__id__' ? b.id : getPath(b.data, o.field);
          const c = cmpVals(av, bv);
          if (c !== 0) return c * o.dir;
        }
        return 0;
      });
    }
    let rows = out;
    if (this._startAfterId) {
      const i = rows.findIndex((r) => r.id === this._startAfterId);
      rows = i < 0 ? [] : rows.slice(i + 1);
    }
    if (this._lim !== null && this._lim !== undefined) rows = rows.slice(0, this._lim);
    return rows;
  }
  async get() {
    const rows = this._all().map(
      (r) => new Snap(new DocRef(this._db, this._col, r.id), r.data)
    );
    return { docs: rows, size: rows.length, empty: rows.length === 0 };
  }
  async count() {
    const rows = this._all();
    return {
      get: async () => rows,
      data: () => ({ count: rows.length }),
      _count: rows.length,
    };
  }
}

class ColRef extends Query {
  constructor(db, colPath) {
    super(db, colPath);
  }
  doc(id) {
    if (!id) id = `auto${++this._db.store.autoId}`;
    return new DocRef(this._db, this._col, id);
  }
  async add(data) {
    const ref = this.doc();
    await ref.set(data);
    return ref;
  }
}

// Admin .count() returns an AggregateQuerySnapshot with .data().count —
// emulate: db.collection().where()...count().get() -> {data:()=>({count})}.
Query.prototype.count = function () {
  const self = this;
  return {
    get: async () => ({ data: () => ({ count: self._all().length }) }),
  };
};

class FakeDb {
  constructor(store) {
    this.store = store;
  }
  collection(p) {
    return new ColRef(this, p);
  }
  async runTransaction(fn) {
    // Mirrors @google-cloud/firestore: every read must precede every write.
    let wrote = false;
    const readGuard = () => {
      if (wrote) throw new Error('Firestore transactions require all reads to be executed before all writes.');
    };
    const tx = {
      get: (refOrQuery) => {
        readGuard();
        return refOrQuery.get();
      },
      getAll: (...refs) => {
        readGuard();
        return Promise.all(refs.map((r) => r.get()));
      },
      set: (ref, data, opts) => { wrote = true; return ref.set(data, opts); },
      update: (ref, data) => { wrote = true; return ref.update(data); },
      delete: (ref) => { wrote = true; return ref.delete(); },
    };
    return fn(tx);
  }
  batch() {
    const ops = [];
    return {
      set: (ref, data, opts) => ops.push(() => ref.set(data, opts)),
      update: (ref, data) => ops.push(() => ref.update(data)),
      delete: (ref) => ops.push(() => ref.delete()),
      commit: async () => {
        for (const op of ops) await op();
      },
    };
  }
  async recursiveDelete(ref) {
    const prefix = ref.path + '/';
    for (const p of [...this.store.docs.keys()]) {
      if (p === ref.path || p.startsWith(prefix)) this.store.docs.delete(p);
    }
  }
  async getAll(...refs) {
    return Promise.all(refs.map((r) => r.get()));
  }
}

// ─── Module interception ────────────────────────────────────────────────────
function intercept(requestPath, exportsObj) {
  const resolved = Module.createRequire(path.join(__dirname, '..', 'index.js')).resolve(requestPath);
  require.cache[resolved] = {
    id: resolved,
    filename: resolved,
    loaded: true,
    exports: exportsObj,
  };
}

class HttpsError extends Error {
  constructor(code, message, details) {
    super(message || code);
    this.code = code;
    this.details = details;
  }
}

function installFakes() {
  const store = new Store();
  const db = new FakeDb(store);
  const sentPush = [];
  const deletedAuthUsers = [];
  const idTokens = new Map();
  const pushFlags = { failPush: false };
  // uid -> { email, emailVerified, metadata } for the Admin Auth reads
  // (getUser / listUsers / deleteUsers). Tests seed it through ctx.authUsers.
  const authUsers = new Map();
  const describeUser = (uid) => {
    const u = authUsers.get(uid) || {};
    return {
      uid,
      email: u.email ?? null,
      emailVerified: u.emailVerified === true,
      metadata: u.metadata || {},
    };
  };
  // Exposed on the db so test factories (helpers.mkUser) can register a
  // matching Admin Auth identity without importing the fake twice.
  db.authUsers = authUsers;

  intercept('firebase-admin/app', {
    initializeApp: () => ({}),
  });
  intercept('firebase-admin/firestore', {
    getFirestore: () => db,
    FieldValue,
    Timestamp,
    FieldPath,
  });
  intercept('firebase-admin/auth', {
    getAuth: () => ({
      deleteUser: async (uid) => {
        deletedAuthUsers.push(uid);
      },
      updateUser: async (uid) => ({ uid }),
      // Website endpoints verify the buyer's ID token. Tests register the
      // tokens they expect with ctx.setIdToken(token, claims).
      verifyIdToken: async (token) => {
        const claims = idTokens.get(token);
        if (!claims) {
          const err = new Error('Decoding Firebase ID token failed');
          err.code = 'auth/argument-error';
          throw err;
        }
        return { ...claims };
      },
      getUser: async (uid) => {
        if (!authUsers.has(uid)) {
          const err = new Error('no user record');
          err.code = 'auth/user-not-found';
          throw err;
        }
        return describeUser(uid);
      },
      listUsers: async (maxResults = 1000, pageToken) => {
        const all = [...authUsers.keys()].map(describeUser);
        const start = pageToken ? Number(pageToken) : 0;
        const page = all.slice(start, start + maxResults);
        const next = start + maxResults < all.length
          ? String(start + maxResults)
          : undefined;
        return { users: page, pageToken: next };
      },
      deleteUsers: async (uids) => {
        let successCount = 0;
        let failureCount = 0;
        for (const uid of uids) {
          if (authUsers.delete(uid)) successCount += 1;
          else failureCount += 1;
          deletedAuthUsers.push(uid);
        }
        return { successCount, failureCount };
      },
    }),
  });
  intercept('firebase-admin/messaging', {
    getMessaging: () => ({
      send: async (msg) => {
        if (pushFlags.failPush) throw new Error('fake fcm outage');
        sentPush.push(msg);
        return 'fake-msg-id';
      },
      sendEachForMulticast: async ({ tokens, notification, data }) => {
        for (const t of tokens) sentPush.push({ token: t, notification, data });
        return { successCount: tokens.length, failureCount: 0 };
      },
    }),
  });
  const wrapCallable = (opts, handler) => {
    const fn = typeof opts === 'function' ? opts : handler;
    return { run: (req) => fn(req || {}), __endpoint: { callableTrigger: {} } };
  };
  intercept('firebase-functions/v2/https', {
    onCall: wrapCallable,
    onRequest: (opts, handler) => {
      const fn = typeof opts === 'function' ? opts : handler;
      return { run: (req, res) => fn(req || {}, res) };
    },
    HttpsError,
  });
  intercept('firebase-functions/v2/scheduler', {
    onSchedule: (opts, handler) => {
      const fn = typeof opts === 'function' ? opts : handler;
      return { run: (event) => fn(event || {}) };
    },
  });
  intercept('firebase-functions/v2/firestore', {
    onDocumentUpdated: (opts, handler) => {
      const fn = typeof opts === 'function' ? opts : handler;
      return { run: (e) => fn(e) };
    },
    onDocumentCreated: (opts, handler) => {
      const fn = typeof opts === 'function' ? opts : handler;
      return { run: (e) => fn(e) };
    },
  });
  intercept('firebase-functions/params', {
    defineSecret: () => ({ value: () => { throw new Error('no secrets in tests'); } }),
  });
  intercept('firebase-functions/v2/identity', {
    onUserDeleted: (handler) => ({ run: (e) => handler(e) }),
  });

  return {
    db, store, sentPush, pushFlags, deletedAuthUsers, HttpsError, FakeTimestamp,
    authUsers,
    // Registers a fake verified ID token for the website endpoints.
    setIdToken: (token, claims) => idTokens.set(token, claims),
  };
}

module.exports = { installFakes, FakeTimestamp };
