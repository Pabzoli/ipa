// lib/core/widgets/coin_earn_animation.dart

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// Premium coin reward animation.
///
/// Usage:
///   CoinEarnAnimation.show(context, amount: 10);
///
/// The overlay manages its own lifecycle and removes itself automatically.
/// Which ledger source the animation represents. Achievement coins render
/// with a distinct purple/trophy style so they are visually separable from
/// base gold/coin earnings everywhere (summary pages, achievements tab).
enum CoinEarnSource { base, achievement }

class CoinEarnAnimation {
  CoinEarnAnimation._();

  static void show(
    BuildContext context, {
    required int amount,
    CoinEarnSource source = CoinEarnSource.base,
  }) {
    assert(amount > 0, 'amount must be positive');

    final overlay = Overlay.of(context, rootOverlay: true);

    late final OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _CoinEarnOverlay(
        amount: amount,
        source: source,
        onDone: () {
          if (entry.mounted) {
            entry.remove();
          }
        },
      ),
    );

    overlay.insert(entry);
  }

  /// Distinct purple/trophy variant for achievement-earned coins
  /// (`earn_achievement` ledger type).
  static void showAchievement(
    BuildContext context, {
    required int amount,
  }) =>
      show(context, amount: amount, source: CoinEarnSource.achievement);
}

class _CoinEarnOverlay extends StatefulWidget {
  final int amount;
  final CoinEarnSource source;
  final VoidCallback onDone;

  const _CoinEarnOverlay({
    required this.amount,
    this.source = CoinEarnSource.base,
    required this.onDone,
  });

  @override
  State<_CoinEarnOverlay> createState() => _CoinEarnOverlayState();
}

