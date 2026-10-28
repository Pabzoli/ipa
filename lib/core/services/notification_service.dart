// lib/core/services/notification_service.dart
//
// MINIMAL FCM infrastructure (Phase 3) — only what the winner payout flow
// needs. Not a general notification framework.
//
//   • FCM permission request + token registration
//   • saves the token to users/{uid}.fcmToken (server reads it in sendToUser)
//   • foreground messages → local banner via flutter_local_notifications
//   • tap (foreground / background / terminated) → payout claim/result screen
//     using the existing Navigator/MaterialPageRoute architecture
//
// Server payout messages carry `{notification: {title, body}}` plus a data
// payload (see sendToUser/sendToTokens in functions/index.js). A tap WITH a
// `weekId` opens that week's PayoutClaimPage; a `leaderboard` tap opens the
// weekly leaderboard; a `friend_request` tap opens Add Friend. Duplicate taps
// are coalesced (see [_dedupeWindow]) so two copies of a screen never stack.

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../features/leaderboard/weekly_leaderboard_page.dart';
import '../../features/friends/add_friend_page.dart';
import '../../features/prizes/payout_claim_page.dart';
import '../widgets/app_page_route.dart';
import 'firestore_service.dart';

/// Background entry-point. Must stay a top-level function. Does no UI work —
/// its registration is what lets taps on background/terminated notifications
/// surface through `getInitialMessage()` / `onMessageOpenedApp`.
@pragma('vm:entry-point')
Future<void> _fcmBackgroundHandler(RemoteMessage message) async {}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _channelId = 'payouts';
  static const _channelName = 'Prizes & payouts';

  final _local = FlutterLocalNotificationsPlugin();
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _inited = false;

  /// Coalesces duplicate navigations. The same tap can arrive through more than
  /// one path (foreground banner then app-open), and two notification taps used
  /// to push two independent copies of the same screen — each with its own
  /// reads. The destination key plus a short window collapses those.
  String _lastNavKey = '';
  DateTime? _lastNavAt;
  static const Duration _dedupeWindow = Duration(seconds: 2);

  /// Idempotent. Call once the authenticated shell exists (see _AppShell).
  Future<void> init({
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {
    if (_inited) return;
    _inited = true;
    _navigatorKey = navigatorKey;

    try {
      FirebaseMessaging.onBackgroundMessage(_fcmBackgroundHandler);

      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      const androidChannel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        importance: Importance.high,
      );
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);

      await _local.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (response) {
          final route = _splitPayload(response.payload);
          _navigateToClaim(route.weekId, type: route.type);
        },
      );

      // Foreground presentation (iOS); Android banners go through _local.
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await FirestoreService.instance.saveFcmToken(token);
      }
      FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        FirestoreService.instance.saveFcmToken(t);
      });

      // Foreground message → local banner (tap carries the weekId, if any).
      FirebaseMessaging.onMessage.listen((message) {
        _showForegroundBanner(message);
      });

      // Tap on a background notification.
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        _navigateToClaim(_weekIdFrom(message), type: _typeFrom(message));
      });

      // Cold start from a terminated-state notification tap.
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        // Post-frame: the navigator must exist before we push.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navigateToClaim(_weekIdFrom(initial), type: _typeFrom(initial));
        });
      }
    } catch (_) {
      // Notifications are best-effort — never break startup.
    }
  }

  static String? _weekIdFrom(RemoteMessage message) {
    final raw = message.data['weekId'];
    if (raw is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
      return raw;
    }
    return null;
  }

  static String? _typeFrom(RemoteMessage message) {
    final raw = message.data['type'];
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  /// Local-notification payload is `type|weekId` (either may be empty). The
  /// plain FCM `data` map is not available on the local banner's tap callback,
  /// so the routing fields are encoded into the payload string.
  static String _payloadFor(RemoteMessage message) =>
      '${_typeFrom(message) ?? ''}|${_weekIdFrom(message) ?? ''}';

  static ({String? type, String? weekId}) _splitPayload(String? payload) {
    if (payload == null || payload.isEmpty) {
      return (type: null, weekId: null);
    }
    final parts = payload.split('|');
    final type = parts.isNotEmpty && parts[0].isNotEmpty ? parts[0] : null;
    final weekId = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
    return (type: type, weekId: weekId);
  }

  Future<void> _showForegroundBanner(RemoteMessage message) async {
    try {
      final notification = message.notification;
      if (notification == null) return;
      await _local.show(
        notification.hashCode,
        notification.title ?? 'AnimeQuiz',
        notification.body ?? '',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        payload: _payloadFor(message),
      );
    } catch (_) {
      // Banner failure must never surface to the user as an error.
    }
  }

  void _navigateToClaim(String? weekId, {String? type}) {
    final nav = _navigatorKey?.currentState;
    if (nav == null) return;

    final hasWeek = weekId != null && weekId.isNotEmpty;
    final key = type == 'friend_request'
        ? 'friends'
        : hasWeek
            ? 'claim:$weekId'
            : 'leaderboard';

    // Drop a repeat of the same destination within the window.
    final now = DateTime.now();
    if (_lastNavKey == key &&
        _lastNavAt != null &&
        now.difference(_lastNavAt!) < _dedupeWindow) {
      return;
    }
    _lastNavKey = key;
    _lastNavAt = now;

    if (type == 'friend_request') {
      nav.push(AppPageRoute(builder: (_) => const AddFriendPage()));
      return;
    }

    final Widget page = hasWeek
        ? PayoutClaimPage(weekId: weekId)
        : const WeeklyLeaderboardPage();
    nav.push(AppPageRoute(builder: (_) => page));
  }
}
