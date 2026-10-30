// lib/features/friends/friend_messages.dart
//
// Player-facing copy for friend callable errors. The server sends a stable
// snake_case code as the error message; known codes map to plain sentences and
// unknown codes never reach the screen raw.

import 'package:cloud_functions/cloud_functions.dart';

/// Mirrors FRIEND_MAX in functions/index.js.
const int kFriendLimit = 50;

final RegExp _rawCode = RegExp(r'^[a-z_]+$');

/// Message for any thrown error from a friend callable.
String friendErrorFrom(Object error) {
  if (error is FirebaseFunctionsException) {
    return friendErrorMessage(error.message ?? error.code);
  }
  return friendErrorMessage(error.toString());
}

String friendErrorMessage(String raw) {
  final s = raw.replaceFirst('Exception: ', '').trim();
  return switch (s) {
    'not_found' => 'No player found with that code.',
    'inbox_full' =>
      'They can\'t accept more requests right now. Try again later.',
    'request_limit_reached' =>
      'Daily request limit reached — 10 new requests per day.',
    'too_many_attempts' => 'Too many wrong codes today — try again tomorrow.',
    'already_friends' => 'You are already friends.',
    'already_pending' => 'A request is already pending.',
    'cannot_friend_yourself' => 'That\'s your own code!',
    'friend_limit_reached' =>
      'Your friend list is full ($kFriendLimit). Remove a friend to add more.',
    'peer_friend_limit' => 'They can\'t add more friends right now.',
    'request_cooldown' =>
      'They turned your last request down. You can ask again in a week.',
    'cannot_accept_own_request' =>
      'That request is waiting for them to answer.',
    'not_pending' => 'That request is no longer pending.',
    'not_your_outgoing_request' => 'That request is no longer yours to cancel.',
    'not_blocked' => 'That player isn\'t blocked any more.',
    'not_friends' => 'You are not friends yet.',
    'blocked' => 'You can\'t interact with this player.',
    'nudge_limit_reached' => 'You already nudged them today.',
    'nudge_not_delivered' => 'Couldn\'t reach them. Try again later.',
    'nothing_to_nudge' || 'not_their_turn' => 'Nothing needs them right now.',
    _ when s.isEmpty || _rawCode.hasMatch(s) =>
      'Something went wrong. Please try again.',
    _ => s,
  };
}
