import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';

// ─── Private constants ────────────────────────────────────────────────────────
const int   _kCountdown = 8;
const Color _kGold      = Color(0xFFFFD700);
const Color _kSilver    = Color(0xFFD0D0D0);
const Color _kBronze    = Color(0xFFCD7F32);
const Color _kWhatsApp  = Color(0xFF25D366);
const Color _kBg        = Color(0xFF090913);

const List<Color> _rankColors = [_kGold, _kSilver, _kBronze];
const List<List<Color>> _rankGradients = [
  [Color(0xFFFFD700), Color(0xFFF5900C)],
  [Color(0xFFDCDCDC), Color(0xFF9A9A9A)],
  [Color(0xFFCD7F32), Color(0xFF8B5E3C)],
];
const List<String> _medals = ['🥇', '🥈', '🥉'];

// ─── Naira formatter (file-level, no intl dep needed) ────────────────────────
String _fmtNaira(double amount) {
  final n = amount.toInt().toString();
  final b = StringBuffer();
  for (int i = 0; i < n.length; i++) {
    if (i > 0 && (n.length - i) % 3 == 0) b.write(',');
    b.write(n[i]);
  }
  return b.toString();
}

// ═══════════════════════════════════════════════════════════════════════════════
// PARTICLE SYSTEM
// ─────────────────────────────────────────────────────────────────────────────
// Isolated in its own StatefulWidget + CustomPainter so no part of the
// announcement page widget tree ever rebuilds because of particle ticks.
// The AnimationController drives a repaint-boundary-scoped canvas redraw;
// the widget tree itself is never marked dirty by the particle logic.
// ═══════════════════════════════════════════════════════════════════════════════

class _PData {
  double x, y, vx, vy, life, radius;
  Color  color;

  _PData(this.x, this.y, this.vx, this.vy, this.life, this.radius, this.color);

  static const _palette = [
    Color(0xFFFFD700),
    Color(0xFFFFA500),
    Color(0xFFFFEC5C),
    Color(0xFFE63946),
  ];

  factory _PData.random(math.Random r, {bool spread = false}) => _PData(
        r.nextDouble(),
        spread ? r.nextDouble() : 1.05 + r.nextDouble() * 0.15,
        (r.nextDouble() - 0.5) * 0.022,
        0.018 + r.nextDouble() * 0.038,
        spread ? r.nextDouble() : 0.5 + r.nextDouble() * 0.5,
        1.5 + r.nextDouble() * 3.0,
        _palette[r.nextInt(_palette.length)],
      );

  void reset(math.Random r) {
    x      = r.nextDouble();
    y      = 1.05 + r.nextDouble() * 0.15;
    vx     = (r.nextDouble() - 0.5) * 0.022;
    vy     = 0.018 + r.nextDouble() * 0.038;
    life   = 0.5 + r.nextDouble() * 0.5;
    radius = 1.5 + r.nextDouble() * 3.0;
    color  = _palette[r.nextInt(_palette.length)];
  }
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter({required this.particles, required Listenable repaint})
      : super(repaint: repaint);

  final List<_PData> particles;
  // Reuse a single Paint to avoid per-particle object allocation.
  final _p = Paint()..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      if (p.life <= 0) continue;
      _p.color = p.color.withValues(alpha: (p.life * 0.65).clamp(0.0, 0.65));
      canvas.drawCircle(
        Offset(p.x * size.width, p.y * size.height),
        (p.radius * p.life).clamp(0.0, 5.0),
        _p,
      );
    }
  }

  // shouldRepaint is only called on parent-driven rebuilds.
  // The listenable handles frame-driven repaints independently.
  @override
  bool shouldRepaint(_ParticlePainter _) => false;
}

class _ParticleField extends StatefulWidget {
  const _ParticleField();

  @override
  State<_ParticleField> createState() => _ParticleFieldState();
}

