import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../../core/constants/referral_economy.dart';
import '../../../../core/services/app_update_service.dart';
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

  /// The inviter's own short invite code (`getMyReferralCode`), minted
  /// server-side on first request and stable after that.
  ///
  /// Returns '' when the call fails, so the page shows no code rather than a
  /// wrong one. The code is display-only: what gets stored on a new account is
  /// the uid the code resolves to, never the code itself.
  Future<String> getReferralCode() async {
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getMyReferralCode')
          .call<Map<String, dynamic>>({
        ...AppUpdateService.instance.clientBuildStamp,
      });
      return (res.data['referralCode'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<List<ReferralEntry>> getReferralEntries() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const [];

    final entries = <ReferralEntry>[];

    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('referrals')
          .orderBy('createdAt', descending: true)
          .get();
      for (final doc in snap.docs) {
        entries.add(_entryFromDoc(doc.data()));
      }
    } catch (_) {
      // Referral records are not readable yet (rules not deployed) — fall
      // back to the ledger-only view instead of failing the whole page.
    }

    final ledgerDates = await _referralLedgerDates(uid);
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
    );
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
