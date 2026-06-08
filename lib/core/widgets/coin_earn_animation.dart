// lib/core/widgets/coin_earn_animation.dart
import 'dart:math';
import 'package:flutter/material.dart';

/// Displays a "+N 🪙" label that floats upward and fades out over 1.4 s,
/// accompanied by a burst of particle sparks.
///
/// Usage:
///   CoinEarnAnimation.show(context, amount: 8);
///
/// The overlay removes itself automatically — no cleanup needed by the caller.
class CoinEarnAnimation {
  CoinEarnAnimation._();

  static void show(BuildContext context, {required int amount}) {
    assert(amount > 0, 'amount must be positive');

    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _CoinEarnOverlay(
        amount: amount,
        onDone: entry.remove,
      ),
    );

    overlay.insert(entry);
  }
}

// ── Internal overlay ───────────────────────────────────────────────────────────

class _CoinEarnOverlay extends StatefulWidget {
  final int amount;
  final VoidCallback onDone;
  const _CoinEarnOverlay({required this.amount, required this.onDone});

  @override
  State<_CoinEarnOverlay> createState() => _CoinEarnOverlayState();
}

class _CoinEarnOverlayState extends State<_CoinEarnOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // Label floats 110 px upward
  late final Animation<double> _dy;

  // Fade: solid for 55%, then fades out
  late final Animation<double> _opacity;

  // Pop-in: quick overshoot scale
  late final Animation<double> _scale;

  // Glow pulse while visible
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    _dy = Tween<double>(begin: 0, end: -110).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );

    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 55),
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 45),
    ]).animate(_ctrl);

    // Overshoot: 0 → 1.3 → 1.0
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.4, end: 1.3)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 15,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.3, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 25,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 60),
    ]).animate(_ctrl);

    _glow = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 12.0, end: 28.0)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: 28.0, end: 12.0)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 30),
      TweenSequenceItem(tween: ConstantTween(12.0), weight: 40),
    ]).animate(_ctrl);

    _ctrl.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final cx = size.width / 2;
    final cy = size.height * 0.40;

    return Stack(
      children: [
        // Spark particles
        ..._buildParticles(cx, cy),

        // Main label
        Positioned(
          left: cx - 80,
          top: cy,
          width: 160,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Opacity(
                opacity: _opacity.value,
                child: Transform.translate(
                  offset: Offset(0, _dy.value),
                  child: Transform.scale(
                    scale: _scale.value,
                    child: _CoinLabel(
                      amount: widget.amount,
                      glowRadius: _glow.value,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildParticles(double cx, double cy) {
    const count = 10;
    return List.generate(count, (i) {
      final angle = (2 * pi / count) * i + (pi / count) * (i % 2);
      return _SparkParticle(
        controller: _ctrl,
        originX: cx,
        originY: cy,
        angle: angle,
        distance: 55 + (i % 3) * 22.0,
        color: i % 3 == 0
            ? const Color(0xFFFBBF24)
            : i % 3 == 1
                ? const Color(0xFFF59E0B)
                : const Color(0xFFFDE68A),
        size: 4 + (i % 2) * 2.5,
      );
    });
  }
}

// ── Spark particle ─────────────────────────────────────────────────────────────

class _SparkParticle extends StatelessWidget {
  final AnimationController controller;
  final double originX;
  final double originY;
  final double angle;
  final double distance;
  final Color color;
  final double size;

  const _SparkParticle({
    required this.controller,
    required this.originX,
    required this.originY,
    required this.angle,
    required this.distance,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    // Particles burst out during first 40% then fade
    final move = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
    );
    final fade = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.2, 0.6, curve: Curves.easeIn),
    );

    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = move.value;
        final dx = cos(angle) * distance * t;
        final dy = sin(angle) * distance * t - 20 * t;
        final opacity = (1.0 - fade.value).clamp(0.0, 1.0);

        return Positioned(
          left: originX + dx - size / 2,
          top: originY + dy - size / 2,
          child: Opacity(
            opacity: opacity,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.7),
                    blurRadius: size * 1.5,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Coin label ─────────────────────────────────────────────────────────────────

class _CoinLabel extends StatelessWidget {
  final int amount;
  final double glowRadius;
  const _CoinLabel({required this.amount, required this.glowRadius});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFFD95A), Color(0xFFFBBF24), Color(0xFFE89B0C)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(36),
          border: Border.all(
            color: const Color(0xFFFDE68A).withOpacity(0.6),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFBBF24).withOpacity(0.65),
              blurRadius: glowRadius,
              spreadRadius: 2,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: const Color(0xFFFBBF24).withOpacity(0.2),
              blurRadius: glowRadius * 2.5,
              spreadRadius: 6,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🪙', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 6),
            Text(
              '+$amount',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                height: 1,
                letterSpacing: -0.5,
                shadows: [
                  Shadow(
                    color: Color(0x55000000),
                    offset: Offset(0, 1),
                    blurRadius: 4,
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