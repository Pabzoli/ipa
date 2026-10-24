// lib/features/player/player_statistics_provider.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/services/firestore_service.dart';
import '../multiplayer/challenge_model.dart';

// ─── Model: PlayerStatistics ──────────────────────────────────────────────────

/// Number of most-recent `users/{uid}/matches` docs the Stats tab aggregates.
///
/// The match subcollection grows without bound, so streaming all of it on every
/// sign-in was an unbounded read. The server-maintained `users/{uid}.stats` map
/// cannot replace it (it uses different semantics and omits quick/rival WP
/// splits), so we cap the window instead. Stats therefore reflect the last
/// [kPlayerStatsMatchWindow] matches rather than strict all-time totals.
const int kPlayerStatsMatchWindow = 500;

class PlayerStatistics {
  // ── AC match stats ──────────────────────────────────────────────────────────
  final int gamesPlayed;
  final int gamesWon;
  final int gamesDraw;
  final int gamesLost;
  final int hseWon; // highest single match AC gain (win)
  final int hseLost; // highest single match AC loss
  final int hseStaked; // highest single match AC stake

  // ── WP stats ────────────────────────────────────────────────────────────────
  final int wpWon; // total WP won (credits from wins/draws)
  final int wpLost; // total WP lost (stakes lost in losses)
  final int wpStakedTotal; // total WP staked across all matches
  final int hseWpWon; // highest single match WP gain
  final int hseWpLost; // highest single match WP loss (stake lost)
  final int hseWpStaked; // highest single match WP stake

  // ── Match breakdown (every counted match lands in exactly one bucket) ─────
  final int quickWins;
  final int quickDraws;
  final int quickLosses;
  final int codeWins;
  final int codeDraws;
  final int codeLosses;
  final int rivalWins;
  final int rivalDraws;
  final int rivalLosses;

  const PlayerStatistics({
    required this.gamesPlayed,
    required this.gamesWon,
    required this.gamesDraw,
    required this.gamesLost,
    required this.hseWon,
    required this.hseLost,
    required this.hseStaked,
    required this.wpWon,
    required this.wpLost,
    required this.wpStakedTotal,
    required this.hseWpWon,
    required this.hseWpLost,
    required this.hseWpStaked,
    required this.quickWins,
    required this.quickDraws,
    required this.quickLosses,
    required this.codeWins,
    required this.codeDraws,
    required this.codeLosses,
    required this.rivalWins,
    required this.rivalDraws,
    required this.rivalLosses,
  });

  static const empty = PlayerStatistics(
    gamesPlayed: 0,
    gamesWon: 0,
    gamesDraw: 0,
    gamesLost: 0,
    hseWon: 0,
    hseLost: 0,
    hseStaked: 0,
    wpWon: 0,
    wpLost: 0,
    wpStakedTotal: 0,
    hseWpWon: 0,
    hseWpLost: 0,
    hseWpStaked: 0,
    quickWins: 0,
    quickDraws: 0,
    quickLosses: 0,
    codeWins: 0,
    codeDraws: 0,
    codeLosses: 0,
    rivalWins: 0,
    rivalDraws: 0,
    rivalLosses: 0,
  );

  /// Match type as the server records it. Docs written before `challengeType`
  /// existed fall back to the same inference resolveChallengeCore uses.
  static String _matchType(Map<String, dynamic> data) {
    final explicit = data['challengeType'] as String?;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (data['isQuickMatch'] == true) return 'quick';
    return ((data['wpStake'] as num?) ?? 0) > 0 ? 'rival' : 'code';
  }

