import 'package:flutter_test/flutter_test.dart';

import 'package:quiz/core/services/firestore_service.dart';
import 'package:quiz/features/friends/friend_messages.dart';
import 'package:quiz/features/friends/friend_ranking.dart';

FriendBoardEntry _friend(
  String uid, {
  int? points,
  bool theirTurn = false,
  bool myTurn = false,
  bool nudgedToday = false,
  bool playedToday = false,
  String university = '',
}) =>
    FriendBoardEntry(
      uid: uid,
      username: uid.toUpperCase(),
      university: university,
      weeklyPoints: points,
      entryWeekId: null,
      theirTurn: theirTurn,
      myTurn: myTurn,
      nudgedToday: nudgedToday,
      playedToday: playedToday,
    );

void main() {
  group('friendErrorMessage', () {
    test('maps every friend code to a plain sentence', () {
      expect(friendErrorMessage('not_found'), 'No player found with that code.');
      expect(friendErrorMessage('already_pending'), 'A request is already pending.');
      expect(
        friendErrorMessage('friend_limit_reached'),
        'Your friend list is full ($kFriendLimit). Remove a friend to add more.',
      );
      expect(
        friendErrorMessage('peer_friend_limit'),
        'They can\'t add more friends right now.',
      );
      expect(
        friendErrorMessage('request_cooldown'),
        'They turned your last request down. You can ask again in a week.',
      );
      expect(friendErrorMessage('blocked'), 'You can\'t interact with this player.');
      expect(
        friendErrorMessage('nudge_limit_reached'),
        'You already nudged them today.',
      );
    });

    test('nudge turn codes share one message', () {
      expect(friendErrorMessage('nothing_to_nudge'), 'Nothing needs them right now.');
      expect(friendErrorMessage('not_their_turn'), 'Nothing needs them right now.');
    });

    test('a nudge that could not be pushed says so and can be retried', () {
      expect(
        friendErrorMessage('nudge_not_delivered'),
        'Couldn\'t reach them. Try again later.',
      );
    });

    test('strips the Exception prefix before matching', () {
      expect(
        friendErrorMessage('Exception: not_found'),
        'No player found with that code.',
      );
    });

    test('never shows a raw snake_case code the copy does not know', () {
      expect(
        friendErrorMessage('some_new_server_code'),
        'Something went wrong. Please try again.',
      );
      expect(friendErrorMessage(''), 'Something went wrong. Please try again.');
    });

    test('keeps a human-readable server message unchanged', () {
      expect(friendErrorMessage('Network is down.'), 'Network is down.');
    });
  });

  group('rankFriendsBoard', () {
    test('ranks the signed-in player together with friends, highest first', () {
      final rows = rankFriendsBoard(
        friends: [_friend('b', points: 300), _friend('c', points: 900)],
        myPoints: 500,
      );
      expect(rows.map((r) => r.name).toList(), ['C', 'You', 'B']);
      expect(rows.map((r) => r.rank).toList(), [1, 2, 3]);
      expect(rows[1].isMe, isTrue);
    });

    test('numbering is sequential — a tie does not share a rank', () {
      final rows = rankFriendsBoard(
        friends: [_friend('b', points: 500), _friend('c', points: 100)],
        myPoints: 500,
      );
      expect(rows.map((r) => r.rank).toList(), [1, 2, 3]);
      // Own row wins a tie on the board.
      expect(rows.first.isMe, isTrue);
    });

    test('friends with no entry this week sort last with no rank', () {
      final rows = rankFriendsBoard(
        friends: [_friend('b', points: null), _friend('c', points: 10)],
        myPoints: 0,
      );
      expect(rows.last.uid, 'b');
      expect(rows.last.points, isNull);
      expect(rows.last.rank, isNull);
    });

    test('keeps each friend\'s turn flag and university', () {
      final rows = rankFriendsBoard(
        friends: [_friend('b', points: 5, theirTurn: true, university: 'UNILAG')],
        myPoints: 1,
      );
      final b = rows.firstWhere((r) => !r.isMe);
      expect(b.theirTurn, isTrue);
      expect(b.subtitle, 'UNILAG');
      expect(rows.firstWhere((r) => r.isMe).theirTurn, isFalse);
    });

    test('an empty friend list still returns the signed-in player alone', () {
      final rows = rankFriendsBoard(friends: const [], myPoints: 42);
      expect(rows, hasLength(1));
      expect(rows.single.isMe, isTrue);
      expect(rows.single.rank, 1);
    });

    test('friends where I owe a move sort first; ranks still follow points', () {
      final rows = rankFriendsBoard(
        friends: [
          _friend('b', points: 900),
          _friend('c', points: 300, myTurn: true),
          _friend('d', points: 100, myTurn: true),
        ],
        myPoints: 500,
      );
      expect(rows.map((r) => r.name).toList(), ['C', 'D', 'B', 'You']);
      expect(rows.map((r) => r.rank).toList(), [3, 4, 1, 2]);
    });

    test('keeps the points order inside each group', () {
      final rows = rankFriendsBoard(
        friends: [
          _friend('b', points: 50, myTurn: true),
          _friend('c', points: 200),
          _friend('d', points: 10, myTurn: true),
          _friend('e', points: 150),
        ],
        myPoints: 0,
      );
      expect(rows.map((r) => r.name).toList(), ['B', 'D', 'C', 'E', 'You']);
    });

    test('carries nudged and played flags onto the row', () {
      final rows = rankFriendsBoard(
        friends: [_friend('b', points: 5, nudgedToday: true, playedToday: true)],
        myPoints: 1,
      );
      final b = rows.firstWhere((r) => !r.isMe);
      expect(b.nudgedToday, isTrue);
      expect(b.playedToday, isTrue);
      expect(b.myTurn, isFalse);
    });
  });

  group('FriendBoardEntry.fromMap', () {
    test('reads the server turn, nudge and played fields', () {
      final e = FriendBoardEntry.fromMap({
        'uid': 'b',
        'username': 'B',
        'university': '',
        'weeklyPoints': 7,
        'entryWeekId': null,
        'theirTurn': true,
        'myTurn': true,
        'nudgedToday': true,
        'playedToday': true,
      });
      expect(e.theirTurn, isTrue);
      expect(e.myTurn, isTrue);
      expect(e.nudgedToday, isTrue);
      expect(e.playedToday, isTrue);
    });

    test('an older server without the new fields reads them as false', () {
      final e = FriendBoardEntry.fromMap({'uid': 'b', 'username': 'B'});
      expect(e.myTurn, isFalse);
      expect(e.nudgedToday, isFalse);
      expect(e.playedToday, isFalse);
    });
  });

  group('shared nudge state', () {
    tearDown(() => FriendsBoardFetch.invalidateFriendsBoardCache());

    test('marking a friend nudged adds only that friend', () {
      FriendsBoardFetch.invalidateFriendsBoardCache();
      FriendsBoardFetch.markFriendNudgedToday('b');
      FriendsBoardFetch.markFriendNudgedToday('c');
      expect(FriendsBoardFetch.friendNudgesToday.value, {'b', 'c'});
    });

    test('notifies listeners so every Nudge button updates at once', () {
      FriendsBoardFetch.invalidateFriendsBoardCache();
      var notified = 0;
      void listener() => notified++;
      FriendsBoardFetch.friendNudgesToday.addListener(listener);
      addTearDown(() => FriendsBoardFetch.friendNudgesToday.removeListener(listener));

      FriendsBoardFetch.markFriendNudgedToday('b');
      expect(notified, 1);
    });

    test('clearing the board cache (sign-in or sign-out) forgets today\'s nudges', () {
      FriendsBoardFetch.markFriendNudgedToday('b');
      FriendsBoardFetch.invalidateFriendsBoardCache();
      expect(FriendsBoardFetch.friendNudgesToday.value, isEmpty);
    });
  });
}
