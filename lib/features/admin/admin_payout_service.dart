// lib/features/admin/admin_payout_service.dart
//
// Client wrapper for the Admin Payout Dashboard.
//
// PAYOUTS ARE MANUAL. The app never moves money. The admin transfers from
// their own bank app and then records it here with a single tap, so this
// dashboard's whole job is: show me who needs paying, give me their exact
// bank details, and let me tick them off.
//
// SECURITY MODEL — read this before touching this file:
//   * The backend callable is the security boundary. Every admin callable
//     (listPayoutClaims / markLeaderboardPayout / exportPayoutLog) enforces
//     the ADMIN_UIDS gate SERVER-SIDE (functions/index.js) and rejects
//     unauthenticated AND authenticated-non-admin callers. Nothing here can
//     bypass that.
//   * [isAdminUid] below is a UX-ONLY mirror used to decide whether to SHOW
//     the dashboard entry point. It grants zero capability: a non-admin who
//     somehow opened the dashboard would get `permission-denied` from every
//     callable and see the "Not authorized" state.
//   * [accountNumber] arrives UNMASKED, because the admin has to read it out
//     and type it into a banking app. That is the one meaningful difference
//     from a masked feed, and it is why the ADMIN_UIDS gate matters so much.
//     Never log, share, or export it.
//   * This file never sends a payout amount of its own — amounts always come
//     from the server (ranked[].share via listPayoutClaims).

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/services/firestore_service.dart';

/// UX-ONLY mirror of the backend ADMIN_UIDS gate (functions/index.js).
/// Controls dashboard VISIBILITY only — never authorization.
const List<String> kAdminUids = <String>[
  'owMNkXmb6QSzO0xfHkSgMlx0zSJ3',
];

/// True when [uid] (or the current user) matches the known admin list.
/// UX gate only — the backend callable remains authoritative.
bool isAdminUid([String? uid]) {
  final u = uid ?? FirebaseAuth.instance.currentUser?.uid;
  return u != null && kAdminUids.contains(u);
}

/// Display states for one winner's payout, derived ONLY from backend fields.
///
/// No state is invented: every value maps to ranked[].paid or pendingClaim
/// status returned by the listPayoutClaims callable.
enum AdminQueueState {
  /// Winner never submitted payout details for this cycle.
  notSubmitted,

  /// Claim submitted, not yet paid. This is the actionable queue — the admin
  /// needs to transfer the money and then mark it paid.
  pending,

  /// Backend says ranked[].paid == true. The ONLY "Paid" source.
  paid,

  /// Claim expired after the 3-day window (checkPendingClaim). The prize is
  /// forfeited — not paid, and not carried into any later week's pool.
  expired,
}

/// One winner's payout review data, exactly as returned by listPayoutClaims.
class AdminClaimInfo {
  final String uid;
  final int rank;
  final String username;
  final double share;
  final bool paid;

  final String? claimStatus;
  final String? bankCode;

  /// FULL account number — the admin needs it to send the money. Null when the
  /// winner never submitted. Never export or log this.
  final String? accountNumber;

  final String? beneficiaryName;
  final DateTime? submittedAt;

  /// When the admin recorded the manual transfer (claim status 'marked').
  final DateTime? markedAt;
  final String? markedBy;

  /// Optional admin-entered reference from their own bank statement.
  final String? payoutReference;

  /// Advisory fraud score (server-computed, display only — never gates
  /// marking paid). Null / empty when scoreFraudForWeek has not run yet.
  /// [fraudScore] is 0-100, [fraudBand] is 'low' | 'moderate' | 'high'.
  final int? fraudScore;
  final String? fraudBand;
  final List<String> fraudReasons;
  final DateTime? fraudScoredAt;

  const AdminClaimInfo({
    required this.uid,
    required this.rank,
    required this.username,
    required this.share,
    required this.paid,
    required this.claimStatus,
    required this.bankCode,
    required this.accountNumber,
    required this.beneficiaryName,
    required this.submittedAt,
    required this.markedAt,
    required this.markedBy,
    required this.payoutReference,
    required this.fraudScore,
    required this.fraudBand,
    required this.fraudReasons,
    required this.fraudScoredAt,
  });