  factory PlayerStatistics.fromMatches(List<QueryDocumentSnapshot> matches) {
    int gamesPlayed = 0, gamesWon = 0, gamesDraw = 0, gamesLost = 0;
    int hseWon = 0, hseLost = 0, hseStaked = 0;
    int wpWon = 0, wpLost = 0, wpStakedTotal = 0;
    int hseWpWon = 0, hseWpLost = 0, hseWpStaked = 0;
    int quickWins = 0, quickDraws = 0, quickLosses = 0;
    int codeWins = 0, codeDraws = 0, codeLosses = 0;
    int rivalWins = 0, rivalDraws = 0, rivalLosses = 0;

    for (final doc in matches) {
      final data = doc.data() as Map<String, dynamic>;
      final type = _matchType(data);
      // Spars never count toward W/D/L or AC/WP stats — the server gates the
      // same way (functions/index.js `!isSpar` on stats.*) — so skip them here
      // so the totals and breakdown agree with the server.
      if (type == 'spar') continue;

      final outcome = data['outcome'] as String? ?? 'lose';
      final isQuick = type == 'quick';

      gamesPlayed++;

      if (outcome == 'win') {
        gamesWon++;
        if (isQuick) {
          quickWins++;
        } else if (type == 'rival') {
          rivalWins++;
        } else {
          codeWins++;
        }
      } else if (outcome == 'draw') {
        gamesDraw++;
        if (isQuick) {
          quickDraws++;
        } else if (type == 'rival') {
          rivalDraws++;
        } else {
          codeDraws++;
        }
      } else {
        gamesLost++;
        if (isQuick) {
          quickLosses++;
        } else if (type == 'rival') {
          rivalLosses++;
        } else {
          codeLosses++;
        }
      }

      // ── AC stats ────────────────────────────────────────────────────────────
      final stake = (data['stakeAmount'] as num?)?.toInt() ?? 0;
      if (stake > hseStaked) hseStaked = stake;

      final isWin = outcome == 'win';
      final isDraw = outcome == 'draw';

      // Net balance delta, not the settlement credit. Must match the History
      // ledger exactly, or the two tabs disagree about the same match — the AC
      // draw fee in particular is stake − floor(stake × 0.95), not
      // floor(stake × 0.05), so the old inline formula was off by one on any
      // stake that is not a multiple of 20.
      final acDelta = ChallengeModel.acLedgerDelta(
        isQuickMatch: isQuick,
        stakeAmount: stake,
        pointsChange: (data['pointsChange'] as num?)?.toInt() ?? 0,
        won: isWin,
        isDraw: isDraw,
      );

      if (acDelta > 0 && acDelta > hseWon) hseWon = acDelta;
      if (acDelta < 0 && acDelta.abs() > hseLost) hseLost = acDelta.abs();

      // ── WP stats ────────────────────────────────────────────────────────────
      final wpStake = (data['wpStake'] as num?)?.toInt() ?? 0;
      if (wpStake > 0) {
        wpStakedTotal += wpStake;
        if (wpStake > hseWpStaked) hseWpStaked = wpStake;
      }

      // `wpChange` is the stake-settlement credit and is never negative on the
      // server, so branching on it directly left wpLost and hseWpLost pinned
      // at 0 forever and made wpWon miss the flat participation bonus. The net
      // delta below carries the stake that was debited at create/join time,
      // which is what makes a rival loss register.
      final wpDelta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: isQuick,
        wpStake: wpStake,
        wpChange: (data['wpChange'] as num?)?.toInt() ?? 0,
        wpAwarded: (data['wpAwarded'] as num?)?.toInt(),
        won: isWin,
        isDraw: isDraw,
      );

      if (wpDelta > 0) {
        wpWon += wpDelta;
        if (wpDelta > hseWpWon) hseWpWon = wpDelta;
      } else if (wpDelta < 0) {
        final lost = wpDelta.abs();
        wpLost += lost;
        if (lost > hseWpLost) hseWpLost = lost;
      }
    }

    return PlayerStatistics(
      gamesPlayed: gamesPlayed,
      gamesWon: gamesWon,
      gamesDraw: gamesDraw,
      gamesLost: gamesLost,
      hseWon: hseWon,
      hseLost: hseLost,
      hseStaked: hseStaked,
      wpWon: wpWon,
      wpLost: wpLost,
      wpStakedTotal: wpStakedTotal,
      hseWpWon: hseWpWon,
      hseWpLost: hseWpLost,
      hseWpStaked: hseWpStaked,
      quickWins: quickWins,
      quickDraws: quickDraws,
      quickLosses: quickLosses,
      codeWins: codeWins,
      codeDraws: codeDraws,
      codeLosses: codeLosses,
      rivalWins: rivalWins,
      rivalDraws: rivalDraws,
      rivalLosses: rivalLosses,
    );
  }
}

