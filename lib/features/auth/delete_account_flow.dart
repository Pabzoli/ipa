import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'auth_service.dart';

/// Why the account-deletion flow lives in its own file rather than inside the
/// profile page: it keeps the single copy of the wording and the failure
/// handling used by the Settings-only surface (Profile → Account → Settings
/// → Danger zone → Delete account).
///
/// This module therefore owns the part that must never be duplicated — the
/// actual call and the error policy — and the Settings surface owns only its
/// own chrome (dialogs). Only one copy of the wording and the failure
/// handling exists.

// ─── Confirmation ────────────────────────────────────────────────────────────

/// The standard "are you sure" gate, shared verbatim so the wording of the
/// erasure warning cannot drift between surfaces.
///
/// Returns true only if the user explicitly confirmed.
Future<bool> confirmAccountDeletion(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Delete account?',
          style: TextStyle(
              color: AppColors.errorText, fontWeight: FontWeight.w900)),
      content: Text(
        'This permanently deletes your account, profile, match history, '
        'bank details and gameplay data. This cannot be '
        'undone.\n\n'
        'Records we are legally required to keep (completed purchase and '
        'payout records) are retained; personal details in them are removed. '
        'Outstanding prize payouts must be settled before deletion.',
        style: TextStyle(color: AppColors.textSecondary, height: 1.45),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('Delete forever',
              style: TextStyle(
                  color: AppColors.errorText, fontWeight: FontWeight.w900)),
        ),
      ],
    ),
  );
  return confirmed == true;
}

// ─── Execution ───────────────────────────────────────────────────────────────

/// Outcome of a deletion attempt. Carries the retained-record count on success
/// because the UI has to disclose it — telling a user "everything was deleted"
/// while quietly keeping financial records would itself be a privacy problem.
class DeleteAccountResult {
  final bool success;
  final String? error; // user-facing message, non-null iff !success
  final int retainedCount; // records kept for legal/accounting reasons

  const DeleteAccountResult.ok(int retained)
      : success = true,
        error = null,
        retainedCount = retained;
  const DeleteAccountResult.failed(String message)
      : success = false,
        error = message,
        retainedCount = 0;
}

/// Performs the deletion. [onBusy] is called with true before the request and
/// false once it settles, so each surface can drive its own busy indicator
/// (a modal spinner in the profile page, an inline one on the update wall).
///
/// Never throws: callers render [DeleteAccountResult.error] rather than
/// duplicating the error policy.
Future<DeleteAccountResult> performAccountDeletion({
  required void Function(bool busy) onBusy,
}) async {
  onBusy(true);
  try {
    // Also signs the user out locally and removes the Auth account.
    final summary = await AuthService.instance.deleteAccount();
    return DeleteAccountResult.ok((summary['retained'] as List?)?.length ?? 0);
  } on FirebaseFunctionsException catch (e) {
    // The server's own failed-precondition messages are user-facing and
    // important (e.g. "a prize payout is in progress") — pass them through
    // verbatim rather than hiding them behind a generic error.
    if (e.code == 'failed-precondition' && (e.message ?? '').isNotEmpty) {
      return DeleteAccountResult.failed(e.message!);
    }
    return const DeleteAccountResult.failed(
      'Could not delete your account right now. '
      'Please try again or contact support.',
    );
  } catch (_) {
    return const DeleteAccountResult.failed(
      'Could not delete your account right now. Please try again.',
    );
  } finally {
    onBusy(false);
  }
}

// ─── Result copy ─────────────────────────────────────────────────────────────

/// The post-deletion summary shown after a successful erasure. [retainedCount]
/// is the number of financial records the server kept for legal/accounting
/// reasons; when non-zero the message discloses that, because silently keeping
/// records after telling a user everything was deleted would itself be a
/// privacy problem.
String deletionSuccessMessage(int retainedCount) =>
    'Your account and personal data have been deleted.'
    '${retainedCount > 0 ? ' A small number of financial records were retained as required by law, with your personal details removed.' : ''}';
