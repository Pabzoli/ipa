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
// Server payout messages carry only `{notification: {title, body}}` (see
// sendToUser in functions/index.js) — no `weekId` data payload. So a tap
// WITH a weekId opens that week's PayoutClaimPage; a tap WITHOUT one opens
// the weekly leaderboard, whose "My prizes" banner lists every claimable
// cycle. Existing startup/auth flow is untouched.
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../features/leaderboard/weekly_leaderboard_page.dart';
import '../../features/friends/add_friend_page.dart';
import '../../features/prizes/payout_claim_page.dart';
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
          _navigateToClaim(response.payload);
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
        _navigateToClaim(_weekIdFrom(message),
            type: _typeFrom(message));
      });

      // Cold start from a terminated-state notification tap.
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        // Post-frame: the navigator must exist before we push.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navigateToClaim(_weekIdFrom(initial),
              type: _typeFrom(initial));
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
        payload: _weekIdFrom(message) ?? '',
      );
    } catch (_) {
      // Banner failure must never surface to the user as an error.
    }
  }

  void _navigateToClaim(String? weekId, {String? type}) {
    final nav = _navigatorKey?.currentState;
    if (nav == null) return;
    // Friend-request taps open Add Friend. NOTE: server sendToUser currently
    // sends notification-only payloads (no data), so these taps fall through
    // to the Rankings fallback until a data payload is attached [unverified
    // live — branch is ready, payload pending].
    if (type == 'friend_request') {
      nav.push(MaterialPageRoute(builder: (_) => const AddFriendPage()));
      return;
    }
    final page = (weekId != null && weekId.isNotEmpty)
        ? PayoutClaimPage(weekId: weekId)
        : const WeeklyLeaderboardPage();
    nav.push(MaterialPageRoute(builder: (_) => page));
  }
}
