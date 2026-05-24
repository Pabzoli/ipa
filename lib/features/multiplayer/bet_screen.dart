// lib/features/multiplayer/bet_screen.dart
//
// CHANGES FROM ORIGINAL:
//  - Removed FindingOpponentScreen, _OpponentDialog, _InfoRow (all fake-opponent code).
//  - BetScreen: button copy "Find Opponent" → "Create Challenge";
//    navigates to AnimePickPage instead of FindingOpponentScreen.
//  - Added "Join a Challenge" secondary button → JoinChallengePage.
//  - Added AnimePickPage: fetches live anime list, lets user pick one,
//    then creates the challenge and navigates to ChallengeLobbyPage.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import 'models/challenge_model.dart';
import 'challenge_lobby_page.dart';
import 'join_challenge_page.dart';

// ─── Bet Screen ───────────────────────────────────────────────────────────────
class BetScreen extends StatefulWidget {
  const BetScreen({super.key});

  @override
  State<BetScreen> createState() => _BetScreenState();
}

class _BetScreenState extends State<BetScreen> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onCreateChallenge(int totalScore) {
    final bet = int.tryParse(_ctrl.text.trim()) ?? 0;
    if (bet < 100 || bet > 99000 || bet % 100 != 0 || bet > totalScore) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter a valid bet: multiple of 100, between 100–99,000, '
            'and within your balance.',
          ),
          backgroundColor: AppColors.wrong,
        ),
      );
      return;
    }

    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) =>
            FadeTransition(opacity: a, child: AnimePickPage(betAmount: bet)),
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userData   = context.watch<UserDataProvider>();
    final totalScore = userData.score;
    final quickBets  =
        [100, 500, 1000, 5000].where((b) => b <= totalScore).toList();

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: Container(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            children: [
              // ── Header ─────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: AppColors.textPrimary),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Text(
                      'Challenge a Friend',
                      style: TextStyle(
                        color:      AppColors.textPrimary,
                        fontSize:   22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),

              // ── Body ───────────────────────────────────────────────────────
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 16),

                      // Balance card
                      GlassCard(
                        borderColor: AppColors.secondary.withOpacity(0.4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                color: AppColors.secondary.withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.stars_rounded,
                                  color: AppColors.secondary, size: 28),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 28),

                      // ── Create Challenge section ──────────────────────────
                      const Text(
                        'Set Your Bet',
                        style: TextStyle(
                          color:      AppColors.textPrimary,
                          fontSize:   18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Send a code to your friend. Whoever scores higher wins the bet.',
                        style: TextStyle(
                          color:    AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 16),

                      TextField(
                        controller:   _ctrl,
                        keyboardType: TextInputType.number,
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
                                color: AppColors.textMuted, fontSize: 13)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: quickBets
                              .map((b) => GestureDetector(
                                    onTap: () =>
                                        setState(() => _ctrl.text = '$b'),
                                    child: Chip(
                                      label: Text('$b'),
                                      backgroundColor: AppColors.surface,
                                      labelStyle: const TextStyle(
                                        color:      AppColors.textSecondary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      side: const BorderSide(
                                          color: AppColors.divider),
                                    ),
                                  ))
                              .toList(),
                        ),
                      ],

                      const SizedBox(height: 28),

                      GradientButton(
                        label: 'Create Challenge',
                        onTap: () => _onCreateChallenge(totalScore),
                        icon:  Icons.bolt_rounded,
                      ),

                      const SizedBox(height: 12),
                      const Center(
                        child: Text(
                          'Minimum 100 pts · Multiples of 100 only',
                          style: TextStyle(
                              color: AppColors.textMuted, fontSize: 12),
                        ),
                      ),

                      // ── Divider ───────────────────────────────────────────
                      const SizedBox(height: 32),
                      Row(
                        children: [
                          const Expanded(
                              child: Divider(color: AppColors.divider)),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'OR',
                              style: TextStyle(
                                color:    AppColors.textMuted.withOpacity(0.6),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                          const Expanded(
                              child: Divider(color: AppColors.divider)),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // ── Join a Challenge ──────────────────────────────────
                      OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          PageRouteBuilder(
                            pageBuilder: (_, a, __) => FadeTransition(
                              opacity: a,
                              child: const JoinChallengePage(),
                            ),
                            transitionDuration:
                                const Duration(milliseconds: 350),
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: BorderSide(
                              color: AppColors.primary.withOpacity(0.5)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        icon: const Icon(Icons.link_rounded),
                        label: const Text(
                          'Join a Challenge',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Center(
                        child: Text(
                          'Have a code from a friend? Enter it here.',
                          style: TextStyle(
                              color: AppColors.textMuted, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 24),
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

// ─── Anime Pick Page ──────────────────────────────────────────────────────────
/// Second step: pick the anime category, then create the challenge.
class AnimePickPage extends StatefulWidget {
  final int betAmount;
  const AnimePickPage({super.key, required this.betAmount});

  @override
  State<AnimePickPage> createState() => _AnimePickPageState();
}

class _AnimePickPageState extends State<AnimePickPage> {
  List<String> _animeList    = [];
  String?      _selected;
  bool         _loadingAnime = true;
  bool         _creating     = false;
  String?      _error;

  @override
  void initState() {
    super.initState();
    _loadAnime();
  }

  Future<void> _loadAnime() async {
    try {
      final list = await FirestoreService.instance.fetchAvailableAnime();
      if (!mounted) return;
      setState(() {
        _animeList    = list;
        _loadingAnime = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error        = e.toString().replaceFirst('Exception: ', '');
        _loadingAnime = false;
      });
    }
  }

  Future<void> _createChallenge() async {
    if (_selected == null || _creating) return;
    setState(() => _creating = true);
    try {
      final challenge = await FirestoreService.instance.createChallenge(
        animeTitle: _selected!,
        betAmount:  widget.betAmount,
      );
      if (!mounted) return;
      // Replace AnimePickPage with ChallengeLobbyPage — back goes to BetScreen.
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: ChallengeLobbyPage(challenge: challenge),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:         Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: AppColors.wrong,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pick Your Anime',
                            style: TextStyle(
                              color:      AppColors.textPrimary,
                              fontSize:   22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'Both players answer questions from this anime.',
                            style: TextStyle(
                                color: AppColors.textMuted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Bet badge ──────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.secondary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppColors.secondary.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.bolt_rounded,
                          color: AppColors.secondary, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        'Bet: ${widget.betAmount} pts',
                        style: const TextStyle(
                          color:      AppColors.secondary,
                          fontWeight: FontWeight.w700,
                          fontSize:   14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Anime grid ─────────────────────────────────────────────────
              Expanded(
                child: _loadingAnime
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary))
                    : _error != null
                        ? _ErrorRetry(
                            message: _error!,
                            onRetry: () {
                              setState(() {
                                _error        = null;
                                _loadingAnime = true;
                              });
                              _loadAnime();
                            })
                        : _animeList.isEmpty
                            ? const Center(
                                child: Text(
                                  'No anime found.\nAdd questions to Firestore first.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color:    AppColors.textMuted,
                                      fontSize: 15),
                                ),
                              )
                            : GridView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                    20, 8, 20, 24),
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount:    2,
                                  mainAxisSpacing:   12,
                                  crossAxisSpacing:  12,
                                  childAspectRatio:  2.4,
                                ),
                                itemCount:   _animeList.length,
                                itemBuilder: (_, i) {
                                  final title    = _animeList[i];
                                  final selected = _selected == title;
                                  return _AnimeTile(
                                    title:    title,
                                    selected: selected,
                                    onTap:    () =>
                                        setState(() => _selected = title),
                                  );
                                },
                              ),
              ),

              // ── CTA ────────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: _creating
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary))
                    : GradientButton(
                        label:    'Generate Challenge Code',
                        icon:     Icons.bolt_rounded,
                        onTap:    _selected != null ? _createChallenge : null,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Anime Tile ───────────────────────────────────────────────────────────────
class _AnimeTile extends StatelessWidget {
  final String   title;
  final bool     selected;
  final VoidCallback onTap;
  const _AnimeTile(
      {required this.title,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.primary.withOpacity(0.15)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.divider,
          width: selected ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap:        onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                if (selected)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(Icons.check_circle_rounded,
                        color: AppColors.primary, size: 18),
                  ),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: selected
                          ? AppColors.primary
                          : AppColors.textPrimary,
                      fontSize:   14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines:  2,
                    overflow:  TextOverflow.ellipsis,
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

// ─── Error + Retry ────────────────────────────────────────────────────────────
class _ErrorRetry extends StatelessWidget {
  final String       message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded,
                  color: AppColors.wrong, size: 48),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 14)),
              const SizedBox(height: 20),
              GradientButton(
                  label: 'Retry',
                  icon: Icons.refresh_rounded,
                  onTap: onRetry),
            ],
          ),
        ),
      );
}
