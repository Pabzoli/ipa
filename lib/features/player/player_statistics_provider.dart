import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/services/firestore_service.dart';

// ─── Data Model ───────────────────────────────────────────────────────────────
class PlayerStatistics {
  int gamesWon;
  int gamesLost;
  int gamesDraw;
  int hseStaked;
  int hseWon;
  int hseLost;
  int gamesPlayed;

  PlayerStatistics({
    this.gamesWon    = 0,
    this.gamesLost   = 0,
    this.gamesDraw   = 0,
    this.hseStaked   = 0,
    this.hseWon      = 0,
    this.hseLost     = 0,
    this.gamesPlayed = 0,
  });

  Map<String, dynamic> toMap() => {
    'gamesWon':    gamesWon,
    'gamesLost':   gamesLost,
    'gamesDraw':   gamesDraw,
    'hseStaked':   hseStaked,
    'hseWon':      hseWon,
    'hseLost':     hseLost,
    'gamesPlayed': gamesPlayed,
  };

  factory PlayerStatistics.fromMap(Map<String, dynamic> m) => PlayerStatistics(
    gamesWon:    (m['gamesWon']    as int?) ?? 0,
    gamesLost:   (m['gamesLost']   as int?) ?? 0,
    gamesDraw:   (m['gamesDraw']   as int?) ?? 0,
    hseStaked:   (m['hseStaked']   as int?) ?? 0,
    hseWon:      (m['hseWon']      as int?) ?? 0,
    hseLost:     (m['hseLost']     as int?) ?? 0,
    gamesPlayed: (m['gamesPlayed'] as int?) ?? 0,
  );
}

// ─── Provider ─────────────────────────────────────────────────────────────────
class PlayerStatisticsProvider extends ChangeNotifier {
  PlayerStatistics _stats = PlayerStatistics();
  StreamSubscription<Map<String, dynamic>>? _statsSub;

  PlayerStatistics get playerStatistics => _stats;

  // Achievements
  bool get won50Games      => _stats.gamesWon    >= 50;
  bool get lost50Games     => _stats.gamesLost   >= 50;
  bool get played100Games  => _stats.gamesPlayed >= 100;
  bool get won5000Score    => _stats.hseWon      >= 5000;
  bool get lost2500Score   => _stats.hseLost     >= 2500;

  /// Subscribes to the live stats stream from Firestore.
  /// Call once after login (e.g. from HomePage.initState).
  /// Stats will now auto-update whenever a challenge resolves,
  /// even if the current user was the first to submit their score.
  void init() {
    _statsSub?.cancel(); // guard against double-init
    _statsSub = FirestoreService.instance.statsStream().listen(
      (map) {
        if (map.isNotEmpty) {
          _stats = PlayerStatistics.fromMap(map);
          notifyListeners();
        }
      },
      onError: (_) {
        // Silently fail — stats stay at current values
      },
    );
  }

  @override
  void dispose() {
    _statsSub?.cancel();
    super.dispose();
  }
}