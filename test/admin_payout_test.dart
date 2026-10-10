// test/admin_payout_test.dart
//
// Unit tests for Admin Payout Dashboard state derivation.
//
// These cover ONLY pure client-side logic: backend queue-state mapping and
// naira formatting. They never touch Firestore, callables, or any payment
// provider, and they move no real money.
//
// Payouts are MANUAL in this system — there is no automated transfer, so
// there is no settlement state machine to derive. What remains is the mapping
// from server fields to display state, which is what these cover.
//
// Behavioral checklist items that REQUIRE a live backend (unauthenticated /
// non-admin rejection, real cycle listing, mark-paid side effects) are NOT
// automated here — they must be verified manually against the deployed
// functions. Never mark a real claim paid while testing.

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz/features/admin/admin_payout_dashboard.dart'
    show formatNaira;
import 'package:quiz/features/admin/admin_payout_service.dart';

AdminClaimInfo _claim({
  bool paid = false,
  String? claimStatus,
  double share = 700,
  String? accountNumber = '0123456789',
  String? beneficiaryName = 'Test Winner',
}) {
  return AdminClaimInfo(
    uid: 'winner-uid-1',
    rank: 1,
    username: 'Winner',
    share: share,
    paid: paid,
    claimStatus: claimStatus,
    bankCode: '044',
    accountNumber: accountNumber,
    beneficiaryName: beneficiaryName,
    submittedAt: DateTime.utc(2026, 9, 7, 10, 0),
    markedAt: paid ? DateTime.utc(2026, 9, 8, 9, 0) : null,
    markedBy: paid ? 'admin-uid' : null,
    payoutReference: null,
    fraudScore: null,
    fraudBand: null,
    fraudReasons: const [],
    fraudScoredAt: null,
  );
}

void main() {
  group('AdminClaimInfo.queueState (backend-state derivation)', () {
    test('submitted claim needs payment', () {
      final c = _claim(claimStatus: 'pending');
      expect(c.queueState, AdminQueueState.pending);
      expect(c.needsPayment, isTrue);
    });

    test('paid is authoritative and overrides claim status', () {
      final c = _claim(paid: true, claimStatus: 'marked');
      expect(c.queueState, AdminQueueState.paid);
      expect(c.needsPayment, isFalse);
    });

    test('marked claim with paid=false is still pending payment', () {
      // Defensive: the backend sets both together. If only one ever lands,
      // ranked[].paid stays the sole authority for the Paid label.
      final c = _claim(claimStatus: 'marked');
      expect(c.queueState, AdminQueueState.pending);
      expect(c.needsPayment, isTrue);
    });

    test('expired claim is terminal and not payable', () {
      final c = _claim(claimStatus: 'expired');
      expect(c.queueState, AdminQueueState.expired);
      expect(c.needsPayment, isFalse);
    });

    test('winner with no submission is not actionable', () {
      final c = _claim();
      expect(c.queueState, AdminQueueState.notSubmitted);
      expect(c.needsPayment, isFalse);
    });

    test('unknown claim status is not actionable', () {
      final c = _claim(claimStatus: 'anonymized');
      expect(c.queueState, AdminQueueState.notSubmitted);
      expect(c.needsPayment, isFalse);
    });

    test('hasBankDetails requires both account number and name', () {
      expect(_claim(claimStatus: 'pending').hasBankDetails, isTrue);
      expect(
        _claim(claimStatus: 'pending', accountNumber: null).hasBankDetails,
        isFalse,
      );
      expect(
        _claim(claimStatus: 'pending', beneficiaryName: null).hasBankDetails,
        isFalse,
      );
    });
  });

  group('formatNaira (display only — amounts always come from server)', () {
    test('formats whole naira with separators', () {
      expect(formatNaira(700), '₦700');
      expect(formatNaira(12500), '₦12,500');
    });

    test('keeps kobo decimals when present', () {
      expect(formatNaira(1234.5), '₦1,234.50');
    });
  });

  group('AdminPayoutCycle counts', () {
    AdminPayoutCycle cycle(List<AdminClaimInfo> claims) => AdminPayoutCycle(
          weekId: '2026-09-07',
          totalCodeRevenue: 10000,
          prizePool: 7000,
          houseCut: 3000,
          guaranteedFloor: 0,
          eligibleCount: 3,
          status: 'calculated',
          calculatedAt: null,
          paidAt: null,
          notes: '',
          claimsSubmitted: 1,
          claimsMarked: 1,
          paidCount: 1,
          claims: claims,
        );

    test('pendingCount and pendingAmount drive the payment queue', () {
      final c = cycle([
        _claim(claimStatus: 'pending', share: 3500),
        _claim(paid: true, claimStatus: 'marked', share: 2800),
        _claim(claimStatus: 'expired', share: 700),
      ]);
      expect(c.pendingCount, 1);
      expect(c.pendingAmount, 3500);
      expect(c.expiredCount, 1);
    });

    test('an empty queue owes nothing', () {
      final c = cycle([_claim(paid: true, claimStatus: 'marked')]);
      expect(c.pendingCount, 0);
      expect(c.pendingAmount, 0);
    });
  });
}