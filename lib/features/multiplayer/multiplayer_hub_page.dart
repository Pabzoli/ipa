import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/providers/user_data_provider.dart';
import 'anime_select_page.dart';
import 'join_challenge_page.dart';

// ─── Entry hub for all multiplayer features ────────────────────────────────────
// What changed: Previously there was no hub — the drawer went directly to
// BetScreen or JoinChallengePage with no unified entry. This page gives users
// a clear choice between creating and joining, with visual hierarchy that
// communicates how the system works at a glance.
class MultiplayerHubPage extends StatefulWidget {
  const MultiplayerHubPage({super.key});

  @override
  State<MultiplayerHubPage> createState() => _MultiplayerHubPageState();
}

class _MultiplayerHubPageState extends State<MultiplayerHubPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    // Ambient pulsing glow on the arena badge — gives energy without being
    // distracting
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _goCreate() => Navigator.push(
        context,
        _slideRoute(const AnimeSelectPage()),
      );

  void _goJoin() => Navigator.push(
        context,
        _slideRoute(const JoinChallengePage()),
      );

  PageRoute _slideRoute(Widget page) => PageRouteBuilder(
        pageBuilder: (_, a, __) => page,
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 350),
      );

  @override
  Widget build(BuildContext context) {
    final score = context.watch<UserDataProvider>().score;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: Container(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            children: [
              _HubAppBar(score: score),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 12),
                      _ArenaBanner(pulseAnim: _pulseAnim),
                      const SizedBox(height: 32),

                      // ── How it works strip ─────────────────────────────
                      const _HowItWorksStrip(),
                      const SizedBox(height: 32),

                      // ── Main action cards ──────────────────────────────
                      // CREATE card — visually dominant (bigger, warmer gradient)
                      _ActionCard(
                        icon: Icons.add_circle_outline_rounded,
                        emoji: '⚔️',
                        title: 'Create Challenge',
                        subtitle:
                            'Pick an anime, set a bet, play first.\nShare your code with anyone.',
                        gradientColors: const [
                          Color(0xFF7C3AED),
                          Color(0xFF4F46E5),
                        ],
                        onTap: _goCreate,
                        isPrimary: true,
                      ),
                      const SizedBox(height: 14),

                      // JOIN card — secondary, cooler tone
                      _ActionCard(
                        icon: Icons.login_rounded,
                        emoji: '🎯',
                        title: 'Join Challenge',
                        subtitle:
                            'Got a 6-character code?\nEnter it and beat your rival.',
                        gradientColors: const [
                          Color(0xFF0EA5E9),
                          Color(0xFF0284C7),
                        ],
                        onTap: _goJoin,
                        isPrimary: false,
                      ),

                      const SizedBox(height: 32),

                      // ── Rules card ─────────────────────────────────────
                      const _RulesCard(),
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

// ── App bar with back + balance ────────────────────────────────────────────────
class _HubAppBar extends StatelessWidget {
  final int score;
  const _HubAppBar({required this.score});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: AppColors.textPrimary, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          const Text(
            'Battle Arena',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const Spacer(),
          // Balance pill — always visible so user knows their stake power
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.secondary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: AppColors.secondary.withOpacity(0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.stars_rounded,
                    color: AppColors.secondary, size: 16),
                const SizedBox(width: 4),
                Text(
                  '$score',
                  style: const TextStyle(
                    color: AppColors.secondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Arena banner with animated pulse ──────────────────────────────────────────
class _ArenaBanner extends StatelessWidget {
  final Animation<double> pulseAnim;
  const _ArenaBanner({required this.pulseAnim});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseAnim,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(vertical: 28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A103C), Color(0xFF0D1B2A)],
          ),
          border: Border.all(
            color: AppColors.primary.withOpacity(0.3 * pulseAnim.value),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withOpacity(0.15 * pulseAnim.value),
              blurRadius: 24,
              spreadRadius: 4,
            ),
          ],
        ),
        child: Column(
          children: [
            // Animated swords icon
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        AppColors.primary.withOpacity(0.12 * pulseAnim.value),
                  ),
                ),
                const Text('⚔️', style: TextStyle(fontSize: 38)),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'ASYNC MULTIPLAYER',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 4),
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [Color(0xFFA78BFA), Color(0xFF818CF8)],
              ).createShader(r),
              child: const Text(
                'Challenge your rival',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Play now • They play when ready • Winner takes all',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── 3-step how-it-works strip ──────────────────────────────────────────────────
class _HowItWorksStrip extends StatelessWidget {
  const _HowItWorksStrip();

  static const _steps = [
    ('🎮', 'You play\nfirst'),
    ('📤', 'Share\nyour code'),
    ('🏆', 'Best score\nwins'),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(_steps.length * 2 - 1, (i) {
        if (i.isOdd) {
          return const Expanded(
            child: Divider(
              color: AppColors.divider,
              thickness: 1,
              indent: 4,
              endIndent: 4,
            ),
          );
        }
        final step = _steps[i ~/ 2];
        return _StepDot(emoji: step.$1, label: step.$2);
      }),
    );
  }
}

class _StepDot extends StatelessWidget {
  final String emoji;
  final String label;
  const _StepDot({required this.emoji, required this.label});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.divider),
            ),
            child:
                Center(child: Text(emoji, style: const TextStyle(fontSize: 22))),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      );
}

