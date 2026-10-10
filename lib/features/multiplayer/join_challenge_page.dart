import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/providers/user_data_provider.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_page_route.dart';
import '../quiz/questions_page.dart';
import 'challenge_model.dart';

class JoinChallengePage extends StatefulWidget {
  const JoinChallengePage({super.key});

  @override
  State<JoinChallengePage> createState() => _JoinChallengePageState();
}

class _JoinChallengePageState extends State<JoinChallengePage> {
  static const int _len = 6;

  final List<TextEditingController> _ctrls =
      List.generate(_len, (_) => TextEditingController());
  final List<FocusNode> _nodes = List.generate(_len, (_) => FocusNode());

  ChallengeModel? _found;
  bool _looking = false;
  bool _joining = false;
  bool _declining = false;
  String? _error;

  StreamSubscription<int>? _joinCountSub;
  int _joinsToday = 0;

  int get _maxJoinsPerDay {
    final premium =
        context.read<UserDataProvider>().premiumActive;
    return premium ? 5 : 3;
  }

  bool get _atDailyLimit => _joinsToday >= _maxJoinsPerDay;
  String get _code => _ctrls.map((c) => c.text.toUpperCase()).join();
  bool get _codeComplete => _code.length == _len;

  @override
  void initState() {
    super.initState();
    _joinCountSub = FirestoreService.instance
        .challengesJoinedTodayStream()
        .listen((count) {
      if (mounted) {
        setState(() => _joinsToday = count);
      }
    });
  }

