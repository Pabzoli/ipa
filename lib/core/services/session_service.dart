import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'app_update_service.dart';
import 'device_id_service.dart';

/// Client half of the single-device login guard (server half lives in
/// `functions/index.js`: `claimSession` / `releaseSession` / `_assertSingleSession`).
///
/// One account holds exactly one live login: signing in on a second device
/// supersedes the first. This service claims the current login right after
/// authentication ([claim], called by the auth gate on every authenticated
/// startup) and watches `users/{uid}.activeSession` ([startGuard]). When a
/// newer login appears, [superseded] flips and listeners (the auth gate) sign
/// this device out; the login screen then shows [supersededNotice].
///
/// Everything here fails open: an unreachable backend never blocks login, and
/// a claim that fails is retried on the next startup. The server-side gate is
/// what actually refuses superseded callers (`failed-precondition /
/// session_superseded`), so a client that never claims (or a patched client
/// that ignores eviction) still cannot transact.
class SessionService extends ChangeNotifier {
  SessionService._();
  static final SessionService instance = SessionService._();

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Per-login random nonce. Breaks the tie when two logins land inside the
  /// same ID-token second (auth_time has 1-second resolution). Stable for the
  /// life of one login: rotating it on every cold start would briefly disagree
  /// with the stored record and look like a supersede.
  String? _nonce;
  String? _nonceUid;
  int _nonceAuthTime = -1;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _guardSub;
  String? _guardUid;

  bool _superseded = false;
  bool get superseded => _superseded;

  bool _noticePending = false;

  /// True when the previous visible login ended in an eviction. Consumed once
  /// by the login screen to render the notice, then cleared.
  bool consumeSupersededNotice() {
    if (!_noticePending) return false;
    _noticePending = false;
    return true;
  }

  static const supersededNotice =
      'You signed in on another device. This session has been signed out.';

  /// True for the server's superseded rejection, whatever the call site.
  static bool isSupersededError(Object e) {
    if (e is FirebaseFunctionsException) {
      if (e.code == 'failed-precondition' &&
          (e.message ?? '') == 'session_superseded') {
        return true;
      }
      final details = e.details;
      if (e.code == 'failed-precondition' &&
          details is Map &&
          details['reason'] == 'session_superseded') {
        return true;
      }
    }
    return false;
  }

  /// Records this login as the single live session, superseding any previous
  /// device. Idempotent for the same login; never throws.
  Future<void> claim() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final authTime = await _ownAuthTimeSeconds();
    if (_nonce == null || _nonceUid != user.uid || _nonceAuthTime != authTime) {
      _nonce = _newNonce();
      _nonceUid = user.uid;
      _nonceAuthTime = authTime;
    }
    try {
      await _functions.httpsCallable('claimSession').call(<String, dynamic>{
        if (_nonce != null) 'sessionId': _nonce,
        'deviceId': await DeviceIdService.instance.value(),
        ...AppUpdateService.instance.clientBuildStamp,
      });
      if (_superseded) {
        _superseded = false;
        notifyListeners();
      }
    } catch (e) {
      debugPrint(
          '[SessionService] claim failed (fail open, retries later): $e');
    }
  }

  /// Starts (idempotently, per uid) the eviction watch. Safe to call on every
  /// authenticated startup; a no-op while signed out.
  void startGuard() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (_guardUid == uid && _guardSub != null) return;
    stopGuard();
    _guardUid = uid;
    _guardSub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen(
      (snap) => _evaluate(snap.data()),
      onError: (_) {
        // Fail open: a broken listener must never sign anyone out.
      },
    );
  }

  void stopGuard() {
    _guardSub?.cancel();
    _guardSub = null;
    _guardUid = null;
  }

  /// Releases the live session, but only when this login still owns it (the
  /// server no-ops otherwise, so evicting a superseded device never clears the
  /// login that replaced it). Best-effort: sign-out always proceeds. Must be
  /// called while still authenticated, before `FirebaseAuth.signOut()`.
  Future<void> release() async {
    final uid = _guardUid ?? FirebaseAuth.instance.currentUser?.uid;
    final nonce = _nonceUid == uid ? _nonce : null;
    stopGuard();
    _nonce = null;
    _nonceUid = null;
    _nonceAuthTime = -1;
    if (uid == null || FirebaseAuth.instance.currentUser?.uid != uid) return;
    try {
      await _functions.httpsCallable('releaseSession').call(<String, dynamic>{
        if (nonce != null) 'sessionId': nonce,
      });
    } catch (e) {
      debugPrint('[SessionService] release failed (ignored): $e');
    }
  }

  Future<void> _evaluate(Map<String, dynamic>? data) async {
    final uid = _guardUid;
    if (uid == null || FirebaseAuth.instance.currentUser?.uid != uid) return;
    final raw = data?['activeSession'];
    if (raw is! Map) return;
    final storedTime = (raw['authTime'] as num?)?.toInt() ?? 0;
    final storedNonce = (raw['sessionId'] as String?)?.trim() ?? '';
    if (storedTime <= 0 && storedNonce.isEmpty) return;

    final ownTime = await _ownAuthTimeSeconds();
    if (FirebaseAuth.instance.currentUser?.uid != uid) return;
    if (ownTime <= 0) return; // Cannot discriminate — fail open.

    bool hit = false;
    if (storedTime > ownTime) {
      hit = true;
    } else if (storedTime == ownTime &&
        storedNonce.isNotEmpty &&
        _nonce != null &&
        _nonceUid == uid &&
        storedNonce != _nonce) {
      // Same-second logins: the nonce is the only discriminator.
      hit = true;
    }
    if (hit && !_superseded) {
      _superseded = true;
      _noticePending = true;
      debugPrint('[SessionService] login superseded by another device');
      notifyListeners();
    }
  }

  Future<int> _ownAuthTimeSeconds() async {
    try {
      final res = await FirebaseAuth.instance.currentUser?.getIdTokenResult();
      final ms = res?.authTime?.millisecondsSinceEpoch;
      if (ms == null) return 0;
      return ms ~/ 1000;
    } catch (_) {
      return 0;
    }
  }

  String _newNonce() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }
}