// ── Big action card ────────────────────────────────────────────────────────────
// Why: The previous design had no hub at all. These cards need to communicate
// the action clearly and feel tappable/exciting. The gradient border + inner
// gradient + scale on hover creates a premium feel.
class _ActionCard extends StatefulWidget {
  final IconData icon;
  final String emoji;
  final String title;
  final String subtitle;
  final List<Color> gradientColors;
  final VoidCallback onTap;
  final bool isPrimary;

  const _ActionCard({
    required this.icon,
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.gradientColors,
    required this.onTap,
    required this.isPrimary,
  });

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleCtrl;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = widget.gradientColors.first;

    return ScaleTransition(
      scale: _scaleAnim,
      child: GestureDetector(
        onTapDown: (_) => _scaleCtrl.forward(),
        onTapUp: (_) {
          _scaleCtrl.reverse();
          widget.onTap();
        },
        onTapCancel: () => _scaleCtrl.reverse(),
        child: Container(
          padding: const EdgeInsets.all(1.5), // gradient border trick
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: widget.gradientColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Container(
            padding: EdgeInsets.all(widget.isPrimary ? 24 : 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(23),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  primary.withOpacity(0.18),
                  primary.withOpacity(0.06),
                ],
              ),
              color: AppColors.surfaceDim,
            ),
            child: Row(
              children: [
                // Icon area
                Container(
                  width: widget.isPrimary ? 64 : 56,
                  height: widget.isPrimary ? 64 : 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: widget.gradientColors,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      widget.emoji,
                      style: TextStyle(
                          fontSize: widget.isPrimary ? 28 : 24),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: widget.isPrimary ? 20 : 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.subtitle,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: primary.withOpacity(0.7),
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Rules card ─────────────────────────────────────────────────────────────────
class _RulesCard extends StatelessWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Text('📋', style: TextStyle(fontSize: 16)),
              SizedBox(width: 8),
              Text(
                'How Scoring Works',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _RuleRow(
              icon: Icons.emoji_events_rounded,
              color: AppColors.correct,
              text: 'Win → You get BOTH bets (double your stake)'),
          const SizedBox(height: 8),
          _RuleRow(
              icon: Icons.compare_arrows_rounded,
              color: AppColors.secondary,
              text: 'Draw → Both bets are fully refunded'),
          const SizedBox(height: 8),
          _RuleRow(
              icon: Icons.trending_down_rounded,
              color: AppColors.wrong,
              text: 'Lose → Your stake goes to your opponent'),
          const SizedBox(height: 8),
          _RuleRow(
              icon: Icons.timer_off_rounded,
              color: AppColors.textMuted,
              text: 'Unclaimed challenges expire after 24 hours'),
        ],
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _RuleRow(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      );
}