import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/constants/referral_economy.dart';
import '../../../../core/services/app_update_service.dart';
import '../../../../core/services/play_integrity_service.dart';
import '../model/referral_cashout.dart';
import '../model/referral_entry.dart';

/// Loads the inviter's referral rows.
///
/// Live records come from `users/{uid}/referrals` (Cloud Functions only).
/// Older payouts predate the records, so the `earn_referral`
/// +[kReferralReferrerReward] coin transactions are still read and merged in
/// as best-effort legacy rows: the ledger carries no invitee identity, so the
/// newest [paidRecordCount] ledger entries are treated as already represented
/// by the rewarded records and only the remainder becomes "Earlier referral".
class ReferralRemoteDataSource {
  const ReferralRemoteDataSource();

  /// Session caches so reopening the page doesn't replay every read.
  /// The invite code is stable once minted (memory + prefs); entries and the
  /// cashout claim are short-TTL memory only — pull-to-refresh bypasses them
  /// via [forceRefresh].
  static const Duration _listTtl = Duration(seconds: 90);
  static final Map<String, String> _codeMemory = {};
  static List<ReferralEntry>? _entriesMemory;
  static DateTime? _entriesMemoryAt;
  static String? _entriesMemoryUid;
  static ReferralCashoutClaim? _cashoutMemory;
  static DateTime? _cashoutMemoryAt;
  static String? _cashoutMemoryUid;
  static bool _cashoutMemoryHasValue = false;

  static String _codePrefsKey(String uid) => 'referral_code_$uid';