class _ParticleFieldState extends State<_ParticleField>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late List<_PData>        _ps;
  final _rand = math.Random();

  @override
  void initState() {
    super.initState();
    // Pre-scatter particles so the screen isn't empty for the first second.
    _ps   = List.generate(30, (i) => _PData.random(_rand, spread: true));
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(seconds: 12),
    )
      ..addListener(_tick)
      ..repeat();
  }

  void _tick() {
    // Mutate in place — no setState, the repaint listenable handles the redraw.
    for (final p in _ps) {
      p.y    -= p.vy * 0.016;
      p.x    += p.vx * 0.016;
      p.life -= 0.016 * 0.075;
      if (p.life <= 0 || p.y < -0.05) p.reset(_rand);
    }
  }

  @override
  void dispose() {
    _ctrl
      ..removeListener(_tick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _ParticlePainter(particles: _ps, repaint: _ctrl),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// WINNER ANNOUNCEMENT PAGE
// ═══════════════════════════════════════════════════════════════════════════════

/// Full-screen Monday announcement of last week's prize winners.
///
/// Shown automatically by [_AnnouncementGate] in main.dart.
/// Auto-dismisses after [_kCountdown] seconds. User can also tap
/// "Skip" or the CTA button to leave early.
///
/// Pops with `'leaderboard'` when the CTA is tapped so the caller
/// can optionally push the weekly leaderboard route.
class WinnerAnnouncementPage extends StatefulWidget {
  const WinnerAnnouncementPage({super.key, required this.result});

  final LastWeekResult result;

  @override
  State<WinnerAnnouncementPage> createState() => _WinnerAnnouncementPageState();
}

class _WinnerAnnouncementPageState extends State<WinnerAnnouncementPage>
    with TickerProviderStateMixin {

  // ── Animation controllers ─────────────────────────────────────────────────
  late final AnimationController _entranceCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _ctaCtrl;

  // ── Derived animations ────────────────────────────────────────────────────
  late final Animation<double> _fadeIn;
  late final Animation<Offset> _slideUp;
  late final Animation<double> _trophyPulse;
  late final Animation<double> _ctaPulse;

  // ── Countdown state ───────────────────────────────────────────────────────
  int    _countdown = _kCountdown;
  Timer? _timer;

  @override
  void initState() {
    super.initState();

    _entranceCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1100),
    );
    _pulseCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _ctaCtrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _fadeIn = CurvedAnimation(
      parent: _entranceCtrl,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    _slideUp = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end:   Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entranceCtrl,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
    ));
    _trophyPulse = Tween<double>(begin: 0.93, end: 1.07).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _ctaPulse = Tween<double>(begin: 1.0, end: 1.025).animate(
      CurvedAnimation(parent: _ctaCtrl, curve: Curves.easeInOut),
    );

    _entranceCtrl.forward();
    _startCountdown();
  }

  /// Returns a staggered animation for the winner card at [index].
  /// Cards enter sequentially with a slight overlap between each.
  Animation<double> _cardAnim(int index) {
    final s = (0.28 + index * 0.09).clamp(0.0, 0.82);
    final e = (s + 0.32).clamp(0.15, 1.0);
    return Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: Interval(s, e, curve: Curves.easeOutBack),
      ),
    );
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_countdown <= 1) {
        t.cancel();
        _dismiss();
      } else {
        setState(() => _countdown--);
      }
    });
  }

  void _dismiss({bool goToLeaderboard = false}) {
    _timer?.cancel();
    if (mounted) {
      Navigator.of(context).pop(goToLeaderboard ? 'leaderboard' : null);
    }
  }

  String _weekRange() {
    final parts = widget.result.weekId.split('-');
    if (parts.length < 3) return widget.result.weekId;
    final mon = DateTime(
      int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]),
    );
    final sun = mon.add(const Duration(days: 6));
    const mo  = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec',
    ];
    final s = '${mo[mon.month - 1]} ${mon.day}';
    final e = mon.month == sun.month
        ? '${sun.day}'
        : '${mo[sun.month - 1]} ${sun.day}';
    return '$s–$e, ${mon.year}';
  }

  Future<void> _share() async {
    HapticFeedback.lightImpact();
    final winners = widget.result.winners;
    if (winners.isEmpty) return;
    // Include all top 3 winners in the share text for more social proof.
    final lines = winners.take(3).map((p) {
      final medal = p.rank <= 3 ? _medals[p.rank - 1] : '#${p.rank}';
      return '$medal ${p.username} (${p.university}) — ₦${_fmtNaira(p.prizeAmount)}';
    }).join('\n');
    final text = '🎌 AnimeQuiz Champions (${_weekRange()}):\n$lines\n\n'
        'Think you can top this? Join AnimeQuiz now!';
    final url = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _pulseCtrl.dispose();
    _ctaCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final winners = widget.result.winners.take(5).toList();

    return Scaffold(
      backgroundColor: _kBg,
      body: Stack(
        children: [
          // ── Gold particle field — isolated, never causes tree rebuilds ────
          const Positioned.fill(child: _ParticleField()),

          // ── Gradient overlay for readability ──────────────────────────────
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF0F0B20).withValues(alpha: 0.97),
                    const Color(0xFF090913).withValues(alpha: 0.95),
                    const Color(0xFF13091E).withValues(alpha: 0.97),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),

          // ── Page content ─────────────────────────────────────────────────
          SafeArea(
            child: FadeTransition(
              opacity: _fadeIn,
              child: SlideTransition(
                position: _slideUp,
                child: Column(
                  children: [
                    _TopBar(
                      countdown: _countdown,
                      total:     _kCountdown,
                      onSkip: () {
                        HapticFeedback.lightImpact();
                        _dismiss();
                      },
                      onShare: _share,
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 4),
                            _Header(
                              pulse:     _trophyPulse,
                              weekRange: _weekRange(),
                            ),
                            const SizedBox(height: 22),
                            _PrizePoolBanner(
                              formatted: _fmtNaira(widget.result.totalNaira),
                            ),
                            const SizedBox(height: 18),
                            // Staggered winner cards
                            ...winners.asMap().entries.map(
                              (e) => _WinnerCard(
                                key:       ValueKey(e.value.uid),
                                winner:    e.value,
                                listIndex: e.key,
                                formatted: _fmtNaira(e.value.prizeAmount),
                                animation: _cardAnim(e.key),
                              ),
                            ),
                            const SizedBox(height: 26),
                            _CtaButton(
                              pulse: _ctaPulse,
                              onTap: () {
                                HapticFeedback.mediumImpact();
                                _dismiss(goToLeaderboard: true);
                              },
                            ),
                            const SizedBox(height: 12),
                            _ShareButton(onTap: _share),
                            const SizedBox(height: 40),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SUB-WIDGETS
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Top Bar ──────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.countdown,
    required this.total,
    required this.onSkip,
    required this.onShare,
  });

  final int          countdown;
  final int          total;
  final VoidCallback onSkip;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _SkipButton(countdown: countdown, total: total, onTap: onSkip),
          _ShareIconButton(onTap: onShare),
        ],
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.countdown,
    required this.total,
    required this.onTap,
  });

  final int          countdown;
  final int          total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color:        Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(24),
          border:       Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Skip',
              style: TextStyle(
                color:      Colors.white.withValues(alpha: 0.7),
                fontSize:   13,
                fontWeight: FontWeight.w600,
                fontFamily: 'Nunito',
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width:  24,
              height: 24,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value:           countdown / total,
                    strokeWidth:     2.5,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    valueColor: const AlwaysStoppedAnimation(_kGold),
                  ),
                  Text(
                    '$countdown',
                    style: const TextStyle(
                      color:      _kGold,
                      fontSize:   9,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'Nunito',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareIconButton extends StatelessWidget {
  const _ShareIconButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        _kWhatsApp.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: _kWhatsApp.withValues(alpha: 0.35)),
        ),
        child: const Icon(Icons.share_rounded, color: _kWhatsApp, size: 20),
      ),
    );
  }
}

