/// What a support message is about.
///
/// [wireValue] is the exact string the `submitFeedback` callable accepts;
/// keep it in step with `FEEDBACK_CATEGORIES` in functions/index.js.
enum FeedbackCategory {
  bug(
    wireValue: 'bug',
    label: 'Bug report',
    hint: 'Something broke, crashed, or does not work as expected.',
  ),
  suggestion(
    wireValue: 'suggestion',
    label: 'Suggestion',
    hint: 'An idea that would make the app better.',
  ),
  other(
    wireValue: 'other',
    label: 'Something else',
    hint: 'Anything else you want us to know.',
  );

  const FeedbackCategory({
    required this.wireValue,
    required this.label,
    required this.hint,
  });

  final String wireValue;
  final String label;
  final String hint;
}
