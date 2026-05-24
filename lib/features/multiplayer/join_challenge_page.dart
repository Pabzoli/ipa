// lib/features/multiplayer/join_challenge_page.dart
//
// Opponent flow:
//   1. Enter 6-char code.
//   2. Challenge preview card appears (creator, anime, bet, expiry).
//   3. "Accept & Start" atomically deducts both bets and starts the quiz.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../quiz/questions.dart';
import 'models/challenge_model.dart';
import 'challenge_quiz_page.dart';

class JoinChallengePage extends StatefulWidget {
  const JoinChallengePage({super.key});

  @override
  State<JoinChallengePage> createState() => _JoinChallengePageState();
}

class _JoinChallengePageState extends State<JoinChallengePage> {
  final _codeCtrl    = TextEditingController();
  final _codeFocus   = FocusNode();

  ChallengeModel?     _found;
  List<AnimeQuestion>? _questions;

  bool    _searching = false;
  bool    _accepting = false;
  String? _searchError;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  // ── Search ───────────────────────────────────────────────────────────────────
  Future<void> _searchChallenge() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(() => _searchError = 'Enter the full 6-character code.');
      return;
    }

    setState(() {
      _searching   = true;
      _searchError = null;
      _found       = null;
      _questions   = null;
    });

    try {
      final challenge =
          await FirestoreService.instance.getChallengeByCode(code);

      if (!mounted) return;

      if (challenge == null) {
        setState(() {
          _searching   = false;
          _searchError = 'No active challenge found for code "$code".\nCheck the code and try again.';
        });
        return;
      }

      setState(() {
        _found     = challenge;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching   = false;
        _searchError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ── Accept ───────────────────────────────────────────────────────────────────
  Future<void> _acceptChallenge() async {
    if (_found == null || _accepting) return;
    setState(() => _accepting = true);

    try {
      // 1. Atomically join (deducts both bets).
      await FirestoreService.instance.joinChallenge(_found!.challengeId);

      // 2. Pre-load questions.
      final qs = await FirestoreService.instance
          .fetchQuestionsByIds(_found!.questionIds);

      if (!mounted) return;

      if (qs.isEmpty) {
        setState(() {
          _accepting  = false;
          _searchError = 'Could not load questions. Please try again.';
        });
        return;
      }

      // 3. Re-fetch the challenge to get the updated opponentUsername etc.
      // (joinChallenge already wrote these; the local model is stale.)
      // We pass the original model — ChallengeQuizPage only needs questionIds,
      // betAmount, animeTitle, creatorUsername, and challengeId, all of which
      // are already correct.

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: ChallengeQuizPage(
              challenge: _found!,
              questions: qs,
              isCreator: false,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _accepting   = false;
        _searchError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final myScore = context.watch<UserDataProvider>().score;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: Container(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ─────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: AppColors.textPrimary),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Text(
                      'Join a Challenge',
                      style: TextStyle(
                        color:      AppColors.textPrimary,
                        fontSize:   22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Code input ──────────────────────────────────────
                      const Text(
                        'Enter Challenge Code',
                        style: TextStyle(
                          color:      AppColors.textPrimary,
                          fontSize:   18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Ask your friend for their 6-character code.',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 13),
                      ),
                      const SizedBox(height: 16),

                      // Code text field — auto-caps, max 6 chars.
                      TextField(
                        controller:   _codeCtrl,
                        focusNode:    _codeFocus,
                        maxLength:    6,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[A-Za-z0-9]')),
                          _UpperCaseFormatter(),
                        ],
                        style: const TextStyle(
                          color:        AppColors.textPrimary,
                          fontSize:     28,
                          fontWeight:   FontWeight.w900,
                          letterSpacing: 6,
                        ),
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          hintText:       '· · · · · ·',
                          counterText:    '',
                          errorText: _searchError,
                          errorMaxLines: 3,
                        ),
                        onChanged: (_) {
                          if (_searchError != null) {
                            setState(() => _searchError = null);
                          }
                        },
                        onSubmitted: (_) => _searchChallenge(),
                      ),

                      const SizedBox(height: 20),

                      _searching
                          ? const Center(
                              child: CircularProgressIndicator(
                                  color: AppColors.primary))
                          : GradientButton(
                              label: 'Find Challenge',
                              icon:  Icons.search_rounded,
                              onTap: _searchChallenge,
                            ),

                      // ── Challenge preview ─────────────────────────────────
                      if (_found != null) ...[
                        const SizedBox(height: 32),
                        _ChallengePreviewCard(
                          challenge:      _found!,
                          myBalance:      myScore,
                          accepting:      _accepting,
                          onAccept:       _acceptChallenge,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Challenge Preview Card ───────────────────────────────────────────────────
class _ChallengePreviewCard extends StatelessWidget {
  final ChallengeModel challenge;
  final int            myBalance;
  final bool           accepting;
  final VoidCallback   onAccept;

  const _ChallengePreviewCard({
    required this.challenge,
    required this.myBalance,
    required this.accepting,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final canAfford = myBalance >= challenge.betAmount;

    return AnimatedOpacity(
      opacity:  1.0,
      duration: const Duration(milliseconds: 400),
      child: Container(
        decoration: BoxDecoration(
          color:        AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border:       Border.all(
              color: AppColors.primary.withOpacity(0.35), width: 1.5),
          boxShadow: [
            BoxShadow(
              color:       AppColors.primary.withOpacity(0.08),
              blurRadius:  24,
              offset:      const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width:  48,
                    height: 48,
                    decoration: BoxDecoration(
                      color:  AppColors.primary.withOpacity(0.12),
                      shape:  BoxShape.circle,
                    ),
                    child: const Icon(Icons.sports_kabaddi_rounded,
                        color: AppColors.primary, size: 26),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Challenge Found!',
                            style: TextStyle(
                              color:      AppColors.textPrimary,
                              fontSize:   18,
                              fontWeight: FontWeight.w800,
                            )),
                        Text(
                          challenge.expiryLabel,
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),
              const Divider(color: AppColors.divider),
              const SizedBox(height: 16),

              // Details
              _DetailRow(
                icon:  Icons.person_rounded,
                label: 'Challenger',
                value: challenge.creatorUsername,
              ),
              const SizedBox(height: 12),
              _DetailRow(
                icon:  Icons.movie_filter_rounded,
                label: 'Anime',
                value: challenge.animeTitle,
              ),
              const SizedBox(height: 12),
              _DetailRow(
                icon:  Icons.bolt_rounded,
                label: 'Bet',
                value: '${challenge.betAmount} pts each',
                valueColor: AppColors.secondary,
              ),
              const SizedBox(height: 12),
              _DetailRow(
                icon:  Icons.quiz_rounded,
                label: 'Questions',
                value: '${challenge.questionIds.length} questions',
              ),

              const SizedBox(height: 20),
              const Divider(color: AppColors.divider),
              const SizedBox(height: 16),

              // Balance check
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color:        (canAfford ? AppColors.correct : AppColors.wrong)
                      .withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (canAfford ? AppColors.correct : AppColors.wrong)
                        .withOpacity(0.4),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      canAfford
                          ? Icons.check_circle_outline_rounded
                          : Icons.warning_amber_rounded,
                      color: canAfford ? AppColors.correct : AppColors.wrong,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        canAfford
                            ? 'Your balance: $myBalance pts — you\'re good to go!'
                            : 'Need ${challenge.betAmount} pts · You have $myBalance pts',
                        style: TextStyle(
                          color: canAfford
                              ? AppColors.correct
                              : AppColors.wrong,
                          fontSize:   13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              accepting
                  ? const Center(
                      child: Column(
                        children: [
                          CircularProgressIndicator(
                              color: AppColors.primary),
                          SizedBox(height: 8),
                          Text('Joining challenge…',
                              style: TextStyle(
                                  color:    AppColors.textMuted,
                                  fontSize: 13)),
                        ],
                      ),
                    )
                  : GradientButton(
                      label: canAfford ? 'Accept & Start Quiz' : 'Insufficient Balance',
                      icon:  Icons.play_arrow_rounded,
                      onTap: canAfford ? onAccept : null,
                    ),

              if (!canAfford) ...[
                const SizedBox(height: 8),
                const Center(
                  child: Text(
                    'Win more matches to earn points.',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final Color?   valueColor;
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: AppColors.textMuted, size: 16),
          const SizedBox(width: 8),
          Text('$label:',
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 14)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color:      valueColor ?? AppColors.textPrimary,
              fontSize:   14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
}

// ─── Input Formatter ─────────────────────────────────────────────────────────
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
          TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
