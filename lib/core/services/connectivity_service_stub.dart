import 'dart:async';

/// VM/test fallback: always online. Real status comes from Firestore and
/// auth stream errors, which fail open and retry.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  bool get isOnlineNow => true;

  Future<bool> checkOnline() async => true;

  Stream<bool> get onStatusChanged => const Stream.empty();
}
