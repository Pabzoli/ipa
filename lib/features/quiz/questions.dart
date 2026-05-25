import 'package:cloud_firestore/cloud_firestore.dart';

/// AnimeQuestion — the single data model for every quiz question.
///
/// Questions live ONLY in Firestore (`questions` collection).
/// No local copy, no fallback list. The creator (you) edits them
/// directly in the Firebase console and every user sees the changes
/// immediately.
///
/// Firestore document shape:
/// {
///   "question":           "Who is the 9th Hokage?",
///   "options":            ["Naruto", "Boruto", "Konohamaru", "Sarada"],
///   "correctAnswerIndex": 1,
///   "animeTitle":         "naruto"
/// }
class AnimeQuestion {
  /// Firestore document ID
  final String id;

  final String question;
  final List<String> options;
  final int correctAnswerIndex;
  final String animeTitle;

  const AnimeQuestion({
    required this.id,
    required this.question,
    required this.options,
    required this.correctAnswerIndex,
    required this.animeTitle,
  });

  // ── Firestore ↔ Dart ──────────────────────────────────────────────────────

  factory AnimeQuestion.fromMap(Map<String, dynamic> map) => AnimeQuestion(
        id: (map['id'] as String?) ?? '',

        question: map['question'] as String,

        options: List<String>.from(map['options'] as List),

        correctAnswerIndex:
            (map['correctAnswerIndex'] as num).toInt(),

        animeTitle: map['animeTitle'] as String,
      );

  /// Create directly from Firestore document
  factory AnimeQuestion.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data()!;

    return AnimeQuestion(
      id: doc.id,

      question: d['question'] as String,

      options: List<String>.from(d['options'] as List),

      correctAnswerIndex:
          (d['correctAnswerIndex'] as num).toInt(),

      animeTitle: d['animeTitle'] as String,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'question': question,
        'options': options,
        'correctAnswerIndex': correctAnswerIndex,
        'animeTitle': animeTitle,
      };

  @override
  String toString() =>
      'AnimeQuestion(id: $id, animeTitle: $animeTitle, question: $question)';
}