import 'dart:math';
import 'package:async/async.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../features/quiz/questions.dart';
import '../../features/multiplayer/challenge_model.dart';
import '../../features/leaderboard/leaderboard_models.dart';
import '../constants/admin_accounts.dart';
import '../constants/anime_catalog.dart';
import '../constants/rival_economy.dart';
import '../constants/rivalries_paging.dart';
import '../constants/solo_economy.dart';
import 'app_update_service.dart';
import 'prize_pool_service.dart';

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

/// Thrown by the `spendCoins` Cloud Function when a Premium-only spend type
/// (e.g. `spend_retry`) is attempted by a non-Premium account. The UI should
/// route the user to the Premium upsell instead of a generic error.
class PremiumRequiredException implements Exception {
  const PremiumRequiredException();

  @override
  String toString() => 'PremiumRequiredException: premium_required';
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

// ─── Weekly standing (live rank beyond the visible board) ───────────────────

/// Where the signed-in player currently stands on the paid weekly board.
///
/// Produced by [FirestoreService.weeklyStanding]. Exists because the visible
/// board is capped at 100 rows: without this, an eligible player ranked #150
/// was shown "#—" on a page whose entire purpose is telling them their rank.
/// Every field is optional because any single query may fail — callers must
/// degrade to the board's own numbers rather than showing a wrong figure.
class WeeklyStanding {
  /// 1-based position within the cohort, matching the board's own sequential
  /// ranking (ties resolved by document order, exactly as `_mapBoardEntries`
  /// does). `0` when the player is not on the board at all.
  final int rank;

  /// Number of players in the cohort.
  final int totalPlayers;

  /// The player's own weekly points.
  final int myPoints;

  /// Weekly points the player ranked directly above has — i.e. the target to
  /// overtake. `null` at rank 1, when unranked, or when the query failed.
  final int? pointsToNextRank;

  /// Username of the player in [pointsToNextRank]'s slot, for "beat X" copy.
  final String? nextRankUsername;

  const WeeklyStanding({
    required this.rank,
    required this.totalPlayers,
    required this.myPoints,
    this.pointsToNextRank,
    this.nextRankUsername,
  });

  /// Percentile bucket (1–99) this rank represents, or `null` when it cannot
  /// be computed meaningfully (no cohort size, or the player is not ranked).
  ///
  /// Ceiled so "Top 5%" never over-claims, and clamped so it never renders as
  /// "Top 100%" or "Top 0%".
  int? get topPercent {
    if (rank <= 0 || totalPlayers <= 1) return null;
    final pct = ((rank / totalPlayers) * 100).ceil().clamp(1, 99);
    return pct;
  }

  /// Points needed to overtake the player above, floored at 1.
  ///
  /// Ties cost nothing here (shared ranks both display), but reporting "0
  /// points needed" would read as a bug, so anything non-positive becomes 1.
  int? get pointsToOvertake {
    final target = pointsToNextRank;
    if (rank <= 0 || target == null) return null;
    final delta = target - myPoints + 1;
    return delta < 1 ? 1 : delta;
  }

  /// Empty result for a player who has no entry, is unauthenticated, or whose
  /// query failed — callers fall back to local data instead of inventing a rank.
  static const WeeklyStanding none =
      WeeklyStanding(rank: 0, totalPlayers: 0, myPoints: 0);
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
///
/// Payouts are manual, so there is no automated account verification and this
/// payload carries no verification result.
class PayoutClaimResult {
  final bool success;
  final String status;
  final String message;

  const PayoutClaimResult({
    required this.success,
    required this.status,
    required this.message,
  });

  bool get alreadySubmitted => status == 'already_submitted';
}

/// Thrown by [FirestoreService.submitPayoutDetails] for callable errors so the
/// claim UI can map server codes (already paid / marked as sent / not a winner /
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
/// [claimStatus] is `'pending' | 'marked' | 'expired'`, or `null` when the
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
  /// expired nor paid out): edits must be disabled in this state. `marked`
  /// means the admin already recorded the transfer, which is also locked.
  bool get isLocked =>
      (claimStatus == 'pending' || claimStatus == 'marked') && !paid;

  /// True when the winner can still submit (or re-submit after expiry).
  bool get canClaim =>
      !paid && (claimStatus == null || claimStatus == 'expired');
}

/// One named rival distilled from match history: running record, most
/// recent meeting, and whether that meeting was a loss (revenge affordance).
class RivalSummary {
  final String uid;
  final String username;
  int wins;
  int losses;
  int draws;
  final DateTime lastPlayed;
  final bool lastWasLoss;

  RivalSummary({
    required this.uid,
    required this.username,
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    required this.lastPlayed,
    this.lastWasLoss = false,
  });

  int get total => wins + losses + draws;
}

/// A discoverable future rival (campus board row): identity + current
/// weekly points for the bounty/suggested-rank context.
class RivalCandidate {
  final String uid;
  final String username;
  final int weeklyPoints;
  final String university;

  const RivalCandidate({
    required this.uid,
    required this.username,
    required this.weeklyPoints,
    required this.university,
  });
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

  // ─── Daily Challenge (retired) ────────────────────────────────────────────
  //
  // The old standalone "1.5× WP once per WAT day" Daily Challenge was removed;
  // its only surviving surface is the Daily Gauntlet, which REUSES the same
  // users/{uid} fields (dailyChallengeDate / dailyChallengeUsed) and is written
  // entirely server-side by submitQuizAnswers / submitDailyGauntlet. There is
  // therefore no client read/write path to keep here.

  // ─── Early Anime Unlock ────────────────────────────────────────────────────

  /// Unlocks [animeTitle] early by calling the `unlockAnimeEarly` Cloud
  /// Function (Section 18), which validates the title against the unlockable
  /// set, charges 5000 AC transactionally, appends it to
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

  // ─── Solo anime cooldowns (server-authoritative) ───────────────────────────

  /// Live cooldown expiries for the signed-in user, keyed by title. Locks are
  /// written only by Cloud Functions; expired entries are filtered by the caller.
  Stream<Map<String, DateTime>> cooldownsStream() {
    if (_uid == null) return Stream.value(<String, DateTime>{});
    return _userDoc.collection('cooldowns').snapshots().map((snap) {
      final out = <String, DateTime>{};
      for (final d in snap.docs) {
        final data = d.data();
        final title = (data['title'] as String?) ?? d.id;
        final expiresAt = data['expiresAt'];
        if (expiresAt is Timestamp) out[title] = expiresAt.toDate();
      }
      return out;
    });
  }