  /// The inviter's own short invite code (`getMyReferralCode`), minted
  /// server-side on first request and stable after that.
  ///
  /// Served from memory, then device storage, then network — a cold-start
  /// Cloud Function call no longer blocks the code card on every visit.
  ///
  /// Returns '' when the call fails, so the page shows no code rather than a
  /// wrong one. The code is display-only: what gets stored on a new account is
  /// the uid the code resolves to, never the code itself.
  Future<String> getReferralCode() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return '';
    final mem = _codeMemory[uid];
    if (mem != null && mem.isNotEmpty) return mem;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_codePrefsKey(uid)) ?? '';
      if (stored.isNotEmpty) {
        _codeMemory[uid] = stored;
        return stored;
      }
    } catch (_) {
      // Storage is best-effort; fall through to the network mint.
    }
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getMyReferralCode')
          .call<Map<String, dynamic>>({
        ...AppUpdateService.instance.clientBuildStamp,
      });
      final code = (res.data['referralCode'] as String?) ?? '';
      if (code.isNotEmpty) {
        _codeMemory[uid] = code;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_codePrefsKey(uid), code);
        } catch (_) {
          // Best-effort only.
        }
      }
      return code;
    } catch (_) {
      return '';
    }
  }

  Future<List<ReferralEntry>> getReferralEntries(
      {bool forceRefresh = false}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const [];

    if (!forceRefresh &&
        _entriesMemoryUid == uid &&
        _entriesMemory != null &&
        _entriesMemoryAt != null &&
        DateTime.now().difference(_entriesMemoryAt!) < _listTtl) {
      return _entriesMemory!;
    }

    final entries = <ReferralEntry>[];

    // The records query and the legacy ledger scan are independent — run
    // them concurrently instead of sequentially.
    List<QueryDocumentSnapshot<Map<String, dynamic>>> recordDocs = [];
    List<DateTime> ledgerDates = [];
    try {
      final results = await Future.wait([
        FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('referrals')
            .orderBy('createdAt', descending: true)
            .get(),
        _referralLedgerDates(uid),
      ]);
      recordDocs = (results[0] as QuerySnapshot<Map<String, dynamic>>).docs;
      ledgerDates = results[1] as List<DateTime>;
    } catch (_) {
      // Referral records are not readable yet (rules not deployed) — fall
      // back to the ledger-only view instead of failing the whole page.
      try {
        ledgerDates = await _referralLedgerDates(uid);
      } catch (_) {
        ledgerDates = [];
      }
    }
    for (final doc in recordDocs) {
      entries.add(_entryFromDoc(doc.data()));
    }

    final paidRecords = entries.where((entry) => entry.isRewarded).length;
    final legacyCount = ledgerDates.length - paidRecords;
    if (legacyCount > 0) {
      // Ledger dates are ascending; the oldest entries are the pre-record
      // payouts that have no per-referral document.
      for (var i = 0; i < legacyCount; i++) {
        entries.add(
          ReferralEntry.legacy(
            awardedAt: ledgerDates[i],
            coins: kReferralReferrerReward,
          ),
        );
      }
    }

    _entriesMemory = entries;
    _entriesMemoryAt = DateTime.now();
    _entriesMemoryUid = uid;
    return entries;
  }

  ReferralEntry _entryFromDoc(Map<String, dynamic> data) {
    return ReferralEntry(
      inviteeUsername: data['inviteeUsername'] as String?,
      status: data['status'] == 'rewarded'
          ? ReferralStatus.rewarded
          : ReferralStatus.pending,
      quizzesCompleted: (data['quizzesCompleted'] as num?)?.toInt() ?? 0,
      quizzesRequired: (data['quizzesRequired'] as num?)?.toInt() ??
          kReferralQualifyingQuizCount,
      quizDays: (data['quizDays'] as num?)?.toInt() ?? 0,
      daysRequired:
          (data['daysRequired'] as num?)?.toInt() ?? kReferralQualifyingDays,
      createdAt: _timestampToDate(data['createdAt']),
      qualifiedAt: _timestampToDate(data['qualifiedAt']),
      expiresAt: _timestampToDate(data['expiresAt']),
      rewardAmount:
          (data['rewardAmount'] as num?)?.toInt() ?? kReferralReferrerReward,
      leaderboardEntryPurchased: data['leaderboardEntryPurchased'] == true,
      leaderboardEntryWeekId: data['leaderboardEntryWeekId'] as String?,
      leaderboardEntryPurchasedAt:
          _timestampToDate(data['leaderboardEntryPurchasedAt']),
    );
  }

  /// The player's own cashout claim, or null when none was submitted.
  ///
  /// Owner-read only (rules). A failed read is treated as "no claim" so a
  /// pending rules deploy never breaks the Referrals page. Short-TTL cached;
  /// pull-to-refresh bypasses via [forceRefresh].
  Future<ReferralCashoutClaim?> getCashoutClaim(
      {bool forceRefresh = false}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    if (!forceRefresh &&
        _cashoutMemoryUid == uid &&
        _cashoutMemoryAt != null &&
        DateTime.now().difference(_cashoutMemoryAt!) < _listTtl) {
      return _cashoutMemoryHasValue ? _cashoutMemory : null;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('referralCashouts')
          .doc(uid)
          .get();
      if (!snap.exists) {
        _storeCashout(uid, null);
        return null;
      }
      final claim = ReferralCashoutClaim.fromMap(snap.data() ?? const {});
      _storeCashout(uid, claim);
      return claim;
    } catch (_) {
      return _cashoutMemoryUid == uid && _cashoutMemoryHasValue
          ? _cashoutMemory
          : null;
    }
  }

  void _storeCashout(String uid, ReferralCashoutClaim? claim) {
    _cashoutMemory = claim;
    _cashoutMemoryHasValue = true;
    _cashoutMemoryAt = DateTime.now();
    _cashoutMemoryUid = uid;
  }

  /// Submits the cashout destination via `claimReferralCashout`.
  ///
  /// The server re-counts qualifying referrals and decides the amount. Returns
  /// the server's confirmation message; throws [ReferralCashoutException] with
  /// the server's reason for anything else.
  Future<String> submitCashoutClaim({
    required String bankCode,
    required String accountNumber,
    required String beneficiaryName,
  }) async {
    final integrity =
        await PlayIntegrityService.instance.tokenFields('cashout');
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('claimReferralCashout')
          .call<Map<String, dynamic>>({
        'accountNumber': accountNumber,
        'bankCode': bankCode,
        'beneficiaryName': beneficiaryName,
        ...AppUpdateService.instance.clientBuildStamp,
        ...integrity,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return (data['message'] as String?) ??
          'Cashout submitted. You will be notified on status change.';
    } on FirebaseFunctionsException catch (e) {
      throw ReferralCashoutException(
        code: e.code,
        message: (e.message ?? '').trim().isNotEmpty
            ? e.message!.trim()
            : 'Could not submit the cashout. Please try again.',
      );
    }
  }

  Future<List<DateTime>> _referralLedgerDates(String uid) async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('coinTransactions')
        .where('type', isEqualTo: 'earn_referral')
        .get();
    final dates = <DateTime>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final delta = (data['delta'] as num?)?.toInt();
      final timestamp = data['timestamp'];
      if (delta == kReferralReferrerReward && timestamp is Timestamp) {
        dates.add(timestamp.toDate());
      }
    }
    dates.sort();
    return dates;
  }

  DateTime? _timestampToDate(Object? value) =>
      value is Timestamp ? value.toDate() : null;
}

/// Thrown for `claimReferralCashout` rejections so the sheet can show the
/// server's reason (not yet unlocked / already paid / rejected / bad input).
class ReferralCashoutException implements Exception {
  final String code;
  final String message;

  const ReferralCashoutException({required this.code, required this.message});

  @override
  String toString() => 'ReferralCashoutException($code): $message';
}
