// ── Admin accounts (ghosts) ────────────────────────────────────────────────
// Canonical client-side list of admin UIDs. An admin account is a GHOST: it
// never appears on any player-facing board, never occupies a rank, and is
// never counted in any cohort total.
//
// This is the SINGLE Dart source of truth. `kBoardHiddenUids`
// (FirestoreService) and `isAdminUid()` (admin payout UX) both read it, so the
// account can only ever drift in one place.
//
// Mirrors, and must stay identical to:
//   * ADMIN_UIDS in functions/index.js
//   * isPayoutAdmin() in firestore.rules
// Update all three together when the admin account rotates.
//
// UX-ONLY: this list decides what the UI SHOWS. It grants zero capability —
// every admin action is re-checked server-side by the Cloud Functions.

import 'package:firebase_auth/firebase_auth.dart';

const List<String> kAdminUids = <String>[
  'owMNkXmb6QSzO0xfHkSgMlx0zSJ3',
];

/// True when [uid] (or the current signed-in user) is an admin account.
bool isAdminUid([String? uid]) {
  final u = uid ?? FirebaseAuth.instance.currentUser?.uid;
  return u != null && kAdminUids.contains(u);
}
