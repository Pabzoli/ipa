// test/admin_payout_test.dart
//
// Unit tests for Admin Payout Dashboard state derivation.
//
// These cover ONLY pure client-side logic: backend queue-state mapping and
// naira formatting. They never touch Firestore, callables, or Flutterwave,
// and they move no real money.
//
// Behavioral checklist items that REQUIRE a live backend (unauthenticated /
// non-admin rejection, real cycle listing, approval side effects) are NOT
// automated here — they must be verified manually against the deployed
// functions WITHOUT approving a real payout.

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz/features/admin/admin_payout_dashboard.dart'
    show formatNaira;
import 'package:quiz/features/admin/admin_payout_service.dart';

AdminClaimInfo _claim({
  bool paid = false,
  String? claimStatus,
  String? ledgerStatus,
  String? payoutStatus,
  double share = 700,
}) {
  return AdminClaimInfo(
    uid: 'winner-uid-1',
    rank: 1,
    username: 'Winner',
    share: share,
    paid: paid,
    claimStatus: claimStatus,
    bankCode: '044',
    maskedAccount: '****1234',
    beneficiaryName: 'Test Winner',
    resolvedNameMatch: true,
    submittedAt: DateTime.utc(2026, 9, 7, 10, 0),
    ledgerStatus: ledgerStatus,
    payoutStatus: payoutStatus,
    flutterwaveReference: '2026-09-07_winner-uid-1',
    flutterwaveTransferId: null,
    fee: null,
    approvedBy: null,
    approvedAt: null,
    completedAt: null,
    failedReason: null,
  );
}

void main() {
  group('AdminClaimInfo.queueState (backend-state derivation)', () {
    test('pending claim needs approval', () {
      final c = _claim(claimStatus: 'pending');
      expect(c.queueState, AdminQueueState.pending);
      expect(c.needsApproval, isTrue);
    });

    test('paid is authoritative even when claim was approved', () {
      final c = _claim(
        paid: true,
        claimStatus: 'approved',
        payoutStatus: 'completed',
      );
      expect(c.queueState, AdminQueueState.paid);
      expect(c.needsApproval, isFalse);
    });

    test('approved claim shows transfer-submitted, never paid', () {
      final c = _claim(
        claimStatus: 'approved',
        ledgerStatus: 'submitted',
        payoutStatus: 'submitted',
      );
      expect(c.queueState, AdminQueueState.approvedAwaiting);
      expect(c.needsApproval, isFalse);
    });

    test('failed transfer surfaces as failed', () {
      final c = _claim(
        claimStatus: 'approved',
        ledgerStatus: 'failed',
        payoutStatus: 'failed',
      );
      expect(c.queueState, AdminQueueState.failed);
      expect(c.needsApproval, isFalse);
    });

    test('reserved ledger with no transfer needs reconciliation', () {
      final c = _claim(claimStatus: 'pending', ledgerStatus: 'reserved');
      expect(c.queueState, AdminQueueState.reservedNeedsReview);
      expect(c.needsApproval, isFalse);
    });

    test('expired claim is terminal', () {
      final c = _claim(claimStatus: 'expired');
      expect(c.queueState, AdminQueueState.expired);
      expect(c.needsApproval, isFalse);
    });

    test('winner with no submission is not actionable', () {
      final c = _claim();
      expect(c.queueState, AdminQueueState.notSubmitted);
      expect(c.needsApproval, isFalse);
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
    test('pending/failed counts derive from claims', () {
      final cycle = AdminPayoutCycle(
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
        claimsApproved: 1,
        paidCount: 1,
        claims: [
          _claim(claimStatus: 'pending'),
          _claim(paid: true, claimStatus: 'approved'),
          _claim(
            claimStatus: 'approved',
            ledgerStatus: 'failed',
            payoutStatus: 'failed',
          ),
        ],
      );
      expect(cycle.pendingCount, 1);
      expect(cycle.failedCount, 1);
    });
  });
}
