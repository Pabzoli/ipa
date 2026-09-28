// lib/features/admin/admin_payout_service.dart
//
// Client wrapper for the Admin Payout Dashboard.
//
// SECURITY MODEL — read this before touching this file:
//   * The backend callable is the security boundary. Every admin callable
//     (listPayoutClaims / approveLeaderboardPayout / exportPayoutLog) enforces
//     the ADMIN_UIDS gate SERVER-SIDE (functions/index.js) and rejects
//     unauthenticated AND authenticated-non-admin callers. Nothing here can
//     bypass that.
//   * [isAdminUid] below is a UX-ONLY mirror used to decide whether to SHOW
//     the dashboard entry point. It grants zero capability: a non-admin who
//     somehow opened the dashboard would get `permission-denied` from every
//     callable and see the "Not authorized" state.
//   * This file NEVER calls Flutterwave, NEVER writes payoutLedger / payouts /
//     paid=true, and NEVER sends a transfer amount — the amount always comes
//     from the server (ranked[].share via listPayoutClaims) and approval goes
//     through the EXISTING approveLeaderboardPayout callable only.
//   * Account numbers are masked SERVER-SIDE (****last4). This file only ever
//     handles the masked form and must never log or display anything else.

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
/// No state is invented: every value maps to ranked[].paid, pendingClaim
/// status, payoutLedger status, or the latest payouts-row status returned by
/// the listPayoutClaims callable.
enum AdminQueueState {
  /// Winner never submitted payout details for this cycle.
  notSubmitted,

  /// Claim submitted, awaiting admin approval — the actionable queue.
  pending,

  /// Claim approved / transfer submitted, awaiting webhook confirmation.
  /// NOT paid — the backend transfer/webhook state is authoritative.
  approvedAwaiting,

  /// Backend says ranked[].paid == true. The ONLY "Paid" source.
  paid,

  /// Transfer definitively failed (winner stays unpaid).
  failed,

  /// Claim expired and rolled over (checkPendingClaim).
  expired,

  /// Ledger is 'reserved' with no submitted transfer — an earlier attempt
  /// timed out with an ambiguous outcome. Needs Flutterwave-dashboard
  /// reconciliation BEFORE any re-approval. Never auto-retry.
  reservedNeedsReview,
}

/// One winner's payout review data, exactly as returned by listPayoutClaims.
/// [maskedAccount] is '****1234' (or null) — full numbers never leave the
/// server.
class AdminClaimInfo {
  final String uid;
  final int rank;
  final String username;
  final double share;
  final bool paid;

  final String? claimStatus;
  final String? bankCode;
  final String? maskedAccount;
  final String? beneficiaryName;

  /// true = MATCH, false = REVIEW REQUIRED, null = UNAVAILABLE.
  /// (The backend persists only the match boolean, not the resolved name.)
  final bool? resolvedNameMatch;
  final DateTime? submittedAt;

  final String? ledgerStatus;
  final String? payoutStatus;
  final String flutterwaveReference;
  final String? flutterwaveTransferId;
  final double? fee;
  final String? approvedBy;
  final DateTime? approvedAt;
  final DateTime? completedAt;
  final String? failedReason;

