/// AnimeQuestion — the single data model for every quiz question.
///
/// Questions live ONLY in Firestore (`questions` collection).
/// No local copy, no fallback list.  The creator (you) edits them
/// directly in the Firebase console and every user sees the changes
/// immediately.
///
/// Firestore document shape:
/// {
///   "question":           "Who is the 9th Hokage?",
///   "options":            ["Naruto", "Boruto", "Konohamaru", "Sarada"],
///   "correctAnswerIndex": 1,
///   "animeTitle":         "naruto"   // lowercase, matches home_page tiles
/// }
class AnimeQuestion {
  final String       question;
  final List<String> options;
  final int          correctAnswerIndex;
  final String       animeTitle;
 
  const AnimeQuestion({
    required this.question,
    required this.options,
    required this.correctAnswerIndex,
    required this.animeTitle,
  });
 
  // ── Firestore ↔ Dart ──────────────────────────────────────────────────────
 
  factory AnimeQuestion.fromMap(Map<String, dynamic> map) => AnimeQuestion(
        question:           map['question']           as String,
        options:            List<String>.from(map['options'] as List),
        correctAnswerIndex: map['correctAnswerIndex'] as int,
        animeTitle:         map['animeTitle']         as String,
      );
 
  Map<String, dynamic> toMap() => {
        'question':           question,
        'options':            options,
        'correctAnswerIndex': correctAnswerIndex,
        'animeTitle':         animeTitle,
      };
 
  @override
  String toString() =>
      'AnimeQuestion(animeTitle: $animeTitle, question: $question)';
}
 