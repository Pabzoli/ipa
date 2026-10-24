import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/services/app_update_service.dart';

/// A failed [SupportRemoteDataSource.submitFeedback] call with copy that is
/// safe to show the player.
class SupportSubmissionException implements Exception {
  const SupportSubmissionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Sends contact / bug-report / suggestion messages through the
/// server-authoritative `submitFeedback` callable.
///
/// The `feedback` collection is unreadable and unwritable from clients (see
/// firestore.rules), so this is the only path in.
class SupportRemoteDataSource {
  const SupportRemoteDataSource();

  Future<void> submitFeedback({
    required String category,
    required String subject,
    required String message,
  }) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('submitFeedback')
          .call<Map<String, dynamic>>(<String, dynamic>{
        'category': category,
        'subject': subject,
        'message': message,
        ...AppUpdateService.instance.clientBuildStamp,
      });
    } on FirebaseFunctionsException catch (e) {
      throw SupportSubmissionException(_messageFor(e));
    } catch (e) {
      debugPrint('[SupportRemoteDataSource] submit failed: $e');
      throw const SupportSubmissionException(
        'Could not send your message. Check your connection and try again.',
      );
    }
  }

  String _messageFor(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'unauthenticated':
        return 'Sign in to send us a message.';
      case 'invalid-argument':
        return 'Please check your message and try again.';
      case 'resource-exhausted':
        // Server copy is written for players (cooldown / daily limit).
        return e.message ?? 'Please wait a moment before sending again.';
      default:
        return 'Could not send your message. Please try again.';
    }
  }
}