  /// Phase 3 fraud advisory (server-computed, advisory only — never gates
  /// approval). Null / empty when scoreFraudForWeek has not run yet.
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
    required this.maskedAccount,
    required this.beneficiaryName,
    required this.resolvedNameMatch,
    required this.submittedAt,
    required this.ledgerStatus,
    required this.payoutStatus,
    required this.flutterwaveReference,
    required this.flutterwaveTransferId,
    required this.fee,
    required this.approvedBy,
    required this.approvedAt,
    required this.completedAt,
    required this.failedReason,
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
      maskedAccount: map['maskedAccount'] as String?,
      beneficiaryName: map['beneficiaryName'] as String?,
      resolvedNameMatch: map['resolvedNameMatch'] as bool?,
      submittedAt: parseTs(map['submittedAt']),
      ledgerStatus: map['ledgerStatus'] as String?,
      payoutStatus: map['payoutStatus'] as String?,
      flutterwaveReference:
          (map['flutterwaveReference'] as String?) ?? '',
      flutterwaveTransferId: map['flutterwaveTransferId'] as String?,
      fee: (map['fee'] as num?)?.toDouble(),
      approvedBy: map['approvedBy'] as String?,
      approvedAt: parseTs(map['approvedAt']),
      completedAt: parseTs(map['completedAt']),
      failedReason: map['failedReason'] as String?,
      fraudScore: (map['fraudScore'] as num?)?.toInt(),
      fraudBand: map['fraudBand'] as String?,
      fraudReasons: ((map['fraudReasons'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      fraudScoredAt: parseTs(map['fraudScoredAt']),
    );
  }

  /// Fraud band derived from the advisory score. Null when unscored.
  /// Display-only — approval logic must never branch on this.
  String? get fraudBandLabel {
    return switch (fraudBand) {
      'high' => 'HIGH RISK',
      'moderate' => 'MODERATE RISK',
      'low' => 'LOW RISK',
      _ => null,
    };
  }

  /// Derived display state. Paid ONLY when the backend says paid == true.
  AdminQueueState get queueState {
    if (paid) return AdminQueueState.paid;
    if (claimStatus == 'expired') return AdminQueueState.expired;
    if (payoutStatus == 'failed' || ledgerStatus == 'failed') {
      return AdminQueueState.failed;
    }
    if (claimStatus == 'approved' ||
        payoutStatus == 'submitted' ||
        payoutStatus == 'completed') {
      return AdminQueueState.approvedAwaiting;
    }
    if (ledgerStatus == 'reserved') {
      return AdminQueueState.reservedNeedsReview;
    }
    if (claimStatus == 'pending') return AdminQueueState.pending;
    return AdminQueueState.notSubmitted;
  }

  /// True only for the actionable approval queue.
  bool get needsApproval => queueState == AdminQueueState.pending;
}

/// One leaderboard cycle with its review queue.
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
  final int claimsApproved;
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
    required this.claimsApproved,
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
      claimsApproved: ((map['claimsApproved'] as num?)?.toInt()) ?? 0,
      paidCount: ((map['paidCount'] as num?)?.toInt()) ?? 0,
      claims: rawClaims
          .map((c) => AdminClaimInfo.fromMap(
              Map<String, dynamic>.from(c as Map)))
          .toList(),
    );
  }

  int get pendingCount =>
      claims.where((c) => c.queueState == AdminQueueState.pending).length;

  int get failedCount => claims
      .where((c) =>
          c.queueState == AdminQueueState.failed ||
          c.queueState == AdminQueueState.reservedNeedsReview)
      .length;
}

/// Result of an approveLeaderboardPayout call. [transferred] is intentionally
/// NOT called "paid": a successful approval means "transfer submitted /
/// awaiting Flutterwave confirmation". Paid is ONLY ever read from backend
/// state ([AdminClaimInfo.paid]).
class AdminApproveResult {
  final bool ok;
  final bool duplicate;
  final String status;
  final String message;

  const AdminApproveResult({
    required this.ok,
    required this.duplicate,
    required this.status,
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

  /// Reads the payout review queue via the read-only `listPayoutClaims`
  /// callable. When [weekId] is null, returns recent cycles (server default).
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

  /// Calls ONLY the existing `approveLeaderboardPayout` callable with the
  /// server-identifying pair {weekId, uid}. No amount is sent — the backend
  /// derives it from ranked[].share. No retry: backend rejections
  /// (already submitted / reserved / expired / not authorized / ...) are
  /// surfaced verbatim for the admin to act on manually.
  Future<AdminApproveResult> approvePayout({
    required String weekId,
    required String uid,
  }) async {
    try {
      final res =
          await _functions.httpsCallable('approveLeaderboardPayout').call({
        'weekId': weekId,
        'uid': uid,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return AdminApproveResult(
        ok: data['success'] == true,
        duplicate: data['duplicate'] == true,
        status: (data['status'] as String?) ?? '',
        message: (data['message'] as String?) ??
            'Transfer submitted. Awaiting Flutterwave confirmation.',
      );
    } on FirebaseFunctionsException catch (e) {
      throw AdminPayoutException(
          code: e.code, message: _adminErrorMessage(e));
    }
  }
  /// Invokes the EXISTING `exportPayoutLog` callable (unchanged) and returns
  /// the CSV text. Bookkeeping fields only — never account numbers.
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

  /// Runs the Phase 3 fraud scorer for [weekId] via the admin-gated
  /// `scoreFraudForWeek` callable, then the caller should reload
  /// (listPayoutClaims) to display fresh fraudScore/fraudReasons.
  /// Advisory only — scoring never approves, blocks, or moves money.
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

  /// Reuses the existing `listNigerianBanks` callable to map bankCode →
  /// display name. Failures return an empty map — the UI falls back to the
  /// raw code rather than failing the whole queue.
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
        // Backend states: already paid / already approved / expired /
        // cycle fully paid / no claim submitted / share invalid / reserved.
        return fallback('The backend refused this approval.');
      case 'already-exists':
        return 'An approval is already in progress for this winner. '
            'Wait and refresh — do not re-approve.';
      case 'invalid-argument':
        return fallback('Invalid request. Refresh and try again.');
      case 'unavailable':
      case 'deadline-exceeded':
      case 'internal':
        return 'Network or server error. Nothing was approved — '
            'refresh to see the current state before retrying.';
      default:
        return fallback('Approval failed (${e.code}).');
    }
  }
}
