import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../quiz/questions_page.dart';
import 'challenge_model.dart';

// ─── Stake Screen — step 2 of Create Challenge flow ───────────────────────────
class StakeScreen extends StatefulWidget {
  final String  animeTitle;
  final String? opponentUid;
  final String? opponentUsername;

  const StakeScreen({
    super.key,
    required this.animeTitle,
    this.opponentUid,
    this.opponentUsername,
  });

  @override
  State<StakeScreen> createState() => _StakeScreenState();
}

class _StakeScreenState extends State<StakeScreen> {
  final _ctrl = TextEditingController();
  bool    _creating      = false;
  String? _inlineError;
  bool    _rulesExpanded = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int get _stakeValue => int.tryParse(_ctrl.text) ?? 0;

  void _setQuickStake(int amount) {
    HapticFeedback.selectionClick();
    setState(() {
      _ctrl.text   = '$amount';
      _inlineError = null;
    });
  }

  String? _validate(int animeCoins, {required bool premiumActive}) {
    final stake    = _stakeValue;
    if (stake <= 0)          return 'Enter a stake amount';
    if (stake < 50)          return 'Minimum stake is 50 AC';
    if (stake % 50 != 0)     return 'Must be a multiple of 50';
    final maxStake = premiumActive ? 2500 : 1000;
    if (stake > maxStake) {
      return premiumActive
          ? 'Maximum stake is 2,500 AC'
          : 'Maximum stake is 1,000 AC (upgrade for 2,500 AC)';
    }
    if (stake > animeCoins) return 'Not enough AC — you have $animeCoins AC';
    return null;
  }

  String _friendlyError(String raw) {
    final s = raw.replaceFirst('Exception: ', '');
    return switch (s) {
      'insufficient_coins'            => 'Not enough AC for this stake',
      'daily_challenge_limit_reached' => 'Daily limit reached — max 3 challenges per day',
      'too_many_active_challenges'    => 'You already have 2 active challenges running',
      'stake_below_minimum'           => 'Minimum stake is 50 AC',
      'stake_exceeds_limit'           => 'Stake exceeds your maximum allowed amount',
      'stake_not_multiple_of_50'      => 'Stake must be a multiple of 50',
      'no_questions_for_anime'        => 'No questions available for this anime yet',
      _                               => s,
    };
  }

