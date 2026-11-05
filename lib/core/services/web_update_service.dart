import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ad_service.dart';
import 'web_reload.dart';

/// Web equivalent of the old Android "update required" wall.
///
/// There is nothing to download on web — a deploy takes effect on refresh.
/// This polls the build-stamped `version.json` (first read = the build this
/// session launched with; the deploy pipeline stamps every release with
/// commit + time so a new deploy is always detectable) and AUTO-REFRESHES
/// when the server reports a newer one.
///
/// Safety rails (a refresh kills in-memory state, so it must never fire
/// blindly):
///
/// * Never during a live quiz run ([AdService.isQuizActive]) — falls back to
///   a manual Refresh prompt instead.
/// * Loop-guarded: at most [_kMaxAutoReloads] auto-reloads per detected
///   build inside [_kGuardWindow] (persisted — survives the reload itself).
///   A CDN serving a stale bundle can never spin forever; it degrades to
///   the manual prompt.
/// * A short grace snackbar precedes the reload, with an Update-now action.
/// * Any failure stays silent — the app keeps working on the running build.
class WebUpdateService {
  WebUpdateService._();
  static final WebUpdateService instance = WebUpdateService._();

  static const String _kGuardKey = 'web_update_guard_v1';
  static const int _kMaxAutoReloads = 2;
  static const Duration _kGuardWindow = Duration(minutes: 10);
  static const Duration _kGracePeriod = Duration(seconds: 3);

  String? _baseline;
  String? _prompted;
  bool _checking = false;

  Future<void> checkAndNotify(BuildContext context) async {
    if (_checking) return;
    _checking = true;
    try {
      final res = await http.get(
        Uri.parse('version.json'),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final body = res.body.trim();
      if (body.isEmpty) return;
      if (_baseline == null) {
        _baseline = body;
        return;
      }
      if (body == _baseline || body == _prompted) return;
      _prompted = body;
      if (!context.mounted) return;

      if (!AdService.instance.isQuizActive && await _takeAutoReloadSlot(body)) {
        if (!context.mounted) return;
        _snack(context, 'New version found — refreshing…',
            actionLabel: 'Update now', onAction: WebReload.reload);
        await Future.delayed(_kGracePeriod);
        // The user may have started a quiz during the grace period.
        if (AdService.instance.isQuizActive) {
          if (context.mounted) _manualPrompt(context);
          return;
        }
        WebReload.reload();
        return;
      }
      if (!context.mounted) return;
      _manualPrompt(context);
    } catch (_) {
      // Offline or unreachable — the running build stays fully usable.
    } finally {
      _checking = false;
    }
  }

  void _manualPrompt(BuildContext context) {
    if (!context.mounted) return;
    _snack(context, 'A new version of AnimeQuiz is ready. Refresh to update.',
        actionLabel: 'Refresh', onAction: WebReload.reload);
  }

  void _snack(
    BuildContext context,
    String message, {
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 15),
        action: SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
  }

  /// Claims one auto-reload for [targetBody]. Returns false when this build
  /// already burned the budget (stale bundle served repeatedly) so the
  /// caller degrades to the manual prompt instead of looping.
  Future<bool> _takeAutoReloadSlot(String targetBody) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kGuardKey);
      if (raw != null) {
        final guard =
            Map<String, dynamic>.from(jsonDecode(raw) as Map<String, dynamic>);
        final atMillis = (guard['at'] as num?)?.toInt();
        final at = atMillis == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(atMillis);
        if (guard['target'] == targetBody &&
            at != null &&
            DateTime.now().difference(at) < _kGuardWindow &&
            ((guard['count'] as num?)?.toInt() ?? 0) >= _kMaxAutoReloads) {
          return false;
        }
      }
      final prior = raw == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(raw) as Map<String, dynamic>);
      final count = (prior != null && prior['target'] == targetBody)
          ? ((prior['count'] as num?)?.toInt() ?? 0) + 1
          : 1;
      await prefs.setString(
          _kGuardKey,
          jsonEncode({
            'target': targetBody,
            'count': count,
            'at': DateTime.now().millisecondsSinceEpoch,
          }));
      return true;
    } catch (_) {
      // Guard storage unavailable — allow this one; the in-memory _prompted
      // flag still prevents repeats within the session.
      return true;
    }
  }
}
