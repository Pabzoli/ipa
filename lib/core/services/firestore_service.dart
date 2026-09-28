import 'dart:math';
import 'package:async/async.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../features/quiz/questions.dart';
import '../../features/multiplayer/challenge_model.dart';
import 'app_update_service.dart';

// ─── Exceptions ───────────────────────────────────────────────────────────────

/// Thrown by [FirestoreService.updateAnimeCoins] when a spend would push the
/// balance below zero. Carry [required] and [available] so the UI can render
/// a precise "you need X more coins" message without doing maths itself.
class InsufficientCoinsException implements Exception {
  final int required;
  final int available;

  const InsufficientCoinsException({
    required this.required,
    required this.available,
  });

  @override
  String toString() =>
      'InsufficientCoinsException: need ${required.abs()} coins, '
      'only $available available.';
}

// ─── University Constants ─────────────────────────────────────────────────────

/// Canonical list used in signup dropdown and campus leaderboard queries.
const List<String> kNigerianUniversities = [
  'UNILAG',
  'UI (University of Ibadan)',
  'OAU',
  'FUTA',
  'UNIABUJA',
  'UNIBEN',
  'ABU Zaria',
  'UNIPORT',
  'NOUN',
  'Other',
];

// ─── Lightweight Models ───────────────────────────────────────────────────────

/// Returned by [FirestoreService.getTopUniversities].
class UniversityTotal {
  final String university;
  final int total;
  const UniversityTotal({required this.university, required this.total});
}

/// A single winner entry from a [prize_pool] document's `winners` array.
class PrizeWinner {
  final String uid;
  final String username;
  final int rank;
  final double prizeAmount;
  final String university;

  const PrizeWinner({
    required this.uid,
    required this.username,
    required this.rank,
    required this.prizeAmount,
    required this.university,
  });

  factory PrizeWinner.fromMap(Map<String, dynamic> map) => PrizeWinner(
        uid: (map['uid'] as String?) ?? '',
        username: (map['username'] as String?) ?? 'Anonymous',
        rank: ((map['rank'] as num?)?.toInt()) ?? 0,
        prizeAmount: ((map['prize'] as num?)?.toDouble()) ?? 0.0,
        university: (map['university'] as String?) ?? '',
      );
}

/// The payload returned by [FirestoreService.getLastWeekWinners].
///
/// [weekId] is the Monday date string of the completed week, e.g. "2025-05-19".
/// [winners] is sorted ascending by rank (1st → last).
class LastWeekResult {
  final String weekId;
  final double totalNaira;
  final List<PrizeWinner> winners;

  const LastWeekResult({
    required this.weekId,
    required this.totalNaira,
    required this.winners,
  });
}

// ─── Leaderboard Payout Claim Models (Phase 3 — client contract) ─────────────
// The server is authoritative for eligibility, prize amount, account
// verification, approval, payout status, and `paid`. These models only carry
// what the server returns / what the client is allowed to read.

/// A Nigerian bank entry returned by the `listNigerianBanks` callable.
///
/// CONTRACT (proposed Cloud Function — NOT yet deployed, see Phase 3 report):
/// authenticated callable, server-side Flutterwave `GET /v3/banks/NG` with the
/// existing `FLW_SECRET_KEY`, ~24h server cache, returns `{ banks: [...] }`
/// with only `{name, code}` pairs. The secret never leaves the server and the
/// client never supplies a URL/provider.
class NigerianBank {
  final String name;
  final String code;

  const NigerianBank({required this.name, required this.code});

  factory NigerianBank.fromMap(Map<String, dynamic> map) => NigerianBank(
        name: (map['name'] as String?) ?? '',
        code: (map['code'] as String?) ?? '',
      );
}

/// Success payload of the `submitPayoutDetails` callable.
///
/// [status] is `'pending'` (new submission) or `'already_submitted'`
/// (a pending claim already exists — idempotent no-op server-side).
/// [resolvedNameMatch] is the server's Flutterwave account-name check result
/// (`true`/`false`, or `null` when verification itself failed).
class PayoutClaimResult {
  final bool success;
  final String status;
  final bool? resolvedNameMatch;
  final String message;

  const PayoutClaimResult({
    required this.success,
    required this.status,
    required this.resolvedNameMatch,
    required this.message,
  });

  bool get alreadySubmitted => status == 'already_submitted';
}

/// Thrown by [FirestoreService.submitPayoutDetails] for callable errors so the
/// claim UI can map server codes (already paid / approved / not a winner /
/// invalid input / network) without parsing raw exceptions.
class PayoutClaimException implements Exception {
  final String code;
  final String message;

  const PayoutClaimException({required this.code, required this.message});

  @override
  String toString() => 'PayoutClaimException($code): $message';
}

/// One leaderboard cycle where the current user is in `ranked[]`, joined with
/// their own `pendingClaim` status (if any).
///
/// [claimStatus] is `'pending' | 'approved' | 'expired'`, or `null` when the
/// winner has never submitted for this cycle. [paid] mirrors
/// `ranked[].paid` — the ONLY source the UI may use for a "Paid" label.
class WinnerClaimSummary {
  final String weekId;
  final int rank;
  final double share;
  final bool paid;
  final String? claimStatus;

  const WinnerClaimSummary({
    required this.weekId,
    required this.rank,
    required this.share,
    required this.paid,
    required this.claimStatus,
  });

  /// True while the destination is locked server-side (submitted and neither
  /// expired nor paid out): edits must be disabled in this state.
  bool get isLocked =>
      (claimStatus == 'pending' || claimStatus == 'approved') && !paid;

  /// True when the winner can still submit (or re-submit after expiry).
  bool get canClaim =>
      !paid && (claimStatus == null || claimStatus == 'expired');
}

// ─── Firestore Service ────────────────────────────────────────────────────────

/// One picked question doc plus the mix slot it fills. [slot] is the tier
/// whose seat this doc occupies ('easy' | 'medium' | 'hard') — for tagged
/// docs this usually equals their native difficulty, but legacy or borrowed
/// docs take the slot they fill so positional modes (Gauntlet tiers) stay
/// aligned regardless of where the question came from.
class _SlottedDoc {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final String slot;
  const _SlottedDoc(this.doc, this.slot);
}

class FirestoreService {
  FirestoreService._();
  static final FirestoreService instance = FirestoreService._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? get _uid => _auth.currentUser?.uid;
  String? get currentUid => _uid;

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      _db.collection('users').doc(_uid);

  // ─── WAT date helper ──────────────────────────────────────────────────────

  /// Returns today's date in WAT (UTC+1) as 'YYYY-MM-DD'.
  static String _watDateString() {
    final wat = DateTime.now().toUtc().add(const Duration(hours: 1));
    final m = wat.month.toString().padLeft(2, '0');
    final d = wat.day.toString().padLeft(2, '0');
    return '${wat.year}-$m-$d';
  }

  // ─── Score ──────────────────────────────────────────────────────────────────

