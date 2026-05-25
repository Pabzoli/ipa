import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/firestore_service.dart';
import '../../core/providers/user_data_provider.dart';
import '../quiz/questions_page.dart';
import 'challenge_model.dart';

// ─── Join Challenge page — redesigned from scratch ────────────────────────────
// What changed:
// - OTP-style 6-box code input replaces a plain TextField. Each box is its own
//   character, auto-advances on input, auto-retreats on backspace.
// - Challenge details slide in from below using AnimatedSwitcher instead of
//   just appearing.
// - Inline error banners replaced the raw SnackBar for errors.
// - Loading state is a skeleton card instead of a spinner + text combo.
class JoinChallengePage extends StatefulWidget {
  const JoinChallengePage({super.key});

  @override
  State<JoinChallengePage> createState() => _JoinChallengePageState();
}

class _JoinChallengePageState extends State<JoinChallengePage> {
  static const _len = 6;

  // One controller + focus node per box
  final List<TextEditingController> _ctrls =
      List.generate(_len, (_) => TextEditingController());
  final List<FocusNode> _nodes =
      List.generate(_len, (_) => FocusNode());

  ChallengeModel? _found;
  bool _looking = false;
  bool _joining = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  String get _code =>
      _ctrls.map((c) => c.text.toUpperCase()).join();

  bool get _codeComplete => _code.length == _len;

  // Called after every character change in a box
  void _onBoxChanged(int i, String val) {
    if (val.isEmpty) return;
    // Auto-advance to next box
    if (i < _len - 1) {
      _nodes[i + 1].requestFocus();
    } else {
      _nodes[i].unfocus();
      // Auto-lookup when last char entered
      if (_codeComplete) _lookUp();
    }
    setState(() {
      _found = null;
      _error = null;
    });
  }

  // Backspace: move to previous box
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

  // Paste handler — fills all boxes from clipboard
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
    for (final c in _ctrls) {
      c.clear();
    }
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

  Future<void> _accept() async {
    if (_found == null || _joining) return;

    final balance = context.read<UserDataProvider>().score;
    if (balance < _found!.betAmount) {
      setState(() => _error =
          'Need ${_found!.betAmount} pts — you have $balance');
      return;
    }

    setState(() {
      _joining = true;
      _error = null;
    });

    try {
      await FirestoreService.instance.joinChallenge(_found!.challengeId);
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = context.watch<UserDataProvider>().score;
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
                      onPressed: busy ? null : () => Navigator.pop(context),
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
                    // Paste button — hugely convenient on mobile
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

                      const SizedBox(height: 32),

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
                            : const SizedBox.shrink(key: ValueKey('none')),
                      ),

                      // ── Loading state ────────────────────────────────
                      if (_looking) ...[
                        const SizedBox(height: 24),
                        const _LookingUp(),
                      ],

                      // ── Challenge details ────────────────────────────
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        transitionBuilder: (child, anim) => SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.15),
                            end: Offset.zero,
                          ).animate(CurvedAnimation(
                              parent: anim, curve: Curves.easeOut)),
                          child: FadeTransition(opacity: anim, child: child),
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
                                        : 'Accept & Play ⚡',
                                    icon: _joining
                                        ? null
                                        : Icons.flash_on_rounded,
                                    onTap: _joining ? null : _accept,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${_found!.betAmount} pts will be deducted from your balance',
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 11,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(key: ValueKey('empty')),
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
// Why: This pattern is ubiquitous for codes and feels native on mobile.
// Each box gets a single character, the caret auto-moves, and the visual
// grouping (3+3 with a dash) helps readability.
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
        ...List.generate(3, (i) => _CodeBox(
              ctrl: ctrls[i],
              node: nodes[i],
              enabled: !busy,
              hasError: hasError,
              onChanged: (v) => onChanged(i, v),
              onKey: (e) => onKey(i, e),
            )),
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
                color: hasError ? AppColors.wrong : AppColors.primary,
                width: 2,
              ),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.divider.withOpacity(0.5)),
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
    final canAfford = userBalance >= challenge.betAmount;

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
                _Row(
                    label: 'Anime',
                    value: challenge.animeTitle),
                const SizedBox(height: 10),
                _Row(
                  label: 'Bet',
                  value: '${challenge.betAmount} pts',
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
                            'You need ${challenge.betAmount} pts. You have $userBalance.',
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

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _Row({required this.label, required this.value, this.valueColor});

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