  Future<void> _createChallenge(int animeCoins, bool premiumActive) async {
    final error = _validate(animeCoins, premiumActive: premiumActive);
    if (error != null) {
      HapticFeedback.lightImpact();
      setState(() => _inlineError = error);
      return;
    }

    setState(() {
      _creating    = true;
      _inlineError = null;
    });

    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('createChallenge')
          .call<Map<String, dynamic>>({
        'animeTitle':       widget.animeTitle,
        'stakeAmount':      _stakeValue,
        'opponentUid':      widget.opponentUid,
        'opponentUsername': widget.opponentUsername,
      });

      final data        = result.data;
      final challengeId = data['challengeId'] as String;
      final questionIds = List<String>.from(data['questionIds'] as List);

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: QuestionsPage(
              mode:        QuizMode.asyncChallenge,
              questionIds: questionIds,
              challengeId: challengeId,
              isCreator:   true,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _creating    = false;
        _inlineError = _friendlyError(e.message ?? '');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating    = false;
        _inlineError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final userData         = context.watch<UserDataProvider>();
    final animeCoins       = userData.animeCoins;
    final premiumActive    = userData.premiumActive;
    final createdToday     = userData.challengesCreatedToday;
    final maxStake         = premiumActive ? 2500 : 1000;
    final dailyLimitReached = createdToday >= 3;

    final quickStakes = <int>[50, 100, 200, 500, 1000, 2500]
        .where((b) => b <= animeCoins && b <= maxStake)
        .take(5)
        .toList();

    final canAfford     = _stakeValue == 0 || _stakeValue <= animeCoins;
    final confirmEnabled = !_creating && !dailyLimitReached && canAfford;

    return PopScope(
      canPop: !_creating,
      child: Scaffold(
        // FIX 1: Transparent + extend flags so the hero background covers
        // the status bar, notch, and bottom system bar — no dark gaps.
        backgroundColor:        Colors.transparent,
        extendBodyBehindAppBar: true,
        extendBody:             true,
        body: AnimatedHeroBackground(
          child: SafeArea(
            // FIX 2: bottom: false lets the sticky CTA pad itself with
            // MediaQuery instead of SafeArea cutting into the gradient.
            bottom: false,
            child: Stack(
              children: [
                // ── Scrollable content ─────────────────────────────────
                Column(
                  children: [
                    _StakeAppBar(
                      animeTitle:       widget.animeTitle,
                      opponentUsername: widget.opponentUsername,
                      enabled:          !_creating,
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          20,
                          0,
                          20,
                          // FIX 3: bottom padding dynamically includes the
                          // system navigation bar height so content isn't
                          // obscured by the sticky CTA on gesture-nav devices.
                          120 + MediaQuery.of(context).padding.bottom,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 20),

                            // ── Balance card ─────────────────────────────
                            _BalanceCard(
                              animeCoins: animeCoins,
                              stakeValue: _stakeValue,
                            ),
                            const SizedBox(height: 12),

                            // ── Daily limit badge ────────────────────────
                            _DailyLimitBadge(createdToday: createdToday),
                            const SizedBox(height: 20),

                            // ── Stake input section ──────────────────────
                            _StakeInputSection(
                              ctrl:          _ctrl,
                              enabled:       !_creating && !dailyLimitReached,
                              inlineError:   _inlineError,
                              quickStakes:   quickStakes,
                              maxStake:      maxStake,
                              premiumActive: premiumActive,
                              onQuickStake:  _setQuickStake,
                              onChanged:     (_) =>
                                  setState(() => _inlineError = null),
                            ),
                            const SizedBox(height: 20),

                            // ── Not enough AC chip ───────────────────────
                            if (_stakeValue > 0 && !canAfford)
                              _NotEnoughAcChip(
                                have: animeCoins,
                                need: _stakeValue,
                              ),

                            // ── Payout preview ───────────────────────────
                            if (_stakeValue >= 50 && canAfford) ...[
                              const SizedBox(height: 4),
                              _PayoutPreview(stake: _stakeValue),
                            ],

                            const SizedBox(height: 20),

                            // ── Collapsible rules ────────────────────────
                            _CollapsibleRules(
                              expanded: _rulesExpanded,
                              onToggle: () => setState(
                                  () => _rulesExpanded = !_rulesExpanded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                // ── Sticky bottom CTA ──────────────────────────────────
                Positioned(
                  left:   0,
                  right:  0,
                  bottom: 0,
                  child: _StakeCta(
                    stakeValue:        _stakeValue,
                    loading:           _creating,
                    canAfford:         canAfford,
                    dailyLimitReached: dailyLimitReached,
                    onTap:             confirmEnabled
                        ? () => _createChallenge(animeCoins, premiumActive)
                        : null,
                  ),
                ),

                // ── Creating overlay ───────────────────────────────────
                if (_creating)
                  _CreatingOverlay(
                    animeTitle:       widget.animeTitle,
                    opponentUsername: widget.opponentUsername,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── App bar ────────────────────────────────────────────────────────────────────
class _StakeAppBar extends StatelessWidget {
  final String  animeTitle;
  final String? opponentUsername;
  final bool    enabled;

  const _StakeAppBar({
    required this.animeTitle,
    required this.enabled,
    this.opponentUsername,
  });

  @override
  Widget build(BuildContext context) {
    final hasRival = opponentUsername != null && opponentUsername!.isNotEmpty;
    final subtitle = hasRival
        ? 'Step 2 of 2 · $animeTitle · vs $opponentUsername'
        : 'Step 2 of 2 · $animeTitle';

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: AppColors.textPrimary, size: 20),
            onPressed: enabled ? () => Navigator.pop(context) : null,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Set Your Stake',
                  style: TextStyle(
                    color:         AppColors.textPrimary,
                    fontSize:      22,
                    fontWeight:    FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color:    AppColors.textMuted,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Balance card ───────────────────────────────────────────────────────────────
class _BalanceCard extends StatelessWidget {
  final int animeCoins;
  final int stakeValue;

  const _BalanceCard({required this.animeCoins, required this.stakeValue});

  @override
  Widget build(BuildContext context) {
    final afterStake   = (animeCoins - stakeValue).clamp(0, animeCoins);
    final isAffordable = stakeValue == 0 || stakeValue <= animeCoins;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        // FIX: Use a slightly opaque surface color so it reads clearly on
        // any background shade the AnimatedHeroBackground generates.
        borderRadius: BorderRadius.circular(20),
        color: AppColors.surface.withOpacity(0.85),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
          colors: [
            AppColors.secondary.withOpacity(0.22),
            AppColors.secondary.withOpacity(0.08),
          ],
        ),
        border: Border.all(
          color: AppColors.secondary.withOpacity(0.40),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withOpacity(0.12),
            blurRadius: 16,
            offset:     const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          // Coin icon
          Container(
            width:  44,
            height: 44,
            decoration: BoxDecoration(
              color:        AppColors.secondary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.secondary.withOpacity(0.3)),
            ),
            child: const Center(
              child: Text('🪙', style: TextStyle(fontSize: 22)),
            ),
          ),
          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your Balance',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: 11),
                ),
                const SizedBox(height: 3),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    '$animeCoins AC',
                    key: ValueKey(animeCoins),
                    style: const TextStyle(
                      color:      AppColors.textPrimary,
                      fontSize:   26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (stakeValue > 0) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.arrow_forward_rounded,
                  color: AppColors.textMuted.withOpacity(0.6),
                  size: 16,
                ),
              ],
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'After stake',
                  style: TextStyle(
                    color:    isAffordable
                        ? AppColors.textMuted
                        : AppColors.wrong.withOpacity(0.8),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 3),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    '$afterStake AC',
                    key: ValueKey(afterStake),
                    style: TextStyle(
                      color:      isAffordable
                          ? AppColors.textSecondary
                          : AppColors.wrong,
                      fontSize:   22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Daily limit badge ──────────────────────────────────────────────────────────
class _DailyLimitBadge extends StatelessWidget {
  final int createdToday;
  const _DailyLimitBadge({required this.createdToday});

  @override
  Widget build(BuildContext context) {
    final remaining   = (3 - createdToday).clamp(0, 3);
    final isExhausted = remaining == 0;

    // ── Dot indicators ──────────────────────────────────────────────────
    final dots = List.generate(3, (i) {
      final filled = i < createdToday;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width:  10,
        height: 10,
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled
              ? (isExhausted ? AppColors.wrong : AppColors.primary)
              : AppColors.divider,
        ),
      );
    });

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        // FIX: Consistent semi-opaque surface so it doesn't look dark
        color: isExhausted
            ? AppColors.wrong.withOpacity(0.10)
            : AppColors.surface.withOpacity(0.80),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isExhausted
              ? AppColors.wrong.withOpacity(0.4)
              : AppColors.divider,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isExhausted ? Icons.block_rounded : Icons.today_rounded,
            color: isExhausted ? AppColors.wrong : AppColors.textMuted,
            size:  15,
          ),
          const SizedBox(width: 8),
          Text(
            isExhausted
                ? 'Daily limit reached — try again tomorrow'
                : '$remaining of 3 challenges remaining today',
            style: TextStyle(
              color:      isExhausted ? AppColors.wrong : AppColors.textMuted,
              fontSize:   12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Row(children: dots),
        ],
      ),
    );
  }
}

// ── Stake input section ────────────────────────────────────────────────────────
class _StakeInputSection extends StatelessWidget {
  final TextEditingController ctrl;
  final bool                  enabled;
  final String?               inlineError;
  final List<int>             quickStakes;
  final int                   maxStake;
  final bool                  premiumActive;
  final ValueChanged<int>     onQuickStake;
  final ValueChanged<String>  onChanged;

  const _StakeInputSection({
    required this.ctrl,
    required this.enabled,
    required this.inlineError,
    required this.quickStakes,
    required this.maxStake,
    required this.premiumActive,
    required this.onQuickStake,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        // FIX: Opaque surface so content is always readable — no dark bleed
        color:        AppColors.surface.withOpacity(0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withOpacity(0.10),
            blurRadius: 14,
            offset:     const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Label ───────────────────────────────────────────────────
          Row(
            children: [
              const Text(
                'Enter stake amount',
                style: TextStyle(
                  color:      AppColors.textPrimary,
                  fontSize:   15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (premiumActive)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFFD700), Color(0xFFFFA500)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '⭐ Premium',
                    style: TextStyle(
                      color:      Colors.black87,
                      fontSize:   10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Text field ───────────────────────────────────────────────
          TextFormField(
            controller:  ctrl,
            enabled:     enabled,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged:   onChanged,
            style: const TextStyle(
              color:      AppColors.textPrimary,
              fontSize:   28,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
            decoration: InputDecoration(
              hintText:  '0',
              hintStyle: TextStyle(
                color:    AppColors.textMuted.withOpacity(0.5),
                fontSize: 28,
              ),
              suffixText: 'AC',
              suffixStyle: const TextStyle(
                color:      AppColors.textMuted,
                fontSize:   18,
                fontWeight: FontWeight.w700,
              ),
              filled:      true,
              fillColor:   AppColors.surfaceDim.withOpacity(0.5),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:   BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:   BorderSide(
                    color: AppColors.divider, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:   BorderSide(
                    color: AppColors.primary, width: 1.5),
              ),
            ),
          ),

          // ── Inline error ─────────────────────────────────────────────
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: inlineError != null
                ? Padding(
                    key:     ValueKey(inlineError),
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: AppColors.wrong, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            inlineError!,
                            style: const TextStyle(
                                color: AppColors.wrong, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(key: ValueKey('none')),
          ),

          // ── Quick stake chips ────────────────────────────────────────
          if (quickStakes.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'QUICK STAKE',
              style: TextStyle(
                color:         AppColors.textMuted,
                fontSize:      10,
                fontWeight:    FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing:    8,
              runSpacing: 8,
              children: quickStakes
                  .map((b) => _QuickStakeChip(
                        amount:   b,
                        selected: ctrl.text == '$b',
                        enabled:  enabled,
                        onTap:    () => onQuickStake(b),
                      ))
                  .toList(),
            ),
          ],

          const SizedBox(height: 10),
          Text(
            premiumActive
                ? 'Min 50 AC · max 2,500 AC · multiples of 50 · Premium ⭐'
                : 'Min 50 AC · max 1,000 AC · multiples of 50',
            style: const TextStyle(
                color: AppColors.textMuted, fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Quick stake chip ───────────────────────────────────────────────────────────
class _QuickStakeChip extends StatelessWidget {
  final int          amount;
  final bool         selected;
  final bool         enabled;
  final VoidCallback onTap;

  const _QuickStakeChip({
    required this.amount,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          // FIX: Ensure chip backgrounds are never transparent/dark
          color: selected
              ? AppColors.primary.withOpacity(0.18)
              : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          '$amount AC',
          style: TextStyle(
            color:      selected
                ? AppColors.primary
                : AppColors.textSecondary,
            fontWeight: FontWeight.w700,
            fontSize:   14,
          ),
        ),
      ),
    );
  }
}

// ── Not enough AC chip ─────────────────────────────────────────────────────────
class _NotEnoughAcChip extends StatelessWidget {
  final int have;
  final int need;
  const _NotEnoughAcChip({required this.have, required this.need});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color:        AppColors.wrong.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.wrong.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppColors.wrong, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Not enough AC — you have $have AC, need $need AC',
                style: const TextStyle(
                    color:  AppColors.wrong,
                    fontSize: 12,
                    height: 1.3),
              ),
            ),
          ],
        ),
      );
}

// ── Payout preview ─────────────────────────────────────────────────────────────
class _PayoutPreview extends StatelessWidget {
  final int stake;
  const _PayoutPreview({required this.stake});

  @override
  Widget build(BuildContext context) {
    final winAmount  = ChallengeModel.payoutWin(stake);
    final drawAmount = ChallengeModel.payoutDraw(stake);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        // FIX: Opaque surface — no semi-transparent dark leaking through
        color:        AppColors.surface.withOpacity(0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset:     const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PAYOUT PREVIEW',
            style: TextStyle(
              color:         AppColors.textMuted,
              fontSize:      10,
              fontWeight:    FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 14),

          _PayoutRow(
            icon:       '🏆',
            label:      'Win',
            detail:     '+${(stake * 0.8).floor()} AC → $winAmount AC total',
            valueColor: AppColors.correct,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(color: AppColors.divider, height: 1),
          ),
          _PayoutRow(
            icon:       '🤝',
            label:      'Draw',
            detail:     'get back $drawAmount AC',
            valueColor: AppColors.secondary,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(color: AppColors.divider, height: 1),
          ),
          _PayoutRow(
            icon:       '💸',
            label:      'Lose',
            detail:     '0 AC',
            valueColor: AppColors.wrong,
          ),

          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color:        AppColors.surfaceDim.withOpacity(0.6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              '🏦  House fee: 20% of opponent\'s stake on a win',
              style: TextStyle(
                  color: AppColors.textMuted, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _PayoutRow extends StatelessWidget {
  final String icon;
  final String label;
  final String detail;
  final Color  valueColor;

  const _PayoutRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(
              color:      AppColors.textSecondary,
              fontSize:   13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            detail,
            style: TextStyle(
              color:      valueColor,
              fontSize:   13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
}

// ── Collapsible rules ──────────────────────────────────────────────────────────
class _CollapsibleRules extends StatelessWidget {
  final bool         expanded;
  final VoidCallback onToggle;

  const _CollapsibleRules(
      {required this.expanded, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // FIX: Solid opaque surface instead of bare AppColors.surface
        // which may render transparent/dark on some theme configs
        color:        AppColors.surface.withOpacity(0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withOpacity(0.07),
            blurRadius: 10,
            offset:     const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            onTap:        onToggle,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width:  32,
                    height: 32,
                    decoration: BoxDecoration(
                      color:        AppColors.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Center(
                      child: Icon(Icons.info_outline_rounded,
                          color: AppColors.primary, size: 17),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'How challenges work',
                      style: TextStyle(
                        color:      AppColors.textPrimary,
                        fontSize:   14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns:    expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.keyboard_arrow_down_rounded,
                        color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve:    Curves.easeInOut,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      children: const [
                        Divider(color: AppColors.divider, height: 1),
                        SizedBox(height: 12),
                        _RuleStep(
                          n:    '1',
                          text: 'Both players stake AC upfront — loser forfeits their stake',
                        ),
                        SizedBox(height: 8),
                        _RuleStep(
                          n:    '2',
                          text: 'Winner gets their stake back + 80% of the loser\'s stake',
                        ),
                        SizedBox(height: 8),
                        _RuleStep(
                          n:    '3',
                          text: 'Draw: each player gets their stake back minus a 5% house fee',
                        ),
                        SizedBox(height: 8),
                        _RuleStep(
                          n:    '4',
                          text: 'Max 3 challenges created and 3 joined per day · Max 2 active at once',
                          last: true,
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _RuleStep extends StatelessWidget {
  final String n;
  final String text;
  final bool   last;

  const _RuleStep(
      {required this.n, required this.text, this.last = false});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width:  24,
            height: 24,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.primary.withOpacity(0.25),
                  AppColors.primary.withOpacity(0.10),
                ],
              ),
              shape:  BoxShape.circle,
              border: Border.all(
                  color: AppColors.primary.withOpacity(0.5)),
            ),
            child: Center(
              child: Text(
                n,
                style: const TextStyle(
                  color:      AppColors.primary,
                  fontSize:   11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                text,
                style: const TextStyle(
                  color:    AppColors.textSecondary,
                  fontSize: 13,
                  height:   1.4,
                ),
              ),
            ),
          ),
        ],
      );
}

// ── Sticky bottom CTA ──────────────────────────────────────────────────────────
class _StakeCta extends StatelessWidget {
  final int          stakeValue;
  final bool         loading;
  final bool         canAfford;
  final bool         dailyLimitReached;
  final VoidCallback? onTap;

  const _StakeCta({
    required this.stakeValue,
    required this.loading,
    required this.canAfford,
    required this.dailyLimitReached,
    required this.onTap,
  });

  String get _label {
    if (loading)                        return 'Creating challenge…';
    if (dailyLimitReached)              return 'Daily limit reached';
    if (stakeValue > 0 && !canAfford)   return 'Not enough AC';
    if (stakeValue > 0)                 return 'Stake $stakeValue AC & Play ⚡';
    return 'Set your entry amount';
  }

  @override
  Widget build(BuildContext context) {
    // FIX: Replace the flat dark container with a gradient fade so it
    // blends into the hero background instead of creating a hard dark bar.
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        // Respect the system bottom bar height so the button isn't hidden
        // on devices using gesture navigation.
        20 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end:   Alignment.bottomCenter,
          colors: [
            AppColors.surfaceDim.withOpacity(0),
            AppColors.surfaceDim.withOpacity(0.96),
            AppColors.surfaceDim,
          ],
          stops: const [0.0, 0.35, 1.0],
        ),
      ),
      child: GradientButton(
        label:     _label,
        icon:      loading ? null : Icons.flash_on_rounded,
        onTap:     onTap,
      ),
    );
  }
}

// ── Full-screen creating overlay ───────────────────────────────────────────────
class _CreatingOverlay extends StatelessWidget {
  final String  animeTitle;
  final String? opponentUsername;

  const _CreatingOverlay({
    required this.animeTitle,
    this.opponentUsername,
  });

  @override
  Widget build(BuildContext context) {
    final hasRival = opponentUsername != null && opponentUsername!.isNotEmpty;
    final heading  = hasRival
        ? 'Challenging $opponentUsername…'
        : 'Building your challenge…';

    return Container(
      color: Colors.black.withOpacity(0.70),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 40),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color:        AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: AppColors.primary.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color:      AppColors.primary.withOpacity(0.15),
                blurRadius: 40,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated logo pulse during loading
              Container(
                width:  56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.primary, Color(0xFFFF6B6B)],
                    begin:  Alignment.topLeft,
                    end:    Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color:      AppColors.primary.withOpacity(0.4),
                      blurRadius: 20,
                      offset:     const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Center(
                  child: CircularProgressIndicator(
                    color:       Colors.white,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                heading,
                style: const TextStyle(
                  color:      AppColors.textPrimary,
                  fontSize:   16,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'Picking 10 $animeTitle questions',
                style: const TextStyle(
                  color:    AppColors.textMuted,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}