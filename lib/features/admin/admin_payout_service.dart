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
//   * [isAdminUid] (re-exported below from
//     lib/core/constants/admin_accounts.dart) is a UX-ONLY mirror used to
//     decide whether to SHOW the dashboard entry point. It grants zero
//     capability: a non-admin who somehow opened the dashboard would get
//     `permission-denied` from every callable and see the "Not authorized"
//     state.
//   * [accountNumber] arrives UNMASKED, because the admin has to read it out
//     and type it into a banking app. That is the one meaningful difference
//     from a masked feed, and it is why the ADMIN_UIDS gate matters so much.
//     Never log, share, or export it.
//   * This file never sends a payout amount of its own — amounts always come
//     from the server (ranked[].share via listPayoutClaims).

import 'package:cloud_functions/cloud_functions.dart';

import '../../core/services/firestore_service.dart';

// Re-export the canonical admin list so existing importers
// (`import '.../admin_payout_service.dart'` → `isAdminUid`) keep working
// without a second, drifting copy of the UIDs.
export '../../core/constants/admin_accounts.dart';

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

  /// Silent enforcement state (auto-ban ladder), read-only.
  /// Review before paying — display only, the server does not block on it.
  final String? enforcementLevel;
  final bool payoutHold;
  final bool suspended;
  final bool leaderboardExcluded;
  final bool payoutAccountShared;
  final int? payoutAccountUidCount;

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
    required this.enforcementLevel,
    required this.payoutHold,
    required this.suspended,
    required this.leaderboardExcluded,
    required this.payoutAccountShared,
    required this.payoutAccountUidCount,
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
      enforcementLevel: map['enforcementLevel'] as String?,
      payoutHold: map['payoutHold'] == true,
      suspended: map['suspended'] == true,
      leaderboardExcluded: map['leaderboardExcluded'] == true,
      payoutAccountShared: map['payoutAccountShared'] == true,
      payoutAccountUidCount: map['payoutAccountUidCount'] != null
          ? ((map['payoutAccountUidCount'] as num?)?.toInt())
          : null,
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

  /// Enforcement hold from the silent auto-ban ladder. Display-only —
  /// the server does not block on it, so the admin must check before paying.
  bool get hasEnforcementHold => payoutHold || suspended || leaderboardExcluded;

  /// Short enforcement label for chips. Null when no hold is active.
  String? get enforcementLabel {
    if (payoutHold) return 'PAYOUT HOLD';
    if (suspended) return 'SUSPENDED';
    if (leaderboardExcluded) return 'EXCLUDED';
    return null;
  }

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
///   * [effectivePool] — what the pool WILL actually be: the fixed amount
///     when one is set, otherwise 0 (unset). Nothing funds the pool
///     automatically.
///   * [entryCodeRevenue] — leaderboard-entry sales so far this week,
///     tracked for accounting only. It does not size the pool.
///
/// There is no rollover term: expired claims are forfeited, never carried
/// forward.
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

  /// True when a fixed pool is set for the week.
  bool get isUnset => !isFixed;
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
      guaranteedFloor: ((map['guaranteedFloor'] as num?)?.toDouble()) ?? 0.0,
      eligibleCount: ((map['eligibleCount'] as num?)?.toInt()) ?? 0,
      status: map['status'] as String?,
      calculatedAt: parseTs(map['calculatedAt']),
      paidAt: parseTs(map['paidAt']),
      notes: (map['notes'] as String?) ?? '',
      claimsSubmitted: ((map['claimsSubmitted'] as num?)?.toInt()) ?? 0,
      claimsMarked: ((map['claimsMarked'] as num?)?.toInt()) ?? 0,
      paidCount: ((map['paidCount'] as num?)?.toInt()) ?? 0,
      claims: rawClaims
          .map((c) =>
              AdminClaimInfo.fromMap(Map<String, dynamic>.from(c as Map)))
          .toList(),
    );
  }

  /// How many winners the admin still has to transfer to.
  int get pendingCount =>
      claims.where((c) => c.queueState == AdminQueueState.pending).length;

  /// Total still owed across the pending queue.
  double get pendingAmount => claims
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
          .map((c) =>
              AdminPayoutCycle.fromMap(Map<String, dynamic>.from(c as Map)))
          .toList();
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Live prize-pool figures for the current week, plus what the pool WILL be.
  ///
  /// [effectivePool] is the number that matters: the fixed amount when one is
  /// set, otherwise 0 (unset). Nothing funds the pool automatically.
  Future<PrizePoolStatus> getPrizePoolStatus() async {
    try {
      final res = await _functions.httpsCallable('getPrizePoolStatus').call({});
      return PrizePoolStatus.fromMap(
          Map<String, dynamic>.from(res.data as Map));
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Fixes the current week's prize pool to [amount] naira. Until this is
  /// set, the week's pool is unset.
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
            code: 'internal',
            message: (data['message'] as String?) ?? 'Failed');
      }
      return getPrizePoolStatus();
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Removes the current week's fixed pool, leaving the pool unset until a new
  /// amount is set. Admin-gated, same current-week-only restriction.
  Future<PrizePoolStatus> clearPrizePool() async {
    try {
      final res = await _functions.httpsCallable('clearPrizePool').call({});
      final data = Map<String, dynamic>.from(res.data as Map);
      if (data['success'] != true) {
        throw AdminPayoutException(
            code: 'internal',
            message: (data['message'] as String?) ?? 'Failed');
      }
      return getPrizePoolStatus();
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
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
      final res = await _functions.httpsCallable('markLeaderboardPayout').call({
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
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Invokes `exportPayoutLog` and returns the CSV text. Bookkeeping fields
  /// only — never account numbers.
  Future<({int rowCount, String csv})> exportPayoutLog({
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
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Runs the advisory fraud scorer for [weekId], then the caller should reload
  /// (listPayoutClaims) to display fresh fraudScore/fraudReasons. Advisory only
  /// — scoring never marks anything paid or blocks a manual transfer.
  Future<({int scored, List<({String uid, int score, String band})> scores})>
      scoreFraudForWeek({required String weekId}) async {
    try {
      final res = await _functions.httpsCallable('scoreFraudForWeek').call({
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
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
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

  // ── Referral cashout queue (separate budget from the prize pool) ─────────
  //
  // The referral cashout is real money paid by hand. Its budget lives in
  // `referralCashoutReserve/ledger`, NOT in `prize_pool`, so paying a few
  // claimants at once never reduces weekly leaderboard prizes. These callables
  // are ADMIN_UIDS-gated server-side, exactly like listPayoutClaims.

  /// Loads referral cashout claims plus the separate budget state.
  ///
  /// [status] may be `pending`, `paid`, `rejected`, `anonymized` or null for
  /// all. Full bank details are returned for manual transfers — never log them.
  Future<AdminReferralCashoutSnapshot> listReferralCashouts({
    String? status,
    int limit = 200,
  }) async {
    try {
      final res =
          await _functions.httpsCallable('listReferralCashoutClaims').call({
        if (status != null) 'status': status,
        'limit': limit,
      });
      return AdminReferralCashoutSnapshot.fromMap(
        Map<String, dynamic>.from(res.data as Map),
      );
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Records a referral cashout as paid or rejected, or re-opens a mis-tap.
  ///
  /// Call this ONLY after checking your own bank transfer. The server moves the
  /// earmark (`encumbered`) into `paidTotal` or back into `available`.
  Future<void> markReferralCashout({
    required String claimId,
    required String status,
    String? payoutReference,
    String? reason,
  }) async {
    try {
      final res =
          await _functions.httpsCallable('markReferralCashoutPaid').call({
        'claimId': claimId,
        'status': status,
        if (payoutReference != null && payoutReference.trim().isNotEmpty)
          'payoutReference': payoutReference.trim(),
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      if (data['success'] != true) {
        throw AdminPayoutException(
            code: 'internal',
            message: (data['message'] as String?) ?? 'Failed');
      }
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
    }
  }

  /// Tops up the referral cashout budget. This is bookkeeping for money you
  /// have set aside — it never touches the weekly prize pool or entry sales.
  Future<AdminReferralCashoutReserve> fundReferralCashoutReserve(
    int amount, {
    String? note,
  }) async {
    try {
      final res =
          await _functions.httpsCallable('fundReferralCashoutReserve').call({
        'amount': amount,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return AdminReferralCashoutReserve.fromMap(
        Map<String, dynamic>.from((data['reserve'] as Map?) ?? const {}),
      );
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(code: e.code, message: _adminErrorMessage(e));
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

// ─── Referral cashout models ────────────────────────────────────────────────

DateTime? _parseIso(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

int _intOf(Object? value) => (value as num?)?.toInt() ?? 0;
double _doubleOf(Object? value) => (value as num?)?.toDouble() ?? 0.0;

/// The separate referral cashout budget.
///   * [available]  — funded and not yet committed. Negative means the admin
///                    needs to top up.
///   * [encumbered] — submitted claims fully earmarked, not yet paid.
///   * [paidTotal]  — already transferred.
///   * [shortfall]  — `-available` when negative, else 0.
class AdminReferralCashoutReserve {
  final double available;
  final double encumbered;
  final double paidTotal;
  final double totalFunded;
  final double shortfall;
  final DateTime? updatedAt;
  final DateTime? lastFundedAt;
  final String? lastFundedBy;

  const AdminReferralCashoutReserve({
    required this.available,
    required this.encumbered,
    required this.paidTotal,
    required this.totalFunded,
    required this.shortfall,
    required this.updatedAt,
    required this.lastFundedAt,
    required this.lastFundedBy,
  });

  const AdminReferralCashoutReserve.empty()
      : available = 0,
        encumbered = 0,
        paidTotal = 0,
        totalFunded = 0,
        shortfall = 0,
        updatedAt = null,
        lastFundedAt = null,
        lastFundedBy = null;

  factory AdminReferralCashoutReserve.fromMap(Map<String, dynamic> map) {
    return AdminReferralCashoutReserve(
      available: _doubleOf(map['available']),
      encumbered: _doubleOf(map['encumbered']),
      paidTotal: _doubleOf(map['paidTotal']),
      totalFunded: _doubleOf(map['totalFunded']),
      shortfall: _doubleOf(map['shortfall']),
      updatedAt: _parseIso(map['updatedAt']),
      lastFundedAt: _parseIso(map['lastFundedAt']),
      lastFundedBy: map['lastFundedBy'] as String?,
    );
  }

  bool get needsTopUp => shortfall > 0 || available <= 0;
}

/// One referral cashout claim as returned by `listReferralCashoutClaims`.
class AdminReferralCashoutClaim {
  final String claimId;
  final String uid;
  final String? username;
  final String? email;
  final int amount;
  final String status;
  final int qualifiedCount;
  final int inviteeCount;
  final String? accountNumber;
  final String? bankCode;
  final String? bankName;
  final String? beneficiaryName;
  final String? accountHash;
  final bool payoutAccountShared;
  final int? payoutAccountUidCount;
  final List<String> riskFlags;
  final DateTime? submittedAt;
  final DateTime? paidAt;
  final DateTime? markedAt;
  final String? markedBy;
  final String? payoutReference;
  final DateTime? rejectedAt;
  final String? rejectionReason;

  const AdminReferralCashoutClaim({
    required this.claimId,
    required this.uid,
    required this.username,
    required this.email,
    required this.amount,
    required this.status,
    required this.qualifiedCount,
    required this.inviteeCount,
    required this.accountNumber,
    required this.bankCode,
    required this.bankName,
    required this.beneficiaryName,
    required this.accountHash,
    required this.payoutAccountShared,
    required this.payoutAccountUidCount,
    required this.riskFlags,
    required this.submittedAt,
    required this.paidAt,
    required this.markedAt,
    required this.markedBy,
    required this.payoutReference,
    required this.rejectedAt,
    required this.rejectionReason,
  });

  factory AdminReferralCashoutClaim.fromMap(Map<String, dynamic> map) {
    final invitees = (map['qualifiedInvitees'] as List?) ?? const [];
    return AdminReferralCashoutClaim(
      claimId: (map['claimId'] as String?) ?? '',
      uid: (map['uid'] as String?) ?? '',
      username: map['username'] as String?,
      email: map['email'] as String?,
      amount: _intOf(map['amount']),
      status: (map['status'] as String?) ?? 'pending',
      qualifiedCount: _intOf(map['qualifiedCount']),
      inviteeCount: invitees.length,
      accountNumber: map['accountNumber'] as String?,
      bankCode: map['bankCode'] as String?,
      bankName: map['bankName'] as String?,
      beneficiaryName: map['beneficiaryName'] as String?,
      accountHash: map['accountHash'] as String?,
      payoutAccountShared: map['payoutAccountShared'] == true,
      payoutAccountUidCount: map['payoutAccountUidCount'] != null
          ? ((map['payoutAccountUidCount'] as num?)?.toInt())
          : null,
      riskFlags: ((map['riskFlags'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      submittedAt: _parseIso(map['submittedAt']),
      paidAt: _parseIso(map['paidAt']),
      markedAt: _parseIso(map['markedAt']),
      markedBy: map['markedBy'] as String?,
      payoutReference: map['payoutReference'] as String?,
      rejectedAt: _parseIso(map['rejectedAt']),
      rejectionReason: map['rejectionReason'] as String?,
    );
  }

  bool get isPending => status == 'pending';
  bool get isPaid => status == 'paid';
  bool get isRejected => status == 'rejected';

  /// `****1234` for display in lists; the payment dialog shows the full number
  /// because the admin must type it into a banking app.
  String get maskedAccount {
    final digits = (accountNumber ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 4) return '****';
    return '****${digits.substring(digits.length - 4)}';
  }
}

/// The admin referral cashout queue plus its budget.
class AdminReferralCashoutSnapshot {
  final List<AdminReferralCashoutClaim> claims;
  final AdminReferralCashoutReserve reserve;

  const AdminReferralCashoutSnapshot({
    required this.claims,
    required this.reserve,
  });

  factory AdminReferralCashoutSnapshot.fromMap(Map<String, dynamic> map) {
    final raw = (map['claims'] as List?) ?? const [];
    return AdminReferralCashoutSnapshot(
      claims: raw
          .map((c) => AdminReferralCashoutClaim.fromMap(
              Map<String, dynamic>.from(c as Map)))
          .toList(),
      reserve: AdminReferralCashoutReserve.fromMap(
        Map<String, dynamic>.from((map['reserve'] as Map?) ?? const {}),
      ),
    );
  }

  List<AdminReferralCashoutClaim> get pending =>
      claims.where((c) => c.isPending).toList();

  /// Total cash still owed across pending claims (each is fully earmarked).
  double get pendingAmount =>
      pending.fold<double>(0, (sum, c) => sum + c.amount);
}
