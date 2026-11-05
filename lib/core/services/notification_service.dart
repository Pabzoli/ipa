import 'package:flutter/material.dart';

/// Web-only stub. Push notifications (FCM + local banners) were removed
/// with the native folders. Payout/leaderboard navigation still works
/// in-app; there are simply no background pushes on web.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  Future<void> init({
    required GlobalKey<NavigatorState> navigatorKey,
  }) async {}
}
