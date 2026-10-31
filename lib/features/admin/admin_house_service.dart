// lib/features/admin/admin_house_service.dart
//
// Client wrapper for the house top-3 engine (`houseAdmin` callable).
// Admin-gated server-side via ADMIN_UIDS. UX gate via isAdminUid only.

import 'package:cloud_functions/cloud_functions.dart';

import 'admin_payout_service.dart';

class HouseEntry {
  final String uid;
  final String username;
  final int weeklyPoints;
  const HouseEntry({
    required this.uid,
    required this.username,
    required this.weeklyPoints,
  });

  factory HouseEntry.fromMap(Map<String, dynamic> map) => HouseEntry(
        uid: (map['uid'] as String?) ?? '',
        username: (map['username'] as String?) ?? '',
        weeklyPoints: ((map['weeklyPoints'] as num?)?.toInt()) ?? 0,
      );
}

class HouseSnapshot {
  final String weekId;
  final Map<String, dynamic> global;
  final List<HouseEntry> houses;
  final List<HouseEntry> chasers;
  final List<HouseEntry> topReal;
  final List<Map<String, dynamic>> social;
  const HouseSnapshot({
    required this.weekId,
    required this.global,
    required this.houses,
    this.chasers = const [],
    required this.topReal,
    this.social = const [],
  });

  factory HouseSnapshot.fromMap(Map<String, dynamic> map) {
    List<HouseEntry> list(Object? v) {
      if (v is! List) return const [];
      return v
          .map((e) => HouseEntry.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    }

    List<Map<String, dynamic>> socialList(Object? v) {
      if (v is! List) return const [];
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }

    return HouseSnapshot(
      weekId: (map['weekId'] as String?) ?? '',
      global: Map<String, dynamic>.from((map['global'] as Map?) ?? const {}),
      houses: list(map['houses']),
      chasers: list(map['chasers']),
      topReal: list(map['topReal']),
      social: socialList(map['social']),
    );
  }
}

class AdminHouseService {
  AdminHouseService._();
  static final AdminHouseService instance = AdminHouseService._();

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  Future<HouseSnapshot> fetch() async {
    try {
      final res =
          await _functions.httpsCallable('houseAdmin').call({'op': 'get'});
      return HouseSnapshot.fromMap(Map<String, dynamic>.from(res.data as Map));
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _msg(e));
    }
  }

  Future<void> save(Map<String, dynamic> patch) async {
    try {
      await _functions
          .httpsCallable('houseAdmin')
          .call({'op': 'save', ...patch});
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _msg(e));
    }
  }

  Future<void> nudge({required String uid, required int wp}) async {
    try {
      await _functions
          .httpsCallable('houseAdmin')
          .call({'op': 'nudge', 'uid': uid, 'wp': wp});
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _msg(e));
    }
  }

  Future<void> rotate({String? uid}) async {
    try {
      await _functions.httpsCallable('houseAdmin').call({
        'op': 'rotate',
        if (uid != null) 'uid': uid,
      });
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _msg(e));
    }
  }

  static String _msg(FirebaseFunctionsException e) {
    if (e.code == 'permission-denied') {
      return 'Not authorized. This account is not a payout admin.';
    }
    final m = (e.message ?? '').trim();
    return m.isEmpty ? 'Request failed (${e.code}).' : m;
  }
}
