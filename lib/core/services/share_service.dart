// lib/core/services/share_service.dart
//
// The one place that talks to the OS share sheet.
//
// Why a service instead of `Share.share` at each call site: every surface used
// to carry its own sentence, its own snackbar and its own failure behaviour.
// Sharing is a growth path now, so it gets one implementation:
//
//   * `shareText`      — plain text invite (no image).
//   * `shareCard`      — renders a `ShareCard` off-screen to PNG, then shares
//                        the image with the invite as its caption.
//   * `copyText`       — clipboard + snackbar, the fallback every share has.
//
// Nothing here grants coins, writes to Firestore or touches the economy. A
// share only produces a code/link; the existing server gates (`referredBy` →
// `claimReferralBonus`, challenge code → `joinChallenge`) stay authoritative.
//
// No `dart:io` and no `path_provider`: the image is handed to share_plus as an
// in-memory `XFile.fromData`, and the plugin writes its own temp file. That
// keeps this file compiling on web, where the app also ships.
//
// Note on BuildContext: the origin rect and messenger are captured up-front so
// nothing here touches a BuildContext after an await (deliberately — the
// capture and the share sheet are both async and the caller may be gone).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

class ShareService {
  ShareService._();

  static final ShareService instance = ShareService._();

  /// 360×450 logical → 1080×1350 px, the 4:5 portrait crop WhatsApp status and
  /// Instagram feed both accept without letterboxing.
  static const double _cardPixelRatio = 3;

  /// Gives the off-screen tree a frame to lay out and load Nunito. The card is
  /// static (no network images), so this does not need the 1s the package
  /// recommends for complex trees.
  static const Duration _captureDelay = Duration(milliseconds: 150);

  /// Native share sheet with plain text.
  Future<ShareResult> shareText(
    BuildContext context, {
    required String text,
    String? subject,
  }) {
    return _shareText(
      text: text,
      subject: subject,
      origin: _originOf(context),
      messenger: ScaffoldMessenger.maybeOf(context),
    );
  }

  /// Renders [card] to a PNG and shares it with [text] as the caption.
  ///
  /// Falls back to plain text when the image route fails, so a share is never
  /// a dead end. [logicalSize] must match the card's fixed size — the render
  /// target is what stops the PNG from being screen-sized with the card
  /// floating in the middle.
  Future<ShareResult> shareCard(
    BuildContext context, {
    required Widget card,
    required Size logicalSize,
    required String fileName,
    String? text,
    String? subject,
  }) async {
    final origin = _originOf(context);
    final messenger = ScaffoldMessenger.maybeOf(context);

    try {
      final bytes = await ScreenshotController().captureFromWidget(
        card,
        context: context,
        pixelRatio: _cardPixelRatio,
        targetSize: logicalSize,
        delay: _captureDelay,
      );

      final file = XFile.fromData(
        bytes,
        mimeType: 'image/png',
        name: '$fileName.png',
      );

      return await Share.shareXFiles(
        [file],
        // `XFile.fromData` ignores `name` on every platform but web.
        fileNameOverrides: ['$fileName.png'],
        text: text,
        subject: subject,
        sharePositionOrigin: origin,
      );
    } catch (error) {
      debugPrint('[ShareService] image share failed: $error');
      if (text != null && text.isNotEmpty) {
        return _shareText(
          text: text,
          subject: subject,
          origin: origin,
          messenger: messenger,
        );
      }
      _notify(messenger, 'Could not create the share image.');
      return ShareResult.unavailable;
    }
  }

  /// Clipboard copy with the same snackbar wording everywhere.
  Future<void> copyText(
    BuildContext context,
    String text, {
    String message = 'Copied!',
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: text));
    _notify(messenger, message);
  }

  Future<ShareResult> _shareText({
    required String text,
    String? subject,
    Rect? origin,
    ScaffoldMessengerState? messenger,
  }) async {
    try {
      return await Share.share(
        text,
        subject: subject,
        sharePositionOrigin: origin,
      );
    } catch (error) {
      debugPrint('[ShareService] text share failed: $error');
      _notify(
          messenger, 'Could not open the share sheet. Copy the code instead.');
      return ShareResult.unavailable;
    }
  }

  /// iPad/Mac popover anchor. Falls back to the whole screen rect, which is
  /// still a valid anchor and avoids the `UIActivityViewController` crash when
  /// no rect is supplied.
  Rect? _originOf(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _notify(ScaffoldMessengerState? messenger, String message) {
    // maybeOf at the call site: sharing must never throw just because there is
    // no ScaffoldMessenger above the caller.
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