  factory AdminClaimInfo.fromMap(Map<String, dynamic> map) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v as String);
      } catch (_) {
        return null;
      }
    }

    return AdminClaimInfo(
      uid: (map['uid'] as String?) ?? '',
      rank: ((map['rank'] as num?)?.toInt()) ?? 0,
      username: (map['username'] as String?) ?? 'Anonymous',
      share: ((map['share'] as num?)?.toDouble()) ?? 0.0,
      paid: map['paid'] == true,
      claimStatus: map['claimStatus'] as String?,
      bankCode: map['bankCode'] as String?,
      accountNumber: map['accountNumber'] as String?,
      beneficiaryName: map['beneficiaryName'] as String?,
      submittedAt: parseTs(map['submittedAt']),
      markedAt: parseTs(map['markedAt']),
      markedBy: map['markedBy'] as String?,
      payoutReference: map['payoutReference'] as String?,
      fraudScore: (map['fraudScore'] as num?)?.toInt(),
      fraudBand: map['fraudBand'] as String?,
      fraudReasons: ((map['fraudReasons'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      fraudScoredAt: parseTs(map['fraudScoredAt']),
    );
  }

  /// Fraud band derived from the advisory score. Null when unscored.
  /// Display-only — marking paid must never branch on this.
  String? get fraudBandLabel {
    return switch (fraudBand) {
      'high' => 'HIGH RISK',
      'moderate' => 'MODERATE RISK',
      'low' => 'LOW RISK',
      _ => null,
    };
  }

  /// True when the admin has a complete destination to transfer to.
  bool get hasBankDetails =>
      (accountNumber ?? '').isNotEmpty && (beneficiaryName ?? '').isNotEmpty;

  /// Derived display state. Paid ONLY when the backend says paid == true.
  ///
  /// 'marked' is treated as pending too. markLeaderboardPayout sets the claim
  /// status and ranked[].paid in one transaction so the two should never
  /// disagree — if only one ever lands, ranked[].paid still wins and this
  /// winner stays in the actionable queue rather than silently vanishing.
  AdminQueueState get queueState {
    if (paid) return AdminQueueState.paid;
    if (claimStatus == 'expired') return AdminQueueState.expired;
    if (claimStatus == 'pending' || claimStatus == 'marked') {
      return AdminQueueState.pending;
    }
    return AdminQueueState.notSubmitted;
  }

  /// True only for the actionable payment queue.
  bool get needsPayment => queueState == AdminQueueState.pending;
}

/// Prize-pool state for the current week, exactly as returned by
/// getPrizePoolStatus.
///
/// Two figures matter and they are easy to confuse:
  ///   * [revenueBasedPool] — what the pool would be from leaderboard entry
  ///     sales alone (70% of revenue, never below the floor).
  ///   * [effectivePool] — what it WILL actually be. Equal to [adminPoolNaira]
  ///     when the admin has fixed it, otherwise [revenueBasedPool].
  ///
  /// There is no rollover term: expired claims are forfeited, never carried
  /// forward, so a week is funded only by its own entries or your fixed amount.
class PrizePoolStatus {
  final String weekId;
  final double entryCodeRevenue;
  final double houseCutPotential;
  final double revenueBasedPool;
  final double guaranteedFloor;
  final double effectivePool;
  final bool isFixed;
  final double? adminPoolNaira;
  final String? poolSetBy;
  final bool weekClosed;
  final int maxPoolNaira;

  const PrizePoolStatus({
    required this.weekId,
    required this.entryCodeRevenue,
    required this.houseCutPotential,
    required this.revenueBasedPool,
    required this.guaranteedFloor,
    required this.effectivePool,
    required this.isFixed,
    required this.adminPoolNaira,
    required this.poolSetBy,
    required this.weekClosed,
    required this.maxPoolNaira,
  });

  factory PrizePoolStatus.fromMap(Map<String, dynamic> map) {
    double num2d(Object? v) => ((v as num?)?.toDouble()) ?? 0.0;
    return PrizePoolStatus(
      weekId: (map['weekId'] as String?) ?? '',
      entryCodeRevenue: num2d(map['entryCodeRevenue']),
      houseCutPotential: num2d(map['houseCutPotential']),
      revenueBasedPool: num2d(map['revenueBasedPool']),
      guaranteedFloor: num2d(map['guaranteedFloor']),
      effectivePool: num2d(map['effectivePool']),
      isFixed: map['isFixed'] == true,
      adminPoolNaira: (map['adminPoolNaira'] as num?)?.toDouble(),
      poolSetBy: map['poolSetBy'] as String?,
      weekClosed: map['weekClosed'] == true,
      maxPoolNaira: ((map['maxPoolNaira'] as num?)?.toInt()) ?? 50000000,
    );
  }

  /// Difference between the fixed pool and what sales alone would produce.
  /// Positive means the admin is adding their own money; negative means the
  /// fixed amount is smaller than the revenue-based figure.
  double get differenceFromRevenue => effectivePool - revenueBasedPool;
}

/// One leaderboard cycle with its payment queue.
class AdminPayoutCycle {
  final String weekId;
  final double totalCodeRevenue;
  final double prizePool;
  final double houseCut;
  final double guaranteedFloor;
  final int eligibleCount;
  final String? status;
  final DateTime? calculatedAt;
  final DateTime? paidAt;
  final String notes;
  final int claimsSubmitted;
  final int claimsMarked;
  final int paidCount;
  final List<AdminClaimInfo> claims;

  const AdminPayoutCycle({
    required this.weekId,
    required this.totalCodeRevenue,
    required this.prizePool,
    required this.houseCut,
    required this.guaranteedFloor,
    required this.eligibleCount,
    required this.status,
    required this.calculatedAt,
    required this.paidAt,
    required this.notes,
    required this.claimsSubmitted,
    required this.claimsMarked,
    required this.paidCount,
    required this.claims,
  });

  factory AdminPayoutCycle.fromMap(Map<String, dynamic> map) {
    DateTime? parseTs(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v as String);
      } catch (_) {
        return null;
      }
    }

    final rawClaims = (map['claims'] as List?) ?? const [];
    return AdminPayoutCycle(
      weekId: (map['weekId'] as String?) ?? '',
      totalCodeRevenue: ((map['totalCodeRevenue'] as num?)?.toDouble()) ?? 0.0,
      prizePool: ((map['prizePool'] as num?)?.toDouble()) ?? 0.0,
      houseCut: ((map['houseCut'] as num?)?.toDouble()) ?? 0.0,
      guaranteedFloor:
          ((map['guaranteedFloor'] as num?)?.toDouble()) ?? 0.0,
      eligibleCount: ((map['eligibleCount'] as num?)?.toInt()) ?? 0,
      status: map['status'] as String?,
      calculatedAt: parseTs(map['calculatedAt']),
      paidAt: parseTs(map['paidAt']),
      notes: (map['notes'] as String?) ?? '',
      claimsSubmitted: ((map['claimsSubmitted'] as num?)?.toInt()) ?? 0,
      claimsMarked: ((map['claimsMarked'] as num?)?.toInt()) ?? 0,
      paidCount: ((map['paidCount'] as num?)?.toInt()) ?? 0,
      claims: rawClaims
          .map((c) => AdminClaimInfo.fromMap(
              Map<String, dynamic>.from(c as Map)))
          .toList(),
    );
  }

  /// How many winners the admin still has to transfer to.
  int get pendingCount =>
      claims.where((c) => c.queueState == AdminQueueState.pending).length;

  /// Total still owed across the pending queue.
  double get pendingAmount =>
      claims
          .where((c) => c.queueState == AdminQueueState.pending)
          .fold<double>(0, (sum, c) => sum + c.share);

  /// Winners who submitted but whose claim has since expired. Their share is
  /// forfeited — there is nothing left to transfer to them.
  int get expiredCount =>
      claims.where((c) => c.queueState == AdminQueueState.expired).length;
}

