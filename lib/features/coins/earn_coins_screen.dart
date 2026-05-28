import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/ad_service.dart';
import '../../core/widgets/coin_balance_widget.dart';
import '../../core/widgets/coin_earn_animation.dart';

/// EarnCoinsScreen — P-04
///
/// Lets users watch rewarded video ads to earn +10 Anime Coins.
/// Cap: 10 ads/day (enforced server-side by recordAdWatch Cloud Function).
/// Cooldown: 90 seconds between ads (enforced client-side by AdService).
///
/// Reward: Anime Coins ONLY. No mention of prize pool or naira anywhere.
class EarnCoinsScreen extends StatefulWidget {
  const EarnCoinsScreen({super.key});

  @override
  State<EarnCoinsScreen> createState() => _EarnCoinsScreenState();
}

class _EarnCoinsScreenState extends State<EarnCoinsScreen> {
  // ── Timers ────────────────────────────────────────────────────────────────
  Timer? _cooldownTimer;    // ticks every second to refresh the countdown UI
  Timer? _midnightTimer;    // fires at WAT midnight to reset the daily display

  int _cooldownSecsLeft = 0;

  // ── Ad state ──────────────────────────────────────────────────────────────
  bool _adLoading = false;  // spinner while ad is being fetched/shown

  @override
  void initState() {
    super.initState();
    AdService.instance.loadRewardedAd();
    _startCooldownTimer();
    _scheduleMidnightRefresh();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _midnightTimer?.cancel();
    super.dispose();
  }

  // ── Timers ────────────────────────────────────────────────────────────────