  /// Starts the cooldown for [titles] via `startSoloCooldowns`. Returns the new
  /// expiry (ms since epoch) for each title that was locked; permanently
  /// unlocked titles are absent. Throws [FirebaseFunctionsException] with
  /// `failed-precondition` / `cooldown_active` if any title is still locked.
  Future<Map<String, int>> startSoloCooldowns(List<String> titles) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('startSoloCooldowns');
    final res = await callable.call(<String, dynamic>{
      'titles': titles,
      ...AppUpdateService.instance.clientBuildStamp,
    });
    final data = Map<String, dynamic>.from(res.data as Map);
    final raw = Map<String, dynamic>.from(data['expiresAt'] as Map? ?? const {});
    return raw.map((k, v) => MapEntry(k, (v as num).toInt()));
  }

  /// Live anime catalogue from app_config/anime_catalog.titles. Falls back to
  /// the bundled [kAnimeCatalog] while the doc is absent or empty.
  Stream<List<String>> animeCatalogStream() {
    return _db.collection('app_config').doc('anime_catalog').snapshots().map((snap) {
      final raw = snap.data()?['titles'];
      if (raw is List) {
        final titles = raw
            .whereType<String>()
            .map((s) => s.trim().toLowerCase())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList();
        if (titles.isNotEmpty) return titles;
      }
      return kAnimeCatalog;
    });
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

  // ─── Difficulty-aware question pools (Step 4 + homepage difficulty) ───
  //
  // Mix ratios:
  //   Solo homepage (10Q, weighted by selected difficulty — see
  //     lib/core/constants/solo_economy.dart):
  //     easy   → 7 Easy / 2 Medium / 1 Hard
  //     medium → 3 Easy / 4 Medium / 3 Hard
  //     hard   → 1 Easy / 2 Medium / 7 Hard
  //   Gauntlet (7Q): 3 Easy / 2 Medium / 2 Hard, positional E,E,E,M,M,H,H to
  //                  align with kGauntletTiers (15,15,15,20,20,25,25).
  //   Challenge/QM (10Q, createChallenge CF): 3 Easy / 4 Medium / 3 Hard.
  //   (Quick Match + Create Challenge are untouched by homepage difficulty.)
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

  /// Fixed per-tier needs for a legacy 10-question Solo session.
  /// Kept for backwards compat — new code resolves the mix from
  /// [kSoloDifficultyMixes] via the `difficulty` param of
  /// [fetchQuestionsForTitles].
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

  /// Homepage solo fetch — 10 questions with a WEIGHTED mix leaning toward
  /// [difficulty] ('easy' | 'medium' | 'hard', see [kSoloDifficultyMixes]).
  /// Quick Match / Create Challenge never call this (they use server-side
  /// mixes + their own CFs) and are unaffected.
  ///
  /// Short pools backfill from legacy untagged docs first, then cross-tier
  /// tagged surpluses — so a thin hard pool still returns 10 playable
  /// questions rather than failing. Rewards stay at the SELECTED tier
  /// (server trusts the difficulty flag), so seed enough hard questions to
  /// keep hard runs honest.
  Future<List<AnimeQuestion>> fetchQuestionsForTitles(
    List<String> titles, {
    String difficulty = 'easy',
  }) async {
    final normalized = _normalizeTitles(titles);
    if (normalized.isEmpty) {
      throw Exception('No anime titles provided.');
    }

    final mix =
        kSoloDifficultyMixes[normalizeSoloDifficulty(difficulty)]!;
    final easyNeed = mix['easy']!;
    final mediumNeed = mix['medium']!;
    final hardNeed = mix['hard']!;
    final need = easyNeed + mediumNeed + hardNeed;

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
    await _resetTierBucketIfShort(
        titles: normalized, tier: 'easy', need: easyNeed,
        tagged: tagged, seen: seen);
    await _resetTierBucketIfShort(
        titles: normalized, tier: 'medium', need: mediumNeed,
        tagged: tagged, seen: seen);
    await _resetTierBucketIfShort(
        titles: normalized, tier: 'hard', need: hardNeed,
        tagged: tagged, seen: seen);

    // Interleaved deal order: E,M,H round-robin (starts easy, ends easy).
    final slotOrder = <String>[
      for (int i = 0;
          i <
              [easyNeed, mediumNeed, hardNeed]
                  .reduce((a, b) => a > b ? a : b);
          i++) ...[
        if (i < easyNeed) 'easy',
        if (i < mediumNeed) 'medium',
        if (i < hardNeed) 'hard',
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

  // REMOVED: leaderboardStream() and getCurrentUserRank().
  //
  // Both were legacy, lifetime-score ("totalScore") queries with NO cohort
  // filter, so under the current `users` read rule they fail wholesale with
  // permission-denied for anyone but the payout admin (they would match docs
  // the caller may not read). Neither had a call site. The weekly board below
  // is the only ranking the app shows.

  // ─── Weekly standing (A5) ───────────────────────────────────────────────

  /// Resolves the caller's live position on the paid weekly cohort board,
  /// including ranks beyond the visible top-100 window.
  ///
  /// Rank must match the board's own sequential numbering (`_mapBoardEntries`
  /// assigns `++eRank` down the `weeklyPoints desc` ordering), so this walks
  /// that same ordering rather than inferring a rank from an aggregate.
  ///
  /// Walking is what makes it tie-safe. A COUNT of "strictly greater than me"
  /// is a lower bound only: when other players share my score, a single
  /// `limit(count + 1)` prefix need not reach my own row, and inferring the
  /// rank from the count would report a rank the board does not show for
  /// someone who is visibly on the board. So we page down the ordering and stop
  /// once we reach our own row, keeping the immediately-preceding row as the
  /// overtake target.
  ///
  /// Queries are cohort-filtered, satisfying the `users` read rule. Requires
  /// the `(leaderboardEntryWeekId ASC, weeklyPoints DESC)` composite index
  /// (firestore.indexes.json).
  ///
  /// Never throws: any failure returns [WeeklyStanding.none] and the UI falls
  /// back to the board it already has.
  Future<WeeklyStanding> weeklyStanding({
    String? entryWeekId,
    bool eligible = false,
  }) async {
    final week = entryWeekId ?? '';
    if (_uid == null || week.isEmpty || !eligible) return WeeklyStanding.none;

    try {
      final uid = _uid!;
      final mySnap = await _userDoc.get();
      final myPts = (mySnap.data()?['weeklyPoints'] as int?) ?? 0;

      final totalSnap = await _db
          .collection('users')
          .where('leaderboardEntryWeekId', isEqualTo: week)
          .count()
          .get();
      final total = totalSnap.count ?? 0;
      if (total == 0) return WeeklyStanding.none;

      var rank = 0;
      int? pointsToNextRank;
      String? nextRankUsername;

      // Score/name of the highest row we have walked past — becomes the
      // overtake target once we reach our own row.
      int? prevPoints;
      String? prevName;

      var found = false;
      DocumentSnapshot<Map<String, dynamic>>? cursor;

      // Bounded so a pathological cohort cannot spin: 40 pages of 50 is 2000
      // rows, far beyond any plausible weekly cohort.
      for (var page = 0; page < 40; page++) {
        var query = _db
            .collection('users')
            .where('leaderboardEntryWeekId', isEqualTo: week)
            .orderBy('weeklyPoints', descending: true);
        if (cursor != null) query = query.startAfterDocument(cursor);
        final snap = await query.limit(50).get();
        if (snap.docs.isEmpty) break;
        cursor = snap.docs.last;

        for (final doc in snap.docs) {
          if (kBoardHiddenUids.contains(doc.id)) continue;
          final data = doc.data();
          final pts = (data['weeklyPoints'] as int?) ?? 0;
          final name = (data['username'] as String?) ?? 'Anonymous';

          if (doc.id == uid) {
            found = true;
            pointsToNextRank = prevPoints;
            nextRankUsername = prevName;
            prevPoints = pts;
            prevName = name;
            break;
          }

          rank++;
          prevPoints = pts;
          prevName = name;
        }

        // Our own row is the only thing this walk is for.
        if (found) break;
      }

      if (!found) return WeeklyStanding.none;

      return WeeklyStanding(
        rank: rank + 1,
        totalPlayers: total,
        myPoints: myPts,
        pointsToNextRank: pointsToNextRank,
        nextRankUsername: nextRankUsername,
      );
    } catch (e) {
      debugPrint('[FirestoreService] weeklyStanding error: $e');
      return WeeklyStanding.none;
    }
  }

  /// Convenience wrapper for the profile badge. Reports `0` ONLY when the
  /// player is not ranked (not found / not eligible), which that surface
  /// renders as "—". An eligible entrant with 0 points still has a real
  /// position and is reported as such.
  ///
  /// Delegates to [weeklyStanding] rather than a COUNT: a COUNT of "strictly
  /// greater than me" is a *competition* rank, which disagrees with the board's
  /// sequential numbering on ties. Same walk, same number everywhere.
  Future<int> getCurrentUserWeeklyRank({
    String? entryWeekId,
    bool eligible = false,
  }) async {
    if (_uid == null) return 0;
    if (!eligible || (entryWeekId ?? '').isEmpty) return 0;
    final standing =
        await weeklyStanding(entryWeekId: entryWeekId, eligible: true);
    // Report the real (sequential) rank whenever the player was found in the
    // walk, INCLUDING a legitimate #1..#N who simply has 0 points so far.
    // Zero is reserved for "not ranked" (not found / not eligible), which the
    // profile renders as "—".
    return standing.rank;
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
  /// [fetchEligibleWeeklyLeaderboard].
  ///
  /// One-shot, not a live listener: the board is polled on a 6-hour cadence
  /// (see kLeaderboardRefreshInterval), so an open Firestore stream per board
  /// would keep a websocket open indefinitely to deliver updates nobody reads
  /// that often. [kBoardHiddenUids] is filtered before rank assignment.
  Future<List<BoardEntry>> fetchWeeklyLeaderboard() async {
    final snap = await _db
        .collection('users')
        .orderBy('weeklyPoints', descending: true)
        .limit(100)
        .get();
    return _mapBoardEntries(snap);
  }

  /// Empty board stream that survives tab disposal/remount cycles.
  ///
  /// NEVER share a `Stream.value([])` instance across StreamBuilders:
  /// single-subscription streams throw "already been listened to" on the
  /// second listen even after the first subscription was cancelled (exactly
  /// what tab switches do). `Stream.multi` invokes its callback per
  /// Cohort board for normal players: only users who entered the SAME
  /// leaderboard week ([entryWeekId]).
  ///
  /// Matches the `users` read rule exactly — every returned doc is one the
  /// caller may read, so the query never fails wholesale. For a current-week
  /// payer this IS the live paid board. Pass the viewer's own entry week; an
  /// empty week resolves to `[]` with no query at all (a non-entrant may read
  /// nobody but themselves, and the page merges their own doc client-side).
  ///
  /// Requires the `(leaderboardEntryWeekId ASC, weeklyPoints DESC)`
  /// composite index (firestore.indexes.json).
  Future<List<BoardEntry>> fetchEligibleWeeklyLeaderboard(
    String entryWeekId,
  ) async {
    if (entryWeekId.isEmpty) return const <BoardEntry>[];
    final snap = await _db
        .collection('users')
        .where('leaderboardEntryWeekId', isEqualTo: entryWeekId)
        .orderBy('weeklyPoints', descending: true)
        .limit(100)
        .get();
    return _mapBoardEntries(snap);
  }

  /// Accounts that must NEVER appear on player-visible boards: invisible to
  /// all players and rank-free (skipped before rank assignment, so they
  /// occupy no rank slot and shift nobody).
  ///
  /// Derived from [kAdminUids] (lib/core/constants/admin_accounts.dart), the
  /// single Dart source of truth, which mirrors ADMIN_UIDS in
  /// functions/index.js and isPayoutAdmin() in firestore.rules. Deliberately
  /// enforced client-side rather than in Firestore rules: denying the doc
  /// server-side would make EVERY cohort query containing it fail wholesale
  /// for all players, and `!=` exclusion filters are incompatible with the
  /// weeklyPoints ordering/counts the boards need.
  static const List<String> kBoardHiddenUids = kAdminUids;

  List<BoardEntry> _mapBoardEntries(
    QuerySnapshot<Map<String, dynamic>> snap,
  ) {
    final weekId = FirestoreService.currentWeekId();
    var eRank = 0;
    final out = <BoardEntry>[];
    for (final entry in snap.docs) {
      if (kBoardHiddenUids.contains(entry.id)) continue;
      final data = entry.data();
      final eligible = data['leaderboardEntryWeekId'] == weekId;
      out.add(BoardEntry(
        rank: eligible ? ++eRank : null,
        uid: entry.id,
        username: (data['username'] as String?) ?? 'Anonymous',
        university: (data['university'] as String?) ?? '',
        weeklyPoints: (data['weeklyPoints'] as int?) ?? 0,
        isCurrentUser: entry.id == _uid,
        entryWeekId: data['leaderboardEntryWeekId'] as String?,
      ));
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

  // REMOVED: getWeeklyPlayerCount().
  //
  // It had no call site. The board's cohort size comes from the
  // `weeklyStanding` COUNT, which is the same query and already tied to the
  // player's own entry week, so a second cached counter was redundant.

  // REMOVED: getRivalForUser().
  //
  // It counted and fetched over ALL users with no cohort filter, so under the
  // current `users` read rule it permission-fails for everyone but the payout
  // admin. It also had no call site — the leaderboard derives its rival from
  // the cohort board it already has, which is both cheaper and guaranteed to
  // be a row the user can actually see and tap.

  // REMOVED: fetchCampusLeaderboard().
  //
  // The campus board was replaced by the single-query campus chip
  // ([campusRankCount]): a 50-row campus fetch per refresh for a tab nobody
  // paid for. The chip shows the one number the campus board was really used
  // for, at a fraction of the reads.

  // ─── University Helpers ──────────────────────────────────────────────────────

  Future<String?> getCurrentUserUniversity() async {
    if (_uid == null) return null;
    final doc = await _userDoc.get();
    final raw = doc.data()?['university'] as String?;
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  Future<void> updateUniversity(String university) async {
    if (_uid == null) return;
    if (!kNigerianUniversities.contains(university)) {
      throw Exception('Choose a university from the list.');
    }
    // `university` is server-owned: the callable re-validates the canonical
    // list, so a direct REST write can no longer spoof a campus.
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('updateUniversity');
    try {
      await callable.call<void>({
        'university': university,
        ...AppUpdateService.instance.clientBuildStamp,
      });
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Could not save campus.');
    }
  }

  // REMOVED: getTopUniversities() / UniversityTotal / invalidateTopUniCache().
  //
  // No call site. It downloaded 500 docs and ordered by `weeklyPoints` with no
  // cohort filter, so under the current `users` read rule it permission-fails
  // for everyone but the payout admin — dead code that could only ever throw.

  // ─── Prize Pool ──────────────────────────────────────────────────────────────

  static String currentWeekId() {
    final now = DateTime.now().toUtc();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final d = DateTime(monday.year, monday.month, monday.day);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  /// The week id immediately before the current one — the last cycle that has
  /// been finalised by `runWeeklyReset` (subject to the admin having run it).
  static String previousWeekId() {
    final monday = PrizePoolService.weekStartUtc();
    final prev = monday.subtract(const Duration(days: 7));
    return '${prev.year}-${prev.month.toString().padLeft(2, '0')}-'
        '${prev.day.toString().padLeft(2, '0')}';
  }

/// One-shot read of `prize_pool/{currentWeek}`.
  ///
  /// Carries the three inputs the weekly reset actually pools from:
  /// `entryCodeRevenue` (accrued by redeemCode), `adminPoolNaira` (optional
  /// admin override) and `status`. Feed these into
  /// [PrizePoolService.projectPrizePool] rather than showing `totalNaira` —
  /// `totalNaira` is legacy ad revenue that the reset never reads, so it is
  /// NOT the number anyone is paid.
  ///
  /// A missing doc is reported as `status: 'missing'` rather than `'active'`:
  /// faking an active week with a zero pool made the board claim a prize was
  /// running before the pool doc existed.
  ///
  /// One-shot so the leaderboard's 6-hourly poll does not need an open stream.
  /// Never throws: an unreadable pool degrades to a zeroed "missing" pool so
  /// the board still renders, because a pool read failure must not blank the
  /// whole leaderboard.
  Future<Map<String, dynamic>> fetchPrizePool() async {
    try {
      final snap = await _db
          .collection('prize_pool')
          .doc(currentWeekId())
          .get();
      return snap.data() ??
          <String, dynamic>{
            'totalNaira': 0.0,
            'entryCodeRevenue': 0.0,
            'adminPoolNaira': null,
            'weekId': currentWeekId(),
            'status': 'missing',
          };
    } catch (e) {
      debugPrint('[FirestoreService] fetchPrizePool error: $e');
      return <String, dynamic>{
        'entryCodeRevenue': 0.0,
        'adminPoolNaira': null,
        'weekId': currentWeekId(),
        'status': 'missing',
      };
    }
  }

  /// Live `prize_pool/{currentWeek}` document, for the home page's compact
  /// pool card where a single always-on listener for one small document is
  /// proportionate. The leaderboard uses [fetchPrizePool] instead.
  Stream<Map<String, dynamic>> prizePoolStream() {
    return _db.collection('prize_pool').doc(currentWeekId()).snapshots().map(
          (s) =>
              s.data() ??
              {
                'totalNaira': 0.0,
                'entryCodeRevenue': 0.0,
                'adminPoolNaira': null,
                'weekId': currentWeekId(),
                'status': 'missing',
              },
        );
  }

  // ─── Guaranteed entry floor (app_config/leaderboard_entry_config) ─────────

  static double? _floorCache;
  static DateTime? _floorCacheTime;

  /// `app_config/leaderboard_entry_config.guaranteedFloor` — the
  /// developer-funded minimum weekly pool, set by `setLeaderboardFloor`.
  ///
  /// Readable by any authenticated client (firestore.rules). It is an
  /// admin-set constant that changes rarely, so it is cached for 30 minutes
  /// rather than held open as a second live listener.
  Future<double> guaranteedFloor() async {
    final cached = _floorCache;
    final at = _floorCacheTime;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at).inMinutes < 30) {
      return cached;
    }
    try {
      final snap = await _db
          .collection('app_config')
          .doc('leaderboard_entry_config')
          .get();
      final value = (snap.data()?['guaranteedFloor'] as num?)?.toDouble() ?? 0;
      _floorCache = value.isFinite && value > 0 ? value : 0;
      _floorCacheTime = DateTime.now();
      return _floorCache!;
    } catch (e) {
      debugPrint('[FirestoreService] guaranteedFloor error: $e');
      return cached ?? 0;
    }
  }

  // ─── Last finalised pool (trust anchor) ──────────────────────────────────

  static double? _lastPoolCache;
  static String? _lastPoolCacheWeek;
  static DateTime? _lastPoolCacheTime;

  /// The prize pool that was actually allocated last week, read from
  /// `leaderboardCycles/{previousWeekId}.prizePool`.
  ///
  /// Shown beneath the live projection purely as a reference so players can
  /// see the projected figure is tracking something real, and can compare it
  /// to what was genuinely paid out. Returns `null` when no cycle has been
  /// calculated yet (e.g. the very first week). Cached for an hour: the value
  /// only changes when the admin runs the next reset.
  Future<double?> lastFinalisedPool() async {
    final week = previousWeekId();
    final cached = _lastPoolCache;
    final at = _lastPoolCacheTime;
    if (_lastPoolCacheWeek == week &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at).inMinutes < 60) {
      return cached;
    }
    try {
      final snap =
          await _db.collection('leaderboardCycles').doc(week).get();
      if (!snap.exists) {
        _lastPoolCacheWeek = week;
        _lastPoolCache = null;
        _lastPoolCacheTime = DateTime.now();
        return null;
      }
      final value = (snap.data()?['prizePool'] as num?)?.toDouble();
      _lastPoolCacheWeek = week;
      _lastPoolCache = (value != null && value.isFinite) ? value : null;
      _lastPoolCacheTime = DateTime.now();
      return _lastPoolCache;
    } catch (e) {
      debugPrint('[FirestoreService] lastFinalisedPool error: $e');
      return cached;
    }
  }

  // REMOVED: incrementPrizePool(nairaPerView).
  //
  // This wrote prize_pool/{weekId}.totalNaira directly from the client. It was
  // doubly broken: weeklyReset never read totalNaira, and firestore.rules deny
  // client writes to prize_pool, so every call threw. The prize pool is now set
  // by the admin through the setPrizePool Cloud Function.

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
      final legacyTotal = ((data['totalNaira'] as num?)?.toDouble()) ?? 0.0;
      final rawList = (data['winners'] as List<dynamic>?) ?? [];

      if (rawList.isEmpty) return null;

      final winners = rawList
          .map((w) => PrizeWinner.fromMap(Map<String, dynamic>.from(w as Map)))
          .toList()
        ..sort((a, b) => a.rank.compareTo(b.rank));

      // `totalNaira` is a legacy ad-revenue field that runWeeklyReset never
      // writes, so it reads 0 — which left the announcement's "Prize pool"
      // badge effectively unreachable. The real pool is the sum of the winners'
      // paid shares (the top-5 percentages sum to 1.0), so fall back to that.
      final shareSum = winners.fold<double>(0.0, (a, w) => a + w.prizeAmount);
      final total = legacyTotal > 0 ? legacyTotal : shareSum;

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

  /// Changes the username through the `changeUsername` callable.
  ///
  /// The 7-day cooldown AND uniqueness are enforced server-side. The local
  /// [canChangeUsername] check is UX only — it is no longer the gate, and a
  /// direct REST/client write to `username` is denied by the rules.
  /// Throws an [Exception] with the server message on rejection.
  Future<void> updateUsername(String newUsername) async {
    if (_uid == null) return;
    final trimmed = newUsername.trim();
    if (trimmed.length < 3 || trimmed.length > 20) {
      throw Exception('Username must be 3-20 characters.');
    }

    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('changeUsername');
    try {
      final res = await callable.call<Map<String, dynamic>>({
        'username': trimmed,
        ...AppUpdateService.instance.clientBuildStamp,
      });
      final applied = (res.data['username'] as String?)?.trim() ?? trimmed;
      // Server already updated Auth's displayName; keep the local user object
      // in sync so the UI does not show the old name until the next refresh.
      try {
        await _auth.currentUser?.updateDisplayName(applied);
      } catch (_) {
        // Cosmetic only — the Firestore field is authoritative.
      }
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Could not change username.');
    }
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
      final data = doc.data();
      // Spars are excluded so this matches the "SPAR - never counts" history
      // copy and the server-side getHeadToHeadRecord callable.
      if (data['challengeType'] == 'spar') continue;
      final outcome = data['outcome'] as String?;
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

  // ─── Rivalries ──────────────────────────────────────────────────────────────
  //
  // The rivalry overhaul organises multiplayer around PEOPLE, not modes:
  //   • rivalry docs (rivalries/{sortedUidPair}) hold best-of-5 series state,
  //     maintained server-side in _resolveChallengeCore (ranked duels only).
  //   • recentRivals() derives the "Your Rivalries" list from match history
  //     (one query, grouped client-side — no N+1 head-to-head reads).
  //   • Spars are created through the same createChallenge callable with
  //     challengeType 'spar' and zero stakes.

  /// Stable doc id for the rivalry between two users (order-independent).
  /// Mirrors the server's `${aUid}_${bUid}` construction in
  /// _resolveChallengeCore — change both together.
  static String rivalryDocId(String uid1, String uid2) {
    final pair = [uid1.trim(), uid2.trim()]..sort();
    return '${pair[0]}_${pair[1]}';
  }

  /// Live series state for the rivalry with [otherUid], or null when no
  /// ranked duel has ever been played between the pair (series start 1-0).
  /// firestore.rules permits reads only to the two participants.
  Stream<Map<String, dynamic>?> rivalryStream(String otherUid) {
    if (_uid == null || otherUid.isEmpty) return Stream.value(null);
    return _db
        .collection('rivalries')
        .doc(rivalryDocId(_uid!, otherUid))
        .snapshots()
        .map((s) => s.data());
  }

  /// Creates a friendly spar (zero stakes) vs a named rival. Returns the
  /// server payload `{ challengeId, questionIds }` — the caller takes the
  /// creator straight into the quiz page, exactly like the stake screen
  /// does for staked duels.
  ///
  /// Throws [FirebaseFunctionsException] with `resource-exhausted` /
  /// `daily_spar_limit_reached` when the daily spar budget is spent.
  Future<Map<String, dynamic>> createSparChallenge({
    required String animeTitle,
    required String opponentUid,
    required String opponentUsername,
  }) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('createChallenge');
    final res = await callable.call({
      'animeTitle': animeTitle.trim().toLowerCase(),
      'stakeAmount': 0,
      'wpStake': 0,
      'opponentUid': opponentUid,
      'opponentUsername': opponentUsername,
      'challengeType': 'spar',
      ...AppUpdateService.instance.clientBuildStamp,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Recent named rivals derived from ONE match-history query (no N+1).
  /// Ghost sessions (no opponentUid) are skipped. Sorted by most recent
  /// duel first. Each entry carries the running W/L/D vs that rival plus
  /// whether the last meeting was a loss (drives the "revenge" affordance).
  ///
  /// Defaults to a single [kRivalriesPageSize] window. Callers that page the
  /// list should use [recentRivalsWindow] so they can tell whether more exist.
  Future<List<RivalSummary>> recentRivals(
      {int limit = kRivalriesPageSize}) async {
    final page = await recentRivalsWindow(window: limit);
    return page.rivals;
  }

  /// One scanned window of the match history, grouped into named rivals.
  ///
  /// [hasMore] is true only when the scan FILLED [window] — i.e. the history
  /// may hold further matches. The grouped rival count cannot answer that
  /// question, because repeat matches against one rival collapse into a single
  /// entry while the raw match count stays at the limit; only the raw count can.
  ///
  /// Bounded by [window]: one query, no N+1, no listeners.
  Future<({List<RivalSummary> rivals, bool hasMore})> recentRivalsWindow({
    required int window,
  }) async {
    if (_uid == null) {
      return (rivals: const <RivalSummary>[], hasMore: false);
    }
    final snap = await _userDoc
        .collection('matches')
        .orderBy('timestamp', descending: true)
        .limit(window)
        .get();
    final hasMore = snap.docs.length == window;

    final byUid = <String, RivalSummary>{};
    final order = <String>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final rUid = (data['opponentUid'] as String?) ?? '';
      if (rUid.isEmpty || rUid == 'ghost') continue;
      final name = (data['opponent'] as String?) ?? 'Rival';
      final outcome = data['outcome'] as String?;
      final ts =
          (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
      var entry = byUid[rUid];
      if (entry == null) {
        entry = RivalSummary(
          uid: rUid,
          username: name,
          lastPlayed: ts,
          lastWasLoss: outcome == 'lose',
        );
        byUid[rUid] = entry;
        order.add(rUid);
      }
      if (outcome == 'win') {
        entry.wins++;
      } else if (outcome == 'lose') {
        entry.losses++;
      } else if (outcome == 'draw') {
        entry.draws++;
      }
    }
    return (
      rivals: [for (final uid in order) byUid[uid]!],
      hasMore: hasMore,
    );
  }

  /// Client mirror of the server's same-rival staked-duel cooldown, for UI
  /// preview only. Whole hours remaining (0 = allowed now).
  ///
  /// Applies the same two rules `createChallenge` does: the rolling
  /// `rivalCooldowns` map (with the legacy single-pair fallback), and no
  /// cooldown inside an active series that already has games. The server stays
  /// authoritative — a stale read here only mis-times a label, never a stake.
  Future<int> rivalDuelCooldownHours(
    String rivalUid, {
    required bool premium,
  }) async {
    final me = _uid;
    if (me == null || rivalUid.isEmpty) return 0;
    try {
      final meSnap = await _userDoc.get();
      final data = meSnap.data() ?? const <String, dynamic>{};
      final map = (data['rivalCooldowns'] as Map<String, dynamic>?) ?? const {};
      final raw = map[rivalUid];
      DateTime? at;
      if (raw is Timestamp) {
        at = raw.toDate();
      } else {
        final legacyUid = data['lastRivalUid'] as String?;
        final legacyAt = data['lastRivalChallenge'];
        if (legacyUid == rivalUid && legacyAt is Timestamp) {
          at = legacyAt.toDate();
        }
      }
      if (at == null) return 0;

      // Series-aware skip. Only reached when a cooldown entry exists, which
      // implies a prior staked duel, which implies the rivalry doc exists.
      try {
        final rSnap = await _db
            .collection('rivalries')
            .doc(rivalryDocId(me, rivalUid))
            .get();
        final r = rSnap.data();
        if (r != null) {
          final games = ((r['winsA'] as num?)?.toInt() ?? 0) +
              ((r['winsB'] as num?)?.toInt() ?? 0);
          if ((r['status'] as String?) == 'active' && games > 0) return 0;
        }
      } catch (_) {
        // Unreadable series treated as "no active series": the cooldown then
        // stands, which is the conservative choice the server mirrors.
      }

      final cooldown =
          premium ? kRivalCooldownPremiumHours : kRivalCooldownFreeHours;
      final left = cooldown - DateTime.now().difference(at).inHours;
      return left > 0 ? left : 0;
    } catch (_) {
      return 0;
    }
  }

  /// One-shot series state for a set of rivals, for the Rivalries list. Every
  /// pair doc includes the signed-in player, so the participants-only read rule
  /// holds. Missing/unreadable docs return no entry (no ranked duel yet). No
  /// listeners: one bounded round trip sized to the list actually on screen.
  Future<Map<String, Map<String, dynamic>>> rivalryStates(
    List<String> otherUids,
  ) async {
    final me = _uid;
    if (me == null || otherUids.isEmpty) return {};
    final entries = await Future.wait(otherUids.map((u) async {
      try {
        final snap = await _db
            .collection('rivalries')
            .doc(rivalryDocId(me, u))
            .get();
        return MapEntry<String, Map<String, dynamic>?>(u, snap.data());
      } catch (_) {
        return MapEntry<String, Map<String, dynamic>?>(u, null);
      }
    }));
    return {
      for (final e in entries)
        if (e.value != null) e.key: e.value!,
    };
  }

  /// Same-university, same-week players for the discovery sheet's Campus
  /// tab. Both filters satisfy the users read rule (same-week entrants).
  Future<List<RivalCandidate>> campusRivals({
    required String university,
    required String weekId,
    int limit = 20,
  }) async {
    if (_uid == null || university.isEmpty || weekId.isEmpty) return [];
    final snap = await _db
        .collection('users')
        .where('university', isEqualTo: university)
        .where('leaderboardEntryWeekId', isEqualTo: weekId)
        .limit(limit)
        .get();
    final out = <RivalCandidate>[];
    for (final doc in snap.docs) {
      if (doc.id == _uid) continue;
      if (kBoardHiddenUids.contains(doc.id)) continue; // ghost admin: never a rival
      final data = doc.data();
      out.add(RivalCandidate(
        uid: doc.id,
        username: (data['username'] as String?) ?? 'Rival',
        weeklyPoints: (data['weeklyPoints'] as num?)?.toInt() ?? 0,
        university: (data['university'] as String?) ?? '',
      ));
    }
    out.sort((a, b) => b.weeklyPoints.compareTo(a.weeklyPoints));
    return out;
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

  // ─── Leaderboard Payout Claim (client contract) ────────────────────────────
  //
  // Payouts are MANUAL: the app never moves money. The player submits bank
  // details; an admin transfers from their own bank and records it.
  //
  // Server is authoritative for eligibility, prize amount, payout status, and
  // `paid`. The client only submits bank details via the callable and reads
  // back claim state. No prize maths and no payout-security logic live here.

  /// Cached result of [listNigerianBanks]. Mirrors the existing
  /// [_weeklyPlayerCountCache] convention.
  static List<NigerianBank>? _banksCache;
  static DateTime? _banksCacheTime;

  /// Returns the verified Nigerian bank list from the `listNigerianBanks`
  /// callable. Kept because the player must be able to select a valid bank
  /// code for the admin to transfer to.
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
  /// `submitPayoutDetails` callable. The admin later transfers to this
  /// account by hand — no automated verification or payment happens.
  ///
  /// Returns [PayoutClaimResult] on success (including idempotent
  /// `'already_submitted'`). Throws [PayoutClaimException] for server
  /// rejections (already paid / marked as sent / expired / not a winner /
  /// invalid input) so the UI can render each state distinctly.
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
        // so a walled build cannot overwrite a destination account the admin
        // is about to pay. Web clients report platform 'web' and are exempt.
        ...AppUpdateService.instance.clientBuildStamp,
      });
      final data = Map<String, dynamic>.from(res.data as Map);
      return PayoutClaimResult(
        success: data['success'] == true,
        status: (data['status'] as String?) ?? 'pending',
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

  /// Live stream of the current user's reusable `payoutDetails` (owner-read
  /// only — writes are CF-only now). After a payout completes, the server
  /// purges sensitive fields, leaving only `accountMask` — the UI must
  /// therefore render masked values and never expect full details here.
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

  /// Updates one reusable payout-detail doc through the `savePayoutDetail`
  /// callable. The server validates the payload and appends a before/after
  /// entry to `payoutDetailAudit` in the same transaction. The UI must still
  /// gate this on lock state ([WinnerClaimSummary.isLocked]) — the server
  /// independently rejects destination changes once a claim is approved.
  Future<void> updatePayoutDetail(
    String docId, {
    required String accountNumber,
    required String bankCode,
    required String beneficiaryName,
  }) async {
    if (_uid == null) return;
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('savePayoutDetail');
    try {
      await callable.call<void>({
        'docId': docId,
        'accountNumber': accountNumber,
        'bankCode': bankCode,
        'beneficiaryName': beneficiaryName,
        ...AppUpdateService.instance.clientBuildStamp,
      });
    } on FirebaseFunctionsException catch (e) {
      throw PayoutClaimException(
        code: e.code,
        message: e.message ?? 'Could not save payout details.',
      );
    }
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

  // ─── Friends (callables only; reads of friendLinks are owner-direct) ─────
  //
  // All friendship writes go through the friend callables (Admin SDK bypasses
  // rules; firestore.rules denies client writes to friendships/friendLinks/
  // friendCodes). Every payload includes the client build stamp so the
  // server's Android gate applies (same pattern as submitPayoutDetails).

  Map<String, dynamic> _friendStamp(Map<String, dynamic> payload) => {
        ...payload,
        ...AppUpdateService.instance.clientBuildStamp,
      };

  Future<String> getMyFriendCode() async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('getMyFriendCode');
    final res = await callable.call(_friendStamp({}));
    final data = Map<String, dynamic>.from(res.data as Map);
    return (data['friendCode'] as String?) ?? '';
  }

  /// Returns 'pending' for a new request, or 'active' when the other player had
  /// already asked us (the request is accepted on the spot).
  Future<String> sendFriendRequest({String? code, String? uid}) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('sendFriendRequest');
    final res = await callable.call(_friendStamp({
      if (code != null) 'code': code,
      if (uid != null) 'uid': uid,
    }));
    final data = Map<String, dynamic>.from(res.data as Map);
    return (data['status'] as String?) ?? 'pending';
  }

  Future<void> respondFriendRequest({
    required String otherUid,
    required bool accept,
  }) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('respondFriendRequest');
    await callable.call(_friendStamp({'otherUid': otherUid, 'accept': accept}));
    // Accepting adds a friend row: drop the cached board so it shows now.
    FriendsBoardFetch.invalidateFriendsBoardCache();
  }

  Future<void> cancelFriendRequest({required String otherUid}) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('cancelFriendRequest');
    await callable.call(_friendStamp({'otherUid': otherUid}));
  }

  Future<void> blockUser({required String otherUid}) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('blockUser');
    await callable.call(_friendStamp({'otherUid': otherUid}));
    FriendsBoardFetch.invalidateFriendsBoardCache();
  }

  Future<void> unblockUser({required String otherUid}) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('unblockUser');
    await callable.call(_friendStamp({'otherUid': otherUid}));
    FriendsBoardFetch.invalidateFriendsBoardCache();
  }

  Future<void> removeFriend({required String otherUid}) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('removeFriend');
    await callable.call(_friendStamp({'otherUid': otherUid}));
    // Removing takes a row away: drop the cached board so it disappears now.
    FriendsBoardFetch.invalidateFriendsBoardCache();
  }

  /// Every friendLinks doc the caller owns, in one read (all states). The Add
  /// Friend page derives its sections and its suggestion filter from this.
  /// Friends themselves come from the getFriendsBoard callable. One-shot.
  Future<List<FriendLink>> getFriendLinks() async {
    if (_uid == null) return [];
    final snap = await _userDoc.collection('friendLinks').get();
    return [for (final d in snap.docs) FriendLink.fromMap(d.id, d.data())];
  }

  /// Campus chip rank: the player's SEQUENTIAL position among same-campus,
  /// same-week players, using the exact ordering and tie rule as the Global
  /// board (`weeklyPoints DESC`, walk-and-count). A COUNT of "strictly greater
  /// than me" would be a *competition* rank (1,2,2,4) and disagree with the
  /// board on ties, so we walk instead — one tie rule across both surfaces.
  ///
  /// Returns null on any failure (the chip then shows the campus without a
  /// number — never an error state). Uses the existing
  /// (university, entryWeek, weeklyPoints DESC) composite index.
  Future<int?> campusRankCount({
    required String university,
    required String entryWeekId,
    required int myPoints,
  }) async {
    if (_uid == null || university.isEmpty || entryWeekId.isEmpty) return null;
    final uid = _uid!;
    try {
      var rank = 0;
      var found = false;
      DocumentSnapshot<Map<String, dynamic>>? cursor;
      for (var page = 0; page < 40; page++) {
        var query = _db
            .collection('users')
            .where('university', isEqualTo: university)
            .where('leaderboardEntryWeekId', isEqualTo: entryWeekId)
            .orderBy('weeklyPoints', descending: true);
        if (cursor != null) query = query.startAfterDocument(cursor);
        final snap = await query.limit(50).get();
        if (snap.docs.isEmpty) break;
        cursor = snap.docs.last;

        for (final doc in snap.docs) {
          if (kBoardHiddenUids.contains(doc.id)) continue;
          if (doc.id == uid) {
            found = true;
            break;
          }
          rank++;
        }
        if (found) break;
      }
      // Not present in the campus cohort (e.g. no campus entry this week):
      // fall back to the count-based position rather than inventing one lower.
      if (!found) {
        final snap = await _db
            .collection('users')
            .where('university', isEqualTo: university)
            .where('leaderboardEntryWeekId', isEqualTo: entryWeekId)
            .where('weeklyPoints', isGreaterThan: myPoints)
            .count()
            .get();
        return (snap.count ?? 0) + 1;
      }
      return rank + 1;
    } catch (e) {
      debugPrint('[FirestoreService] campusRankCount error: $e');
      return null;
    }
  }

  /// Preset nudge ("Your turn!" ping, server-templated text, no free text).
  /// Pass [challengeId] when known (challenge cards); omit it and the server
  /// nudges the pair's latest their-turn duel (Friends rows).
  /// Throws [FirebaseFunctionsException]: not_friends / not_their_turn /
  /// nothing_to_nudge / nudge_limit_reached / nudge_not_delivered. Success and
  /// nudge_limit_reached both update [FriendsBoardFetch.friendNudgesToday].
  Future<void> nudgeFriend({required String friendUid, String? challengeId}) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('nudgeFriend');
    try {
      await callable.call(_friendStamp({
        'friendUid': friendUid,
        if (challengeId != null) 'challengeId': challengeId,
      }));
    } on FirebaseFunctionsException catch (e) {
      // Today's nudge already went out (e.g. from another screen or device):
      // show it as sent rather than leaving a live button.
      if (e.message == 'nudge_limit_reached') {
        FriendsBoardFetch.markFriendNudgedToday(friendUid);
      }
      rethrow;
    }
    FriendsBoardFetch.markFriendNudgedToday(friendUid);
  }
}

/// Sanitized friend row returned by the getFriendsBoard callable.
///
/// weeklyPoints is null when the friend has no entry for the current week —
/// the tab renders "-" and sorts those rows last (same convention as the
/// Global tab's unranked rows).
class FriendBoardEntry {
  final String uid;
  final String username;
  final String university;
  final int? weeklyPoints;
  final String? entryWeekId;

  /// True when this friend owes a move on a shared duel, so a nudge will land.
  final bool theirTurn;

  /// True when I owe this friend a move on a shared duel ("Your move").
  final bool myTurn;

  /// True when I already nudged this friend today (WAT).
  final bool nudgedToday;

  /// True when this friend played a match today (WAT).
  final bool playedToday;

  const FriendBoardEntry({
    required this.uid,
    required this.username,
    required this.university,
    required this.weeklyPoints,
    required this.entryWeekId,
    this.theirTurn = false,
    this.myTurn = false,
    this.nudgedToday = false,
    this.playedToday = false,
  });

  factory FriendBoardEntry.fromMap(Map<String, dynamic> map) =>
      FriendBoardEntry(
        uid: (map['uid'] as String?) ?? '',
        username: (map['username'] as String?) ?? 'Deleted user',
        university: (map['university'] as String?) ?? '',
        weeklyPoints: (map['weeklyPoints'] as num?)?.toInt(),
        entryWeekId: map['entryWeekId'] as String?,
        theirTurn: map['theirTurn'] == true,
        myTurn: map['myTurn'] == true,
        nudgedToday: map['nudgedToday'] == true,
        playedToday: map['playedToday'] == true,
      );
}

/// One row of the caller's own friendLinks: a request in either direction, a
/// friend, or a block. [status] is one of incoming / outgoing / friend / blocked.
class FriendLink {
  final String uid;
  final String status;
  final String username;

  const FriendLink({
    required this.uid,
    required this.status,
    required this.username,
  });

  factory FriendLink.fromMap(String uid, Map<String, dynamic> map) =>
      FriendLink(
        uid: uid,
        status: (map['status'] as String?) ?? '',
        username: ((map['username'] as String?) ?? '').trim(),
      );
}

/// One cached fetch of the friends board: friend rows + when it was read.
/// Assembled by [fetchFriendsBoard]; the weekly page holds it as a
/// reassignable future on the same 6h cadence as the global snapshot.
class FriendsBoardData {
  final List<FriendBoardEntry> friends;
  final DateTime? fetchedAt;

  const FriendsBoardData({required this.friends, required this.fetchedAt});
}

extension FriendsBoardFetch on FirestoreService {
  static List<FriendBoardEntry>? _friendsCache;
  static DateTime? _friendsCacheAt;

  /// The friends board is re-read on demand (tab open / pull-to-refresh), not
  /// on a timer. This short TTL is the only floor: it absorbs rapid tab
  /// flipping and repeated opens without spending a callable per glance.
  static const Duration _friendsCacheTtl = Duration(minutes: 5);

  /// True while the cached board is still within its TTL. The page uses this to
  /// avoid re-assigning an identical future (which would flash a spinner) when
  /// nothing has aged out.
  bool get friendsBoardCacheFresh {
    final at = _friendsCacheAt;
    return _friendsCache != null &&
        at != null &&
        DateTime.now().difference(at) < _friendsCacheTtl;
  }

  /// Friend uids I already nudged today (WAT). The single source for every
  /// Nudge button: seeded by each board read, updated as soon as a nudge lands.
  static final ValueNotifier<Set<String>> friendNudgesToday =
      ValueNotifier<Set<String>>(<String>{});

  static Future<FriendsBoardData>? _inFlightBoard;

  /// Records a nudge to [friendUid] as sent today.
  static void markFriendNudgedToday(String friendUid) {
    friendNudgesToday.value = {...friendNudgesToday.value, friendUid};
  }

  /// Drops the cached board so the next fetch re-reads. Called by every
  /// mutating friend callable, so a new/removed/blocked friend shows up on the
  /// next tab open instead of waiting out a cache window.
  static void invalidateFriendsBoardCache() {
    _friendsCache = null;
    _friendsCacheAt = null;
    friendNudgesToday.value = <String>{};
  }

  /// Calls getFriendsBoard (zero writes server-side) and caches for
  /// [_friendsCacheTtl]. A forced call (pull-to-refresh / retry) bypasses the
  /// cache. Never throws: failures yield an empty list with a null fetchedAt so
  /// the tab shows its error state.
  Future<FriendsBoardData> fetchFriendsBoard({bool force = false}) {
    if (!force && friendsBoardCacheFresh) {
      return Future.value(FriendsBoardData(
          friends: _friendsCache!, fetchedAt: _friendsCacheAt));
    }
    // Several Nudge buttons can ask at once on a cold cache; share one read.
    return _inFlightBoard ??=
        _loadFriendsBoard().whenComplete(() => _inFlightBoard = null);
  }

  Future<FriendsBoardData> _loadFriendsBoard() async {
    final now = DateTime.now();
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getFriendsBoard');
      final res = await callable.call(
          {...AppUpdateService.instance.clientBuildStamp});
      final data = Map<String, dynamic>.from(res.data as Map);
      final raw = (data['friends'] as List?) ?? const [];
      final friends = raw
          .map((e) =>
              FriendBoardEntry.fromMap(Map<String, dynamic>.from(e as Map)))
          .where((e) => e.uid.isNotEmpty)
          .toList();
      _friendsCache = friends;
      _friendsCacheAt = now;
      friendNudgesToday.value = {
        for (final f in friends)
          if (f.nudgedToday) f.uid,
      };
      return FriendsBoardData(friends: friends, fetchedAt: now);
    } catch (e) {
      debugPrint('[FirestoreService] fetchFriendsBoard error: $e');
      return const FriendsBoardData(friends: [], fetchedAt: null);
    }
  }
}