// ─── Provider ──────────────────────────────────────────────────────────────────

class PlayerStatisticsProvider extends ChangeNotifier {
  PlayerStatistics _playerStatistics = PlayerStatistics.empty;
  bool _loading = true;
  String? _error;
  StreamSubscription<QuerySnapshot>? _matchSubscription;
  StreamSubscription<User?>? _authSubscription;
  bool _initialized = false;
  String? _currentUid;

  // ── Server-authoritative achievement state (users/{uid}.stats +
  //    users/{uid}.achievementsGranted from Stage 13) ─────────────────────────
  StreamSubscription<Map<String, dynamic>>? _achievementsSubscription;
  Map<String, dynamic> _serverStats = const {};
  Map<String, List<int>> _achievementsGranted = const {};

  PlayerStatistics get playerStatistics => _playerStatistics;
  bool get loading => _loading;
  String? get error => _error;

  // Current server value for each tracked achievement stat (0 when absent).
  int achievementStatValue(String statKey) =>
      ((_serverStats[statKey] as num?)?.toInt()) ?? 0;

  // Thresholds already granted per achievement stat, from the server map.
  List<int> grantedThresholds(String statKey) =>
      _achievementsGranted[statKey] ?? const [];

  PlayerStatisticsProvider() {
    // Do NOT auto-start – wait for explicit init() call.
  }

  void init() {
    if (_initialized) return;
    _initialized = true;
    _listenToAuthChanges();
  }

  void _listenToAuthChanges() {
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      final newUid = user?.uid;
      if (_currentUid != newUid) {
        _currentUid = newUid;
        _restartMatchSubscription();
        _restartAchievementsSubscription();
      }
    });
  }

  void _restartAchievementsSubscription() {
    _achievementsSubscription?.cancel();
    _achievementsSubscription = null;
    _serverStats = const {};
    _achievementsGranted = const {};

    final uid = _currentUid;
    if (uid == null) return;

    _achievementsSubscription =
        FirestoreService.instance.achievementsStream().listen(
      (payload) {
        final rawStats = payload['stats'] as Map<String, dynamic>? ?? const {};
        final rawGranted =
            payload['achievementsGranted'] as Map<String, dynamic>? ?? const {};

        final granted = <String, List<int>>{};
        rawGranted.forEach((key, value) {
          if (value is List) {
            granted[key] = value
                .whereType<num>()
                .map((e) => e.toInt())
                .toList(growable: false);
          }
        });

        _serverStats = rawStats;
        _achievementsGranted = granted;
        notifyListeners();
      },
      onError: (_) {
        // Achievements are non-critical UI — keep last-known-good values.
      },
    );
  }

  void _restartMatchSubscription() {
    _matchSubscription?.cancel();
    _matchSubscription = null;

    final uid = _currentUid;
    if (uid == null) {
      _loading = false;
      _playerStatistics = PlayerStatistics.empty;
      notifyListeners();
      return;
    }

    _loading = true;
    notifyListeners();

    final matchesRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('matches')
        .orderBy('timestamp', descending: true)
        .limit(kPlayerStatsMatchWindow);

    _matchSubscription = matchesRef.snapshots().listen(
      (snapshot) {
        final matches = snapshot.docs;
        if (matches.isEmpty) {
          _playerStatistics = PlayerStatistics.empty;
        } else {
          try {
            _playerStatistics = PlayerStatistics.fromMatches(matches);
          } catch (e) {
            _error = e.toString();
            _playerStatistics = PlayerStatistics.empty;
          }
        }
        _loading = false;
        notifyListeners();
      },
      onError: (error) {
        _error = error.toString();
        _loading = false;
        _playerStatistics = PlayerStatistics.empty;
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _matchSubscription?.cancel();
    _achievementsSubscription?.cancel();
    super.dispose();
  }
}
