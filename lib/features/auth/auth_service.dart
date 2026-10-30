import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../core/services/app_update_service.dart';
import '../../core/services/device_id_service.dart';
import '../../core/services/firestore_service.dart';

/// Wraps Firebase Auth + Firestore profile operations.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  // ── Stream ────────────────────────────────────────────────────────────────

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  // ── Sign Up ───────────────────────────────────────────────────────────────

  /// [university] is optional so the call site stays backward-compatible.
  /// When provided (and non-empty), it is stored in the Firestore profile
  /// so the campus leaderboard can filter by it.
  ///
  /// [termsAccepted] must be true; the server stamps the acceptance and the
  /// terms version onto the profile, so the client never writes them.
  Future<UserCredential> signUp({
    required String email,
    required String password,
    required String username,
    required bool termsAccepted,
    String? university,
    String? referredBy,
  }) async {
    if (!termsAccepted) {
      throw const SignUpException(
        'Accept the Terms of Service and Privacy Policy to continue.',
      );
    }

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
        'deviceId': await DeviceIdService.instance.value(),
        'termsAccepted': true,
        if (university != null && university.isNotEmpty)
          'university': university,
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

    // Verification email is best-effort: a failed send must not undo signup.
    // The banner + resend button on the verification page cover it.
    try {
      await sendVerificationEmail();
    } catch (_) {
      // Covered by the resend path.
    }

    return cred;
  }

  // ── Terms re-acceptance ───────────────────────────────────────────────────
  //
  // One-time screen for pre-terms accounts (no `termsAcceptedAt` on the user
  // doc). The stamp and version are written server-side by `acceptTerms`;
  // the client never writes them (firestore.rules denies it).
  Future<void> acceptTerms() async {
    try {
      await _functions.httpsCallable('acceptTerms').call({
        'termsAccepted': true,
        ...AppUpdateService.instance.clientBuildStamp,
      });
    } on FirebaseFunctionsException catch (e) {
      throw AuthFlowException(e.message ?? 'Could not save your acceptance.');
    }
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

  // ── Email verification ────────────────────────────────────────────────────
  //
  // A verified email is required to get past the login screen. AuthGate shows
  // the verification screen to any signed-in account whose email is not
  // verified, so this is the single gate for the whole app.

  // Test accounts skip the verification-link flow entirely.
  static const bypassVerificationEmails = <String>{
    '1@gmail.com',
    '2@gmail.com',
  };

  static bool isBypassVerificationEmail(String? email) =>
      bypassVerificationEmails.contains((email ?? '').trim().toLowerCase());

  bool get isEmailVerified {
    final user = _auth.currentUser;
    if (user == null) return false;
    if (user.emailVerified) return true;
    return isBypassVerificationEmail(user.email);
  }

  String get accountEmail => _auth.currentUser?.email ?? '';

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Asks the server for permission to send (60s / 5-per-day budget), then
  /// performs the actual Firebase send. Returns the server payload so the UI
  /// can render the countdown and remaining sends.
  Future<Map<String, dynamic>> sendVerificationEmail() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthFlowException('Sign in again to verify your email.');
    }

    final res = await _functions
        .httpsCallable('requestEmailVerification')
        .call<Map<String, dynamic>>({
      ...AppUpdateService.instance.clientBuildStamp,
    });
    final data = Map<String, dynamic>.from(res.data);
    if (data['alreadyVerified'] == true) return data;
    if (data['ok'] != true) return data;

    await user.sendEmailVerification();
    return data;
  }

  /// Re-reads the Firebase user, mirrors the verified state server-side, and
  /// forces a token refresh so `email_verified` is on the next callable/rules
  /// request without a re-login.
  Future<bool> refreshEmailVerification() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    if (isBypassVerificationEmail(user.email)) {
      try {
        await _functions.httpsCallable('syncEmailVerification').call();
      } catch (_) {
        // The token claim is authoritative; the mirror is best-effort.
      }
      await _auth.currentUser?.getIdToken(true);
      return true;
    }

    await user.reload();
    final verified = _auth.currentUser?.emailVerified ?? false;
    if (!verified) return false;

    try {
      await _functions.httpsCallable('syncEmailVerification').call();
    } catch (_) {
      // The token claim is authoritative; the mirror is best-effort.
    }
    await _auth.currentUser?.getIdToken(true);
    return true;
  }

  /// Moves an unverified account to [newEmail]. Re-authenticates with the
  /// current password first (Firebase requires a recent sign-in for this),
  /// asks the server to approve the address, then sends the confirmation link
  /// to the NEW address. The sign-in email only changes once that link is
  /// opened, so a typo leaves the account where it was.
  Future<Map<String, dynamic>> changeUnverifiedEmail({
    required String newEmail,
    required String password,
  }) async {
    final user = _auth.currentUser;
    final currentEmail = user?.email;
    if (user == null || currentEmail == null) {
      throw const AuthFlowException('Sign in again to change your email.');
    }

    await user.reauthenticateWithCredential(
      EmailAuthProvider.credential(email: currentEmail, password: password),
    );

    final res = await _functions
        .httpsCallable('prepareEmailChange')
        .call<Map<String, dynamic>>({
      'newEmail': newEmail.trim(),
      ...AppUpdateService.instance.clientBuildStamp,
    });
    final data = Map<String, dynamic>.from(res.data);
    if (data['ok'] != true) return data;

    await user.verifyBeforeUpdateEmail(newEmail.trim());
    return data;
  }

  // ── Sign-in failure limits ────────────────────────────────────────────────

  /// Server-side lock check before a sign-in / password-reset attempt.
  Future<Map<String, dynamic>> checkAuthAttempt(String email) async {
    try {
      final res = await _functions
          .httpsCallable('checkAuthAttempt')
          .call<Map<String, dynamic>>({'email': email.trim()});
      return Map<String, dynamic>.from(res.data);
    } catch (_) {
      // Never block the user because the limiter is unreachable.
      return const {'allowed': true, 'retryAfterSeconds': 0};
    }
  }

  Future<void> reportAuthFailure(String email, {String kind = 'signin'}) async {
    try {
      await _functions.httpsCallable('reportAuthFailure').call({
        'email': email.trim(),
        'kind': kind,
      });
    } catch (_) {
      // Advisory layer only.
    }
  }

  Future<void> reportAuthSuccess(String email) async {
    try {
      await _functions
          .httpsCallable('reportAuthSuccess')
          .call({'email': email.trim()});
    } catch (_) {
      // Advisory layer only.
    }
  }

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

/// A failure in the email-verification flow that the UI can show verbatim.
class AuthFlowException implements Exception {
  final String message;
  const AuthFlowException(this.message);

  @override
  String toString() => message;
}
