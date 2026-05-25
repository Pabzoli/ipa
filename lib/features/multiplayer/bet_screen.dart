import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/firestore_service.dart';
import '../quiz/questions_page.dart';

// ─── Bet configuration — step 2 of Create Challenge flow ──────────────────────
// What changed: Complete UI overhaul. The old screen had a plain TextField and
// generic chips. The new design uses:
// - Animated balance display that reacts to bet selection
// - Visual chip-stack buttons instead of plain Chip widgets
// - Inline validation feedback (not just a SnackBar)
// - A collapsible "How it works" section to save vertical space
// - A sticky bottom CTA so the button is always visible without scrolling
class BetScreen extends StatefulWidget {
  final String animeTitle;
  const BetScreen({super.key, required this.animeTitle});

  @override
  State<BetScreen> createState() => _BetScreenState();
}

class _BetScreenState extends State<BetScreen>{
  final _ctrl = TextEditingController();
  bool _creating = false;
  String? _inlineError;

  // Expand/collapse the rules panel
  bool _rulesExpanded = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int get _betValue => int.tryParse(_ctrl.text) ?? 0;

  void _setQuickBet(int amount) {
    HapticFeedback.selectionClick();
    setState(() {
      _ctrl.text = '$amount';
      _inlineError = null;
    });
  }

  String? _validate(int totalScore) {
    final bet = _betValue;
    if (bet < 100) return 'Minimum bet is 100 pts';
    if (bet > 99000) return 'Maximum bet is 99,000 pts';
    if (bet % 100 != 0) return 'Must be a multiple of 100';
    if (bet > totalScore) return 'Not enough balance ($totalScore pts)';
    return null;
  }

