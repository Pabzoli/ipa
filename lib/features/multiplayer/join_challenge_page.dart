import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import '../../core/providers/user_data_provider.dart';
import '../quiz/questions_page.dart';
import 'challenge_model.dart';
import 'challenge_result_page.dart';

class JoinChallengePage extends StatefulWidget {
  const JoinChallengePage({super.key});

  @override
  State<JoinChallengePage> createState() => _JoinChallengePageState();
}

class _JoinChallengePageState extends State<JoinChallengePage> {
  final _codeCtrl = TextEditingController();

  ChallengeModel? _found;       // populated after successful lookup
  bool _looking  = false;       // lookup in progress
  bool _joining  = false;       // join+navigate in progress
  String? _errorMsg;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _lookUp() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(() => _errorMsg = 'Code must be exactly 6 characters');
      return;
    }

    setState(() {
      _looking  = true;
      _found    = null;
      _errorMsg = null;
    });

    try {
      final challenge =
          await FirestoreService.instance.getChallengeByCode(code);

      if (!mounted) return;

      if (challenge == null) {
        setState(() {
          _looking  = false;
          _errorMsg = 'No challenge found with code "$code"';
        });
        return;
      }

      // Client-side pre-checks for clear UX errors
      final uid = FirestoreService.instance.currentUid;
      if (challenge.creatorUid == uid) {
        setState(() {
          _looking  = false;
          _errorMsg = "That's your own challenge — share the code with a friend!";
        });
        return;
      }
      if (challenge.isExpired) {
        setState(() {
          _looking  = false;
          _errorMsg = 'This challenge has expired.';
        });
        return;
      }
      if (challenge.status != ChallengeStatus.waiting) {
        setState(() {
          _looking  = false;
          _errorMsg = challenge.isCompleted
              ? 'This challenge is already completed.'
              : 'An opponent has already joined this challenge.';
        });
        return;
      }

      setState(() {
        _looking = false;
        _found   = challenge;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _looking  = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _acceptAndPlay() async {
    if (_found == null || _joining) return;

    final balance = context.read<UserDataProvider>().score;
    if (balance < _found!.betAmount) {
      setState(() => _errorMsg =
          'You need ${_found!.betAmount} pts to accept. You have $balance.');
      return;
    }

    setState(() { _joining = true; _errorMsg = null; });

    try {
      await FirestoreService.instance.joinChallenge(_found!.challengeId);

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: QuestionsPage(
              mode:        QuizMode.asyncChallenge,
              questionIds: _found!.questionIds,
              challengeId: _found!.challengeId,
              isCreator:   false,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _joining  = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = context.watch<UserDataProvider>().score;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: Container(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            children: [
              // ── App bar ──────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: AppColors.textPrimary),
                      onPressed: (_looking || _joining)
                          ? null
                          : () => Navigator.pop(context),
                    ),
                    const Text(
                      'Join Challenge',
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
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 16),

                      // ── Code input ──────────────────────────────────
                      TextField(
                        controller:   _codeCtrl,
                        enabled:      !_looking && !_joining,
                        textCapitalization:
                            TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[A-Za-z0-9]'),
                          ),
                          LengthLimitingTextInputFormatter(6),
                        ],
                        style: const TextStyle(
                          color:         AppColors.textPrimary,
                          fontSize:      28,
                          fontWeight:    FontWeight.w900,
                          letterSpacing: 6,
                        ),
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          hintText:  'Enter 6-char code',
                          labelText: 'Challenge Code',
                        ),
                        onChanged: (_) => setState(() {
                          _found    = null;
                          _errorMsg = null;
                        }),
                        onSubmitted: (_) => _lookUp(),
                      ),

                      const SizedBox(height: 16),

                      GradientButton(
                        label: 'Look Up',
                        icon:  Icons.search_rounded,
                        onTap: (_looking || _joining) ? null : _lookUp,
                      ),

                      // ── Error ───────────────────────────────────────
                      if (_errorMsg != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color:        AppColors.wrong.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border:       Border.all(
                                color: AppColors.wrong.withOpacity(0.4)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline_rounded,
                                  color: AppColors.wrong, size: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _errorMsg!,
                                  style: const TextStyle(
                                    color:    AppColors.wrong,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // ── Challenge details card ───────────────────────
                      if (_found != null) ...[
                        const SizedBox(height: 24),
                        _ChallengeDetailsCard(
                          challenge: _found!,
                          userBalance: balance,
                        ),
                        const SizedBox(height: 20),
                        GradientButton(
                          label: _joining
                              ? 'Accepting…'
                              : 'Accept & Play',
                          icon:  Icons.flash_on_rounded,
                          onTap: _joining ? null : _acceptAndPlay,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_found!.betAmount} pts will be deducted from your balance',
                          style: const TextStyle(
                              color: AppColors.textMuted, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],

                      // ── Loading state ───────────────────────────────
                      if (_looking) ...[
                        const SizedBox(height: 32),
                        const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                  color: AppColors.primary),
                              SizedBox(height: 12),
                              Text('Looking up challenge…',
                                  style: TextStyle(
                                      color: AppColors.textMuted)),
                            ],
                          ),
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

// ── Challenge details card ─────────────────────────────────────────────────────
class _ChallengeDetailsCard extends StatelessWidget {
  final ChallengeModel challenge;
  final int            userBalance;
  const _ChallengeDetailsCard({
    required this.challenge,
    required this.userBalance,
  });

  @override
  Widget build(BuildContext context) {
    final canAfford = userBalance >= challenge.betAmount;

    return GlassCard(
      borderColor: AppColors.secondary.withOpacity(0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width:  44,
                height: 44,
                decoration: BoxDecoration(
                  color:        AppColors.correct.withOpacity(0.15),
                  shape:        BoxShape.circle,
                ),
                child: const Icon(Icons.person_rounded,
                    color: AppColors.correct, size: 24),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    challenge.creatorUsername,
                    style: const TextStyle(
                      color:      AppColors.textPrimary,
                      fontSize:   17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Text(
                    'challenges you!',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: AppColors.divider),
          const SizedBox(height: 12),
          _DetailRow(
            label: 'Anime',
            value: challenge.animeTitle,
          ),
          const SizedBox(height: 8),
          _DetailRow(
            label: 'Bet',
            value: '${challenge.betAmount} pts',
            valueColor: canAfford ? AppColors.correct : AppColors.wrong,
          ),
          const SizedBox(height: 8),
          _DetailRow(
            label: 'Questions',
            value: '${challenge.questionIds.length} questions',
          ),
          const SizedBox(height: 8),
          _DetailRow(
            label: 'Expires in',
            value: _formatRemaining(challenge.timeRemaining),
          ),
          if (!canAfford) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:        AppColors.wrong.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: AppColors.wrong, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'You need ${challenge.betAmount} pts. You have $userBalance.',
                    style: const TextStyle(
                        color: AppColors.wrong, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatRemaining(Duration d) {
    if (d == Duration.zero) return 'Expired';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _DetailRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 13)),
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