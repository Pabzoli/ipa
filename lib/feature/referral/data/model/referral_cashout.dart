import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/referral_economy.dart';

/// Server-written state of a referral cashout claim.
enum ReferralCashoutClaimStatus { pending, paid, rejected }

/// One submitted referral cashout claim (`referralCashouts/{uid}`).
///
/// The owner reads their own doc; every write is a Cloud Function. Amount and
/// qualification are server-derived — nothing here is trusted to compute a
/// payout.
class ReferralCashoutClaim {
  final ReferralCashoutClaimStatus status;

  /// Server amount in naira (mirror of REFERRAL_CASHOUT_AMOUNT).
  final int amount;

  final String? accountNumber;
  final String? bankName;
  final DateTime? submittedAt;
  final DateTime? paidAt;
  final String? payoutReference;
  final String? rejectionReason;

  const ReferralCashoutClaim({
    required this.status,
    required this.amount,
    required this.accountNumber,
    required this.bankName,
    required this.submittedAt,
    required this.paidAt,
    required this.payoutReference,
    required this.rejectionReason,
  });

  factory ReferralCashoutClaim.fromMap(Map<String, dynamic> map) {
    final rawStatus = map['status'] as String?;
    return ReferralCashoutClaim(
      status: switch (rawStatus) {
        'paid' => ReferralCashoutClaimStatus.paid,
        'rejected' => ReferralCashoutClaimStatus.rejected,
        _ => ReferralCashoutClaimStatus.pending,
      },
      amount: (map['amount'] as num?)?.toInt() ?? kReferralCashoutAmountNaira,
      accountNumber: map['accountNumber'] as String?,
      bankName: map['bankName'] as String?,
      submittedAt: _toDate(map['submittedAt']),
      paidAt: _toDate(map['paidAt']),
      payoutReference: map['payoutReference'] as String?,
      rejectionReason: map['rejectionReason'] as String?,
    );
  }

  bool get isPending => status == ReferralCashoutClaimStatus.pending;
  bool get isPaid => status == ReferralCashoutClaimStatus.paid;
  bool get isRejected => status == ReferralCashoutClaimStatus.rejected;

  /// `****1234`, matching the payout page's masking.
  String get maskedAccount {
    final digits = (accountNumber ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 4) return '****';
    return '****${digits.substring(digits.length - 4)}';
  }

  static DateTime? _toDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}

/// Everything the cashout card needs: qualifying invitees plus the claim (if
/// one was already submitted). Derived counts are display-only; the server
/// re-counts at claim time.
class ReferralCashoutState {
  final int qualifiedCount;
  final ReferralCashoutClaim? claim;

  const ReferralCashoutState({
    required this.qualifiedCount,
    required this.claim,
  });

  const ReferralCashoutState.empty()
      : qualifiedCount = 0,
        claim = null;

  /// True when the player may submit a claim. The milestone is never printed
  /// on the card — only the server decides (and the Terms of Service document
  /// the exact number).
  bool get canClaim =>
      claim == null && qualifiedCount >= kReferralCashoutTarget;

  bool get hasClaim => claim != null;

  /// 0..1 bar fill. A submitted claim always shows a full bar.
  double get progress =>
      claim != null ? 1.0 : referralCashoutProgress(qualifiedCount);
}
