import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
    String?         university,   // ← NEW: campus / university name
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    await cred.user!.updateDisplayName(username.trim());

    // Build the profile doc. We only write `university` when the user
    // actually selected one — existing-user upgrade paths set it later via
    // FirestoreService.updateUniversity().
    final profile = <String, dynamic>{
      'username':     username.trim(),
      'email':        email.trim(),
      'totalScore':   500,
      'hintCount':    5,
      'weeklyPoints': 0,
      'weeklyReset':  FieldValue.serverTimestamp(),
      'createdAt':    FieldValue.serverTimestamp(),
      'stats': {
        'gamesPlayed': 0,
        'gamesWon':    0,
        'gamesLost':   0,
        'hseWon':      0,
        'hseLost':     0,
        'hseStaked':   0,
      },
    };

    // Only persist the field if the user actually chose something
    if (university != null && university.isNotEmpty) {
      profile['university'] = university;
    }

    await _db.collection('users').doc(cred.user!.uid).set(profile);

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