  @override
  void dispose() {
    _joinCountSub?.cancel();
    for (final c in _ctrls) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _onBoxChanged(int index, String value) {
    if (value.isEmpty) {
      setState(() {
        _found = null;
        _error = null;
      });
      return;
    }

    if (index < _len - 1) {
      _nodes[index + 1].requestFocus();
    } else {
      _nodes[index].unfocus();
      if (_codeComplete) {
        _lookUp();
      }
    }

    setState(() {
      _found = null;
      _error = null;
    });
  }

  void _onBoxKey(int index, RawKeyEvent event) {
    if (event is RawKeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _ctrls[index].text.isEmpty &&
        index > 0) {
      _nodes[index - 1].requestFocus();
      _ctrls[index - 1].clear();
      setState(() {
        _found = null;
        _error = null;
      });
    }
  }

  Future<void> _pasteCode() async {
    if (_joining || _looking) return;

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = (data?.text ?? '')
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toUpperCase();

    if (raw.length < _len) {
      setState(() {
        _error = 'Clipboard does not contain a 6-character challenge code.';
      });
      return;
    }

    for (int i = 0; i < _len; i++) {
      _ctrls[i].text = raw[i];
    }

    setState(() {
      _found = null;
      _error = null;
    });

    if (_codeComplete) {
      _nodes[_len - 1].unfocus();
      await _lookUp();
    }
  }

  void _clearCode() {
    if (_joining || _looking) return;

    for (final c in _ctrls) {
      c.clear();
    }

    setState(() {
      _found = null;
      _error = null;
    });

    _nodes.first.requestFocus();
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
          _error = 'No challenge found with code "$_code".';
        });
        return;
      }

      final uid = FirestoreService.instance.currentUid;

      if (challenge.creatorUid == uid) {
        setState(() {
          _looking = false;
          _error = "That's your own challenge — share the code with a friend.";
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

  String _friendlyError(String raw) {
    final s = raw.replaceFirst('Exception: ', '').trim();

    return switch (s) {
      'insufficient_coins' => 'Not enough AC for this stake',
      'daily_challenge_limit_reached' =>
        'Daily limit reached — max $_maxJoinsPerDay challenges joined per day',
      'too_many_active_challenges' =>
        'You already have $_maxJoinsPerDay active challenges',
      'challenge_not_waiting' => 'This challenge is no longer available',
      'cannot_join_own_challenge' => "That's your own challenge!",
      'not_friends' => 'Add them as a friend to spar.',
      _ => s.isEmpty ? 'Something went wrong. Please try again.' : s,
    };
  }

  Future<void> _accept() async {
    if (_found == null || _joining) return;

    if (_atDailyLimit) {
      setState(() {
        _error =
            'Daily limit reached — max $_maxJoinsPerDay challenges joined per day';
      });
      return;
    }

    final balance = context.read<UserDataProvider>().animeCoins;

    if (balance < _found!.stakeAmount) {
      setState(() {
        _error = 'Need ${_found!.stakeAmount} AC — you have $balance AC';
      });
      return;
    }

    setState(() {
      _joining = true;
      _error = null;
    });

try {
        await FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('joinChallenge')
            .call({
          'challengeId': _found!.challengeId,
          ...AppUpdateService.instance.clientBuildStamp,
        });

        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          AppPageRoute(
            builder: (_) => QuestionsPage(
              mode: QuizMode.asyncChallenge,
              questionIds: _found!.questionIds,
              challengeId: _found!.challengeId,
              isCreator: false,
            ),
          ),
        );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;

      setState(() {
        _joining = false;
        _error = _friendlyError(e.message ?? e.code);
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _joining = false;
        _error = _friendlyError(e.toString());
      });
    }
  }

  String _friendlyDeclineError(String raw) {
    final s = raw.replaceFirst('Exception: ', '').trim();
    return switch (s) {
      'challenge_not_pending' => 'This challenge is no longer pending.',
      'not_the_invited_opponent' => 'You can\'t decline this challenge.',
      _ => s.isEmpty ? 'Something went wrong. Please try again.' : s,
    };
  }

  /// Declines an INVITED rival challenge looked up by code.
  ///
  /// Only shown when the looked-up challenge names the current user as its
  /// invited opponent (opponentUid == me, status waiting) — the exact gate
  /// declineChallenge enforces server-side. Open code challenges
  /// (opponentUid null) never show this button.
  Future<void> _decline() async {
    if (_found == null || _declining || _joining || _looking) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Decline challenge?',
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: const Text(
          'Their stake will be refunded to them. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Decline',
                style: TextStyle(
                    color: AppColors.wrong, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _declining = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('declineChallenge')
          .call({'challengeId': _found!.challengeId});
      if (!mounted) return;
      setState(() {
        _declining = false;
        _found = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Challenge declined.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _declining = false;
        _error = _friendlyDeclineError(e.message ?? e.code);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _declining = false;
        _error = _friendlyDeclineError(e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = context.watch<UserDataProvider>().animeCoins;
    final busy = _looking || _joining || _declining;
    final canAfford =
        _found != null && balance >= _found!.stakeAmount;
    final uid = FirestoreService.instance.currentUid;
    final canDecline = _found != null &&
        !_joining &&
        !_looking &&
        !_declining &&
        _found!.status == ChallengeStatus.waiting &&
        _found!.opponentUid != null &&
        _found!.opponentUid == uid;
    final canAccept =
        _found != null &&
        !_joining &&
        !_looking &&
        !_atDailyLimit &&
        canAfford;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: Column(
          children: [
            _JoinHeader(
              busy: busy,
              onBack: () => Navigator.pop(context),
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(16.r, 4.r, 16.r, 32.r),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 8.h),
                    _JoinHeroCard(
                      onPaste: busy ? null : _pasteCode,
                    ),
                    SizedBox(height: 14.h),
                    _CodeEntryCard(
                      ctrls: _ctrls,
                      nodes: _nodes,
                      busy: busy,
                      complete: _codeComplete,
                      hasError: _error != null,
                      onChanged: _onBoxChanged,
                      onKey: _onBoxKey,
                      onClear: _codeComplete || _error != null
                          ? _clearCode
                          : null,
                    ),
                    if (_atDailyLimit && _error == null) ...[
                      SizedBox(height: 12.h),
                      _StatusBanner(
                        icon: Icons.block_rounded,
                        message:
                            'Daily join limit reached. You cannot accept another challenge today.',
                        color: AppColors.wrong,
                      ),
                    ],
                    if (_looking) ...[
                      SizedBox(height: 14.h),
                      const _LookupState(),
                    ],
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      child: _error != null && !_atDailyLimit
                          ? Padding(
                              key: ValueKey(_error),
                              padding: EdgeInsets.only(top: 12.r),
                              child: _StatusBanner(
                                icon: Icons.error_outline_rounded,
                                message: _error!,
                                color: AppColors.wrong,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      child: _found == null
                          ? const SizedBox.shrink(
                              key: ValueKey('empty'),
                            )
                          : Padding(
                              key: ValueKey(_found!.challengeId),
                              padding: EdgeInsets.only(top: 14.r),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  _FoundChallengeCard(
                                    challenge: _found!,
                                    balance: balance,
                                  ),
                                  SizedBox(height: 12.h),
                                  AppButton(
                                    label: _joining
                                        ? 'Joining…'
                                        : _atDailyLimit
                                            ? 'Daily limit reached'
                                            : !canAfford
                                                ? 'Insufficient AC'
                                                : 'Accept Challenge',
                                    icon: canAccept
                                        ? const Icon(Icons.flash_on_rounded)
                                        : null,
                                    onPressed: canAccept ? _accept : null,
                                    variant: AppButtonVariant.gradient,
                                    size: AppButtonSize.large,
                                    height: 52.h,
                                  ),
                                  if (canDecline) ...[
                                    SizedBox(height: 10.h),
                                    SizedBox(
                                      width: double.infinity,
                                      height: 48.h,
                                      child: OutlinedButton(
                                        onPressed: _declining ? null : _decline,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppColors.wrong,
                                          side: BorderSide(
                                              color: AppColors.wrong
                                                  .withOpacity(0.45)),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(14.r),
                                          ),
                                        ),
                                        child: _declining
                                            ? SizedBox(
                                                width: 18.w,
                                                height: 18.h,
                                                child:
                                                    const CircularProgressIndicator(
                                                        strokeWidth: 2),
                                              )
                                            : Text(
                                                'Decline',
                                                style: TextStyle(
                                                    fontSize: 14.sp,
                                                    fontWeight:
                                                        FontWeight.w800),
                                              ),
                                      ),
                                    ),
                                  ],
                                  SizedBox(height: 8.h),
                                  Text(
                                    canAfford
                                        ? '${_found!.stakeAmount} AC will be deducted when you accept.'
                                        : 'You need ${_found!.stakeAmount} AC to accept this challenge.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 11.sp,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
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

class _JoinHeader extends StatelessWidget {
  final bool busy;
  final VoidCallback onBack;

  const _JoinHeader({
    required this.busy,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8.r, 10.r, 14.r, 12.r),
      child: Row(
        children: [
          IconButton(
            onPressed: busy ? null : onBack,
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary,
              size: 19.r,
            ),
            splashRadius: 22,
          ),
          SizedBox(width: 2.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Join Challenge',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.55,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  'Enter the code your opponent shared',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          // Removed _BalanceStrip
        ],
      ),
    );
  }
}



class _JoinBlueColors {
  static const blue = Color(0xFF3B82F6);
  static const bright = Color(0xFF60A5FA);
  static const soft = Color(0x142563EB);
  static const border = Color(0x403B82F6);
}

class _JoinHeroCard extends StatelessWidget {
  final VoidCallback? onPaste;

  const _JoinHeroCard({required this.onPaste});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(18.r, 18.r, 12.r, 18.r),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20.r),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _JoinBlueColors.blue.withValues(alpha: 0.16),
            AppColors.surface.withValues(alpha: 0.9),
          ],
        ),
        border: Border.all(
          color: _JoinBlueColors.blue.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48.w,
            height: 48.h,
            decoration: BoxDecoration(
              color: _JoinBlueColors.blue.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(15.r),
            ),
            child: Icon(
              Icons.sports_esports_rounded,
              color: AppColors.skyBright,
              size: 25.r,
            ),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ready to battle?',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  'Paste the code or type it below. We’ll find the challenge automatically.',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.5.sp,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8.w),
          TextButton(
            onPressed: onPaste,
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(
                horizontal: 8.r,
                vertical: 8.r,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Paste',
              style: TextStyle(
                color: AppColors.skyBright,
                fontSize: 12.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeEntryCard extends StatelessWidget {
  final List<TextEditingController> ctrls;
  final List<FocusNode> nodes;
  final bool busy;
  final bool complete;
  final bool hasError;
  final void Function(int, String) onChanged;
  final void Function(int, RawKeyEvent) onKey;
  final VoidCallback? onClear;

  const _CodeEntryCard({
    required this.ctrls,
    required this.nodes,
    required this.busy,
    required this.complete,
    required this.hasError,
    required this.onChanged,
    required this.onKey,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(14.r, 16.r, 14.r, 12.r),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(
          color: hasError
              ? AppColors.wrong.withValues(alpha: 0.35)
              : AppColors.divider,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Challenge code',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (complete)
                TextButton(
                  onPressed: busy ? null : onClear,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Clear',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: 13.h),
          _CodeBoxes(
            ctrls: ctrls,
            nodes: nodes,
            busy: busy,
            hasError: hasError,
            onChanged: onChanged,
            onKey: onKey,
          ),
          SizedBox(height: 11.h),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                color: AppColors.textMuted,
                size: 12.r,
              ),
              SizedBox(width: 5.w),
              Text(
                '6 letters or numbers',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CodeBoxes extends StatelessWidget {
  final List<TextEditingController> ctrls;
  final List<FocusNode> nodes;
  final bool busy;
  final bool hasError;
  final void Function(int, String) onChanged;
  final void Function(int, RawKeyEvent) onKey;

  const _CodeBoxes({
    required this.ctrls,
    required this.nodes,
    required this.busy,
    required this.hasError,
    required this.onChanged,
    required this.onKey,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ...List.generate(
          3,
          (i) => _CodeBox(
            ctrl: ctrls[i],
            node: nodes[i],
            enabled: !busy,
            hasError: hasError,
            onChanged: (value) => onChanged(i, value),
            onKey: (event) => onKey(i, event),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 4.r),
          child: Text(
            '–',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 22.sp,
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
        ...List.generate(
          3,
          (i) {
            final index = i + 3;
            return _CodeBox(
              ctrl: ctrls[index],
              node: nodes[index],
              enabled: !busy,
              hasError: hasError,
              onChanged: (value) => onChanged(index, value),
              onKey: (event) => onKey(index, event),
            );
          },
        ),
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
    final borderColor =
        hasError ? AppColors.wrong : AppColors.divider;

    return SizedBox(
      width: 44,
      height: 56,
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
            FilteringTextInputFormatter.allow(
              RegExp(r'[A-Za-z0-9]'),
            ),
          ],
          style: TextStyle(
            color:
                hasError ? AppColors.wrong : AppColors.textPrimary,
            fontSize: 23,
            fontWeight: FontWeight.w900,
          ),
          decoration: InputDecoration(
            counterText: '',
            filled: true,
            fillColor: hasError
                ? AppColors.wrong.withValues(alpha: 0.07)
                : AppColors.surfaceDim,
            contentPadding: EdgeInsets.zero,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(13),
              borderSide: BorderSide(
                color: borderColor,
                width: 1.3,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(13),
              borderSide: BorderSide(
                color: hasError
                    ? AppColors.wrong
                    : AppColors.skyBright,
                width: 1.8,
              ),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(13),
              borderSide: BorderSide(
                color: AppColors.divider.withValues(alpha: 0.55),
              ),
            ),
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _LookupState extends StatelessWidget {
  const _LookupState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 16.r,
        vertical: 14.r,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 17.w,
            height: 17.h,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.skyBright,
            ),
          ),
          SizedBox(width: 10.w),
          Text(
            'Finding challenge…',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final IconData icon;
  final String message;
  final Color color;

  const _StatusBanner({
    required this.icon,
    required this.message,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 13.r,
        vertical: 12.r,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(15.r),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18.r),
          SizedBox(width: 9.w),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 11.5.sp,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FoundChallengeCard extends StatelessWidget {
  final ChallengeModel challenge;
  final int balance;

  const _FoundChallengeCard({
    required this.challenge,
    required this.balance,
  });

  String _remaining(Duration duration) {
    if (duration == Duration.zero) return 'Expired';
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    return hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final stake = challenge.stakeAmount;
    final canAfford = balance >= stake;
    final winAmount = ChallengeModel.payoutWin(stake);
    final drawAmount = ChallengeModel.payoutDraw(stake);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22.r),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _JoinBlueColors.blue.withValues(alpha: 0.12),
            AppColors.surface.withValues(alpha: 0.94),
          ],
        ),
        border: Border.all(
          color: _JoinBlueColors.blue.withValues(alpha: 0.26),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16.r, 16.r, 16.r, 15.r),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 44.w,
                  height: 44.h,
                  decoration: BoxDecoration(
                    color: _JoinBlueColors.blue.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '⚔️',
                      style: TextStyle(fontSize: 20.sp),
                    ),
                  ),
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        challenge.creatorUsername,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        'Challenge found',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11.sp,
                        ),
                      ),
                    ],
                  ),
                ),
                _TinyBadge(
                  icon: Icons.schedule_rounded,
                  text: _remaining(
                    challenge.timeRemaining,
                  ),
                ),
              ],
            ),
            SizedBox(height: 14.h),
            Row(
              children: [
                Expanded(
                  child: _InfoTile(
                    label: 'ANIME',
                    value: challenge.animeTitle,
                    icon: Icons.movie_creation_outlined,
                  ),
                ),
                SizedBox(width: 8.w),
                Expanded(
                  child: _InfoTile(
                    label: 'STAKE',
                    value: '$stake AC',
                    valueColor: canAfford
                        ? AppColors.correct
                        : AppColors.wrong,
                    icon: Icons.monetization_on_outlined,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8.h),
            Row(
              children: [
                Expanded(
                  child: _InfoTile(
                    label: 'QUESTIONS',
                    value: '${challenge.questionIds.length}',
                    icon: Icons.quiz_outlined,
                  ),
                ),
                SizedBox(width: 8.w),
                Expanded(
                  child: _InfoTile(
                    label: 'WIN PREVIEW',
                    value: '+$winAmount AC',
                    valueColor: AppColors.correct,
                    icon: Icons.emoji_events_outlined,
                  ),
                ),
              ],
            ),
            if (!canAfford) ...[
              SizedBox(height: 10.h),
              _StatusBanner(
                icon: Icons.warning_amber_rounded,
                message:
                    'You need $stake AC to accept this challenge, but you currently have $balance AC.',
                color: AppColors.wrong,
              ),
            ],
            SizedBox(height: 11.h),
            Row(
              children: [
                Expanded(
                  child: _PayoutLine(
                    label: 'Draw',
                    value: '+$drawAmount AC',
                    valueColor: AppColors.secondary,
                  ),
                ),
                SizedBox(width: 8.w),
                Expanded(
                  child: _PayoutLine(
                    label: 'Lose',
                    value: '0 AC',
                    valueColor: AppColors.wrong,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TinyBadge extends StatelessWidget {
  final IconData icon;
  final String text;

  const _TinyBadge({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 8.r,
        vertical: 6.r,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.r, color: AppColors.textMuted),
          SizedBox(width: 4.w),
          Text(
            text,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;

  const _InfoTile({
    required this.label,
    required this.value,
    required this.icon,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 10.r,
        vertical: 10.r,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(13.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 14.r,
            color: AppColors.textMuted,
          ),
          SizedBox(width: 7.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 8.5.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: valueColor ?? AppColors.textPrimary,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w900,
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

class _PayoutLine extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _PayoutLine({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.sp,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 11.sp,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}