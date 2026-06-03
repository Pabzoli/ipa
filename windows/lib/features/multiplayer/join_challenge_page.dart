import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart'; // Added for Cloud Function integration

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import '../../core/providers/user_data_provider.dart';
import '../quiz/questions_page.dart';
import 'challenge_model.dart';

// ─── Join Challenge page — redesigned from scratch ────────────────────────────
//
// Stage 08 changes:
//   - Balance check uses animeCoins instead of totalScore (pts).
//   - All "pts" labels updated to "AC".
//   - Stake details card shows AC and an AC-based affordability check.
//   - Friendly CF error messages added (mirrors StakeScreen).
//   - The Cloud Function joinChallenge already deducts stakeAmount server-side;
//     the client check here is purely a UX guard to surface the error early.
//
// NOTE: UserDataProvider must expose int get animeCoins.
// ──────────────────────────────────────────────────────────────────────────────
class JoinChallengePage extends StatefulWidget {
  const JoinChallengePage({super.key});

  @override
  State<JoinChallengePage> createState() => _JoinChallengePageState();
}

class _JoinChallengePageState extends State<JoinChallengePage> {
  static const _len = 6;
  static const int _kMaxJoinsPerDay = 3;

  final List<TextEditingController> _ctrls =
      List.generate(_len, (_) => TextEditingController());
  final List<FocusNode> _nodes =
      List.generate(_len, (_) => FocusNode());

  ChallengeModel? _found;
  bool _looking = false;
  bool _joining = false;
  String? _error;

  // ── Daily join-limit tracking ─────────────────────────────────────────────
  StreamSubscription<int>? _joinCountSub;
  int _joinsToday = 0;

  bool get _atDailyLimit => _joinsToday >= _kMaxJoinsPerDay;

  @override
  void initState() {
    super.initState();
    _joinCountSub = FirestoreService.instance
        .challengesJoinedTodayStream()
        .listen((count) {
      if (mounted) setState(() => _joinsToday = count);
    });
  }

  @override
  void dispose() {
    _joinCountSub?.cancel();
    for (final c in _ctrls) c.dispose();
    for (final n in _nodes) n.dispose();
    super.dispose();
  }

  String get _code =>
      _ctrls.map((c) => c.text.toUpperCase()).join();

  bool get _codeComplete => _code.length == _len;

  void _onBoxChanged(int i, String val) {
    if (val.isEmpty) return;
    if (i < _len - 1) {
      _nodes[i + 1].requestFocus();
    } else {
      _nodes[i].unfocus();
      if (_codeComplete) _lookUp();
    }
    setState(() {
      _found = null;
      _error = null;
    });
  }

  void _onBoxKey(int i, RawKeyEvent event) {
    if (event is RawKeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _ctrls[i].text.isEmpty &&
        i > 0) {
      _nodes[i - 1].requestFocus();
      _ctrls[i - 1].clear();
      setState(() {});
    }
  }