  void _startCooldownTimer() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final secs = AdService.instance.cooldownSecondsRemaining();
      if (mounted) setState(() => _cooldownSecsLeft = secs);
    });
  }

  /// Schedules a single setState at WAT midnight so the "X / 10 watched"
  /// progress bar resets visually without the user leaving and returning.
  void _scheduleMidnightRefresh() {
    final nowWAT    = DateTime.now().toUtc().add(const Duration(hours: 1));
    final midnight  = DateTime(nowWAT.year, nowWAT.month, nowWAT.day + 1);
    final msUntil   = midnight.difference(nowWAT).inMilliseconds;
    _midnightTimer  = Timer(Duration(milliseconds: msUntil), () {
      if (mounted) setState(() {});
    });
  }

  // ── Button tap ────────────────────────────────────────────────────────────

  Future<void> _onWatchAdTapped() async {
    final provider = context.read<UserDataProvider>();

    if (provider.adsRemainingToday <= 0) return;
    if (_cooldownSecsLeft > 0) return;

    // Ad not yet loaded — show spinner and poll briefly before giving up.
    if (!AdService.instance.isRewardedAdReady) {
      setState(() => _adLoading = true);
      AdService.instance.loadRewardedAd();
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (AdService.instance.isRewardedAdReady) break;
      }
      if (!mounted) return;
      setState(() => _adLoading = false);

      if (!AdService.instance.isRewardedAdReady) {
        _showSnack('Ad not available right now. Try again in a moment.');
        return;
      }
    }

    setState(() => _adLoading = true);

    final shown = await AdService.instance.showRewardedAd(
      context: context,
      onComplete: (int coinsAwarded) {
        if (!mounted) return;
        setState(() => _cooldownSecsLeft = 90);
        // CoinEarnAnimation is an Overlay utility — call show(), don't instantiate.
        CoinEarnAnimation.show(context, amount: coinsAwarded);
      },
    );

    if (mounted) setState(() => _adLoading = false);

    if (!shown && mounted && _cooldownSecsLeft == 0) {
      _showSnack('Ad not available right now. Try again in a moment.');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontFamily: 'Nunito')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _formatMmSs(int secs) {
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _midnightCountdown() {
    final nowWAT   = DateTime.now().toUtc().add(const Duration(hours: 1));
    final midnight = DateTime(nowWAT.year, nowWAT.month, nowWAT.day + 1);
    final secs     = midnight.difference(nowWAT).inSeconds;
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider   = context.watch<UserDataProvider>();
    final ac         = provider.animeCoins;
    final watched    = provider.dailyAdWatched;
    final remaining  = provider.adsRemainingToday;
    final dailyLimit = remaining <= 0;
    final onCooldown = _cooldownSecsLeft > 0;
    final cs         = Theme.of(context).colorScheme;

    final bool buttonEnabled = !dailyLimit && !onCooldown && !_adLoading;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text(
          'Earn Coins',
          style: TextStyle(fontFamily: 'Nunito', fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: CoinBalanceWidget(),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 16),

              // ── Balance hero card ────────────────────────────────────────
              _BalanceCard(animeCoins: ac),

              const SizedBox(height: 40),

              // ── How-it-works blurb ───────────────────────────────────────
              Text(
                'Watch short ads to earn Anime Coins.\n'
                'Use coins for hints, cooldown skips, and more.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14,
                  color: cs.onSurface.withOpacity(0.65),
                  height: 1.5,
                ),
              ),

              const SizedBox(height: 40),

              // ── Daily progress bar ───────────────────────────────────────
              _DailyProgressBar(watched: watched, dailyCap: 10),
              const SizedBox(height: 8),
              Text(
                dailyLimit
                    ? 'Resets in ${_midnightCountdown()}'
                    : '$watched / 10 watched today',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: dailyLimit
                      ? cs.error
                      : cs.onSurface.withOpacity(0.6),
                ),
              ),

              const SizedBox(height: 48),

              // ── Watch Ad button ──────────────────────────────────────────
              _WatchAdButton(
                enabled:      buttonEnabled,
                loading:      _adLoading,
                dailyLimit:   dailyLimit,
                onCooldown:   onCooldown,
                cooldownSecs: _cooldownSecsLeft,
                onTap:        _onWatchAdTapped,
              ),

              const SizedBox(height: 24),

              // ── Cooldown / daily-limit status label ──────────────────────
              if (dailyLimit)
                _StatusLabel(
                  icon:  Icons.bedtime_outlined,
                  color: cs.error,
                  text:  "You've watched all 10 ads today. Come back tomorrow!",
                )
              else if (onCooldown)
                _StatusLabel(
                  icon:  Icons.timer_outlined,
                  color: cs.primary,
                  text:  'Next ad available in ${_formatMmSs(_cooldownSecsLeft)}',
                ),

              const SizedBox(height: 48),

              // ── Info tip cards ───────────────────────────────────────────
              const _EarnTipRow(),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ─── Sub-widgets ─────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.animeCoins});
  final int animeCoins;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primaryContainer, cs.primary.withOpacity(0.85)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color:  cs.primary.withOpacity(0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          const Text('🪙', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 8),
          Text(
            animeCoins.toString(),
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize:   48,
              fontWeight: FontWeight.w900,
              color:      cs.onPrimary,
              height:     1.0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Anime Coins',
            style: TextStyle(
              fontFamily:  'Nunito',
              fontSize:    14,
              fontWeight:  FontWeight.w700,
              color:       cs.onPrimary.withOpacity(0.8),
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyProgressBar extends StatelessWidget {
  const _DailyProgressBar({required this.watched, required this.dailyCap});
  final int watched;
  final int dailyCap;

  @override
  Widget build(BuildContext context) {
    final cs       = Theme.of(context).colorScheme;
    final progress = (watched / dailyCap).clamp(0.0, 1.0);
    final full     = watched >= dailyCap;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LinearProgressIndicator(
        value:           progress,
        minHeight:       10,
        backgroundColor: cs.surfaceVariant,
        color:           full ? cs.error : cs.primary,
      ),
    );
  }
}

class _WatchAdButton extends StatelessWidget {
  const _WatchAdButton({
    required this.enabled,
    required this.loading,
    required this.dailyLimit,
    required this.onCooldown,
    required this.cooldownSecs,
    required this.onTap,
  });

  final bool         enabled;
  final bool         loading;
  final bool         dailyLimit;
  final bool         onCooldown;
  final int          cooldownSecs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    String label;
    if (loading) {
      label = 'Loading ad…';
    } else if (dailyLimit) {
      label = 'Come back tomorrow 🌙';
    } else if (onCooldown) {
      final m = (cooldownSecs ~/ 60).toString().padLeft(2, '0');
      final s = (cooldownSecs % 60).toString().padLeft(2, '0');
      label = 'Next ad in $m:$s';
    } else {
      label = 'Watch Ad — Earn +10 🪙';
    }

    return SizedBox(
      width:  double.infinity,
      height: 60,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: enabled
              ? LinearGradient(
                  colors: [cs.primary, cs.primary.withOpacity(0.75)],
                )
              : null,
          color: enabled ? null : cs.surfaceVariant,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color:      cs.primary.withOpacity(0.40),
                    blurRadius: 14,
                    offset:     const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Material(
          color:        Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? onTap : null,
            child: Center(
              child: loading
                  ? SizedBox(
                      width:  24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(cs.onPrimary),
                      ),
                    )
                  : Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize:   17,
                        fontWeight: FontWeight.w800,
                        color: enabled
                            ? cs.onPrimary
                            : cs.onSurface.withOpacity(0.45),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color    color;
  final String   text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize:   13,
              fontWeight: FontWeight.w600,
              color:      color,
            ),
          ),
        ),
      ],
    );
  }
}

class _EarnTipRow extends StatelessWidget {
  const _EarnTipRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _TipCard(emoji: '📅', label: 'Up to\n10 per day')),
        const SizedBox(width: 12),
        Expanded(child: _TipCard(emoji: '⏱️', label: '90s\ncooldown')),
        const SizedBox(width: 12),
        Expanded(child: _TipCard(emoji: '🪙', label: '+10 coins\nper ad')),
      ],
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard({required this.emoji, required this.label});
  final String emoji;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color:        cs.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: cs.outlineVariant, width: 1),
      ),
      child: Column(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize:   12,
              fontWeight: FontWeight.w700,
              color:      cs.onSurface.withOpacity(0.75),
              height:     1.4,
            ),
          ),
        ],
      ),
    );
  }
}