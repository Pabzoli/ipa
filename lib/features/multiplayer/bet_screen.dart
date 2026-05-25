import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../quiz/questions_page.dart';

class BetScreen extends StatefulWidget {
  /// The anime title chosen before reaching this screen.
  final String animeTitle;

  const BetScreen({super.key, required this.animeTitle});

  @override
  State<BetScreen> createState() => _BetScreenState();
}

class _BetScreenState extends State<BetScreen> {
  final _ctrl     = TextEditingController();
  bool  _creating = false; // shows overlay during Firestore write

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _createChallenge(int totalScore) async {
    final bet = int.tryParse(_ctrl.text) ?? 0;

    if (bet < 100 || bet > 99000 || bet % 100 != 0) {
      _showError(
          'Enter a valid bet (multiple of 100, between 100 – 99,000)');
      return;
    }
    if (bet > totalScore) {
      _showError('Bet cannot exceed your current balance ($totalScore pts)');
      return;
    }

    setState(() => _creating = true);

    try {
      final result = await FirestoreService.instance.createChallenge(
        animeTitle: widget.animeTitle,
        betAmount:  bet,
      );

      if (!mounted) return;

      // Navigate straight into the quiz — don't let the user back out
      // since the bet is already deducted and the challenge is live.
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: QuestionsPage(
              mode:        QuizMode.asyncChallenge,
              questionIds: result.questionIds,
              challengeId: result.challengeId,
              isCreator:   true,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      _showError(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:         Text(msg),
        backgroundColor: AppColors.wrong,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userData   = context.watch<UserDataProvider>();
    final totalScore = userData.score;
    final quickBets  =
        [100, 500, 1000, 5000].where((b) => b <= totalScore).toList();

    return PopScope(
      canPop: !_creating,
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: Stack(
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new,
                                color: AppColors.textPrimary),
                            onPressed: _creating
                                ? null
                                : () => Navigator.pop(context),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Create Challenge',
                                  style: TextStyle(
                                    color:      AppColors.textPrimary,
                                    fontSize:   22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Text(
                                  widget.animeTitle,
                                  style: const TextStyle(
                                    color:    AppColors.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
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

                            // ── Balance Card ──────────────────────────────
                            GlassCard(
                              borderColor:
                                  AppColors.secondary.withOpacity(0.4),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('Your Balance',
                                          style: TextStyle(
                                              color:    AppColors.textMuted,
                                              fontSize: 13)),
                                      const SizedBox(height: 4),
                                      Text(
                                        '$totalScore pts',
                                        style: const TextStyle(
                                          color:      AppColors.textPrimary,
                                          fontSize:   28,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    width:  52,
                                    height: 52,
                                    decoration: BoxDecoration(
                                      color: AppColors.secondary
                                          .withOpacity(0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.stars_rounded,
                                        color: AppColors.secondary,
                                        size:  28),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 20),

                            // ── How it works card ─────────────────────────
                            GlassCard(
                              borderColor:
                                  AppColors.primary.withOpacity(0.3),
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: const [
                                  Row(
                                    children: [
                                      Icon(Icons.info_outline_rounded,
                                          color:    AppColors.primary,
                                          size:     16),
                                      SizedBox(width: 6),
                                      Text(
                                        'How challenges work',
                                        style: TextStyle(
                                          color:      AppColors.primary,
                                          fontSize:   13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 10),
                                  _HowItWorksStep(
                                    n: '1',
                                    text:
                                        'You play 10 questions immediately',
                                  ),
                                  _HowItWorksStep(
                                    n: '2',
                                    text:
                                        'Share your 6-letter code via WhatsApp',
                                  ),
                                  _HowItWorksStep(
                                    n: '3',
                                    text:
                                        'Opponent plays the same questions',
                                  ),
                                  _HowItWorksStep(
                                    n: '4',
                                    text:
                                        'Higher score wins both bets. Draw = refund',
                                    last: true,
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 28),

                            // ── Bet input ─────────────────────────────────
                            const Text(
                              'Enter Bet Amount',
                              style: TextStyle(
                                color:      AppColors.textPrimary,
                                fontSize:   18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller:    _ctrl,
                              keyboardType:  TextInputType.number,
                              enabled:       !_creating,
                              style: const TextStyle(
                                color:      AppColors.textPrimary,
                                fontSize:   24,
                                fontWeight: FontWeight.w700,
                              ),
                              decoration: const InputDecoration(
                                hintText:   '0',
                                prefixText: '⚡ ',
                                labelText:  'Points to stake',
                              ),
                              onChanged: (_) => setState(() {}),
                            ),

                            if (quickBets.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              const Text('Quick select',
                                  style: TextStyle(
                                      color:    AppColors.textMuted,
                                      fontSize: 13)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: quickBets
                                    .map(
                                      (b) => GestureDetector(
                                        onTap: _creating
                                            ? null
                                            : () => setState(
                                                () => _ctrl.text = '$b'),
                                        child: Chip(
                                          label: Text('$b'),
                                          backgroundColor: AppColors.surface,
                                          labelStyle: const TextStyle(
                                            color: AppColors.textSecondary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          side: const BorderSide(
                                              color: AppColors.divider),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],

                            const SizedBox(height: 36),
                            GradientButton(
                              label: 'Create Challenge',
                              onTap: _creating
                                  ? null
                                  : () => _createChallenge(totalScore),
                              icon: Icons.flash_on_rounded,
                            ),
                            const SizedBox(height: 12),
                            const Center(
                              child: Text(
                                'Minimum 100 pts • Multiples of 100 only',
                                style: TextStyle(
                                    color:    AppColors.textMuted,
                                    fontSize: 12),
                              ),
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                // ── Creating overlay ──────────────────────────────────────
                if (_creating)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                              color: AppColors.primary),
                          SizedBox(height: 16),
                          Text(
                            'Setting up your challenge…',
                            style: TextStyle(
                              color:    AppColors.textPrimary,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Small helpers ─────────────────────────────────────────────────────────────
class _HowItWorksStep extends StatelessWidget {
  final String n;
  final String text;
  final bool   last;

  const _HowItWorksStep({
    required this.n,
    required this.text,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 6),
      child: Row(
        children: [
          Container(
            width:  20,
            height: 20,
            decoration: BoxDecoration(
              color:        AppColors.primary.withOpacity(0.15),
              shape:        BoxShape.circle,
              border: Border.all(color: AppColors.primary, width: 1),
            ),
            child: Center(
              child: Text(
                n,
                style: const TextStyle(
                  color:      AppColors.primary,
                  fontSize:   10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color:    AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}