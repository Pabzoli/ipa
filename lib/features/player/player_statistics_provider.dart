import 'package:flutter/material.dart';
import '../../core/services/firestore_service.dart';

// ─── Data Model ───────────────────────────────────────────────────────────────
class PlayerStatistics {
  int gamesWon;
  int gamesLost;
  int gamesDraw;
  int hseStaked;   // highest single stake in one match (AC)
  int hseWon;      // highest single match AC won
  int hseLost;     // highest single match AC lost
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

  /// FIX: use (as num?)?.toInt() so that Firestore doubles never cause a
  /// "type 'double' is not a subtype of type 'int'" cast error.
  factory PlayerStatistics.fromMap(Map<String, dynamic> m) => PlayerStatistics(
    gamesWon:    (m['gamesWon']    as num?)?.toInt() ?? 0,
    gamesLost:   (m['gamesLost']   as num?)?.toInt() ?? 0,
    gamesDraw:   (m['gamesDraw']   as num?)?.toInt() ?? 0,
    hseStaked:   (m['hseStaked']   as num?)?.toInt() ?? 0,
    hseWon:      (m['hseWon']      as num?)?.toInt() ?? 0,
    hseLost:     (m['hseLost']     as num?)?.toInt() ?? 0,
    gamesPlayed: (m['gamesPlayed'] as num?)?.toInt() ?? 0,
  );
}

// ─── Provider ─────────────────────────────────────────────────────────────────
class PlayerStatisticsProvider extends ChangeNotifier {
  PlayerStatistics _stats = PlayerStatistics();

  PlayerStatistics get playerStatistics => _stats;

  // ── Achievement flags (updated for AC economy) ────────────────────────────
  /// Win 50 games
  bool get won50Games     => _stats.gamesWon    >= 50;
  /// Lose 50 games
  bool get lost50Games    => _stats.gamesLost   >= 50;
  /// Play 100 games
  bool get played100Games => _stats.gamesPlayed >= 100;
  /// Stake 500+ AC in a single match (requires index.js fix: track stake not betAmount)
  bool get staked500AC    => _stats.hseStaked   >= 500;
  /// Win 1,000+ AC in a single match (floor(stake * 0.8) ≥ 1000 → stake ≥ 1250 AC)
  bool get won1000AC      => _stats.hseWon      >= 1000;

  /// Loads stats from Firestore. Call once after login (e.g. from HomePage.initState).
  Future<void> init() async {
    try {
      final map = await FirestoreService.instance.loadUserStats();
      if (map.isNotEmpty) {
        _stats = PlayerStatistics.fromMap(map);
        notifyListeners();
      }
    } catch (_) {
      // Silently fail — stats stay at defaults
    }
  }

  void updatePlayerStatistics(PlayerStatistics newStats) {
    _stats = newStats;
    notifyListeners();
    _saveToFirestore();
  }

  Future<void> _saveToFirestore() async {
    try {
      await FirestoreService.instance.updateStats(_stats.toMap());
    } catch (_) {
      // Silently fail — local state already updated
    }
  }
}