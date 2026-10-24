// lib/features/friends/friend_ranking.dart
//
// Orders the Friends board: the signed-in player and their friends, by weekly
// points. Pure Dart so the rules are unit-tested without a widget tree.

import '../../core/services/firestore_service.dart';

class FriendRankRow {
  /// Empty for the signed-in player's own row.
  final String uid;
  final String name;
  final String subtitle;

  /// Null when [points] is null. Numbering is SEQUENTIAL (1, 2, 3) — the same
  /// tie rule as the Global weekly board and the campus chip, so one position
  /// never shows two different numbers across surfaces.
  final int? points;
  final int? rank;
  final bool isMe;
  final bool theirTurn;
  final bool myTurn;
  final bool nudgedToday;
  final bool playedToday;

  const FriendRankRow({
    required this.uid,
    required this.name,
    required this.subtitle,
    required this.points,
    required this.rank,
    required this.isMe,
    required this.theirTurn,
    this.myTurn = false,
    this.nudgedToday = false,
    this.playedToday = false,
  });
}

/// Ranks by points, then orders the display: friends where I owe a move come
/// first, the rest keep their points order. Ranks are the weekly positions, so
/// a row lifted by "Your move" can show a higher number below a lower one.
List<FriendRankRow> rankFriendsBoard({
  required List<FriendBoardEntry> friends,
  required int myPoints,
  String myLabel = 'You',
}) {
  final unranked = [
    FriendRankRow(
      uid: '',
      name: myLabel,
      subtitle: '',
      points: myPoints,
      rank: null,
      isMe: true,
      theirTurn: false,
    ),
    for (final f in friends)
      FriendRankRow(
        uid: f.uid,
        name: f.username,
        subtitle: f.university,
        points: f.weeklyPoints,
        rank: null,
        isMe: false,
        theirTurn: f.theirTurn,
        myTurn: f.myTurn,
        nudgedToday: f.nudgedToday,
        playedToday: f.playedToday,
      ),
  ]..sort((a, b) {
      final byPoints = (b.points ?? -1).compareTo(a.points ?? -1);
      if (byPoints != 0) return byPoints;
      if (a.isMe != b.isMe) return a.isMe ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  final ranked = <FriendRankRow>[];
  for (var i = 0; i < unranked.length; i++) {
    final row = unranked[i];
    final points = row.points;
    // Sequential, matching the Global board: a tie does not share a number.
    final int? rank = points == null ? null : i + 1;
    ranked.add(FriendRankRow(
      uid: row.uid,
      name: row.name,
      subtitle: row.subtitle,
      points: points,
      rank: rank,
      isMe: row.isMe,
      theirTurn: row.theirTurn,
      myTurn: row.myTurn,
      nudgedToday: row.nudgedToday,
      playedToday: row.playedToday,
    ));
  }

  // Stable on the points order: "Your move" rows lift to the top, everything
  // else keeps its position.
  final indexed = [for (var i = 0; i < ranked.length; i++) (i, ranked[i])];
  indexed.sort((a, b) {
    final aMove = !a.$2.isMe && a.$2.myTurn ? 0 : 1;
    final bMove = !b.$2.isMe && b.$2.myTurn ? 0 : 1;
    if (aMove != bMove) return aMove.compareTo(bMove);
    return a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}