class _CoinEarnOverlayState extends State<_CoinEarnOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  late final Animation<double> _progress;
  late final Animation<double> _badgeScale;
  late final Animation<double> _badgeOpacity;
  late final Animation<double> _badgeY;
  late final Animation<double> _glow;
  late final Animation<double> _flash;

  late final List<_CoinParticle> _particles;

  static const _duration = Duration(milliseconds: 1550);

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: _duration,
    );

    _particles = _createParticles();

    _progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.linear,
    );

    _badgeScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.35, end: 1.12).chain(
          CurveTween(curve: Curves.easeOutBack),
        ),
        weight: 18,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.12, end: 0.96).chain(
          CurveTween(curve: Curves.easeOut),
        ),
        weight: 10,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.96, end: 1.0).chain(
          CurveTween(curve: Curves.easeOut),
        ),
        weight: 8,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 44,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.92).chain(
          CurveTween(curve: Curves.easeIn),
        ),
        weight: 20,
      ),
    ]).animate(_controller);

    _badgeOpacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0).chain(
          CurveTween(curve: Curves.easeOut),
        ),
        weight: 10,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 68,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0).chain(
          CurveTween(curve: Curves.easeIn),
        ),
        weight: 22,
      ),
    ]).animate(_controller);

    _badgeY = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 12.0, end: 0.0).chain(
          CurveTween(curve: Curves.easeOutBack),
        ),
        weight: 16,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: -4.0).chain(
          CurveTween(curve: Curves.easeOut),
        ),
        weight: 12,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: -4.0, end: -115.0).chain(
          CurveTween(curve: Curves.easeOutCubic),
        ),
        weight: 57,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: -115.0, end: -132.0).chain(
          CurveTween(curve: Curves.easeIn),
        ),
        weight: 15,
      ),
    ]).animate(_controller);

    _glow = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 8, end: 34).chain(
          CurveTween(curve: Curves.easeOut),
        ),
        weight: 22,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 34, end: 17).chain(
          CurveTween(curve: Curves.easeInOut),
        ),
        weight: 24,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 17, end: 24).chain(
          CurveTween(curve: Curves.easeInOut),
        ),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 24, end: 8).chain(
          CurveTween(curve: Curves.easeIn),
        ),
        weight: 34,
      ),
    ]).animate(_controller);

    _flash = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 0.9).chain(
          CurveTween(curve: Curves.easeOut),
        ),
        weight: 6,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.9, end: 0.0).chain(
          CurveTween(curve: Curves.easeIn),
        ),
        weight: 15,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(0.0),
        weight: 79,
      ),
    ]).animate(_controller);

    _controller.forward().whenComplete(widget.onDone);
  }

  List<_CoinParticle> _createParticles() {
    final random = Random(42);

    final isAchievement = widget.source == CoinEarnSource.achievement;
    final colors = isAchievement
        ? const [
            Color(0xFFE9D5FF),
            Color(0xFFC4B5FD),
            Color(0xFF8B5CF6),
            Color(0xFF7C3AED),
            Color(0xFFFFFFFF),
          ]
        : const [
            Color(0xFFFFE7A0),
            Color(0xFFFFD45C),
            Color(0xFFFFC226),
            Color(0xFFF59E0B),
            Color(0xFFFFFFFF),
          ];

    return List.generate(22, (index) {
      final angle = (pi * 2 * index / 22) +
          (random.nextDouble() - 0.5) * 0.18;

      return _CoinParticle(
        angle: angle,
        distance: 46 + random.nextDouble() * 72,
        size: 2.5 + random.nextDouble() * 4.5,
        delay: random.nextDouble() * 0.08,
        duration: 0.30 + random.nextDouble() * 0.23,
        rotation: random.nextDouble() * pi * 2,
        color: colors[index % colors.length],
        sparkle: index % 4 == 0,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    // Slightly above center so it feels connected to the action
    // rather than sitting directly in the middle of the screen.
    final centerX = size.width * 0.5;
    final centerY = size.height * 0.43;

    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Radial impact flash.
          Positioned(
            left: centerX - 90,
            top: centerY - 90,
            width: 180,
            height: 180,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (_, __) {
                return Opacity(
                  opacity: _flash.value,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFFFFE082).withValues(alpha: 0.7),
                          const Color(0xFFFFC107).withValues(alpha: 0.20),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.35, 1.0],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Flying particles.
          ..._buildParticles(centerX, centerY),

          // Main reward.
          Positioned(
            left: centerX - 100,
            top: centerY - 32,
            width: 200,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (_, __) {
                return Opacity(
                  opacity: _badgeOpacity.value,
                  child: Transform.translate(
                    offset: Offset(0, _badgeY.value),
                    child: Transform.scale(
                      scale: _badgeScale.value,
                      child: _RewardBadge(
                        amount: widget.amount,
                        glowRadius: _glow.value,
                        progress: _progress.value,
                        source: widget.source,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildParticles(double cx, double cy) {
    return _particles.map((particle) {
      return _ParticleWidget(
        controller: _controller,
        originX: cx,
        originY: cy,
        particle: particle,
      );
    }).toList();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Particle
// ─────────────────────────────────────────────────────────────────────────────

class _CoinParticle {
  final double angle;
  final double distance;
  final double size;
  final double delay;
  final double duration;
  final double rotation;
  final Color color;
  final bool sparkle;

  const _CoinParticle({
    required this.angle,
    required this.distance,
    required this.size,
    required this.delay,
    required this.duration,
    required this.rotation,
    required this.color,
    required this.sparkle,
  });
}

class _ParticleWidget extends StatelessWidget {
  final AnimationController controller;
  final double originX;
  final double originY;
  final _CoinParticle particle;

  const _ParticleWidget({
    required this.controller,
    required this.originX,
    required this.originY,
    required this.particle,
  });

  @override
  Widget build(BuildContext context) {
    final start = particle.delay;
    final end = (start + particle.duration).clamp(0.0, 1.0);

    final movement = CurvedAnimation(
      parent: controller,
      curve: Interval(
        start,
        end,
        curve: Curves.easeOutCubic,
      ),
    );

    final fade = CurvedAnimation(
      parent: controller,
      curve: Interval(
        start + 0.10,
        end,
        curve: Curves.easeIn,
      ),
    );

    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = movement.value;

        final dx = cos(particle.angle) * particle.distance * t;

        // Slightly curved trajectory.
        final dy = sin(particle.angle) * particle.distance * t -
            (18 * t * t);

        final scale = 1.0 - (0.55 * fade.value);
        final opacity = (1.0 - fade.value).clamp(0.0, 1.0);

        return Positioned(
          left: originX + dx - particle.size,
          top: originY + dy - particle.size,
          width: particle.size * 2,
          height: particle.size * 2,
          child: Opacity(
            opacity: opacity,
            child: Transform.rotate(
              angle: particle.rotation * t,
              child: Transform.scale(
                scale: scale,
                child: particle.sparkle
                    ? _Sparkle(
                        size: particle.size * 2,
                        color: particle.color,
                      )
                    : _Dot(
                        size: particle.size * 2,
                        color: particle.color,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  final double size;
  final Color color;

  const _Dot({
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.75),
            blurRadius: size * 2.5,
            spreadRadius: size * 0.2,
          ),
        ],
      ),
    );
  }
}

class _Sparkle extends StatelessWidget {
  final double size;
  final Color color;

  const _Sparkle({
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SparklePainter(color),
    );
  }
}

class _SparklePainter extends CustomPainter {
  final Color color;

  const _SparklePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(
        BlurStyle.normal,
        1.5,
      );

    final cx = size.width / 2;
    final cy = size.height / 2;

    final path = Path()
      ..moveTo(cx, 0)
      ..quadraticBezierTo(
        cx + size.width * 0.13,
        cy - size.height * 0.13,
        size.width,
        cy,
      )
      ..quadraticBezierTo(
        cx + size.width * 0.13,
        cy + size.height * 0.13,
        cx,
        size.height,
      )
      ..quadraticBezierTo(
        cx - size.width * 0.13,
        cy + size.height * 0.13,
        0,
        cy,
      )
      ..quadraticBezierTo(
        cx - size.width * 0.13,
        cy - size.height * 0.13,
        cx,
        0,
      );

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reward badge
// ─────────────────────────────────────────────────────────────────────────────

class _RewardBadge extends StatelessWidget {
  final int amount;
  final double glowRadius;
  final double progress;
  final CoinEarnSource source;

  const _RewardBadge({
    required this.amount,
    required this.glowRadius,
    required this.progress,
    this.source = CoinEarnSource.base,
  });

  @override
  Widget build(BuildContext context) {
    final isAchievement = source == CoinEarnSource.achievement;
    final glow = isAchievement
        ? const Color(0xFF8B5CF6)
        : const Color(0xFFFFB300);
    return Center(
      child: Container(
        padding: EdgeInsets.fromLTRB(9.r, 8.r, 18.r, 8.r),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30.r),

          // Deep outer layer creates separation from any background.
          boxShadow: [
            BoxShadow(
              color: glow.withValues(alpha: 0.16),
              blurRadius: glowRadius * 2.2,
              spreadRadius: 3,
            ),
            BoxShadow(
              color: glow.withValues(alpha: 0.38),
              blurRadius: glowRadius,
              spreadRadius: 1,
              offset: const Offset(0, 5),
            ),
          ],

          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isAchievement
                ? const [
                    Color(0xFFE9D5FF),
                    Color(0xFFA78BFA),
                    Color(0xFF7C3AED),
                  ]
                : const [
                    Color(0xFFFFE7A3),
                    Color(0xFFFFCE47),
                    Color(0xFFFFB300),
                  ],
          ),

          border: Border.all(
            color: isAchievement
                ? const Color(0xFFF5F3FF)
                : const Color(0xFFFFF4C2),
            width: 1.2,
          ),
        ),

        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Coin icon vs trophy for achievements.
            if (isAchievement)
              Text('🏆', style: TextStyle(fontSize: 22.sp))
            else
              const _AnimatedCoin(),

            SizedBox(width: 8.w),

            // + amount.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '+$amount',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 23.sp,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  letterSpacing: -0.8,
                  shadows: [
                    Shadow(
                      color: Color(0x66000000),
                      offset: Offset(0, 2),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Coin icon
// ─────────────────────────────────────────────────────────────────────────────

class _AnimatedCoin extends StatefulWidget {
  const _AnimatedCoin();

  @override
  State<_AnimatedCoin> createState() => _AnimatedCoinState();
}

class _AnimatedCoinState extends State<_AnimatedCoin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _rotation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..repeat();

    _rotation = Tween<double>(
      begin: -0.08,
      end: 0.08,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _rotation,
      builder: (_, __) {
        return Transform.rotate(
          angle: _rotation.value,
          child: CustomPaint(
            size: Size.square(28.r),
            painter: _CoinPainter(),
          ),
        );
      },
    );
  }
}

class _CoinPainter extends CustomPainter {
  const _CoinPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(
      size.width / 2,
      size.height / 2,
    );

    final radius = size.width * 0.43;

    // Outer dark rim.
    final rimPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFFFFF1A8),
          Color(0xFFF5A900),
        ],
      ).createShader(
        Rect.fromCircle(
          center: center,
          radius: radius,
        ),
      );

    canvas.drawCircle(
      center,
      radius,
      rimPaint,
    );

    // Main coin face.
    final facePaint = Paint()
      ..shader = const RadialGradient(
        colors: [
          Color(0xFFFFF0A8),
          Color(0xFFFFCC3A),
          Color(0xFFF2A900),
        ],
        stops: [
          0.0,
          0.62,
          1.0,
        ],
      ).createShader(
        Rect.fromCircle(
          center: center,
          radius: radius * 0.84,
        ),
      );

    canvas.drawCircle(
      center,
      radius * 0.84,
      facePaint,
    );

    // Inner highlight ring.
    final ringPaint = Paint()
      ..color = const Color(0xFFFFF4BF).withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.drawCircle(
      center,
      radius * 0.68,
      ringPaint,
    );

    // Small coin symbol.
    final textPainter = TextPainter(
      text: const TextSpan(
        text: '\$',
        style: TextStyle(
          color: Color(0xFFB66D00),
          fontSize: 15,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _CoinPainter oldDelegate) {
    return false;
  }
}