  Stream<int> scoreStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['totalScore'] as int?) ?? 0,
        );
  }

  Future<void> addToScore(int amount) async {
    if (_uid == null) return;
    await _userDoc.update({'totalScore': FieldValue.increment(amount)});
  }

  Future<void> subtractFromScore(int amount) async {
    if (_uid == null) return;
    await _userDoc.update({'totalScore': FieldValue.increment(-amount)});
  }

  // ─── Anime Coins ─────────────────────────────────────────────────────────────

  /// Live stream of the current user's [animeCoins] balance.
  Stream<int> animeCoinsStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['animeCoins'] as num?)?.toInt() ?? 0,
        );
  }

  /// Atomically adjusts [animeCoins] by [delta] (positive = earn, negative = spend)
  /// and appends an immutable entry to the [coinTransactions] subcollection.
  ///
  /// [type] must match the coinTransactions schema:
  ///   'earn_daily' | 'earn_quiz' | 'earn_ad' | 'earn_referral' |
  ///   'earn_gauntlet' | 'earn_gauntlet_milestone' | 'earn_achievement' |
  ///   'earn_quick_match' | 'earn_challenge_win' | 'earn_challenge_draw' |
  ///   'spend_hint' | 'spend_cooldown' | 'spend_unlock' |
  ///   'spend_shield' | 'spend_timer' | 'spend_retry' |
  ///   'spend_gauntlet_entry' | 'iap'
  ///
  /// Throws [InsufficientCoinsException] if the resulting balance would be < 0.
  ///
  /// ⛔ DEAD PATH — animeCoins is blacklisted for direct client writes in
  /// Firestore security rules. All coin mutations go through Cloud Functions
  /// (submitQuizAnswers, spendCoins, recordAdWatch, etc.).  Calling this
  /// method will always result in a Firestore Permission-Denied error.
  /// Kept here to surface the call site clearly; throws immediately so any
  /// accidental call fails fast and loudly.
  @Deprecated(
    'animeCoins is server-only. Use the appropriate Cloud Function instead.',
  )
  Future<void> updateAnimeCoins(int delta, String type) async {
    throw UnsupportedError(
      'updateAnimeCoins() is disabled: animeCoins is a server-only field '
      'protected by Firestore security rules. '
      'Use the spendCoins / submitQuizAnswers / recordAdWatch CF instead.',
    );
  }

  // ─── One-time migration: hintCount → animeCoins ───────────────────────────

  /// Converts any legacy [hintCount] field into [animeCoins] (× 2 exchange rate)
  /// and deletes the old field — all in a single atomic transaction.
  Future<void> runMigrationIfNeeded() async {
    if (_uid == null) return;
    try {
      await _db.runTransaction((tx) async {
        final snap = await tx.get(_userDoc);
        final data = snap.data();
        if (data == null || !data.containsKey('hintCount')) return;

        final hintCount = (data['hintCount'] as int?) ?? 0;

        final animeCoins = data.containsKey('animeCoins')
            ? (data['animeCoins'] as num?)?.toInt() ?? 0
            : hintCount * 2;

        tx.update(_userDoc, {
          'animeCoins': animeCoins,
          'hintCount': FieldValue.delete(),
        });
      });
    } catch (e) {
      debugPrint('[FirestoreService] migration error (ignored): $e');
    }
  }

  // ─── Anime Coins field patch (additive) ──────────────────────────────────

  /// Adds [animeCoins: 0] to docs that predate the field.
  /// No-ops on accounts that already have it.
  Future<void> ensureAnimeCoinField() async {
    if (_uid == null) return;
    try {
      final snap = await _userDoc.get();
      final data = snap.data();
      if (data == null) return;
      if (!data.containsKey('animeCoins')) {
        await _userDoc.update({'animeCoins': 0});
      }
    } catch (e) {
      debugPrint('[FirestoreService] ensureAnimeCoinField error (ignored): $e');
    }
  }

  // ─── Daily Ad Watched stream (P-04) ──────────────────────────────────────

  /// Live stream of how many rewarded ads the signed-in user has watched today.
  Stream<int> dailyAdWatchedStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return 0;

      final lastWatchTs = data['lastAdWatchDate'] as Timestamp?;
      if (lastWatchTs == null) return 0;

      final lastWAT =
          lastWatchTs.toDate().toUtc().add(const Duration(hours: 1));
      final nowWAT = DateTime.now().toUtc().add(const Duration(hours: 1));
      final sameDay = lastWAT.year == nowWAT.year &&
          lastWAT.month == nowWAT.month &&
          lastWAT.day == nowWAT.day;

      if (!sameDay) return 0;
      return (data['dailyAdWatched'] as int?) ?? 0;
    });
  }

  Future<void> ensureDailyAdWatchedFields() async {
    if (_uid == null) return;
    try {
      final snap = await _userDoc.get();
      final data = snap.data();
      if (data == null) return;

      final updates = <String, dynamic>{};
      if (!data.containsKey('dailyAdWatched')) {
        updates['dailyAdWatched'] = 0;
      }
      if (!data.containsKey('lastAdWatchDate')) {
        updates['lastAdWatchDate'] = null;
      }
      if (updates.isNotEmpty) await _userDoc.update(updates);
    } catch (e) {
      debugPrint(
          '[FirestoreService] ensureDailyAdWatchedFields error (ignored): $e');
    }
  }

  // ─── Premium Active stream (P-05) ────────────────────────────────────────

  /// Live stream of users/{uid}.premiumActive.
  Stream<bool> premiumActiveStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['premiumActive'] as bool?) ?? false,
        );
  }

  // ─── WP staked today fields (server-only, read-only listeners) ──────────

  Stream<int> wpStakedTodayStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['wpStakedToday'] as int?) ?? 0,
        );
  }

  Stream<String> wpStakedDateStream() {
    if (_uid == null) return Stream.value('');
    return _userDoc.snapshots().map(
          (s) => (s.data()?['wpStakedDate'] as String?) ?? '',
        );
  }

  Stream<Timestamp?> lastRivalChallengeStream() {
    if (_uid == null) return Stream.value(null);
    return _userDoc.snapshots().map(
          (s) => s.data()?['lastRivalChallenge'] as Timestamp?,
        );
  }

  Stream<String?> lastRivalUidStream() {
    if (_uid == null) return Stream.value(null);
    return _userDoc.snapshots().map(
          (s) => s.data()?['lastRivalUid'] as String?,
        );
  }

  // ─── Challenges Created Today stream ─────────────────────────────────────

  Stream<int> challengesCreatedTodayStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return 0;

      // CF writes challengesCreatedDate as a 'YYYY-MM-DD' String (WAT).
      final dateStr = data['challengesCreatedDate'] as String?;
      if (dateStr == null || dateStr != _watDateString()) return 0;
      return (data['challengesCreatedToday'] as int?) ?? 0;
    });
  }

  Future<void> ensureChallengesCreatedTodayField() async {
    if (_uid == null) return;
    try {
      final snap = await _userDoc.get();
      final data = snap.data();
      if (data == null) return;

      final updates = <String, dynamic>{};
      if (!data.containsKey('challengesCreatedToday')) {
        updates['challengesCreatedToday'] = 0;
      }
      if (!data.containsKey('challengesCreatedDate')) {
        updates['challengesCreatedDate'] = null;
      }
      if (updates.isNotEmpty) await _userDoc.update(updates);
    } catch (e) {
      debugPrint(
        '[FirestoreService] ensureChallengesCreatedTodayField error (ignored): $e',
      );
    }
  }

  // ─── Challenges Joined Today stream ──────────────────────────────────────

  /// Live stream emitting how many challenges the signed-in user has joined
  /// during the current WAT day.  Resets to 0 at the start of each new day
  /// (when [challengesJoinedDate] no longer matches today's WAT date string).
  ///
  /// Mirrors [challengesCreatedTodayStream] — the CF writes
  /// [challengesJoinedDate] as a 'YYYY-MM-DD' WAT string and increments
  /// [challengesJoinedToday] atomically on each successful join.
  Stream<int> challengesJoinedTodayStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return 0;

      // CF writes challengesJoinedDate as a 'YYYY-MM-DD' String (WAT).
      final dateStr = data['challengesJoinedDate'] as String?;
      if (dateStr == null || dateStr != _watDateString()) return 0;
      return (data['challengesJoinedToday'] as int?) ?? 0;
    });
  }

  // ─── Quick Match token streams ────────────────────────────────────────────

  Stream<int> qmTokensStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['qmTokens'] as int?) ?? 0,
        );
  }

  Stream<bool> qmAdTokenUsedStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['qmAdTokenUsed'] as bool?) ?? false,
        );
  }

  // ─── Daily Challenge ──────────────────────────────────────────────────────
  //
  // Implements the "once per WAT day, 1.5× WP multiplier" feature.
  //
  // Firestore fields on users/{uid}:
  //   dailyChallengeDate : String?  — WAT date 'YYYY-MM-DD' of last use
  //   dailyChallengeUsed : bool     — whether used on [dailyChallengeDate]
  //
  // The client writes these fields directly after a successful CF submission.
  // The actual 1.5× multiplier is applied server-side in submitQuizAnswers CF
  // when the isDailyChallenge flag is present and true.

  /// Live stream emitting `true` when the signed-in user has already consumed
  /// their Daily Challenge for today (WAT), `false` otherwise.
  ///
  /// Emits `false` when:
  ///   • [dailyChallengeDate] is absent (new account / first open).
  ///   • [dailyChallengeDate] differs from today in WAT (new day — auto-reset).
  ///   • [dailyChallengeUsed] is false.
  ///   • The user is not authenticated.
  Stream<bool> dailyChallengeUsedTodayStream() {
    if (_uid == null) return Stream.value(false);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return false;
      final dateStr = data['dailyChallengeDate'] as String?;
      if (dateStr == null) return false;
      if (dateStr != _watDateString()) return false; // new WAT day → not used
      return (data['dailyChallengeUsed'] as bool?) ?? false;
    });
  }

  /// Returns `true` if the signed-in user has NOT yet used their Daily
  /// Challenge today (WAT). Safe to call before the stream has emitted.
  ///
  /// Returns `true` for brand-new accounts and at the start of every new WAT day.
  Future<bool> isDailyChallengeAvailable() async {
    if (_uid == null) return false;
    final snap = await _userDoc.get();
    final data = snap.data();
    if (data == null) return true; // brand-new account
    final dateStr = data['dailyChallengeDate'] as String?;
    if (dateStr == null) return true;
    if (dateStr != _watDateString()) return true; // new WAT day
    return !((data['dailyChallengeUsed'] as bool?) ?? false);
  }

  /// Live stream emitting the number of cooldown-skips the signed-in user has
  /// performed during the current WAT day. Resets to 0 at WAT midnight.
  Stream<int> cooldownSkipsTodayStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return 0;
      final dateStr = data['cooldownSkipsDate'] as String?;
      if (dateStr == null || dateStr != _watDateString()) return 0;
      return (data['cooldownSkipsToday'] as int?) ?? 0;
    });
  }

  Future<void> ensureCooldownSkipsFields() async {
    if (_uid == null) return;
    try {
      final snap = await _userDoc.get();
      final data = snap.data();
      if (data == null) return;
      final updates = <String, dynamic>{};
      if (!data.containsKey('cooldownSkipsToday')) {
        updates['cooldownSkipsToday'] = 0;
      }
      if (!data.containsKey('cooldownSkipsDate')) {
        updates['cooldownSkipsDate'] = null;
      }
      if (updates.isNotEmpty) await _userDoc.update(updates);
    } catch (e) {
      debugPrint(
          '[FirestoreService] ensureCooldownSkipsFields error (ignored): $e');
    }
  }

  /// No-op — retained so callers compile without changes.
  ///
  /// Both [dailyChallengeDate] and [dailyChallengeUsed] are blacklisted from
  /// direct client writes in Firestore security rules, so the previous
  /// implementation fired a guaranteed-to-fail write on every app launch for
  /// pre-DC accounts. Those fields are now populated by the [submitQuizAnswers]
  /// CF on the user's first Daily Challenge submission. The stream already
  /// handles absent fields correctly (returns false / "not used").
  Future<void> ensureDailyChallengeFields() async {}

  // ─── Early Anime Unlock ────────────────────────────────────────────────────

  /// Unlocks [animeTitle] early by calling the `unlockAnimeEarly` Cloud
  /// Function (Section 18), which validates the title against the unlockable
  /// set, charges 500 AC transactionally, appends it to
  /// users/{uid}.unlockedAnimes, and logs a `spend_unlock` coin transaction.
  ///
  /// Returns the server payload:
  /// `{ success, alreadyUnlocked, animeTitle, newBalance[, coinsSpent] }`.
  ///
  /// Throws [FirebaseFunctionsException] with code `resource-exhausted` and
  /// message `insufficient_coins` when the balance cannot cover the cost —
  /// the caller surfaces the insufficient-coins sheet for that case.
  Future<Map<String, dynamic>> unlockAnimeEarly(String animeTitle) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('unlockAnimeEarly');
    final res = await callable.call({'animeTitle': animeTitle});
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ─── Questions ──────────────────────────────────────────────────────────────

  Future<List<AnimeQuestion>> fetchQuestions() async {
    final snap = await _db
        .collection('questions')
        .get(const GetOptions(source: Source.server));

    if (snap.docs.isEmpty) {
      throw Exception(
        'No questions found. Please check your internet connection '
        'or make sure questions have been added to Firestore.',
      );
    }

    return snap.docs.map((doc) => AnimeQuestion.fromDoc(doc)).toList();
  }

  // ─── Difficulty-aware question pools (Step 4) ─────────────────────────────
  //
  // Mix ratios:
  //   Solo (10Q):    4 Easy / 3 Medium / 3 Hard, interleaved E,M,H round-robin.
  //   Gauntlet (7Q): 3 Easy / 2 Medium / 2 Hard, positional E,E,E,M,M,H,H to
  //                  align with kGauntletTiers (15,15,15,20,20,25,25).
  //   Challenge/QM (10Q, createChallenge CF): 3 Easy / 4 Medium / 3 Hard.
  //
  // Query shape: EQUALITY-ONLY filters —
  //   .where('animeTitle', whereIn: chunk).where('difficulty', isEqualTo: tier)
  // plus a legacy fallback query (animeTitle only, client-filtered to docs
  // WITHOUT a difficulty field) used ONLY when tagged pools run short.
  // Equality-only queries need no composite index: the Step 1
  // (animeTitle ASC, difficulty ASC) composite index is NOT consumed by these
  // queries, but it is harmless and covers us if an orderBy is ever added.
  // Do NOT add orderBy to these queries without checking index requirements.
  //
  // Graceful degradation: legacy untagged docs (the pre-Step-1 pool) parse
  // as 'medium' in AnimeQuestion.fromDoc and fill shortfalls FIRST, so mixes
  // skew Medium until difficulty-tagged seeds land. Zero docs total keeps
  // throwing the original exceptions (callers already handle those).

  /// Fixed per-tier needs for a 10-question Solo session.
  static const int kSoloEasyCount = 4;
  static const int kSoloMediumCount = 3;
  static const int kSoloHardCount = 3;

  /// Fixed per-tier needs for a Gauntlet session (positional tiers).
  static const int kGauntletEasyCount = 3;
  static const int kGauntletMediumCount = 2;
  static const int kGauntletHardCount = 2;

  // ─── Seen-question marker, fetch side (Step 5a) ───────────────────────────
  //
  // Key invariant (shared with the write side in the submit CFs):
  // seen records carry the question's NATIVE difficulty — the stored
  // `difficulty` field, or 'medium' when the doc has none (legacy docs).
  // This matches AnimeQuestion.fromDoc's fallback exactly, so fetch-side
  // buckets line up with mark-time records 1:1. Legacy doc IDs therefore
  // live ONLY in `<anime>::medium` buckets, and every legacy draw (for any
  // slot) consults that same bucket. A doc marked seen never reappears in
  // any pool until its bucket is reset.
  //
  // Bucket key format: "<anime>::<difficulty>" (anime lowercased/trimmed).

  String _seenBucketKey(String anime, String difficulty) =>
      '${anime.trim().toLowerCase()}::$difficulty';

  /// Normalizes user-selected titles to the Firestore contract (lowercased /
  /// trimmed, deduped, order-preserving). Seed data (`scripts/seed_questions.js`)
  /// and seen-bucket writes are all lowercase, so every `whereIn` query must
  /// use this form — raw mixed-case titles would silently match 0 docs.
  List<String> _normalizeTitles(List<String> titles) {
    final out = <String>[];
    final seen = <String>{};
    for (final t in titles) {
      final n = t.trim().toLowerCase();
      if (n.isEmpty || seen.contains(n)) continue;
      seen.add(n);
      out.add(n);
    }
    return out;
  }

  /// Groups question docs by normalized `animeTitle` for fair dealing.
  /// Each per-anime queue is shuffled so draws within an anime stay random.
  Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _groupDocsByAnime(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final map = <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    for (final d in docs) {
      final a = ((d.data()['animeTitle'] as String?) ?? '')
          .trim()
          .toLowerCase();
      map.putIfAbsent(a, () => []).add(d);
    }
    for (final list in map.values) {
      list.shuffle(Random());
    }
    return map;
  }

  /// Loads the caller's seen-question IDs for [titles], bucketed by
  /// `{anime}::{difficulty}` keys. Returns {} when signed out. Throws on
  /// Firestore errors (notably offline with Source.server) — callers catch
  /// and degrade to full (unfiltered) pools.
  Future<Map<String, Set<String>>> _loadSeenBuckets(
    List<String> titles,
  ) async {
    final buckets = <String, Set<String>>{};
    if (_uid == null || titles.isEmpty) return buckets;
    const chunkSize = 10;
    final distinct = titles
        .toSet()
        .map((t) => t.trim().toLowerCase())
        .toList();
    for (int i = 0; i < distinct.length; i += chunkSize) {
      final chunk =
          distinct.sublist(i, (i + chunkSize).clamp(0, distinct.length));
      final snap = await _db
          .collection('users')
          .doc(_uid)
          .collection('seenQuestions')
          .where('animeTitle', whereIn: chunk)
          .get(const GetOptions(source: Source.server));
      for (final doc in snap.docs) {
        final data = doc.data();
        final a =
            ((data['animeTitle'] as String?) ?? '').trim().toLowerCase();
        var d = ((data['difficulty'] as String?) ?? 'medium')
            .trim()
            .toLowerCase();
        if (d != 'easy' && d != 'medium' && d != 'hard') d = 'medium';
        buckets.putIfAbsent('$a::$d', () => <String>{}).add(doc.id);
      }
    }
    return buckets;
  }

  /// Calls the resetSeenPool CF once per bucket key (`{anime}::{difficulty}`).
  /// No-op when signed out (no seen docs can exist) or given nothing.
  Future<void> _resetSeenBuckets(Set<String> bucketKeys) async {
    if (bucketKeys.isEmpty || _uid == null) return;
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('resetSeenPool');
    await Future.wait(bucketKeys.map((k) {
      final sep = k.lastIndexOf('::');
      return callable.call({
        'animeTitle': k.substring(0, sep),
        'difficulty': k.substring(sep + 2),
      });
    }));
  }

  /// Resets + refetches tier [tier] across [titles] when its pooled unseen
  /// falls short of [need]. Mutates [tagged] and [seen] in place.
  Future<void> _resetTierBucketIfShort({
    required List<String> titles,
    required String tier,
    required int need,
    required Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>
        tagged,
    required Map<String, Set<String>> seen,
  }) async {
    if (tagged[tier]!.length >= need) return;
    debugPrint(
      '[FirestoreService] unseen $tier pool short '
      '(${tagged[tier]!.length}/$need) — resetting buckets',
    );
    final keys = titles.toSet().map((t) => _seenBucketKey(t, tier)).toSet();
    await _resetSeenBuckets(keys);
    for (final k in keys) {
      seen.remove(k);
    }
    tagged[tier] =
        await _fetchTierPool(titles, tier, seenBuckets: seen);
  }

  /// Tagged pool for one difficulty tier across [titles] (chunked for the
  /// whereIn-10 limit), minus [seenBuckets] IDs. Returned shuffled.
  /// [titles] are normalized to lowercase/trimmed before querying so
  /// mixed-case selections still match the lowercase Firestore contract.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _fetchTierPool(
    List<String> titles,
    String difficulty, {
    Map<String, Set<String>> seenBuckets = const {},
  }) async {
    final out = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    const chunkSize = 10;
    final distinct = _normalizeTitles(titles);
    for (int i = 0; i < distinct.length; i += chunkSize) {
      final chunk =
          distinct.sublist(i, (i + chunkSize).clamp(0, distinct.length));
      final snap = await _db
          .collection('questions')
          .where('animeTitle', whereIn: chunk)
          .where('difficulty', isEqualTo: difficulty)
          .get(const GetOptions(source: Source.server));
      out.addAll(snap.docs.where((d) {
        final a = ((d.data()['animeTitle'] as String?) ?? '')
            .trim()
            .toLowerCase();
        return !(seenBuckets[_seenBucketKey(a, difficulty)]?.contains(d.id) ??
            false);
      }));
    }
    out.shuffle(Random());
    return out;
  }

  /// Legacy pool: docs for [titles] with NO difficulty field (pre-Step-1),
  /// minus IDs seen under `<anime>::medium` buckets. Fetched ONLY when tagged
  /// pools run short. Returned shuffled. [titles] are normalized before
  /// querying (see [_fetchTierPool]).
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _fetchLegacyPool(
    List<String> titles, {
    Map<String, Set<String>> seenBuckets = const {},
  }) async {
    final out = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    const chunkSize = 10;
    final distinct = _normalizeTitles(titles);
    for (int i = 0; i < distinct.length; i += chunkSize) {
      final chunk =
          distinct.sublist(i, (i + chunkSize).clamp(0, distinct.length));
      final snap = await _db
          .collection('questions')
          .where('animeTitle', whereIn: chunk)
          .get(const GetOptions(source: Source.server));
      // Explicit client-side missing-field check (not `== null`): the only
      // reliable cross-SDK way to select pre-Step-1 docs.
      out.addAll(snap.docs.where((d) {
        final data = d.data();
        final isLegacy =
            !data.containsKey('difficulty') || data['difficulty'] == null;
        if (!isLegacy) return false;
        final a = ((data['animeTitle'] as String?) ?? '')
            .trim()
            .toLowerCase();
        return !(seenBuckets[_seenBucketKey(a, 'medium')]?.contains(d.id) ??
            false);
      }));
    }
    out.shuffle(Random());
    return out;
  }

  /// Deals [slotOrder] seats from [tagged] pools (consumed in place).
  ///
  /// FAIRNESS: pools are grouped by anime and dealt round-robin across
  /// [titles] (shuffled rotation, single shared cursor), so every selected
  /// anime appears as evenly as possible. E.g. 9 titles / 10 slots → each of
  /// the 9 appears once, then the rotation wraps for the 10th. Unfilled seats backfill from [legacy] first
  /// (preferring the least-represented anime), then from tagged surpluses of
  /// any tier (same preference). Seats still empty after that are dropped
  /// (pool totally exhausted). Returned in deal order.
  List<_SlottedDoc> _dealSlots({
    required List<String> slotOrder,
    required Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>
        tagged,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> legacy,
    required List<String> titles,
  }) {
    // Per-tier per-anime queues (each queue pre-shuffled).
    final perTierAnime =
        <String, Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>>{
      for (final tier in const ['easy', 'medium', 'hard'])
        tier: _groupDocsByAnime(tagged[tier] ?? const []),
    };
    // Shuffled rotation so the first title isn't systematically favoured.
    // Fall back to whatever anime actually appear when [titles] is empty.
    final rotation = _normalizeTitles(titles);
    if (rotation.isEmpty) {
      final seenAnime = <String>{};
      for (final tierMap in perTierAnime.values) {
        for (final a in tierMap.keys) {
          if (seenAnime.add(a)) rotation.add(a);
        }
      }
      final legacyAnime = _groupDocsByAnime(legacy);
      for (final a in legacyAnime.keys) {
        if (seenAnime.add(a)) rotation.add(a);
      }
    }
    rotation.shuffle(Random());

    final picksPerAnime = <String, int>{for (final t in rotation) t: 0};
    int _picks(String anime) => picksPerAnime[anime] ?? 0;

    final filled = <_SlottedDoc>[];
    final unfilled = <String>[];
    // Single shared round-robin cursor into [rotation] across ALL slots.
    // This is what guarantees coverage: 9 titles / 10 slots → each title
    // picked once, then the rotation wraps for the 10th. A per-tier cursor
    // would restart at rotation[0] for every tier and re-pick the same
    // first anime for Easy, Medium and Hard.
    var cursor = 0;

    String? _nextAnimeForTier(String tier) {
      if (rotation.isEmpty) return null;
      final queues = perTierAnime[tier]!;
      for (int offset = 0; offset < rotation.length; offset++) {
        final idx = (cursor + offset) % rotation.length;
        final anime = rotation[idx];
        if ((queues[anime]?.isNotEmpty ?? false)) {
          cursor = (idx + 1) % rotation.length;
          return anime;
        }
      }
      return null;
    }

    for (final slot in slotOrder) {
      final anime = _nextAnimeForTier(slot);
      if (anime != null) {
        final doc = perTierAnime[slot]![anime]!.removeLast();
        filled.add(_SlottedDoc(doc, slot));
        picksPerAnime[anime] = _picks(anime) + 1;
      } else {
        unfilled.add(slot);
      }
    }

    // Legacy backfill: prefer the least-represented anime that still has a
    // legacy doc, tie-broken by rotation order for determinism.
    final legacyByAnime = _groupDocsByAnime(legacy);
    int _rotationIndex(String anime) {
      final i = rotation.indexOf(anime);
      return i < 0 ? 1 << 30 : i;
    }

    final stillUnfilled = <String>[];
    for (final slot in unfilled) {
      String? best;
      var bestPicks = 1 << 30;
      var bestOrder = 1 << 30;
      for (final entry in legacyByAnime.entries) {
        if (entry.value.isEmpty) continue;
        final p = _picks(entry.key);
        final o = _rotationIndex(entry.key);
        if (p < bestPicks || (p == bestPicks && o < bestOrder)) {
          best = entry.key;
          bestPicks = p;
          bestOrder = o;
        }
      }
      if (best != null) {
        final doc = legacyByAnime[best]!.removeLast();
        filled.add(_SlottedDoc(doc, slot));
        picksPerAnime[best] = _picks(best) + 1;
      } else {
        stillUnfilled.add(slot);
      }
    }

    // Cross-tier borrow: same least-represented preference, but drawn from
    // any tagged surplus (tiers tried in E,M,H order within the chosen anime
    // for determinism).
    for (final slot in stillUnfilled) {
      String? best;
      var bestPicks = 1 << 30;
      var bestOrder = 1 << 30;
      for (final anime in rotation) {
        var hasAny = false;
        for (final tier in const ['easy', 'medium', 'hard']) {
          if ((perTierAnime[tier]![anime]?.isNotEmpty ?? false)) {
            hasAny = true;
            break;
          }
        }
        if (!hasAny) {
          // Also consider anime that only appear in docs but weren't in the
          // original title list (defensive: casing drift / legacy rows).
          continue;
        }
        final p = _picks(anime);
        final o = _rotationIndex(anime);
        if (p < bestPicks || (p == bestPicks && o < bestOrder)) {
          best = anime;
          bestPicks = p;
          bestOrder = o;
        }
      }
      // Defensive fallback: any surplus from any anime (covers docs whose
      // anime key wasn't in [rotation]).
      QueryDocumentSnapshot<Map<String, dynamic>>? borrowed;
      String? borrowedFrom;
      if (best != null) {
        for (final tier in const ['easy', 'medium', 'hard']) {
          final q = perTierAnime[tier]![best];
          if (q != null && q.isNotEmpty) {
            borrowed = q.removeLast();
            borrowedFrom = best;
            break;
          }
        }
      }
      if (borrowed == null) {
        for (final tier in const ['easy', 'medium', 'hard']) {
          final queues = perTierAnime[tier]!;
          for (final entry in queues.entries) {
            if (entry.value.isNotEmpty) {
              borrowed = entry.value.removeLast();
              borrowedFrom = entry.key;
              break;
            }
          }
          if (borrowed != null) break;
        }
      }
      if (borrowed != null) {
        filled.add(_SlottedDoc(borrowed, slot));
        if (borrowedFrom != null) {
          picksPerAnime[borrowedFrom] = _picks(borrowedFrom) + 1;
        }
      }
      // Else: seat dropped — the whole pool (tagged + legacy) is exhausted.
    }
    // Restore deal order (backfills were appended out of order): bucket
    // picks by slot tier, then walk the original slotOrder dealing one pick
    // per seat. Seats dropped as unfillable are simply skipped.
    final buckets = <String, List<_SlottedDoc>>{
      'easy': [],
      'medium': [],
      'hard': [],
    };
    for (final s in filled) {
      buckets[s.slot]!.add(s);
    }
    final out = <_SlottedDoc>[];
    final cursors = <String, int>{'easy': 0, 'medium': 0, 'hard': 0};
    for (final slot in slotOrder) {
      final i = cursors[slot]!;
      if (i < buckets[slot]!.length) {
        out.add(buckets[slot]![i]);
        cursors[slot] = i + 1;
      }
    }
    return out;
  }

  Future<List<AnimeQuestion>> fetchQuestionsForTitles(
      List<String> titles) async {
    final normalized = _normalizeTitles(titles);
    if (normalized.isEmpty) {
      throw Exception('No anime titles provided.');
    }

    // Phase 0: seen buckets ({} on signed-out/offline → full pools).
    Map<String, Set<String>> seen = {};
    try {
      seen = await _loadSeenBuckets(normalized);
    } catch (e) {
      debugPrint(
          '[FirestoreService] seen-buckets load failed, using full pools: $e');
      seen = {};
    }

    // Phase 1: tagged tier pools, unseen-filtered (3 equality-only queries,
    // 1 chunk each at ≤10 titles), with per-tier reset+refetch on shortfall.
    // Legacy pool is fetched ONLY on shortfall (Phase 2).
    final tagged = <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{
      'easy': await _fetchTierPool(normalized, 'easy', seenBuckets: seen),
      'medium': await _fetchTierPool(normalized, 'medium', seenBuckets: seen),
      'hard': await _fetchTierPool(normalized, 'hard', seenBuckets: seen),
    };
    const need = kSoloEasyCount + kSoloMediumCount + kSoloHardCount;
    await _resetTierBucketIfShort(
        titles: normalized, tier: 'easy', need: kSoloEasyCount,
        tagged: tagged, seen: seen);
    await _resetTierBucketIfShort(
        titles: normalized, tier: 'medium', need: kSoloMediumCount,
        tagged: tagged, seen: seen);
    await _resetTierBucketIfShort(
        titles: normalized, tier: 'hard', need: kSoloHardCount,
        tagged: tagged, seen: seen);

    // Interleaved deal order: E,M,H round-robin (starts easy, ends easy).
    final slotOrder = <String>[
      for (int i = 0;
          i <
              [kSoloEasyCount, kSoloMediumCount, kSoloHardCount]
                  .reduce((a, b) => a > b ? a : b);
          i++) ...[
        if (i < kSoloEasyCount) 'easy',
        if (i < kSoloMediumCount) 'medium',
        if (i < kSoloHardCount) 'hard',
      ],
    ];

    // Phase 2: legacy pool, unseen-filtered — fetched ONLY when tagged
    // unseen runs short (preserves the Step 4 steady-state query cost).
    final taggedHave = tagged.values.fold<int>(0, (n, p) => n + p.length);
    var legacy = taggedHave < need
        ? await _fetchLegacyPool(normalized, seenBuckets: seen)
        : <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    if (taggedHave + legacy.length < need) {
      // Whole unseen pool (tagged + legacy) exhausted: reset the medium
      // buckets (legacy source of truth lives there) and refetch legacy
      // unfiltered. Tagged tiers were already reset individually above.
      final mKeys =
          normalized.map((t) => _seenBucketKey(t, 'medium')).toSet();
      debugPrint(
        '[FirestoreService] total unseen pool short '
        '(${taggedHave + legacy.length}/$need) — resetting medium buckets',
      );
      await _resetSeenBuckets(mKeys);
      for (final k in mKeys) {
        seen.remove(k);
      }
      legacy = await _fetchLegacyPool(normalized, seenBuckets: seen);
    }

    final dealt = _dealSlots(
        slotOrder: slotOrder,
        tagged: tagged,
        legacy: legacy,
        titles: normalized);

    if (dealt.isEmpty) {
      throw Exception(
        'No questions found for the selected anime. '
        'More content is coming soon!',
      );
    }
    // Deal count is fixed at [need]; short pools return fewer (graceful —
    // QuizController plays whatever it receives).
    return dealt.map((s) => AnimeQuestion.fromDoc(s.doc)).toList();
  }

  // ─── Anime Titles ────────────────────────────────────────────────────────────

  Future<List<String>> fetchAnimeTitles() async {
    try {
      final snap = await _db
          .collection('questions')
          .get(const GetOptions(source: Source.server));

      if (snap.docs.isEmpty) return [];

      final titles = snap.docs
          .map((d) => (d.data()['animeTitle'] as String?) ?? '')
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

      return titles;
    } catch (e) {
      throw Exception('Failed to load anime list: $e');
    }
  }

  /// Daily Gauntlet — picks [count] (normally 7) question ids from the
  /// player's unlocked anime pool with a 3:2:2 Easy:Medium:Hard mix.
  /// Returned in POSITIONAL order E,E,E,M,M,H,H — the submitDailyGauntlet CF
  /// awards its escalating WP tiers by position, so callers must preserve it.
  ///
  /// Shortfalls backfill from the legacy untagged pool first (parses as
  /// medium client-side), then from tagged surpluses of any tier. Throws
  /// when the whole pool (tagged + legacy) holds fewer than [count], exactly
  /// like the old implementation — a short Gauntlet would misalign WP tiers.
  ///
  /// `whereIn` accepts at most 10 values per query, so titles are chunked.
  Future<List<String>> fetchGauntletQuestionIds({
    required List<String> unlockedTitles,
    required int count,
  }) async {
    final titles = _normalizeTitles(unlockedTitles);
    if (titles.isEmpty) {
      throw Exception('No unlocked anime titles for the Daily Gauntlet.');
    }
    if (count <= 0) return [];

    // 3:2:2 ratio scaled to [count] (for 7 → exactly 3/2/2).
    final easyNeed = (count * 3 / 7).round();
    final mediumNeed = (count * 2 / 7).round();
    final hardNeed = count - easyNeed - mediumNeed;

    // Phase 0: seen buckets ({} on signed-out/offline → full pools).
    Map<String, Set<String>> seen = {};
    try {
      seen = await _loadSeenBuckets(titles);
    } catch (e) {
      debugPrint(
          '[FirestoreService] seen-buckets load failed, using full pools: $e');
      seen = {};
    }

    final tagged = <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{
      'easy':
          await _fetchTierPool(titles, 'easy', seenBuckets: seen),
      'medium':
          await _fetchTierPool(titles, 'medium', seenBuckets: seen),
      'hard':
          await _fetchTierPool(titles, 'hard', seenBuckets: seen),
    };
    await _resetTierBucketIfShort(
        titles: titles, tier: 'easy', need: easyNeed,
        tagged: tagged, seen: seen);
    await _resetTierBucketIfShort(
        titles: titles, tier: 'medium', need: mediumNeed,
        tagged: tagged, seen: seen);
    await _resetTierBucketIfShort(
        titles: titles, tier: 'hard', need: hardNeed,
        tagged: tagged, seen: seen);

    // Positional deal order: E,E,E,M,M,H,H (matches kGauntletTiers).
    final slotOrder = <String>[
      for (int i = 0; i < easyNeed; i++) 'easy',
      for (int i = 0; i < mediumNeed; i++) 'medium',
      for (int i = 0; i < hardNeed; i++) 'hard',
    ];

    // Legacy pool, unseen-filtered — fetched ONLY when tagged unseen runs
    // short. Whole-pool exhaustion resets the medium buckets (legacy source
    // of truth) and refetches unfiltered.
    final taggedHave = tagged.values.fold<int>(0, (n, p) => n + p.length);
    var legacy = taggedHave < count
        ? await _fetchLegacyPool(titles, seenBuckets: seen)
        : <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    if (taggedHave + legacy.length < count) {
      final mKeys =
          titles.map((t) => _seenBucketKey(t, 'medium')).toSet();
      debugPrint(
        '[FirestoreService] gauntlet unseen pool short '
        '(${taggedHave + legacy.length}/$count) — resetting medium buckets',
      );
      await _resetSeenBuckets(mKeys);
      for (final k in mKeys) {
        seen.remove(k);
      }
      legacy = await _fetchLegacyPool(titles, seenBuckets: seen);
    }

    final dealt = _dealSlots(
        slotOrder: slotOrder, tagged: tagged, legacy: legacy, titles: titles);

    if (dealt.length < count) {
      throw Exception(
          'Not enough questions in your unlocked pool for the Daily Gauntlet.');
    }

    return dealt.take(count).map((s) => s.doc.id).toList();
  }

  // ─── Stats ──────────────────────────────────────────────────────────────────

  Future<void> updateStats(Map<String, dynamic> stats) async {
    if (_uid == null) return;
    await _userDoc.set({'stats': stats}, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>> loadUserStats() async {
    if (_uid == null) return {};
    final doc = await _userDoc.get();
    return (doc.data()?['stats'] as Map<String, dynamic>?) ?? {};
  }

  /// Server-authoritative achievement source. Emits the live `stats` object and
  /// the `achievementsGranted` map from users/{uid} so the Achievements tab
  /// reflects exactly what the backend (Stage 13) has recorded, instead of
  /// recomputing from match history client-side. Emits a map of the shape:
  ///   { 'stats': &amp;lt;Map&amp;lt;String,num&amp;gt;&amp;gt;, 'achievementsGranted': &amp;lt;Map&amp;lt;String,List&amp;lt;num&amp;gt;&amp;gt;&amp;gt; }
  Stream<Map<String, dynamic>> achievementsStream() {
    if (_uid == null) return Stream.value(const {});
    return _userDoc.snapshots().map((snap) {
      final d = snap.data() ?? <String, dynamic>{};
      return <String, dynamic>{
        'stats': (d['stats'] as Map<String, dynamic>?) ?? const {},
        'achievementsGranted':
            (d['achievementsGranted'] as Map<String, dynamic>?) ?? const {},
      };
    });
  }

  /// Daily Gauntlet progress for the home entry card: current streak, the
  /// milestone days already claimed this streak run, whether the free
  /// daily attempt has been used, and the per-day retry cursor.
  /// Live so the card stays accurate after a run. Retry fields mirror the
  /// server's GAUNTLET_RETRY_* logic (functions/index.js) client-side for
  /// display only — backend remains authoritative.
  Stream<Map<String, dynamic>> gauntletProgressStream() {
    if (_uid == null) return Stream.value(const {});
    return _userDoc.snapshots().map((snap) {
      final d = snap.data() ?? <String, dynamic>{};

      // Mirror the server's isFreeAttempt logic (functions/index.js):
      // isFreeAttempt = (storedDate !== todayWAT || !storedUsed)
      // So usedToday is true ONLY when the stored date matches today's
      // WAT date AND the flag is set. Without the date check, a flag
      // left from yesterday would falsely show "used" today.
      final storedUsed = d['dailyChallengeUsed'] == true;
      final storedDate = (d['dailyChallengeDate'] as String?) ?? '';
      final todayWAT = _watDateString();
      final usedToday = storedUsed && storedDate == todayWAT;

      final retryDate = (d['gauntletRetryDate'] as String?) ?? '';
      final storedIdx = (d['gauntletRetryIndex'] as num?)?.toInt() ?? 0;
      // Effective index resets at WAT midnight, same as server.
      final retryIndex = retryDate == todayWAT ? storedIdx : 0;

      return <String, dynamic>{
        'streak': (d['gauntletStreak'] as num?)?.toInt() ?? 0,
        'milestones': (d['gauntletMilestonesAwarded'] as List?)?.cast<int>() ??
            const <int>[],
        'usedToday': usedToday,
        'retryIndex': retryIndex,
        'retryDate': retryDate,
        'premiumActive': (d['premiumActive'] as bool?) ?? false,
      };
    });
  }

  /// Pre-entry Gauntlet payment — deducts the retry cost BEFORE the player
  /// enters the quiz page (non-refundable on quit, per product decision).
  ///
  /// Calls the `enterDailyGauntlet` Cloud Function which atomically:
  /// - returns `{isFreeAttempt: true, retryCost: 0, ticketId: null}` for the
  ///   free daily attempt (no deduction, index untouched), or
  /// - deducts `retryCost`, advances `gauntletRetryIndex`, logs a
  ///   `spend_gauntlet_entry` transaction, and mints a single-use ticket
  ///   `{isFreeAttempt: false, retryCost, ticketId}` for paid retries.
  ///
  /// The returned `ticketId` (null for free) must be forwarded through
  /// QuestionsPage → QuizController → submitDailyGauntlet, which consumes it
  /// WITHOUT charging again. Throws [FirebaseFunctionsException] with
  /// `resource-exhausted/insufficient_coins:<cost>` when unaffordable and
  /// `failed-precondition/max_retries_exceeded` at the daily cap.
  Future<Map<String, dynamic>> enterDailyGauntlet() async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('enterDailyGauntlet');
    final res = await callable.call<Map<Object?, Object?>>({});
    return Map<String, dynamic>.from(res.data);
  }

  // ─── Match History ───────────────────────────────────────────────────────────
  //
  // Match documents are written exclusively by Cloud Functions via the admin
  // SDK (_resolveChallengeCore, submitQuickMatchResult); firestore.rules sets
  // `allow create: if false` on users/{uid}/matches. An earlier client-side
  // `saveMatchHistory` writer lived here and was removed: it was unreachable,
  // would have been rejected by those rules, and — had it ever run — would have
  // written an Anime Coins value into `pointsChange` with no `wpChange` at all,
  // which the History ledger then had to guess a WP figure from.
  Stream<List<Map<String, dynamic>>> matchHistoryStream() {
    if (_uid == null) return Stream.value([]);
    return _userDoc
        .collection('matches')
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => {...doc.data(), 'id': doc.id}).toList());
  }

  // ─── Leaderboard ────────────────────────────────────────────────────────────

  Stream<List<Map<String, dynamic>>> leaderboardStream() {
    return _db
        .collection('users')
        .orderBy('totalScore', descending: true)
        .limit(100)
        .snapshots()
        .map((snap) {
      return snap.docs.asMap().entries.map((entry) {
        final data = entry.value.data();
        return {
          'rank': entry.key + 1,
          'uid': entry.value.id,
          'username': (data['username'] as String?) ?? 'Anonymous',
          'totalScore': (data['totalScore'] as int?) ?? 0,
          'isCurrentUser': entry.value.id == _uid,
        };
      }).toList();
    });
  }

  Future<int> getCurrentUserRank() async {
    if (_uid == null) return -1;
    final myDoc = await _userDoc.get();
    final myScore = (myDoc.data()?['totalScore'] as int?) ?? 0;

    final above = await _db
        .collection('users')
        .where('totalScore', isGreaterThan: myScore)
        .count()
        .get();

    return (above.count ?? 0) + 1;
  }

  /// Returns the current user's rank on the **paid weekly board** (1-based),
  /// counting only users who entered the same week ([entryWeekId]).
  ///
  /// Returns `0` when the user is unauthenticated, not currently eligible,
  /// or has no weekly points yet. Pass the viewer's own entry week and
  /// eligibility from [UserDataProvider]; unfiltered counting is no longer
  /// permitted by the `users` read rule.
  ///
  /// Requires the `(leaderboardEntryWeekId ASC, weeklyPoints DESC)`
  /// composite index (firestore.indexes.json).
  Future<int> getCurrentUserWeeklyRank({
    String? entryWeekId,
    bool eligible = false,
  }) async {
    if (_uid == null) return 0;
    if (!eligible || (entryWeekId ?? '').isEmpty) return 0;
    final myDoc = await _userDoc.get();
    final myPts = (myDoc.data()?['weeklyPoints'] as int?) ?? 0;

    // Not on the weekly board yet.
    if (myPts == 0) return 0;

    final above = await _db
        .collection('users')
        .where('leaderboardEntryWeekId', isEqualTo: entryWeekId)
        .where('weeklyPoints', isGreaterThan: myPts)
        .count()
        .get();

    return (above.count ?? 0) + 1;
  }

  // ─── Weekly Points ───────────────────────────────────────────────────────────

  Stream<int> weeklyPointsStream() {
    if (_uid == null) return Stream.value(0);
    return _userDoc.snapshots().map(
          (s) => (s.data()?['weeklyPoints'] as int?) ?? 0,
        );
  }

  /// ⛔ DEAD PATH — weeklyPoints is blacklisted for direct client writes in
  /// Firestore security rules. All WP awards are made server-side by
  /// submitQuizAnswers, submitQuickMatchResult, and resolveChallengeOutcome CFs.
  @Deprecated(
    'weeklyPoints is server-only. Awarded by Cloud Functions only.',
  )
  Future<void> addWeeklyPoints(int amount) async {
    throw UnsupportedError(
      'addWeeklyPoints() is disabled: weeklyPoints is a server-only field '
      'protected by Firestore security rules. '
      'It is awarded automatically by the submitQuizAnswers and '
      'resolveChallengeOutcome Cloud Functions.',
    );
  }

  /// Global weekly board — UNFILTERED (all users, top 100).
  ///
  /// Admin-only in practice: under the `users` read rule only the payout
  /// admin can evaluate this query (any other caller gets permission-denied
  /// because unreadable docs would be in the result set). The Rankings page
  /// uses this solely for the admin account; normal players use
  /// [eligibleWeeklyLeaderboardStream].
  ///
  /// Broadcast: tab switches and stream swaps re-listen across rebuilds, and
  /// a second listener on a single-subscription stream throws. The hidden
  /// admin account (see [kBoardHiddenUids]) is filtered before rank mapping.
  Stream<List<Map<String, dynamic>>> weeklyLeaderboardStream() {
    return _db
        .collection('users')
        .orderBy('weeklyPoints', descending: true)
        .limit(100)
        .snapshots()
        .map(_mapBoardEntries)
        .asBroadcastStream();
  }

  /// Empty board stream that survives tab disposal/remount cycles.
  ///
  /// NEVER share a `Stream.value([])` instance across StreamBuilders:
  /// single-subscription streams throw "already been listened to" on the
  /// second listen even after the first subscription was cancelled (exactly
  /// what tab switches do). `Stream.multi` invokes its callback per
  /// listener, so every subscription — first or fifth — gets `[]` + done.
  Stream<List<Map<String, dynamic>>> emptyBoardStream() =>
      Stream<List<Map<String, dynamic>>>.multi((c) {
        c.add(<Map<String, dynamic>>[]);
        c.close();
      });

  /// Cohort board for normal players: only users who entered the SAME
  /// leaderboard week ([entryWeekId]).
  ///
  /// Matches the `users` read rule exactly — every returned doc is one the
  /// caller may read, so the query never fails wholesale. For a current-week
  /// payer this IS the live paid board. Pass the viewer's own entry week;
  /// an empty week emits `[]` with no query (a non-entrant may read nobody
  /// but themselves, and the page merges their own doc client-side).
  ///
  /// Requires the `(leaderboardEntryWeekId ASC, weeklyPoints DESC)`
  /// composite index (firestore.indexes.json).
  Stream<List<Map<String, dynamic>>> eligibleWeeklyLeaderboardStream(
    String entryWeekId,
  ) {
    if (entryWeekId.isEmpty) return emptyBoardStream();
    return _db
        .collection('users')
        .where('leaderboardEntryWeekId', isEqualTo: entryWeekId)
        .orderBy('weeklyPoints', descending: true)
        .limit(100)
        .snapshots()
        .map(_mapBoardEntries)
        .asBroadcastStream();
  }

  /// Accounts that must NEVER appear on player-visible boards: invisible to
  /// all players and rank-free (skipped before rank assignment, so they
  /// occupy no rank slot and shift nobody).
  ///
  /// Mirror of ADMIN_UIDS (functions/index.js) and kAdminUids
  /// (lib/features/admin/admin_payout_service.dart). Deliberately enforced
  /// client-side rather than in Firestore rules: denying the doc server-side
  /// would make EVERY cohort query containing it fail wholesale for all
  /// players, and `!=` exclusion filters are incompatible with the
  /// weeklyPoints ordering/counts the boards need.
  static const List<String> kBoardHiddenUids = <String>[
    'owMNkXmb6QSzO0xfHkSgMlx0zSJ3',
  ];

  List<Map<String, dynamic>> _mapBoardEntries(
    QuerySnapshot<Map<String, dynamic>> snap,
  ) {
    final weekId = FirestoreService.currentWeekId();
    var eRank = 0;
    final out = <Map<String, dynamic>>[];
    for (final entry in snap.docs) {
      if (kBoardHiddenUids.contains(entry.id)) continue;
      final data = entry.data();
      final eligible = data['leaderboardEntryWeekId'] == weekId;
      out.add({
        'rank': eligible ? ++eRank : null,
        'uid': entry.id,
        'username': (data['username'] as String?) ?? 'Anonymous',
        'university': (data['university'] as String?) ?? '',
        'weeklyPoints': (data['weeklyPoints'] as int?) ?? 0,
        'isCurrentUser': entry.id == _uid,
        'leaderboardEntryWeekId': data['leaderboardEntryWeekId'] as String?,
      });
    }
    return out;
  }

  // ─── Leaderboard entry eligibility (leaderboard_entry codes) ────────────────

  /// Live stream of users/{uid}.leaderboardEntryWeekId — the week ID the user
  /// has paid for. Compared against [currentWeekId] for current eligibility
  /// (Decision D: the field is intentionally left stale, not cleared, after
  /// each weekly reset).
  Stream<String?> leaderboardEntryStream() {
    if (_uid == null) return Stream.value(null);
    return _userDoc.snapshots().map(
          (s) => s.data()?['leaderboardEntryWeekId'] as String?,
        );
  }

  // ─── Weekly Player Count (Stage 19 — percentile display) ──────────────────

  /// Cached result of [getWeeklyPlayerCount], keyed by entry week.
  static int? _weeklyPlayerCountCache;
  static DateTime? _weeklyPlayerCountCacheTime;
  static String? _weeklyPlayerCountCacheWeek;

  /// Returns the number of users who entered the leaderboard for
  /// [entryWeekId] (i.e. the paid board size the caller may see).
  ///
  /// Uses a Firestore COUNT aggregation on the cohort equality filter — no
  /// documents are downloaded, and the query satisfies the `users` read
  /// rule (single-field equality needs no composite index). Pass the
  /// viewer's own entry week; an empty week returns the cache (or 0).
  /// The result is cached in a static variable for up to 5 minutes per week.
  Future<int> getWeeklyPlayerCount({String entryWeekId = ''}) async {
    final now = DateTime.now();
    if (_weeklyPlayerCountCache != null &&
        _weeklyPlayerCountCacheTime != null &&
        _weeklyPlayerCountCacheWeek == entryWeekId &&
        now.difference(_weeklyPlayerCountCacheTime!).inMinutes < 5) {
      return _weeklyPlayerCountCache!;
    }

    if (entryWeekId.isEmpty) return _weeklyPlayerCountCache ?? 0;

    try {
      final snap = await _db
          .collection('users')
          .where('leaderboardEntryWeekId', isEqualTo: entryWeekId)
          .count()
          .get();

      final count = snap.count ?? 0;
      _weeklyPlayerCountCache = count;
      _weeklyPlayerCountCacheTime = now;
      _weeklyPlayerCountCacheWeek = entryWeekId;
      return count;
    } catch (e) {
      debugPrint('[FirestoreService] getWeeklyPlayerCount error: $e');
      // Return cache even if stale rather than surfacing an error to the UI.
      return _weeklyPlayerCountCache ?? 0;
    }
  }

  /// Returns the leaderboard entry for the user ranked exactly one position
  /// above the current user — their "Rival" — or `null` if:
  ///   • the user is not authenticated
  ///   • the user has 0 weeklyPoints (not on the board yet)
  ///   • the user is already rank 1
  ///   • the user is outside the visible top-100 window
  ///
  /// Implementation notes:
  ///   1. A COUNT aggregation cheaply tells us how many users have strictly
  ///      more weeklyPoints than the current user (`countAbove`).
  ///   2. The rival sits at position `countAbove` in the desc-ordered list,
  ///      so we fetch exactly `countAbove` docs and take the last one.
  ///   3. We cap at 99 — a user outside the top-100 leaderboard widget has
  ///      no visible rival row to tap, so there is nothing to tag.
  Future<Map<String, dynamic>?> getRivalForUser() async {
    if (_uid == null) return null;

    // 1. Read current user's weekly points.
    final mySnap = await _userDoc.get();
    final myPts = (mySnap.data()?['weeklyPoints'] as int?) ?? 0;

    // Not on the board yet.
    if (myPts == 0) return null;

    // 2. Count users with strictly higher points.
    final countSnap = await _db
        .collection('users')
        .where('weeklyPoints', isGreaterThan: myPts)
        .count()
        .get();

    final countAbove = countSnap.count ?? 0;

    // Already rank 1 — no one to rival.
    if (countAbove == 0) return null;

    // Outside the visible top-100 — no rival shown in the leaderboard widget.
    if (countAbove >= 100) return null;

    // 3. Fetch the top `countAbove` users; the last document is the rival
    //    (the person ranked immediately above the current user).
    final snap = await _db
        .collection('users')
        .orderBy('weeklyPoints', descending: true)
        .limit(countAbove)
        .get();

    if (snap.docs.isEmpty) return null;

    final rivalDoc = snap.docs.last;
    final rivalData = rivalDoc.data();

    return {
      'uid': rivalDoc.id,
      'username': (rivalData['username'] as String?) ?? 'Anonymous',
      'university': (rivalData['university'] as String?) ?? '',
      'weeklyPoints': (rivalData['weeklyPoints'] as int?) ?? 0,
      'rank': countAbove, // their rank equals countAbove
    };
  }

  // ─── Campus Leaderboard ──────────────────────────────────────────────────────

  Stream<List<Map<String, dynamic>>> weeklyCampusLeaderboardStream(
    String university, {
    String entryWeekId = '',
    bool includeAll = false,
  }) {
    if (university.isEmpty) return emptyBoardStream();
    // Non-entrants may read nobody but themselves: issuing the unfiltered
    // query would fail wholesale with permission-denied (it WOULD match
    // unreadable docs), so emit [] with no query instead. The admin path
    // passes includeAll:true explicitly.
    if (!includeAll && entryWeekId.isEmpty) return emptyBoardStream();

    // Cohort filter matches the `users` read rule: an empty [entryWeekId]
    // means "no cohort constraint" — only the payout admin may evaluate
    // that (the Rankings page passes '' solely for the admin account).
    // Normal players always pass their own entry week.
    //
    // Requires the
    // `(university ASC, leaderboardEntryWeekId ASC, weeklyPoints DESC)`
    // composite index when the cohort filter is present, or
    // `(university ASC, weeklyPoints DESC)` without it
    // (firestore.indexes.json).
    var query = _db
        .collection('users')
        .where('university', isEqualTo: university);
    if (entryWeekId.isNotEmpty) {
      query =
          query.where('leaderboardEntryWeekId', isEqualTo: entryWeekId);
    }
    return query
        .orderBy('weeklyPoints', descending: true)
        .limit(50)
        .snapshots()
        .map((snap) {
      final weekId = FirestoreService.currentWeekId();
      var eRank = 0;
      final out = <Map<String, dynamic>>[];
      for (final entry in snap.docs) {
        // Hidden admin account: invisible and rank-free (see
        // [kBoardHiddenUids]).
        if (kBoardHiddenUids.contains(entry.id)) continue;
        final data = entry.data();
        final eligible = data['leaderboardEntryWeekId'] == weekId;
        out.add({
          'rank': eligible ? ++eRank : null,
          'uid': entry.id,
          'username': (data['username'] as String?) ?? 'Anonymous',
          'weeklyPoints': (data['weeklyPoints'] as int?) ?? 0,
          'isCurrentUser': entry.id == _uid,
          'leaderboardEntryWeekId': data['leaderboardEntryWeekId'] as String?,
        });
      }
      return out;
    }).asBroadcastStream();
  }

  // ─── University Helpers ──────────────────────────────────────────────────────

  Future<String?> getCurrentUserUniversity() async {
    if (_uid == null) return null;
    final doc = await _userDoc.get();
    final raw = doc.data()?['university'] as String?;
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  Future<void> updateUniversity(String university) async {
    if (_uid == null) return;
    await _userDoc.update({'university': university});
  }

  // ─── Top Universities (5-minute in-memory cache) ─────────────────────────────

  Map<String, int>? _topUniCache;
  DateTime? _topUniCacheTime;

  Future<List<UniversityTotal>> getTopUniversities() async {
    if (_topUniCache != null &&
        _topUniCacheTime != null &&
        DateTime.now().difference(_topUniCacheTime!).inMinutes < 5) {
      return _buildTopTwo(_topUniCache!);
    }

    final snap = await _db
        .collection('users')
        .orderBy('weeklyPoints', descending: true)
        .limit(500)
        .get();

    final totals = <String, int>{};
    for (final doc in snap.docs) {
      final data = doc.data();
      final uni = data['university'] as String?;
      final pts = (data['weeklyPoints'] as int?) ?? 0;
      if (uni != null && uni.isNotEmpty && uni != 'Other') {
        totals[uni] = (totals[uni] ?? 0) + pts;
      }
    }

    _topUniCache = totals;
    _topUniCacheTime = DateTime.now();
    return _buildTopTwo(totals);
  }

  void invalidateTopUniCache() {
    _topUniCache = null;
    _topUniCacheTime = null;
  }

  List<UniversityTotal> _buildTopTwo(Map<String, int> totals) {
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .take(2)
        .map((e) => UniversityTotal(university: e.key, total: e.value))
        .toList();
  }

  // ─── Prize Pool ──────────────────────────────────────────────────────────────

  static String currentWeekId() {
    final now = DateTime.now().toUtc();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final d = DateTime(monday.year, monday.month, monday.day);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Stream<Map<String, dynamic>> prizePoolStream() {
    return _db.collection('prize_pool').doc(currentWeekId()).snapshots().map(
        (s) =>
            s.data() ??
            {'totalNaira': 0.0, 'weekId': currentWeekId(), 'status': 'active'});
  }

  Future<void> incrementPrizePool(double nairaPerView) async {
    final ref = _db.collection('prize_pool').doc(currentWeekId());
    await ref.set({
      'totalNaira': FieldValue.increment(nairaPerView),
      'adViewCount': FieldValue.increment(1),
      'weekId': currentWeekId(),
      'status': 'active',
    }, SetOptions(merge: true));
  }

  // ─── Last Week Winners ───────────────────────────────────────────────────────

  Future<LastWeekResult?> getLastWeekWinners() async {
    try {
      final snap = await _db
          .collection('prize_pool')
          // NOTE: query for 'pending_payment' OR 'paid' status. Winners should be
          // announced as soon as they're calculated (pending_payment), not just
          // after manual payment processing (paid). This ensures users see the
          // announcement even if admin never marks payments as complete.
          // BUG FIX: was 'paid' only, causing announcements to never show if
          // admin didn't manually process payments.
          .where('status', whereIn: ['pending_payment', 'paid'])
          .orderBy('weekId', descending: true)
          .limit(1)
          .get(const GetOptions(source: Source.server));

      if (snap.docs.isEmpty) return null;

      final data = snap.docs.first.data();
      final weekId = (data['weekId'] as String?) ?? '';
      final total = ((data['totalNaira'] as num?)?.toDouble()) ?? 0.0;
      final rawList = (data['winners'] as List<dynamic>?) ?? [];

      if (rawList.isEmpty) return null;

      final winners = rawList
          .map((w) => PrizeWinner.fromMap(Map<String, dynamic>.from(w as Map)))
          .toList()
        ..sort((a, b) => a.rank.compareTo(b.rank));

      return LastWeekResult(
        weekId: weekId,
        totalNaira: total,
        winners: winners,
      );
    } catch (_) {
      return null;
    }
  }

  // ─── Username ────────────────────────────────────────────────────────────────

  Future<bool> canChangeUsername() async {
    if (_uid == null) return false;
    final doc = await _userDoc.get();
    final lastChange = doc.data()?['lastUsernameChange'] as Timestamp?;
    if (lastChange == null) return true;
    final daysSince = DateTime.now().difference(lastChange.toDate()).inDays;
    return daysSince >= 7;
  }

  Future<DateTime?> nextUsernameChangeDate() async {
    if (_uid == null) return null;
    final doc = await _userDoc.get();
    final lastChange = doc.data()?['lastUsernameChange'] as Timestamp?;
    if (lastChange == null) return null;
    final nextAllowed = lastChange.toDate().add(const Duration(days: 7));
    if (DateTime.now().isAfter(nextAllowed)) return null;
    return nextAllowed;
  }

  Future<void> updateUsername(String newUsername) async {
    if (_uid == null) return;
    final canChange = await canChangeUsername();
    if (!canChange) {
      throw Exception('Username can only be changed once every 7 days.');
    }
    await _auth.currentUser!.updateDisplayName(newUsername.trim());
    await _userDoc.update({
      'username': newUsername.trim(),
      'lastUsernameChange': FieldValue.serverTimestamp(),
    });
  }

  Future<String> getUsername() async {
    if (_uid == null) return 'Trainer';
    final doc = await _userDoc.get();
    return (doc.data()?['username'] as String?) ??
        _auth.currentUser?.displayName ??
        'Trainer';
  }

  // ─── Challenges ───────────────────────────────────────────────────────────────

  CollectionReference<Map<String, dynamic>> get _challenges =>
      _db.collection('challenges');

  String _generateChallengeCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand = Random();
    return List.generate(6, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  /// ⚠️ DO NOT USE — BYPASSES ALL CLOUD FUNCTIONS VALIDATION
  ///
  /// This method is DEAD CODE and only exists for backwards compatibility.
  /// It does NOT:
  ///   - Deduct coins from the creator
  ///   - Check daily challenge creation limits
  ///   - Validate the active-challenge cap
  ///   - Trigger any CF-side payouts/refunds
  ///
  /// All challenge creation MUST go through Cloud Functions instead.
  /// This method will throw [Exception] to prevent accidental misuse.
  @Deprecated('Use Cloud Functions instead — never call this directly')
  Future<ChallengeCreationResult> createChallenge({
    required String animeTitle,
    required int stakeAmount,
    String? opponentUid,
    String? opponentUsername,
  }) async {
    throw Exception(
      'createChallenge() is DEAD CODE and bypasses all CF validation. '
      'Use Cloud Functions createChallenge instead.',
    );
  }

  Stream<ChallengeModel?> challengeStream(String challengeId) {
    return _challenges
        .doc(challengeId)
        .snapshots()
        .map((s) => s.exists ? ChallengeModel.fromDoc(s) : null);
  }

  Future<ChallengeModel?> getChallengeByCode(String code) async {
    final snap = await _challenges
        .doc(code.trim().toUpperCase())
        .get(const GetOptions(source: Source.server));
    return snap.exists ? ChallengeModel.fromDoc(snap) : null;
  }

  /// ⚠️ DO NOT USE — BYPASSES ALL CLOUD FUNCTIONS VALIDATION
  ///
  /// This method is DEAD CODE and only exists for backwards compatibility.
  /// It does NOT:
  ///   - Deduct coins from the opponent
  ///   - Check opponent's daily challenge join limits
  ///   - Validate the active-challenge cap
  ///   - Trigger any CF-side coin locking or escrow
  ///   - Execute payout logic on completion
  ///
  /// All challenge joins MUST go through Cloud Functions instead.
  /// This method will throw [Exception] to prevent accidental misuse.
  @Deprecated('Use Cloud Functions instead — never call this directly')
  Future<void> joinChallenge(String challengeId) async {
    throw Exception(
      'joinChallenge() is DEAD CODE and bypasses all CF validation. '
      'Use Cloud Functions joinChallenge instead.',
    );
  }

  Future<void> submitCreatorScore(String challengeId, int score) async {
    if (_uid == null) return;
    await _challenges.doc(challengeId).update({'creatorScore': score});
  }

  Future<void> submitOpponentScore(String challengeId, int score) async {
    if (_uid == null) return;
    await _challenges.doc(challengeId).update({'opponentScore': score});
  }

  Future<List<AnimeQuestion>> fetchQuestionsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];

    final chunks = <List<String>>[];
    for (int i = 0; i < ids.length; i += 30) {
      chunks.add(ids.sublist(i, (i + 30).clamp(0, ids.length)));
    }

    final results = <AnimeQuestion>[];
    for (final chunk in chunks) {
      final snap = await _db
          .collection('questions')
          .where(FieldPath.documentId, whereIn: chunk)
          .get(const GetOptions(source: Source.server));
      results.addAll(snap.docs.map((d) => AnimeQuestion.fromDoc(d)));
    }

    final byId = {for (final q in results) q.id: q};
    return ids.map((id) => byId[id]).whereType<AnimeQuestion>().toList();
  }

  // ─── My Challenges stream ───────────────────────────────────────────────────

  /// Live stream of all challenges where the current user is either the creator
  /// or the opponent. Returns the full list; the UI filters by status into
  /// Active / Pending / Completed tabs.
  Stream<List<ChallengeModel>> getMyChallengesStream() {
    if (_uid == null) return Stream.value([]);
    // Firestore doesn't support OR queries directly, so we use two separate
    // where-in clauses merged client-side. We filter on creatorUid and
    // opponentUid separately, then deduplicate by document id.
    final asCreator = _challenges
        .where('creatorUid', isEqualTo: _uid)
        .snapshots()
        .map((snap) => snap.docs.map(ChallengeModel.fromDoc).toList());
    final asOpponent = _challenges
        .where('opponentUid', isEqualTo: _uid)
        .snapshots()
        .map((snap) => snap.docs.map(ChallengeModel.fromDoc).toList());
    return StreamZip([asCreator, asOpponent]).map((pairs) {
      final seen = <String>{};
      final merged = <ChallengeModel>[];
      for (final list in pairs) {
        for (final c in list) {
          if (seen.add(c.challengeId)) merged.add(c);
        }
      }
      return merged;
    });
  }

  // ─── Head-to-head record ───────────────────────────────────────────────────

  /// Returns win/loss/draw counts for the current user against uid2, derived
  /// entirely from the current user's own `users/{uid}/matches` subcollection
  /// filtered to opponentUid == uid2. Outcomes are stored from the current
  /// user's perspective ('win' = they won, 'lose' = they lost, 'draw').
  /// firestore.rules only permits reading the authenticated user's own
  /// matches subcollection, so users/{uid2}/matches is never queried.
  Future<Map<String, int>> getHeadToHeadRecord(
    String uid1,
    String uid2,
  ) async {
    if (_uid == null || uid2.isEmpty) {
      return {'wins': 0, 'losses': 0, 'draws': 0};
    }
    // firestore.rules: matches subcollection read requires
    // request.auth.uid == userId — so we can ONLY query the current
    // user's own users/{uid}/matches. Outcomes are stored from the
    // current user's perspective: 'win' = they won, 'lose' = they lost.
    final snap = await _userDoc
        .collection('matches')
        .where('opponentUid', isEqualTo: uid2)
        .get();
    int wins = 0, losses = 0, draws = 0;
    for (final doc in snap.docs) {
      final outcome = doc.data()['outcome'] as String?;
      if (outcome == 'win') {
        wins++;
      } else if (outcome == 'lose') {
        losses++;
      } else if (outcome == 'draw') {
        draws++;
      }
    }
    return {'wins': wins, 'losses': losses, 'draws': draws};
  }

  Future<List<String>> _pickRandomQuestionIds(
    String animeTitle,
    int count,
  ) async {
    final snap = await _db
        .collection('questions')
        .where('animeTitle', isEqualTo: animeTitle)
        .get(const GetOptions(source: Source.server));

    if (snap.docs.isEmpty) {
      throw Exception('No questions found for "$animeTitle".');
    }

    final docs = List.of(snap.docs)..shuffle(Random());
    return docs.take(count).map((d) => d.id).toList();
  }

  // ─── Leaderboard Payout Claim (Phase 3 — client contract) ──────────────────
  //
  // Server is authoritative for eligibility, prize amount, account
  // verification, approval, payout status, and `paid`. The client only
  // submits bank details via the callable and reads back claim state.
  // No prize maths and no payout-security logic live here.

  /// Cached result of [listNigerianBanks] (contract: proposed CF, NOT yet
  /// deployed). Mirrors the existing [_weeklyPlayerCountCache] convention.
  static List<NigerianBank>? _banksCache;
  static DateTime? _banksCacheTime;

  /// Returns the verified Nigerian bank list from the `listNigerianBanks`
  /// callable (PROPOSED contract — see [NigerianBank]).
  ///
  /// Throws [FirebaseFunctionsException] when the callable is missing or
  /// Flutterwave is unavailable — the caller shows an error/retry state and
  /// must NOT fall back to a hardcoded catalogue or free-form code entry.
  Future<List<NigerianBank>> listNigerianBanks() async {
    final now = DateTime.now();
    if (_banksCache != null &&
        _banksCacheTime != null &&
        now.difference(_banksCacheTime!).inHours < 24) {
      return _banksCache!;
    }

    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('listNigerianBanks');
    final res = await callable.call({});
    final data = Map<String, dynamic>.from(res.data as Map);
    final raw = (data['banks'] as List?) ?? const [];

    final banks = raw
        .map((b) => NigerianBank.fromMap(Map<String, dynamic>.from(b as Map)))
        .where((b) => b.name.isNotEmpty && b.code.isNotEmpty)
        .toList();

    _banksCache = banks;
    _banksCacheTime = now;
    return banks;
  }

  void invalidateBankCache() {
    _banksCache = null;
    _banksCacheTime = null;
  }

  /// Submits the winner's bank details for [weekId] via the
  /// `submitPayoutDetails` callable. The server resolves the account via
  /// Flutterwave and determines the verified account name.
  ///
  /// Returns [PayoutClaimResult] on success (including idempotent
  /// `'already_submitted'`). Throws [PayoutClaimException] for server
  /// rejections (already paid / approved / expired / not a winner / invalid
  /// input) so the UI can render each state distinctly.
  Future<PayoutClaimResult> submitPayoutDetails({
    required String weekId,
    required String accountNumber,
    required String bankCode,
    required String beneficiaryName,
  }) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('submitPayoutDetails');
    try {
      final res = await callable.call({
        'weekId': weekId,
        'accountNumber': accountNumber,
        'bankCode': bankCode,
        'beneficiaryName': beneficiaryName,
        // Forced-update gate: the server refuses an outdated Android client
        // before it resolves the bank account, so a walled build cannot spend
        // a transfer-fee credit. Web clients report platform 'web' and are
        // exempt.
        ...AppUpdateService.instance.clientBuildStamp,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return PayoutClaimResult(
        success: data['success'] == true,
        status: (data['status'] as String?) ?? 'pending',
        resolvedNameMatch: data['resolvedNameMatch'] as bool?,
        message: (data['message'] as String?) ?? '',
      );
    } on FirebaseFunctionsException catch (e) {
      throw PayoutClaimException(code: e.code, message: e.message ?? e.code);
    }
  }

  /// Live stream of `leaderboardCycles/{weekId}` (auth-read per rules).
  /// Emits `null` once when unauthenticated.
  Stream<DocumentSnapshot<Map<String, dynamic>>?> leaderboardCycleStream(
    String weekId,
  ) {
    if (_uid == null) return Stream.value(null);
    return _db.collection('leaderboardCycles').doc(weekId).snapshots();
  }

  /// Live stream of the current user's own
  /// `leaderboardCycles/{weekId}/pendingClaim/{uid}` (owner-read per rules).
  /// Emits `null` once when unauthenticated.
  Stream<DocumentSnapshot<Map<String, dynamic>>?> pendingClaimStream(
    String weekId,
  ) {
    if (_uid == null) return Stream.value(null);
    return _db
        .collection('leaderboardCycles')
        .doc(weekId)
        .collection('pendingClaim')
        .doc(_uid)
        .snapshots();
  }

  /// One-shot read of `leaderboardCycles/{weekId}`. Returns `null` when
  /// unauthenticated, missing, or unreadable (never throws to the UI).
  Future<Map<String, dynamic>?> getLeaderboardCycle(String weekId) async {
    if (_uid == null) return null;
    try {
      final snap =
          await _db.collection('leaderboardCycles').doc(weekId).get();
      return snap.exists ? snap.data() : null;
    } catch (e) {
      debugPrint('[FirestoreService] getLeaderboardCycle error: $e');
      return null;
    }
  }

  /// One-shot read of the current user's own pending claim for [weekId].
  /// Returns `null` when unauthenticated, never submitted, or unreadable.
  Future<Map<String, dynamic>?> getPendingClaim(String weekId) async {
    if (_uid == null) return null;
    try {
      final snap = await _db
          .collection('leaderboardCycles')
          .doc(weekId)
          .collection('pendingClaim')
          .doc(_uid)
          .get();
      return snap.exists ? snap.data() : null;
    } catch (e) {
      debugPrint('[FirestoreService] getPendingClaim error: $e');
      return null;
    }
  }

  /// Returns recent cycles where the current user is in `ranked[]`, newest
  /// first, each joined with their own pending-claim status.
  ///
  /// `ranked` is an array of maps so it cannot be queried server-side;
  /// mirrors the `exportPayoutLog` pattern (`orderBy documentId`) and filters
  /// client-side. Result sets are tiny (one doc per week).
  Future<List<WinnerClaimSummary>> getMyWinnerCycles({int limit = 8}) async {
    if (_uid == null) return [];
    final uid = _uid;
    try {
      final snap = await _db
          .collection('leaderboardCycles')
          .orderBy(FieldPath.documentId, descending: true)
          .limit(limit)
          .get();

      final out = <WinnerClaimSummary>[];
      for (final doc in snap.docs) {
        final data = doc.data();
        final ranked = (data['ranked'] as List?) ?? const [];
        Map<String, dynamic>? mine;
        for (final r in ranked) {
          final m = Map<String, dynamic>.from(r as Map);
          if (m['uid'] == uid) {
            mine = m;
            break;
          }
        }
        if (mine == null) continue;

        String? claimStatus;
        try {
          final claim = await doc.reference
              .collection('pendingClaim')
              .doc(uid)
              .get();
          if (claim.exists) {
            claimStatus = claim.data()?['status'] as String?;
          }
        } catch (e) {
          debugPrint('[FirestoreService] getMyWinnerCycles claim read: $e');
        }

        out.add(WinnerClaimSummary(
          weekId: doc.id,
          rank: ((mine['rank'] as num?)?.toInt()) ?? 0,
          share: ((mine['share'] as num?)?.toDouble()) ?? 0.0,
          paid: mine['paid'] == true,
          claimStatus: claimStatus,
        ));
      }
      return out;
    } catch (e) {
      debugPrint('[FirestoreService] getMyWinnerCycles error: $e');
      return [];
    }
  }

  /// Live stream of the current user's reusable `payoutDetails`
  /// (owner CRUD per rules). After a payout completes, the server purges
  /// sensitive fields, leaving only `accountMask` — the UI must therefore
  /// render masked values and never expect full details here.
  Stream<List<Map<String, dynamic>>> payoutDetailsStream() {
    if (_uid == null) return Stream.value([]);
    return _db
        .collection('users')
        .doc(_uid)
        .collection('payoutDetails')
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => {...doc.data(), 'id': doc.id}).toList());
  }

  /// Updates one reusable payout-detail doc. The UI must gate this on lock
  /// state ([WinnerClaimSummary.isLocked]) — the server independently rejects
  /// destination changes once a claim is approved.
  Future<void> updatePayoutDetail(
    String docId, {
    required String accountNumber,
    required String bankCode,
    required String beneficiaryName,
  }) async {
    if (_uid == null) return;
    await _db
        .collection('users')
        .doc(_uid)
        .collection('payoutDetails')
        .doc(docId)
        .update({
      'accountNumber': accountNumber,
      'bankCode': bankCode,
      'beneficiaryName': beneficiaryName,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Saves the device FCM token for server-side winner/payout notifications.
  /// `fcmToken` is NOT in the rules update-blacklist, so this merge-write is
  /// permitted. Failures are logged and ignored (notifications are
  /// best-effort; the claim flow never depends on them).
  Future<void> saveFcmToken(String token) async {
    if (_uid == null || token.isEmpty) return;
    try {
      await _userDoc.set({'fcmToken': token}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[FirestoreService] saveFcmToken error (ignored): $e');
    }
  }
}
