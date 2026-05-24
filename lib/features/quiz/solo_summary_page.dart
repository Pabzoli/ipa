// lib/features/quiz/solo_summary_page.dart
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/ad_service.dart';
import '../../core/providers/user_data_provider.dart';
import '../questions/questions_page.dart';
import 'share_card_widget.dart';

class SoloSummaryPage extends StatefulWidget {
  final int          correctCount;
  final int          totalQuestions;
  final List<String> selectedTitles;

  const SoloSummaryPage({
    super.key,
    required this.correctCount,
    required this.totalQuestions,
    required this.selectedTitles,
  });

  @override
  State<SoloSummaryPage> createState() => _SoloSummaryPageState();
}

class _SoloSummaryPageState extends State<SoloSummaryPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _scaleAnim;
  late Animation<double>   _fadeAnim;

  bool _navigating = false;
  bool _adWatched  = false;
  bool _isSharing  = false;   // ← NEW: guards the share button

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _scaleAnim = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fadeAnim  = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int get _pointsEarned => widget.correctCount * 10;

  _Tier get _tier {
    final ratio = widget.correctCount / widget.totalQuestions;
    if (ratio == 1.0) return _Tier.perfect;
    if (ratio >= 0.8) return _Tier.great;
    if (ratio >= 0.5) return _Tier.good;
    return _Tier.keepPracticing;
  }

  // ── Share ──────────────────────────────────────────────────────────────────

  Future<void> _shareResult() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);

    try {
      // Resolve username — displayName > email prefix > fallback
      final fbUser  = FirebaseAuth.instance.currentUser;
      final username = (fbUser?.displayName?.isNotEmpty == true)
          ? fbUser!.displayName!
          : fbUser?.email?.split('@').first ?? 'Player';

      final userData = context.read<UserDataProvider>();

      // Render the off-screen card. Wrapping in Theme + Directionality
      // ensures fonts and text direction are available outside the live tree.
      final bytes = await ScreenshotController().captureFromWidget(
        Theme(
          data: AppTheme.dark,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ShareCardWidget(
              correctCount:   widget.correctCount,
              totalQuestions: widget.totalQuestions,
              selectedTitles: widget.selectedTitles,
              username:       username,
              tierEmoji:      _tier.emoji,
              tierTitle:      _tier.title,
              tierColor:      _tier.color,
              weeklyPoints:   userData.weeklyPoints,
              totalScore:     userData.score,
            ),
          ),
        ),
        context:    context,
        delay:      const Duration(milliseconds: 300),
        pixelRatio: 3.0,
        targetSize: const Size(ShareCardWidget.kWidth, ShareCardWidget.kHeight),
      );

      // Write to temp file (timestamp prevents stale cached images)
      final dir  = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/animequiz_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);

      if (!mounted) return;

      await Share.shareXFiles(
        [XFile(file.path)],
        text: '🎌 I scored ${widget.correctCount}/${widget.totalQuestions}'
            ' on AnimeQuiz!\nCan you beat me?',
      );
    } catch (e, st) {
      debugPrint('[ShareResult] error: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn\'t generate share card — please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (_) => _goHome(),
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        body: Container(
          decoration: AppDecorations.heroBg,
          child: SafeArea(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const SizedBox(height: 32),

                    // ── Result emoji + title ───────────────────────────────
                    ScaleTransition(
                      scale: _scaleAnim,
                      child: Column(
                        children: [
                          Text(
                            _tier.emoji,
                            style: const TextStyle(fontSize: 72),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _tier.title,
                            style: const TextStyle(
                              color:      AppColors.textPrimary,
                              fontSize:   28,
                              fontWeight: FontWeight.w900,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _tier.subtitle,
                            style: const TextStyle(
                              color:    AppColors.textSecondary,
                              fontSize: 14,
                              height:   1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 36),

                    // ── Score card ─────────────────────────────────────────
                    GlassCard(
                      borderColor: _tier.color.withOpacity(0.4),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${widget.correctCount}',
                                style: TextStyle(
                                  color:      _tier.color,
                                  fontSize:   64,
                                  fontWeight: FontWeight.w900,
                                  height:     1,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(
                                  ' / ${widget.totalQuestions}',
                                  style: const TextStyle(
                                    color:      AppColors.textSecondary,
                                    fontSize:   24,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'correct answers',
                            style: TextStyle(
                              color:    AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 20),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value:           widget.correctCount /
                                               widget.totalQuestions,
                              backgroundColor: AppColors.divider,
                              valueColor:      AlwaysStoppedAnimation(_tier.color),
                              minHeight:       10,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 12),
                            decoration: BoxDecoration(
                              color:        AppColors.accent.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border:       Border.all(
                                  color: AppColors.accent.withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.stars_rounded,
                                    color: AppColors.accent, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  '+$_pointsEarned pts added to your balance',
                                  style: const TextStyle(
                                    color:      AppColors.accent,
                                    fontSize:   14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ── Hint nudge ─────────────────────────────────────────
                    if (widget.correctCount < 5)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border:
                              Border.all(color: AppColors.divider),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.info_outline_rounded,
                                color: AppColors.textMuted, size: 20),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Struggling? Use hints next round — or'
                                ' watch an ad to earn more.',
                                style: TextStyle(
                                  color:    AppColors.textSecondary,
                                  fontSize: 13,
                                  height:   1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 32),

                    // ── Actions ────────────────────────────────────────────
                    GradientButton(
                      label:  'Play Again',
                      icon:   Icons.refresh_rounded,
                      onTap:  _playAgain,
                      colors: const [AppColors.primary, Color(0xFFFF6B6B)],
                    ),
                    const SizedBox(height: 12),

                    // ── Share Result ───────────────────────────────────────
                    // Swaps to a subtle loading container while the card is
                    // being rendered and the share sheet is being prepared.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _isSharing
                          ? _ShareLoadingIndicator(key: const ValueKey('loading'))
                          : _ShareButton(
                              key:   const ValueKey('share'),
                              onTap: _shareResult,
                            ),
                    ),
                    const SizedBox(height: 12),

                    // ── Watch Ad for bonus ─────────────────────────────────
                    if (!_adWatched)
                      GestureDetector(
                        onTap: _watchAdForBonus,
                        child: Container(
                          width: double.infinity,
                          height: 52,
                          decoration: BoxDecoration(
                            color: AppColors.accent.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: AppColors.accent.withOpacity(0.4)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.play_circle_outline_rounded,
                                  color: AppColors.accent, size: 20),
                              SizedBox(width: 8),
                              Text(
                                'Watch ad  →  +30 pts  +1 hint',
                                style: TextStyle(
                                  color:      AppColors.accent,
                                  fontSize:   14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_adWatched)
                      Container(
                        width: double.infinity,
                        height: 52,
                        decoration: BoxDecoration(
                          color: AppColors.correct.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: AppColors.correct.withOpacity(0.3)),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_outline_rounded,
                                color: AppColors.correct, size: 20),
                            SizedBox(width: 8),
                            Text(
                              '+30 pts  +1 hint earned!',
                              style: TextStyle(
                                color:      AppColors.correct,
                                fontSize:   14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _goHome,
                        icon: const Icon(Icons.home_rounded,
                            color: AppColors.textSecondary, size: 18),
                        label: const Text(
                          'Back to Home',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side:    const BorderSide(color: AppColors.divider),
                          shape:   RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Handlers ───────────────────────────────────────────────────────────────

  Future<void> _watchAdForBonus() async {
    if (_adWatched) return;
    final ud    = context.read<UserDataProvider>();
    final shown = await AdService.instance.showRewarded(
      onRewarded: () async {
        await ud.addWeeklyPoints(30);
        await ud.addHint();
        if (mounted) setState(() => _adWatched = true);
      },
    );
    if (!shown && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Ad not ready yet — try again in a moment.')),
      );
    }
  }

  void _goHome() {
    if (_navigating) return;
    _navigating = true;
    Navigator.of(context).pop();
  }

  void _playAgain() {
    if (_navigating) return;
    _navigating = true;
    AdService.instance.showInterstitial();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, a, __) => FadeTransition(
          opacity: a,
          child: QuestionsPage(selectedTitles: widget.selectedTitles),
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }
}

// ── Share button widgets ────────────────────────────────────────────────────

class _ShareButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ShareButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          height: 52,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF5B2D8E), Color(0xFF7B4FBB)],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7B4FBB).withOpacity(0.35),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.ios_share_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(
                'Share Result',
                style: TextStyle(
                  color:      Colors.white,
                  fontSize:   15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      );
}

class _ShareLoadingIndicator extends StatelessWidget {
  const _ShareLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: const Color(0xFF5B2D8E).withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF7B4FBB).withOpacity(0.3),
          ),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 15, height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF9B6FDB),
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Creating share card…',
              style: TextStyle(
                color:      Color(0xFF9B6FDB),
                fontSize:   14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
}

// ── Performance Tiers ──────────────────────────────────────────────────────
enum _Tier { perfect, great, good, keepPracticing }

extension _TierProps on _Tier {
  String get emoji {
    switch (this) {
      case _Tier.perfect:        return '🏆';
      case _Tier.great:          return '🔥';
      case _Tier.good:           return '⚔️';
      case _Tier.keepPracticing: return '📖';
    }
  }

  String get title {
    switch (this) {
      case _Tier.perfect:        return 'Perfect Score!';
      case _Tier.great:          return 'You\'re on Fire!';
      case _Tier.good:           return 'Good Fight!';
      case _Tier.keepPracticing: return 'Keep Training!';
    }
  }

  String get subtitle {
    switch (this) {
      case _Tier.perfect:
        return 'Flawless. You know your anime.';
      case _Tier.great:
        return 'Strong performance — leaderboard material.';
      case _Tier.good:
        return 'Decent run. One more session and you\'re climbing.';
      case _Tier.keepPracticing:
        return 'Every legend starts somewhere. Keep going.';
    }
  }

  Color get color {
    switch (this) {
      case _Tier.perfect:        return AppColors.accent;
      case _Tier.great:          return AppColors.correct;
      case _Tier.good:           return AppColors.secondary;
      case _Tier.keepPracticing: return AppColors.textMuted;
    }
  }
}