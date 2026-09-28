import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Wraps Firebase Auth + Firestore profile operations.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final _auth = FirebaseAuth.instance;
  final _db   = FirebaseFirestore.instance;

  // ── Stream ────────────────────────────────────────────────────────────────

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User?         get currentUser      => _auth.currentUser;

  // ── Sign Up ───────────────────────────────────────────────────────────────

  /// [university] is optional so the call site stays backward-compatible.
  /// When provided (and non-empty), it is stored in the Firestore profile
  /// so the campus leaderboard can filter by it.
    Future<UserCredential> signUp({
    required String email,
    required String password,
    required String username,
    String?         university,
    String?         referredBy,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    await cred.user!.updateDisplayName(username.trim());

    // ── Optional referral capture ─────────────────────────────────────────────
    // client-side courtesy only — the real guards (referrer exists, no self-
    // referral, referralBonusClaimed idempotency, 30-day cap) live in the
    // claimReferralBonus callable. We only normalize + sanity-check here.
    String? validReferredBy;
    if (referredBy != null) {
      final trimmed = referredBy.trim();
      if (trimmed.isNotEmpty && trimmed != cred.user!.uid) {
        // NOTE (leaderboard visibility rule): reading another user's doc is
        // now denied unless they share your entry week. A denial here must
        // NOT fail signup — it only means the code can't be verified, so the
        // referral is skipped and the server callable remains authoritative.
        try {
          final referrerSnap =
              await _db.collection('users').doc(trimmed).get();
          if (referrerSnap.exists) {
            validReferredBy = trimmed;
          }
        } catch (_) {
          validReferredBy = null;
        }
      }
    }

    // Build the profile document.
    // - hintCount is gone; animeCoins replaces it.
    final profile = <String, dynamic>{
      'username':            username.trim(),
      'email':               email.trim(),
      'totalScore':          500,
      'animeCoins':          0,
      'weeklyPoints':        0,
      'weeklyReset':         FieldValue.serverTimestamp(),
      'createdAt':           FieldValue.serverTimestamp(),
      'stats': {
        'gamesPlayed': 0,
        'gamesWon':    0,
        'gamesLost':   0,
        'hseWon':      0,
        'hseLost':     0,
        'hseStaked':   0,
      },
    };

    // Only persist the university field if the user actually chose one.
    if (university != null && university.isNotEmpty) {
      profile['university'] = university;
    }

    // Only persist the referral field when a valid referrer was supplied.
    if (validReferredBy != null) {
      profile['referredBy'] = validReferredBy;
    }

    await _db.collection('users').doc(cred.user!.uid).set(profile);

    // ── Phase 2 fraud-signal registration ────────────────────────────────────
    // Best-effort only: records server-side creation IP/timestamp via the
    // ensureProfile callable. NEVER fails signup — any error is swallowed.
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('ensureProfile')
          .call({});
    } catch (_) {
      // ignored — signal capture must not block registration
    }

    return cred;
  }

  // ── Sign In ───────────────────────────────────────────────────────────────

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  Future<void> signOut() => _auth.signOut();

  // ── Delete Account ────────────────────────────────────────────────────────

  /// Requests full account deletion via the `deleteAccount` Cloud Function,
  /// which hard-deletes the user's data (and anonymizes records we must keep
  /// for legal/accounting reasons), then removes the Firebase Auth account.
  ///
  /// Returns the server summary so the UI can tell the user exactly what was
  /// deleted vs retained. Throws [FirebaseFunctionsException] on failure
  /// (e.g. `failed-precondition` when a payout is in progress).
  Future<Map<String, dynamic>> deleteAccount() async {
    final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('deleteAccount')
        .call<Map<String, dynamic>>();
    // Server already deleted the Auth user; clear the local session too.
    try {
      await _auth.signOut();
    } catch (_) {
      // Non-fatal — the auth account no longer exists server-side.
    }
    return Map<String, dynamic>.from(res.data);
  }

  // ── Password Reset ────────────────────────────────────────────────────────

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  // ── Firestore helpers ─────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> getUserProfile() async {
    final uid = currentUser?.uid;
    if (uid == null) return null;
    final doc = await _db.collection('users').doc(uid).get();
    return doc.data();
  }

  Future<void> updateScore(int score) async {
    final uid = currentUser?.uid;
    if (uid == null) return;
    await _db.collection('users').doc(uid).update({'totalScore': score});
  }

  Future<void> updateStats(Map<String, dynamic> stats) async {
    final uid = currentUser?.uid;
    if (uid == null) return;
    await _db.collection('users').doc(uid).update({'stats': stats});
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> userProfileStream() {
    final uid = currentUser!.uid;
    return _db.collection('users').doc(uid).snapshots();
  }
}