  Future<void> _pasteCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = (data?.text ?? '')
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toUpperCase();
    if (raw.length < _len) return;
    for (int i = 0; i < _len; i++) {
      _ctrls[i].text = raw[i];
    }
    setState(() {
      _found = null;
      _error = null;
    });
    if (_codeComplete) _lookUp();
  }

  void _clearCode() {
    for (final c in _ctrls) c.clear();
    setState(() {
      _found = null;
      _error = null;
    });
    _nodes[0].requestFocus();
  }

  Future<void> _lookUp() async {
    if (!_codeComplete || _looking) return;

    setState(() {
      _looking = true;
      _found = null;
      _error = null;
    });

    try {
      final challenge =
          await FirestoreService.instance.getChallengeByCode(_code);
      if (!mounted) return;

      if (challenge == null) {
        setState(() {
          _looking = false;
          _error = 'No challenge found with code "$_code"';
        });
        return;
      }

      final uid = FirestoreService.instance.currentUid;
      if (challenge.creatorUid == uid) {
        setState(() {
          _looking = false;
          _error = "That's your own challenge — share it with a friend!";
        });
        return;
      }
      if (challenge.isExpired) {
        setState(() {
          _looking = false;
          _error = 'This challenge has expired.';
        });
        return;
      }
      if (challenge.status != ChallengeStatus.waiting) {
        setState(() {
          _looking = false;
          _error = challenge.isCompleted
              ? 'This challenge is already completed.'
              : 'Someone already joined this challenge.';
        });
        return;
      }

      setState(() {
        _looking = false;
        _found = challenge;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _looking = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // Maps CF error codes to user-facing messages (same pattern as StakeScreen).
  String _friendlyError(String raw) {
    final s = raw.replaceFirst('Exception: ', '');
    return switch (s) {
      'insufficient_coins'            => 'Not enough AC for this stake',
      'daily_challenge_limit_reached' => 'Daily limit reached — max 3 challenges joined per day',
      'too_many_active_challenges'    => 'You already have 2 active challenges running',
      'challenge_not_waiting'         => 'This challenge is no longer available',
      'cannot_join_own_challenge'     => "That's your own challenge!",
      _                               => s,
    };
  }

  Future<void> _accept() async {
    if (_found == null || _joining) return;

    // Proactive daily-limit guard — same information the CF will reject with,
    // but surfaces it before the network round-trip.
    if (_atDailyLimit) {
      setState(() => _error =
          'Daily limit reached — max $_kMaxJoinsPerDay challenges joined per day');
      return;
    }

    // Client-side AC balance guard — prevents a network round-trip the user
    // knows will fail. The actual deduction happens server-side in joinChallenge.
    final balance = context.read<UserDataProvider>().animeCoins;
    if (balance < _found!.stakeAmount) {
      setState(() => _error =
          'Need ${_found!.stakeAmount} AC — you have $balance AC');
      return;
    }

    setState(() {
      _joining = true;
      _error = null;
    });

    try {
      // Routed through the Cloud Function backend to ensure safe state changes & validations
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('joinChallenge')
          .call({'challengeId': _found!.challengeId});
          
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, a, __) => FadeTransition(
            opacity: a,
            child: QuestionsPage(
              mode: QuizMode.asyncChallenge,
              questionIds: _found!.questionIds,
              challengeId: _found!.challengeId,
              isCreator: false,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = _friendlyError(e.message ?? '');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Stage 08: use animeCoins (AC) instead of totalScore (pts).
    final balance = context.watch<UserDataProvider>().animeCoins;
    final busy = _looking || _joining;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: Container(
        decoration: AppDecorations.heroBg,
        child: SafeArea(
          child: Column(
            children: [
              // ── App bar ──────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded,
                          color: AppColors.textPrimary, size: 20),
                      onPressed:
                          busy ? null : () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'Join Challenge',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: busy ? null : _pasteCode,
                      icon: const Icon(Icons.paste_rounded,
                          size: 16, color: AppColors.primary),
                      label: const Text(
                        'Paste',
                        style: TextStyle(
                            color: AppColors.primary, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Hero text ────────────────────────────────────
                      const Text(
                        'Enter the 6-character\nchallenge code',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          height: 1.2,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Ask your friend to share their code from the lobby.',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── Daily join counter ────────────────────────────
                      _DailyLimitChip(
                        joinsToday: _joinsToday,
                        maxJoins:   _kMaxJoinsPerDay,
                        atLimit:    _atDailyLimit,
                      ),

                      const SizedBox(height: 18),

                      // ── OTP boxes ────────────────────────────────────
                      _CodeBoxes(
                        ctrls: _ctrls,
                        nodes: _nodes,
                        busy: busy,
                        onChanged: _onBoxChanged,
                        onKey: _onBoxKey,
                        hasError: _error != null,
                      ),

                      const SizedBox(height: 16),

                      // ── Clear link ───────────────────────────────────
                      if (_codeComplete || _error != null)
                        Center(
                          child: TextButton(
                            onPressed: busy ? null : _clearCode,
                            child: const Text(
                              'Clear code',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),

                      // ── Error state ──────────────────────────────────
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: _error != null
                            ? _ErrorBanner(
                                key: ValueKey(_error),
                                message: _error!)
                            : const SizedBox.shrink(
                                key: ValueKey('none')),
                      ),

                      // ── Loading state ────────────────────────────────
                      if (_looking) ...[
                        const SizedBox(height: 24),
                        const _LookingUp(),
                      ],

                      // ── Challenge details ────────────────────────────
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        transitionBuilder: (child, anim) =>
                            SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.15),
                            end: Offset.zero,
                          ).animate(CurvedAnimation(
                              parent: anim,
                              curve: Curves.easeOut)),
                          child: FadeTransition(
                              opacity: anim, child: child),
                        ),
                        child: _found != null
                            ? Column(
                                key: ValueKey(_found!.challengeId),
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(height: 24),
                                  _ChallengeDetailsCard(
                                    challenge: _found!,
                                    userBalance: balance,
                                  ),
                                  const SizedBox(height: 16),
                                  GradientButton(
                                    label: _joining
                                        ? 'Joining…'
                                        : _atDailyLimit
                                            ? 'Daily limit reached'
                                            : 'Accept & Play ⚡',
                                    icon: _joining || _atDailyLimit
                                        ? null
                                        : Icons.flash_on_rounded,
                                    onTap: _joining || _atDailyLimit
                                        ? null
                                        : _accept,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${_found!.stakeAmount} AC will be deducted from your balance',
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 11,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(
                                key: ValueKey('empty')),
                      ),
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

// ── OTP-style 6-box code input ─────────────────────────────────────────────────
class _CodeBoxes extends StatelessWidget {
  final List<TextEditingController> ctrls;
  final List<FocusNode> nodes;
  final bool busy;
  final void Function(int, String) onChanged;
  final void Function(int, RawKeyEvent) onKey;
  final bool hasError;

  const _CodeBoxes({
    required this.ctrls,
    required this.nodes,
    required this.busy,
    required this.onChanged,
    required this.onKey,
    required this.hasError,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // First 3 boxes
        ...List.generate(
          3,
          (i) => _CodeBox(
            ctrl: ctrls[i],
            node: nodes[i],
            enabled: !busy,
            hasError: hasError,
            onChanged: (v) => onChanged(i, v),
            onKey: (e) => onKey(i, e),
          ),
        ),
        // Dash separator
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            '–',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 24,
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
        // Last 3 boxes
        ...List.generate(3, (i) {
          final idx = i + 3;
          return _CodeBox(
            ctrl: ctrls[idx],
            node: nodes[idx],
            enabled: !busy,
            hasError: hasError,
            onChanged: (v) => onChanged(idx, v),
            onKey: (e) => onKey(idx, e),
          );
        }),
      ],
    );
  }
}

class _CodeBox extends StatelessWidget {
  final TextEditingController ctrl;
  final FocusNode node;
  final bool enabled;
  final bool hasError;
  final ValueChanged<String> onChanged;
  final ValueChanged<RawKeyEvent> onKey;

  const _CodeBox({
    required this.ctrl,
    required this.node,
    required this.enabled,
    required this.hasError,
    required this.onChanged,
    required this.onKey,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 54,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      child: RawKeyboardListener(
        focusNode: FocusNode(),
        onKey: onKey,
        child: TextField(
          controller: ctrl,
          focusNode: node,
          enabled: enabled,
          maxLength: 1,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
          ],
          style: TextStyle(
            color: hasError ? AppColors.wrong : AppColors.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
          decoration: InputDecoration(
            counterText: '',
            filled: true,
            fillColor: hasError
                ? AppColors.wrong.withOpacity(0.08)
                : AppColors.surface,
            contentPadding: EdgeInsets.zero,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: hasError
                    ? AppColors.wrong.withOpacity(0.5)
                    : AppColors.divider,
                width: 1.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: hasError
                    ? AppColors.wrong
                    : AppColors.primary,
                width: 2,
              ),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                  color: AppColors.divider.withOpacity(0.5)),
            ),
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ── Error banner ───────────────────────────────────────────────────────────────
class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.wrong.withOpacity(0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.wrong.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppColors.wrong, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                  color: AppColors.wrong, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Looking-up skeleton ────────────────────────────────────────────────────────
class _LookingUp extends StatelessWidget {
  const _LookingUp();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.divider),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            SizedBox(width: 12),
            Text(
              'Looking up challenge…',
              style:
                  TextStyle(color: AppColors.textMuted, fontSize: 14),
            ),
          ],
        ),
      );
}

// ── Challenge details card ─────────────────────────────────────────────────────
// Stage 08: Shows AC amounts and the payout preview inline.
class _ChallengeDetailsCard extends StatelessWidget {
  final ChallengeModel challenge;
  final int userBalance;
  const _ChallengeDetailsCard({
    required this.challenge,
    required this.userBalance,
  });

  String _formatRemaining(Duration d) {
    if (d == Duration.zero) return 'Expired';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m left' : '${m}m left';
  }

  @override
  Widget build(BuildContext context) {
    final stake = challenge.stakeAmount;
    final canAfford = userBalance >= stake;
    final winAmount  = ChallengeModel.payoutWin(stake);
    final drawAmount = ChallengeModel.payoutDraw(stake);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.correct.withOpacity(0.12),
            AppColors.correct.withOpacity(0.04),
          ],
        ),
        border: Border.all(
          color: AppColors.correct.withOpacity(0.3),
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          // Creator header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.correct.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Text('⚔️', style: TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      challenge.creatorUsername,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Text(
                      'is challenging you!',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(color: AppColors.divider, height: 1),

          // Detail rows
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _Row(label: 'Anime', value: challenge.animeTitle),
                const SizedBox(height: 10),
                _Row(
                  label: 'Stake',
                  value: '$stake AC',
                  valueColor:
                      canAfford ? AppColors.correct : AppColors.wrong,
                ),
                const SizedBox(height: 10),
                _Row(
                  label: 'Questions',
                  value: '${challenge.questionIds.length} questions',
                ),
                const SizedBox(height: 10),
                _Row(
                  label: 'Expires',
                  value: _formatRemaining(challenge.timeRemaining),
                ),

                // Payout preview rows
                const SizedBox(height: 12),
                const Divider(color: AppColors.divider, height: 1),
                const SizedBox(height: 12),
                _Row(
                  label: '🏆 Win',
                  value: '+$winAmount AC',
                  valueColor: AppColors.correct,
                ),
                const SizedBox(height: 6),
                _Row(
                  label: '🤝 Draw',
                  value: '+$drawAmount AC',
                  valueColor: AppColors.secondary,
                ),
                const SizedBox(height: 6),
                _Row(
                  label: '💸 Lose',
                  value: '0 AC',
                  valueColor: AppColors.wrong,
                ),

                // Insufficient balance warning
                if (!canAfford) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.wrong.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: AppColors.wrong, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'You need $stake AC. You have $userBalance AC.',
                            style: const TextStyle(
                                color: AppColors.wrong,
                                fontSize: 12,
                                height: 1.3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Daily join-limit chip ──────────────────────────────────────────────────────
//
// Mirrors the "X of 3 challenges remaining today" chip on StakeScreen.
// Reads [joinsToday] from the live [challengesJoinedTodayStream] and renders:
//   • Green pill  → 0 used  ("3 of 3 joins remaining today")
//   • Amber pill  → 1–2 used
//   • Red pill    → limit reached ("Daily limit reached")
class _DailyLimitChip extends StatelessWidget {
  final int  joinsToday;
  final int  maxJoins;
  final bool atLimit;

  const _DailyLimitChip({
    required this.joinsToday,
    required this.maxJoins,
    required this.atLimit,
  });

  @override
  Widget build(BuildContext context) {
    final remaining = (maxJoins - joinsToday).clamp(0, maxJoins);

    final Color bgColor;
    final Color textColor;
    final IconData icon;
    final String label;

    if (atLimit) {
      bgColor   = AppColors.wrong.withOpacity(0.12);
      textColor = AppColors.wrong;
      icon      = Icons.block_rounded;
      label     = 'Daily limit reached — resets tomorrow';
    } else if (remaining == maxJoins) {
      bgColor   = AppColors.correct.withOpacity(0.10);
      textColor = AppColors.correct;
      icon      = Icons.check_circle_outline_rounded;
      label     = '$remaining of $maxJoins joins remaining today';
    } else {
      bgColor   = AppColors.secondary.withOpacity(0.12);
      textColor = AppColors.secondary;
      icon      = Icons.timelapse_rounded;
      label     = '$remaining of $maxJoins joins remaining today';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: textColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: textColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color:      textColor,
              fontSize:   12,
              fontWeight: FontWeight.w600,
              height:     1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _Row(
      {required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
}