import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../core/services/app_update_service.dart';
import '../../core/services/firestore_service.dart';

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
    // The player types a short code (historically, a uid was accepted instead).
    // The server resolves it to the referrer's uid, and THAT uid is what gets
    // stored, so the claimReferralBonus gate is unchanged. Best-effort: a
    // failed resolution must never fail registration, it only means no
    // referral, and the server callable stays authoritative.
    String? validReferredBy;
    if (referredBy != null) {
      final trimmed = referredBy.trim();
      if (trimmed.isNotEmpty) {
        try {
          final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
              .httpsCallable('resolveReferralCode')
              .call<Map<String, dynamic>>({
            'code': trimmed,
            ...AppUpdateService.instance.clientBuildStamp,
          });
          final resolved = (res.data['uid'] as String?)?.trim();
          if (resolved != null &&
              resolved.isNotEmpty &&
              resolved != cred.user!.uid) {
            validReferredBy = resolved;
          }
        } catch (_) {
          validReferredBy = null;
        }
      }
    }

    // ── Server-authoritative profile creation ────────────────────────────────
    // The client no longer writes users/{uid} (firestore.rules denies it). The
    // ensureProfile callable validates the username, claims it in
    // `usernames/{key}` (so signup cannot create duplicates), seeds
    // totalScore/stats/animeCoins/weeklyPoints server-side, validates the
    // university, and resolves the referral itself.
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('ensureProfile')
          .call<Map<String, dynamic>>({
        'username': username.trim(),
        'email': email.trim(),
        if (university != null && university.isNotEmpty) 'university': university,
        if (validReferredBy != null) 'referredBy': validReferredBy,
        ...AppUpdateService.instance.clientBuildStamp,
      });
    } on FirebaseFunctionsException catch (e) {
      // Roll back the half-created Auth account so the player can retry the
      // same username instead of being left with an account that has no
      // profile (and no way to create one).
      try {
        await cred.user!.delete();
      } catch (_) {
        // If deletion fails the account still exists; surface the original
        // reason so the UI can tell them what to do.
      }
      throw SignUpException(e.message ?? 'Registration failed.');
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

  Future<void> signOut() async {
    FriendsBoardFetch.invalidateFriendsBoardCache();
    await _auth.signOut();
  }

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
    FriendsBoardFetch.invalidateFriendsBoardCache();
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

  // REMOVED: updateScore / updateStats.
  // `totalScore` and `stats` are server-owned (firestore.rules now uses a
  // positive `hasOnly(['fcmToken'])` allowlist), so these methods could only
  // ever throw permission-denied. They had no call sites.

  Stream<DocumentSnapshot<Map<String, dynamic>>> userProfileStream() {
    final uid = currentUser!.uid;
    return _db.collection('users').doc(uid).snapshots();
  }
}

/// A registration failure the UI can show verbatim (e.g. "That username is
/// already taken."). Distinct from [FirebaseAuthException] so the login page
/// does not need to know about Cloud Functions error codes.
class SignUpException implements Exception {
  final String message;
  const SignUpException(this.message);

  @override
  String toString() => message;
}