// ─── Header ───────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({required this.pulse, required this.weekRange});

  final Animation<double> pulse;
  final String            weekRange;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Trophy with pulsing glow rings
        ScaleTransition(
          scale: pulse,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer diffuse glow
              Container(
                width:  130,
                height: 130,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _kGold.withValues(alpha: 0.18),
                      _kGold.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
              // Inner ring
              Container(
                width:  90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:  _kGold.withValues(alpha: 0.07),
                  border: Border.all(
                    color: _kGold.withValues(alpha: 0.30),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:       _kGold.withValues(alpha: 0.35),
                      blurRadius:  32,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              const Text('🏆', style: TextStyle(fontSize: 54)),
            ],
          ),
        ),
        const SizedBox(height: 20),

        const Text(
          "Last Week's Champions",
          style: TextStyle(
            color:         _kGold,
            fontSize:      26,
            fontWeight:    FontWeight.w900,
            letterSpacing: -0.5,
            height:        1.1,
            fontFamily:    'Nunito',
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),

        // Week range pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color:        Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(20),
            border:       Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.calendar_today_rounded,
                         color: AppColors.textMuted, size: 11),
              const SizedBox(width: 5),
              Text(
                weekRange,
                style: const TextStyle(
                  color:      AppColors.textSecondary,
                  fontSize:   12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Nunito',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Prize Pool Banner ────────────────────────────────────────────────────────
class _PrizePoolBanner extends StatelessWidget {
  const _PrizePoolBanner({required this.formatted});

  final String formatted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _kGold.withValues(alpha: 0.14),
            AppColors.accent.withValues(alpha: 0.07),
          ],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _kGold.withValues(alpha: 0.32),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color:      _kGold.withValues(alpha: 0.08),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('💰', style: TextStyle(fontSize: 28)),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '₦$formatted',
                style: const TextStyle(
                  color:         _kGold,
                  fontSize:      26,
                  fontWeight:    FontWeight.w900,
                  letterSpacing: -0.5,
                  height:        1.0,
                  fontFamily:    'Nunito',
                ),
              ),
              const SizedBox(height: 3),
              const Text(
                'shared with this week\'s champions',
                style: TextStyle(
                  color:      AppColors.textMuted,
                  fontSize:   11,
                  fontFamily: 'Nunito',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Winner Card ──────────────────────────────────────────────────────────────
/// Each card enters with a staggered slide-up + fade via [animation].
///
/// The `child` of [AnimatedBuilder] is built once (static layout) and reused
/// across animation frames — no redundant rebuilds.
class _WinnerCard extends StatelessWidget {
  const _WinnerCard({
    super.key,
    required this.winner,
    required this.listIndex,
    required this.formatted,
    required this.animation,
  });

  final PrizeWinner       winner;
  final int               listIndex;
  final String            formatted;
  final Animation<double> animation;

  bool  get _isTop3    => listIndex < 3;
  Color get _rankColor => _isTop3 ? _rankColors[listIndex] : AppColors.textMuted;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      // Static child built once, passed into every frame's builder.
      child: _buildCard(),
      builder: (context, child) => Opacity(
        // Clamp to guard against easeOutBack's overshoot going slightly < 0.
        opacity: animation.value.clamp(0.0, 1.0),
        child: Transform.translate(
          // easeOutBack overshoot also moves card slightly above final pos,
          // creating a satisfying bounce-settle effect.
          offset: Offset(0, 24.0 * (1.0 - animation.value)),
          child: child,
        ),
      ),
    );
  }

  Widget _buildCard() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _isTop3
                ? [
                    _rankColor.withValues(alpha: 0.10),
                    AppColors.surface.withValues(alpha: 0.98),
                  ]
                : const [AppColors.surface, AppColors.surfaceAlt],
            begin: Alignment.centerLeft,
            end:   Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _isTop3
                ? _rankColor.withValues(alpha: 0.38)
                : AppColors.divider,
            width: _isTop3 ? 1.5 : 1.0,
          ),
          boxShadow: _isTop3
              ? [
                  BoxShadow(
                    color:      _rankColor.withValues(alpha: 0.12),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            _RankIndicator(
              listIndex: listIndex,
              rank:      winner.rank,
              isTop3:    _isTop3,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    winner.username,
                    style: TextStyle(
                      color:      _isTop3 ? Colors.white : AppColors.textPrimary,
                      fontSize:   _isTop3 ? 15 : 14,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'Nunito',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(Icons.school_rounded,
                                 color: AppColors.textMuted, size: 11),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          winner.university,
                          style: const TextStyle(
                            color:      AppColors.textMuted,
                            fontSize:   11,
                            fontWeight: FontWeight.w500,
                            fontFamily: 'Nunito',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _PrizeBadge(
              listIndex: listIndex,
              isTop3:    _isTop3,
              formatted: formatted,
            ),
          ],
        ),
      ),
    );
  }
}

class _RankIndicator extends StatelessWidget {
  const _RankIndicator({
    required this.listIndex,
    required this.rank,
    required this.isTop3,
  });

  final int  listIndex;
  final int  rank;
  final bool isTop3;

  @override
  Widget build(BuildContext context) {
    if (isTop3) {
      return Text(
        _medals[listIndex],
        style: TextStyle(fontSize: listIndex == 0 ? 32 : 26),
      );
    }
    return Container(
      width:  36,
      height: 36,
      decoration: BoxDecoration(
        color:  AppColors.surfaceAlt,
        shape:  BoxShape.circle,
        border: Border.all(color: AppColors.divider),
      ),
      child: Center(
        child: Text(
          '$rank',
          style: const TextStyle(
            color:      AppColors.textSecondary,
            fontSize:   13,
            fontWeight: FontWeight.w700,
            fontFamily: 'Nunito',
          ),
        ),
      ),
    );
  }
}

class _PrizeBadge extends StatelessWidget {
  const _PrizeBadge({
    required this.listIndex,
    required this.isTop3,
    required this.formatted,
  });

  final int    listIndex;
  final bool   isTop3;
  final String formatted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        gradient: isTop3
            ? LinearGradient(colors: _rankGradients[listIndex])
            : null,
        color:        isTop3 ? null : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border:       isTop3 ? null : Border.all(color: AppColors.divider),
      ),
      child: Text(
        '₦$formatted',
        style: TextStyle(
          color:      isTop3 ? Colors.black87 : AppColors.textSecondary,
          fontSize:   13,
          fontWeight: FontWeight.w800,
          fontFamily: 'Nunito',
        ),
      ),
    );
  }
}