  Future<void> _createChallenge(int totalScore) async {
    final error = _validate(totalScore);
    if (error != null) {
      HapticFeedback.lightImpact();
      setState(() => _inlineError = error);
      return;
    }

    setState(() {
      _creating = true;
      _inlineError = null;
    });

    try {
      final result = await FirestoreService.instance.createChallenge(
        animeTitle: widget.animeTitle,
        betAmount: _betValue,
      );
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: QuestionsPage(
              mode: QuizMode.asyncChallenge,
              questionIds: result.questionIds,
              challengeId: result.challengeId,
              isCreator: true,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _inlineError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final userData = context.watch<UserDataProvider>();
    final totalScore = userData.score;
    final quickBets =
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
                    // ── App bar ────────────────────────────────────────
                    _BetAppBar(
                      animeTitle: widget.animeTitle,
                      enabled: !_creating,
                    ),

                    Expanded(
                      child: SingleChildScrollView(
                        padding:
                            const EdgeInsets.fromLTRB(20, 0, 20, 120),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 20),

                            // ── Balance card ───────────────────────────
                            _BalanceCard(
                              balance: totalScore,
                              betValue: _betValue,
                            ),

                            const SizedBox(height: 20),

                            // ── Bet input section ──────────────────────
                            _BetInputSection(
                              ctrl: _ctrl,
                              enabled: !_creating,
                              inlineError: _inlineError,
                              quickBets: quickBets,
                              onQuickBet: _setQuickBet,
                              onChanged: (_) => setState(() => _inlineError = null),
                            ),

                            const SizedBox(height: 20),

                            // ── Collapsible rules ──────────────────────
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
                // Why: Placed in a Stack overlay so it's always visible
                // regardless of scroll position — the user never loses the CTA.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _StickyBetCta(
                    betValue: _betValue,
                    loading: _creating,
                    onTap: _creating ? null : () => _createChallenge(totalScore),
                  ),
                ),

                // ── Creating overlay ───────────────────────────────────
                if (_creating)
                _CreatingOverlay(animeTitle: widget.animeTitle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── App bar ────────────────────────────────────────────────────────────────────
class _BetAppBar extends StatelessWidget {
  final String animeTitle;
  final bool enabled;
  const _BetAppBar({required this.animeTitle, required this.enabled});

  @override
  Widget build(BuildContext context) {
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
                  'Set Your Bet',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  'Step 2 of 2 · ${animeTitle}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
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

// ── Balance card — shows remaining balance after bet ───────────────────────────
// Why: Animated switcher makes the "after bet" number feel immediate and
// communicates the consequence of the bet clearly.
class _BalanceCard extends StatelessWidget {
  final int balance;
  final int betValue;
  const _BalanceCard({required this.balance, required this.betValue});

  @override
  Widget build(BuildContext context) {
    final afterBet = (balance - betValue).clamp(0, balance);
    final isAffordable = betValue == 0 || betValue <= balance;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.secondary.withOpacity(0.18),
            AppColors.secondary.withOpacity(0.06),
          ],
        ),
        border: Border.all(
          color: AppColors.secondary.withOpacity(0.35),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your Balance',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    '$balance pts',
                    key: ValueKey(balance),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (betValue > 0) ...[
            const Icon(Icons.arrow_forward_rounded,
                color: AppColors.textMuted, size: 18),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text(
                  'After bet',
                  style: TextStyle(
                      color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    '$afterBet pts',
                    key: ValueKey(afterBet),
                    style: TextStyle(
                      color: isAffordable
                          ? AppColors.textSecondary
                          : AppColors.wrong,
                      fontSize: 22,
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

// ── Bet input section ──────────────────────────────────────────────────────────
class _BetInputSection extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;
  final String? inlineError;
  final List<int> quickBets;
  final ValueChanged<int> onQuickBet;
  final ValueChanged<String> onChanged;

  const _BetInputSection({
    required this.ctrl,
    required this.enabled,
    required this.inlineError,
    required this.quickBets,
    required this.onQuickBet,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Stake Amount',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),

        // Big number input
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: inlineError != null
                  ? AppColors.wrong.withOpacity(0.6)
                  : AppColors.divider,
              width: 1.5,
            ),
          ),
          child: TextField(
            controller: ctrl,
            enabled: enabled,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 32,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
            ),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              hintText: '0',
              hintStyle: TextStyle(
                color: AppColors.textMuted,
                fontSize: 32,
                fontWeight: FontWeight.w900,
              ),
              prefixText: '⚡  ',
              suffixText: ' pts',
              suffixStyle: TextStyle(
                color: AppColors.textMuted,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              border: InputBorder.none,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            ),
            onChanged: onChanged,
          ),
        ),

        // Inline error
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: inlineError != null
              ? Padding(
                  key: ValueKey(inlineError),
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

        // Quick bet chips
        if (quickBets.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Text(
            'Quick bet',
            style: TextStyle(
                color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: quickBets
                .map((b) => _QuickBetChip(
                      amount: b,
                      selected: ctrl.text == '$b',
                      enabled: enabled,
                      onTap: () => onQuickBet(b),
                    ))
                .toList(),
          ),
        ],

        const SizedBox(height: 8),
        const Text(
          'Min 100 pts · multiples of 100',
          style: TextStyle(color: AppColors.textMuted, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ── Quick bet chip ─────────────────────────────────────────────────────────────
class _QuickBetChip extends StatelessWidget {
  final int amount;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _QuickBetChip({
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
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withOpacity(0.2)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : AppColors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          '$amount',
          style: TextStyle(
            color: selected
                ? AppColors.primary
                : AppColors.textSecondary,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

// ── Collapsible rules ──────────────────────────────────────────────────────────
// Why: The old "how it works" card was always expanded, eating vertical space.
// Collapsing it by default puts the bet input in focus.
class _CollapsibleRules extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  const _CollapsibleRules({required this.expanded, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      color: AppColors.primary, size: 18),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'How challenges work',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
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
            curve: Curves.easeInOut,
            child: expanded
                ? Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      children: const [
                        Divider(color: AppColors.divider, height: 1),
                        SizedBox(height: 12),
                        _RuleStep(n: '1', text: 'You answer 10 questions immediately after creating'),
                        SizedBox(height: 8),
                        _RuleStep(n: '2', text: 'Share your 6-letter code with your opponent'),
                        SizedBox(height: 8),
                        _RuleStep(n: '3', text: 'They play the exact same questions'),
                        SizedBox(height: 8),
                        _RuleStep(n: '4', text: 'Higher score wins both bets · Draw = full refund', last: true),
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
  final bool last;
  const _RuleStep(
      {required this.n, required this.text, this.last = false});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(
                  color: AppColors.primary.withOpacity(0.5)),
            ),
            child: Center(
              child: Text(
                n,
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: 2, bottom: last ? 0 : 0),
              child: Text(
                text,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      );
}

// ── Sticky bottom CTA ──────────────────────────────────────────────────────────
class _StickyBetCta extends StatelessWidget {
  final int betValue;
  final bool loading;
  final VoidCallback? onTap;
  const _StickyBetCta(
      {required this.betValue, required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        border: const Border(
            top: BorderSide(color: AppColors.divider, width: 0.5)),
      ),
      child: GradientButton(
        label: loading
            ? 'Creating challenge…'
            : betValue > 0
                ? 'Stake $betValue pts & Play ⚡'
                : 'Enter a bet amount',
        icon: loading ? null : Icons.flash_on_rounded,
        onTap: onTap,
      ),
    );
  }
}

// ── Full-screen creating overlay ───────────────────────────────────────────────
class _CreatingOverlay extends StatelessWidget {
  final String animeTitle;
  const _CreatingOverlay({required this.animeTitle});

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black.withOpacity(0.75),
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 40),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: AppColors.primary.withOpacity(0.3)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: AppColors.primary),
                const SizedBox(height: 20),
                const Text(
                  'Building your challenge…',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Picking 10 $animeTitle questions',
                  style: const TextStyle(
                    color: AppColors.textMuted,
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