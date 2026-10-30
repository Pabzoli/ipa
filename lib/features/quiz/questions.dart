import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// AnimeQuestion — the single data model for every quiz question.
///
/// Questions live ONLY in Firestore (`questions` collection).
/// No local copy, no fallback list. The creator (you) edits them
/// directly in the Firebase console and every user sees the changes
/// immediately.
///
/// Allowed difficulty tiers. Stored lowercase in Firestore.
/// Firestore document shape:
/// {
///   "question":           "Who is the 9th Hokage?",
///   "options":            ["Naruto", "Boruto", "Konohamaru", "Sarada"],
///   "correctAnswerIndex": 1,
///   "animeTitle":         "naruto",
///   "difficulty":         "easy" | "medium" | "hard"
/// }
const List<String> kQuestionDifficulties = ['easy', 'medium', 'hard'];

class AnimeQuestion {
  /// Firestore document ID
  final String id;

  final String question;
  final List<String> options;
  final int correctAnswerIndex;
  final String animeTitle;

  /// Difficulty tier — always one of [kQuestionDifficulties].
  final String difficulty;

  const AnimeQuestion({
    required this.id,
    required this.question,
    required this.options,
    required this.correctAnswerIndex,
    required this.animeTitle,
    required this.difficulty,
  });

  // ── Firestore ↔ Dart ──────────────────────────────────────────────────────

  // TODO(STEP-1-followup): remove the legacy 'medium' fallback once all
  // pre-difficulty questions have been backfilled or replaced (see
  // scripts/seed_questions.js). Until then every fallback hit is logged so
  // silently-mislabeled questions can't accumulate unnoticed.
  static String _difficultyOrLegacyFallback(
    Map<String, dynamic> data,
    String docId,
  ) {
    final raw = data['difficulty'];
    // Remote data is untrusted — a legacy question doc may store `difficulty`
    // as a non-string (e.g. an int) or an off-spec string. Difficulty must
    // always end up in the valid tier set (easy/medium/hard), never an
    // arbitrary coerced value, so any non-valid raw value falls back to
    // 'medium'. The offending doc is logged so it can be backfilled/fixed.
    final normalized = raw is String ? raw.trim().toLowerCase() : null;
    if (normalized != null && kQuestionDifficulties.contains(normalized)) {
      return normalized;
    }
    debugPrint(
      '[AnimeQuestion] Non-valid difficulty coerced to "medium" '
      '(raw=$raw, doc: $docId). Fix the source question doc to store '
      'difficulty as a lowercase string in {easy, medium, hard}.',
    );
    return 'medium';
  }

  /// Defensive builder for `options`. Remote data is untrusted — a legacy
  /// question doc may store an option as a non-string (e.g. an int), which
  /// used to crash `List<String>.from(...)` with a type-cast error.
  /// Non-string entries are coerced with string interpolation and the
  /// offending doc is logged so the bad question can be identified/fixed.
  static List<String> _optionsListOf(Object? raw) {
    if (raw is! List) return const [];
    final out = List<String>.generate(raw.length, (i) => '${raw[i]}');
    if (raw.any((e) => e is! String)) {
      debugPrint(
        '[AnimeQuestion] Non-string option coerced to string. '
        'Fix the source question doc to store string options.',
      );
    }
    return out;
  }

  factory AnimeQuestion.fromMap(Map<String, dynamic> map) {
    final id = (map['id'] as String?) ?? '';
    return AnimeQuestion(
      id: id,
      question: map['question'] as String,
      options: _optionsListOf(map['options']),
      correctAnswerIndex: (map['correctAnswerIndex'] as num).toInt(),
      animeTitle: map['animeTitle'] as String,
      difficulty: _difficultyOrLegacyFallback(map, id),
    );
  }

  /// Create directly from Firestore document
  factory AnimeQuestion.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data()!;

    return AnimeQuestion(
      id: doc.id,
      question: d['question'] as String,
      options: _optionsListOf(d['options']),
      correctAnswerIndex: (d['correctAnswerIndex'] as num).toInt(),
      animeTitle: d['animeTitle'] as String,
      difficulty: _difficultyOrLegacyFallback(d, doc.id),
    );
  }

  /// Sanitized wire shape returned by `getQuizRun`.
  ///
  /// The server deliberately omits `correctAnswerIndex`; -1 is a sentinel that
  /// must never be used for scoring. All scoring is server-side.
  factory AnimeQuestion.fromWire(Map<String, dynamic> map) {
    final id = (map['id'] as String?) ?? '';
    return AnimeQuestion(
      id: id,
      question: (map['question'] as String?) ?? '',
      options: _optionsListOf(map['options']),
      correctAnswerIndex: -1,
      animeTitle: (map['animeTitle'] as String?) ?? '',
      difficulty: _difficultyOrLegacyFallback(map, id),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'question': question,
        'options': options,
        'correctAnswerIndex': correctAnswerIndex,
        'animeTitle': animeTitle,
        'difficulty': difficulty,
      };

  @override
  String toString() =>
      'AnimeQuestion(id: $id, animeTitle: $animeTitle, difficulty: $difficulty, question: $question)';
}