/// Result of a markLeaderboardPayout call.
class AdminMarkResult {
  final bool ok;

  /// True when the call was a no-op because the state already matched.
  final bool unchanged;
  final bool allPaid;
  final double amount;
  final String message;

  const AdminMarkResult({
    required this.ok,
    required this.unchanged,
    required this.allPaid,
    required this.amount,
    required this.message,
  });
}

/// Thrown for admin callable errors so the dashboard can render each backend
/// state distinctly. No automatic retries — the caller surfaces the message.
class AdminPayoutException implements Exception {
  final String code;
  final String message;

  const AdminPayoutException({required this.code, required this.message});

  @override
  String toString() => 'AdminPayoutException($code): $message';
}

class AdminPayoutService {
  AdminPayoutService._();
  static final AdminPayoutService instance = AdminPayoutService._();

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Reads the payment queue via the read-only `listPayoutClaims` callable.
  /// When [weekId] is null, returns recent cycles (server default).
  Future<List<AdminPayoutCycle>> listPayoutClaims({String? weekId}) async {
    try {
      final res = await _functions.httpsCallable('listPayoutClaims').call({
        if (weekId != null) 'weekId': weekId,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      final raw = (data['cycles'] as List?) ?? const [];
      return raw
          .map((c) => AdminPayoutCycle.fromMap(
              Map<String, dynamic>.from(c as Map)))
          .toList();
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(
          code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Live prize-pool figures for the current week, plus what the pool WILL be.
  ///
  /// [effectivePool] is the number that matters: the admin's fixed amount when
  /// one is set, otherwise the revenue-based figure (70% of entry sales, floored
  /// at the guaranteed minimum). There is no rollover term — each week's pool is
  /// funded only by that week's own entries or by the admin's fixed figure.
  Future<PrizePoolStatus> getPrizePoolStatus() async {
    try {
      final res = await _functions.httpsCallable('getPrizePoolStatus').call({});
      return PrizePoolStatus.fromMap(Map<String, dynamic>.from(res.data as Map));
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(
          code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Fixes the current week's prize pool to [amount] naira, REPLACING the
  /// revenue-based figure rather than adding to it.
  ///
  /// Admin-gated server-side. Refused once the week has closed, because
  /// winners' shares are already assigned from the snapshotted pool.
  Future<PrizePoolStatus> setPrizePool(int amount) async {
    try {
      final res = await _functions.httpsCallable('setPrizePool').call({
        'amount': amount,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      final ok = data['success'] == true;
      if (!ok) {
        throw AdminPayoutException(
            code: 'internal', message: (data['message'] as String?) ?? 'Failed');
      }
      return getPrizePoolStatus();
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(
          code: e.code, message: _adminErrorMessage(e));
    }
  }

/// Reverts the current week to the revenue-based pool (70% of entry sales,
/// floored at the guaranteed minimum, with no rollover). Admin-gated, same
/// current-week-only restriction.
  Future<PrizePoolStatus> clearPrizePool() async {
    try {
      final res = await _functions.httpsCallable('clearPrizePool').call({});
      final data = Map<String, dynamic>.from(res.data as Map);
      if (data['success'] != true) {
        throw AdminPayoutException(
            code: 'internal', message: (data['message'] as String?) ?? 'Failed');
      }
      return getPrizePoolStatus();
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(
          code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Records that the admin transferred the prize by hand.
  ///
  /// Call this ONLY after the money has actually left the admin's bank. It is
  /// a bookkeeping assertion, not a settlement confirmation — the app has no
  /// way to verify a manual transfer.
  ///
  /// Sends only {weekId, uid, paid, payoutReference}. No amount: the backend
  /// derives it from ranked[].share.
  Future<AdminMarkResult> markPaid({
    required String weekId,
    required String uid,
    String? payoutReference,
  }) async {
    return _mark(
      weekId: weekId,
      uid: uid,
      paid: true,
      payoutReference: payoutReference,
    );
  }

  /// Undoes a mistaken [markPaid] and returns the winner to the payment queue.
  /// The recovery path for a mis-tap — with manual payouts there is no
  /// upstream settlement to reconcile against, so this has to be simple.
  Future<AdminMarkResult> markUnpaid({
    required String weekId,
    required String uid,
  }) async {
    return _mark(weekId: weekId, uid: uid, paid: false);
  }

  Future<AdminMarkResult> _mark({
    required String weekId,
    required String uid,
    required bool paid,
    String? payoutReference,
  }) async {
    try {
      final res =
          await _functions.httpsCallable('markLeaderboardPayout').call({
        'weekId': weekId,
        'uid': uid,
        'paid': paid,
        if (payoutReference != null && payoutReference.trim().isNotEmpty)
          'payoutReference': payoutReference.trim(),
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return AdminMarkResult(
        ok: data['success'] == true,
        unchanged: data['unchanged'] == true,
        allPaid: data['allPaid'] == true,
        amount: ((data['amount'] as num?)?.toDouble()) ?? 0.0,
        message: (data['message'] as String?) ??
            (paid ? 'Recorded as sent.' : 'Mark reverted.'),
      );
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(
          code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Invokes `exportPayoutLog` and returns the CSV text. Bookkeeping fields
  /// only — never account numbers.
  Future<({int rowCount, String csv})>
      exportPayoutLog({
    String? fromWeekId,
    String? toWeekId,
  }) async {
    try {
      final res = await _functions.httpsCallable('exportPayoutLog').call({
        if (fromWeekId != null) 'fromWeekId': fromWeekId,
        if (toWeekId != null) 'toWeekId': toWeekId,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return (
        rowCount: ((data['rowCount'] as num?)?.toInt()) ?? 0,
        csv: (data['csv'] as String?) ?? '',
      );
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(
          code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Runs the advisory fraud scorer for [weekId], then the caller should reload
  /// (listPayoutClaims) to display fresh fraudScore/fraudReasons. Advisory only
  /// — scoring never marks anything paid or blocks a manual transfer.
  Future<({int scored, List<({String uid, int score, String band})> scores})>
      scoreFraudForWeek({required String weekId}) async {
    try {
      final res =
          await _functions.httpsCallable('scoreFraudForWeek').call({
        'weekId': weekId,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      final raw = (data['scores'] as List?) ?? const [];
      return (
        scored: ((data['scored'] as num?)?.toInt()) ?? 0,
        scores: raw.map((s) {
          final m = Map<String, dynamic>.from(s as Map);
          return (
            uid: (m['uid'] as String?) ?? '',
            score: ((m['score'] as num?)?.toInt()) ?? 0,
            band: (m['band'] as String?) ?? 'low',
          );
        }).toList(),
      );
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(
          code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Reuses the `listNigerianBanks` callable to map bankCode → display name.
  /// Failures return an empty map — the UI falls back to the raw code rather
  /// than failing the whole queue.
  Future<Map<String, String>> bankCodeToName() async {
    try {
      final banks = await FirestoreService.instance.listNigerianBanks();
      return {for (final b in banks) b.code: b.name};
    } catch (_) {
      return const {};
    }
  }

  /// Maps backend callable errors to clear human-readable admin messages.
  /// Every known backend state is covered; nothing is retried here.
  static String _adminErrorMessage(FirebaseFunctionsException e) {
    final msg = (e.message ?? '').trim();
    String fallback(String s) => msg.isEmpty ? s : msg;
    switch (e.code) {
      case 'permission-denied':
        return 'Not authorized. This account is not a payout admin.';
      case 'unauthenticated':
        return 'Your session expired. Sign in again and retry.';
      case 'not-found':
        return fallback('Cycle or winner not found on the server.');
      case 'failed-precondition':
        // Backend states: no claim submitted / claim expired / share invalid /
        // cycle fully paid. All mean the same thing to an admin: look again.
        return fallback('The backend refused this change. Refresh to see the '
            'current state.');
      case 'already-exists':
        return 'That change is already in progress. Refresh before retrying.';
      case 'invalid-argument':
        return fallback('Invalid request. Refresh and try again.');
      case 'unavailable':
      case 'deadline-exceeded':
      case 'internal':
        return 'Network or server error. Nothing was changed — '
            'refresh to see the current state before retrying.';
      default:
        return fallback('Request failed (${e.code}).');
    }
  }
}