// ─── CTA Button ───────────────────────────────────────────────────────────────
class _CtaButton extends StatelessWidget {
  const _CtaButton({required this.pulse, required this.onTap});

  final Animation<double> pulse;
  final VoidCallback      onTap;

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: pulse,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width:   double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.primary, Color(0xFFFF6B6B)],
              begin:  Alignment.centerLeft,
              end:    Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color:      AppColors.primary.withValues(alpha: 0.50),
                blurRadius: 28,
                offset:     const Offset(0, 8),
              ),
            ],
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '⚔️  This could be you!',
                style: TextStyle(
                  color:         Colors.white,
                  fontSize:      17,
                  fontWeight:    FontWeight.w900,
                  letterSpacing: -0.3,
                  fontFamily:    'Nunito',
                ),
              ),
              SizedBox(height: 3),
              Text(
                'View weekly leaderboard →',
                style: TextStyle(
                  color:      Colors.white70,
                  fontSize:   12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Nunito',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Share Button ─────────────────────────────────────────────────────────────
class _ShareButton extends StatelessWidget {
  const _ShareButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width:   double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color:        _kWhatsApp.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(18),
          border:       Border.all(color: _kWhatsApp.withValues(alpha: 0.35)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.share_rounded, color: _kWhatsApp, size: 18),
            SizedBox(width: 8),
            Text(
              'Share on WhatsApp',
              style: TextStyle(
                color:      _kWhatsApp,
                fontSize:   15,
                fontWeight: FontWeight.w700,
                fontFamily: 'Nunito',
              ),
            ),
          ],
        ),
      ),
    );
  }
}