// lib/features/multiplayer/spar_launcher.dart
//
// Free spar entry, shared by the rival page and the friends board: pick an
// anime, the server opens the spar, then the quiz replaces the picker. Friendship
// and the daily spar budget are enforced by createSparChallenge.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../core/services/firestore_service.dart';
import '../../core/widgets/app_page_route.dart';
import '../quiz/questions_page.dart';
import 'anime_select_page.dart';

/// Opens the anime picker for a free spar with [opponentUid].
void openSparPicker(
  BuildContext context, {
  required String opponentUid,
  required String opponentUsername,
}) {
  Navigator.of(context).push(
    AppPageRoute(
      builder: (_) => AnimeSelectPage(
        opponentUid: opponentUid,
        opponentUsername: opponentUsername,
        onSelect: (animeTitle) => startFreeSpar(
          context,
          opponentUid: opponentUid,
          opponentUsername: opponentUsername,
          animeTitle: animeTitle,
        ),
      ),
    ),
  );
}

/// Creates the spar and replaces the current route with its quiz. Failures
/// show a snackbar. Returns true when the quiz opened.
Future<bool> startFreeSpar(
  BuildContext context, {
  required String opponentUid,
  required String opponentUsername,
  required String animeTitle,
}) async {
  try {
    final res = await FirestoreService.instance.createSparChallenge(
      animeTitle: animeTitle,
      opponentUid: opponentUid,
      opponentUsername: opponentUsername,
    );
    final challengeId = res['challengeId']?.toString() ?? '';
    final rawIds = res['questionIds'];
    if (!context.mounted) return false;
    if (challengeId.isEmpty || rawIds is! List) {
      throw Exception('challenge_creation_failed');
    }
    final questionIds = List<String>.unmodifiable(rawIds.map((e) => '$e'));
    Navigator.of(context).pushReplacement(
      AppPageRoute(
        builder: (_) => QuestionsPage(
          mode: QuizMode.asyncChallenge,
          selectedTitles: [animeTitle],
          questionIds: questionIds,
          challengeId: challengeId,
          isCreator: true,
          opponentName: opponentUsername,
        ),
      ),
    );
    return true;
  } on FirebaseFunctionsException catch (e) {
    if (!context.mounted) return false;
    final msg = e.message ?? '';
    _snack(
      context,
      msg.contains('daily_spar_limit_reached')
          ? 'Daily spar limit reached — come back tomorrow for friendlies.'
          : msg.contains('not_friends')
              ? 'Add them as a friend to spar.'
              : 'Could not start the spar — please try again.',
    );
    return false;
  } catch (_) {
    if (!context.mounted) return false;
    _snack(context, 'Could not start the spar — please try again.');
    return false;
  }
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
