import 'package:flutter_test/flutter_test.dart';

import 'package:quiz/core/providers/user_data_provider.dart';
import 'package:quiz/features/quiz/quiz_controller.dart';

// UserDataProvider starts Connectivity and Firestore listeners from its
// constructor, which cannot run under flutter_test. The submit path never
// touches the provider, so the fake just skips init().
class _FakeUserData extends UserDataProvider {
  @override
  void init() {}
}

void main() {
  test(
    'failed submit sets submitFailed; retrySubmit succeeds and resets it',
    () async {
      var submitCalls = 0;
      final callableNames = <String>[];
      final errors = <String>[];
      var retryOffered = false;
      final completed = <(String, bool, int)>[];

      Future<Map<String, dynamic>> submit(
        String name,
        Map<String, dynamic> payload,
      ) async {
        callableNames.add(name);
        submitCalls++;
        if (submitCalls == 1) throw Exception('network down');
        return {'correctCount': 7};
      }

      final controller = QuizController(
        mode: QuizMode.asyncChallenge,
        selectedTitles: const ['naruto'],
        challengeId: 'challenge-1',
        isCreator: true,
        submitCaller: submit,
        userDataProvider: _FakeUserData(),
        onQuestionAdvance: (_) {},
        onSoloComplete: (
          correct,
          total,
          coins,
          wp, {
          isGauntlet = false,
          streak = 0,
          answeredCount = 0,
          gauntletPerQuestionWP = const [],
          achievementCoins = 0,
        }) {},
        onChallengeComplete: (id, isCreator, correct) =>
            completed.add((id, isCreator, correct)),
        onInsufficientCoins: (_) async {},
        onError: (msg, {void Function()? onRetry}) {
          errors.add(msg);
          retryOffered = onRetry != null;
        },
      );
      addTearDown(controller.dispose);

      // First submission fails: this is the old dead-end state.
      await controller.finishRunForTest();

      expect(controller.submitFailed, isTrue);
      expect(controller.isNavigating, isFalse);
      expect(errors, hasLength(1));
      expect(errors.single, contains('Failed to save score'));
      expect(retryOffered, isTrue, reason: 'snackbar must expose Retry');
      expect(callableNames, ['submitRun']);

      // Retry succeeds: the flag clears and the result callback fires.
      await controller.retrySubmit();

      expect(controller.submitFailed, isFalse);
      expect(completed, [('challenge-1', true, 7)]);
      expect(callableNames, ['submitRun', 'submitRun']);
    },
  );
}
