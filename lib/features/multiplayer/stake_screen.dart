import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/app_update_service.dart';
import '../../core/widgets/app_button.dart';
import '../../core/providers/user_data_provider.dart';
import '../quiz/questions_page.dart';
import '../premium/premium_upsell_screen.dart';
import 'challenge_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// STAKE SCREEN
// Step 2 of Create Challenge flow
//
// • Generic challenge = AC stake only.
// • Rival challenge = AC + WP stake.
// • Full client-side validation.
// • Server remains the source of truth.
// • Better Firebase Functions error handling.
//
// Values below mirror functions/index.js — keep them in sync with the server
// constants (AC_MIN_STAKE / AC_STAKE_STEP / WP_* / ACTIVE_CHALLENGES_*/DAILY_*).
// ─────────────────────────────────────────────────────────────────────────────

const kAcMinStake = 20;
const kAcStakeStep = 10;
const kAcMaxStakeFree = 2000;
const kAcMaxStakePremium = 5000;
const kWpMinStake = 5;
const kWpMaxStakeFree = 200;
const kWpMaxStakePremium = 400;
const kWpDailyCapFree = 300;
const kWpDailyCapPremium = 500;
const kActiveChallengesFree = 3;
const kActiveChallengesPremium = 5;
const kDailyCreateFree = 5;
const kDailyCreatePremium = 8;
const kDailyJoinFree = 5;
const kDailyJoinPremium = 8;

class StakeScreen extends StatefulWidget {
  final String animeTitle;
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
  final TextEditingController _acCtrl = TextEditingController();
  final TextEditingController _wpCtrl = TextEditingController();

  bool _creating = false;
  String? _inlineError;
  bool _rulesExpanded = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Derived values
  // ─────────────────────────────────────────────────────────────────────────

  bool get isRivalChallenge {
    final uid = widget.opponentUid?.trim() ?? '';
    return uid.isNotEmpty;
  }

  int get _acStake {
    return int.tryParse(_acCtrl.text.trim()) ?? 0;
  }

  int get _wpStake {
    return int.tryParse(_wpCtrl.text.trim()) ?? 0;
  }

  @override
  void dispose() {
    _acCtrl.dispose();
    _wpCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Quick stake actions
  // ─────────────────────────────────────────────────────────────────────────

  void _setQuickACStake(int amount) {
    if (_creating) return;

    HapticFeedback.selectionClick();

    setState(() {
      _acCtrl.text = '$amount';
      _inlineError = null;
    });
  }

  void _setQuickWPStake(int amount) {
    if (_creating || !isRivalChallenge) return;

    HapticFeedback.selectionClick();

    setState(() {
      _wpCtrl.text = '$amount';
      _inlineError = null;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // AC validation
  // ─────────────────────────────────────────────────────────────────────────

  String? _validateAC(
    int animeCoins, {
    required bool premiumActive,
  }) {
    final stake = _acStake;

    if (stake <= 0) {
      return 'Enter an AC stake amount';
    }

    if (stake < kAcMinStake) {
      return 'Minimum stake is $kAcMinStake AC';
    }

    if (stake % kAcStakeStep != 0) {
      return 'AC stake must be a multiple of $kAcStakeStep';
    }

    final maxStake = premiumActive ? kAcMaxStakePremium : kAcMaxStakeFree;

    if (stake > maxStake) {
      return premiumActive
          ? 'Maximum stake is 5,000 AC'
          : 'Maximum stake is 2,000 AC';
    }

    if (stake > animeCoins) {
      return 'Not enough AC — you have $animeCoins AC';
    }

    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // WP validation
  // ─────────────────────────────────────────────────────────────────────────

  String? _validateWP({
    required int weeklyPoints,
    required int wpStakedToday,
    required bool premiumActive,
    required String wpStakedDate,
  }) {
    if (!isRivalChallenge) {
      return null;
    }

    final stake = _wpStake;

    if (stake <= 0) {
      return 'Enter a WP stake amount';
    }

    if (stake < kWpMinStake) {
      return 'Minimum WP stake is $kWpMinStake WP';
    }

    if (stake % 5 != 0) {
      return 'WP stake must be a multiple of 5';
    }

    final maxStake = premiumActive ? kWpMaxStakePremium : kWpMaxStakeFree;

    if (stake > maxStake) {
      return 'Maximum WP stake is $maxStake WP';
    }

    final todayWAT = _watDateString();

    final usedToday = wpStakedDate == todayWAT
        ? wpStakedToday
        : 0;

    final dailyCap = premiumActive ? kWpDailyCapPremium : kWpDailyCapFree;

    if (usedToday + stake > dailyCap) {
      final remaining = dailyCap - usedToday;

      if (remaining <= 0) {
        return 'Your daily WP staking limit has been reached';
      }

      return 'You can stake up to $remaining WP today';
    }

    if (stake > weeklyPoints) {
      return 'Not enough WP — you have $weeklyPoints WP';
    }

    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Friendly Firebase errors
  // ─────────────────────────────────────────────────────────────────────────

  String _friendlyError(
    String raw, {
    String? code,
  }) {
    final error = raw
        .replaceFirst('Exception: ', '')
        .trim();

    if (code == 'unauthenticated') {
      return 'Please sign in again and try again';
    }

    if (code == 'permission-denied') {
      return 'You do not have permission to create this challenge';
    }

    if (code == 'unavailable') {
      return 'Unable to reach the server. Check your internet connection.';
    }

    if (code == 'deadline-exceeded') {
      return 'The request took too long. Please try again.';
    }

    if (error.startsWith('wp_cooldown_active_')) {
      final time = error
          .replaceFirst('wp_cooldown_active_', '')
          .replaceAll('_', ' ');

      return 'You can challenge this rival again in $time';
    }

    return switch (error) {
      'insufficient_coins' =>
        'Not enough AC for this stake',

      'insufficient_wp' =>
        'Not enough weekly points for this stake',

      'wp_daily_cap_exceeded' =>
        'Your daily WP staking limit has been reached',

      'wp_stake_exceeds_limit' =>
        'This WP stake exceeds your maximum allowed amount',

      'wp_stake_below_minimum' =>
        'Minimum WP stake is $kWpMinStake WP',

      'wp_stake_invalid_step' =>
        'WP stake must be a multiple of 5',

      'invalid_wp_stake' =>
        'Enter a valid WP stake amount',

      'wp_stake_requires_opponent' =>
        'WP staking is only available for rival challenges',

      'invalid_opponent' =>
        'Your opponent could not be identified. Please select them again.',

      'cannot_challenge_yourself' =>
        'You cannot challenge yourself',

      'daily_challenge_limit_reached' =>
        'Daily limit reached — maximum $kDailyCreatePremium challenges per day',

      'daily_spar_limit_reached' =>
        'Daily spar limit reached — come back tomorrow for friendlies',

      'too_many_active_challenges' =>
        'You already have $kActiveChallengesPremium active challenges',
      'stake_below_minimum' =>
        'Minimum stake is $kAcMinStake AC',

      'stake_exceeds_limit' =>
        'This stake exceeds your maximum allowed amount',

      'stake_not_multiple_of_50' =>
        'AC stake must be a multiple of $kAcStakeStep',

      'invalid_stake_amount' =>
        'Enter a valid AC stake amount',

      'invalid_anime_title' =>
        'Invalid anime selected',

      'no_questions_for_anime' =>
        'No questions are available for this anime yet',

      'not_enough_questions_for_anime' =>
        'Not enough questions are available for this anime yet',

      'user_not_found' =>
        'Your account data could not be found',

      'challenge_creation_failed' =>
        'Unable to create the challenge right now. Please try again.',

      '' =>
        'Something went wrong. Please try again.',

      _ =>
        error,
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Create challenge
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _createChallenge({
    required int animeCoins,
    required bool premiumActive,
    required int weeklyPoints,
    required int wpStakedToday,
    required String wpStakedDate,
  }) async {
    if (_creating) return;

    final acError = _validateAC(
      animeCoins,
      premiumActive: premiumActive,
    );

    final wpError = isRivalChallenge
        ? _validateWP(
            weeklyPoints: weeklyPoints,
            wpStakedToday: wpStakedToday,
            premiumActive: premiumActive,
            wpStakedDate: wpStakedDate,
          )
        : null;

    if (acError != null || wpError != null) {
      HapticFeedback.lightImpact();

      setState(() {
        _inlineError = acError ?? wpError;
      });

      return;
    }

    final opponentUid =
        widget.opponentUid?.trim() ?? '';

    final opponentUsername =
        widget.opponentUsername?.trim() ?? '';

    if (isRivalChallenge &&
        (opponentUid.isEmpty ||
            opponentUsername.isEmpty)) {
      HapticFeedback.lightImpact();

      setState(() {
        _inlineError =
            'Your opponent could not be identified. Please go back and select them again.';
      });

      return;
    }

    HapticFeedback.mediumImpact();

    setState(() {
      _creating = true;
      _inlineError = null;
    });

    try {
      final payload = <String, dynamic>{
        // Lowercase contract: questions/seen buckets are all lowercase.
        'animeTitle': widget.animeTitle.trim().toLowerCase(),
        'stakeAmount': _acStake,
        'challengeType': isRivalChallenge ? 'rival' : 'code', // 🆕
      };

      if (isRivalChallenge) {
        payload['opponentUid'] = opponentUid;
        payload['opponentUsername'] = opponentUsername;
        payload['wpStake'] = _wpStake;
      }

      // Forced-update gate stamp (server rejects outdated Android builds).
      payload.addAll(AppUpdateService.instance.clientBuildStamp);

      debugPrint(
        '══════════════════════════════════════',
      );

      debugPrint(
        'CREATE CHALLENGE PAYLOAD',
      );

      debugPrint(
        'animeTitle: ${payload['animeTitle']}',
      );

      debugPrint(
        'stakeAmount: ${payload['stakeAmount']}',
      );

      debugPrint(
        'opponentUid: ${payload['opponentUid']}',
      );

      debugPrint(
        'opponentUsername: ${payload['opponentUsername']}',
      );

      debugPrint(
        'wpStake: ${payload['wpStake']}',
      );

      debugPrint(
        'challengeType: ${payload['challengeType']}',
      );

      debugPrint(
        '══════════════════════════════════════',
      );

      final functions =
          FirebaseFunctions.instanceFor(
        region: 'us-central1',
      );

      final result = await functions
          .httpsCallable(
            'createChallenge',
          )
          .call<Map<String, dynamic>>(
            payload,
          );

      final data = result.data;

      final challengeId =
          data['challengeId'] as String?;

      final rawQuestionIds =
          data['questionIds'];

      if (challengeId == null ||
          challengeId.trim().isEmpty) {
        throw Exception(
          'challenge_creation_failed',
        );
      }

      if (rawQuestionIds is! List) {
        throw Exception(
          'challenge_creation_failed',
        );
      }

      // Remote data is untrusted — a legacy source may store ids as ints,
      // which would crash List<String>.from(...) with a type-cast error.
      final questionIds = List<String>.unmodifiable(
        rawQuestionIds.map((e) => '$e'),
      );

      if (!mounted) return;

      HapticFeedback.heavyImpact();

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, animation, __) {
            return FadeTransition(
              opacity: animation,
              child: QuestionsPage(
                mode: QuizMode.asyncChallenge,
                questionIds: questionIds,
                challengeId: challengeId,
                isCreator: true,
              ),
            );
          },
          transitionDuration:
              const Duration(milliseconds: 400),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        '''
══════════════════════════════════════
CREATE CHALLENGE FIREBASE ERROR

CODE:
${e.code}

MESSAGE:
${e.message}

DETAILS:
${e.details}

══════════════════════════════════════
''',
      );

      if (!mounted) return;

      HapticFeedback.lightImpact();

      final message = e.code == 'internal'
          ? 'A server error occurred while creating the challenge. Please try again.'
          : _friendlyError(
              e.message ?? '',
              code: e.code,
            );

      setState(() {
        _inlineError = message;
      });
    } catch (e, stackTrace) {
      debugPrint(
        'CREATE CHALLENGE UNKNOWN ERROR: $e',
      );

      debugPrintStack(
        stackTrace: stackTrace,
      );

      if (!mounted) return;

      setState(() {
        _inlineError = _friendlyError(
          e.toString(),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _creating = false;
        });
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // WAT date helper
  // ─────────────────────────────────────────────────────────────────────────

  static String _watDateString() {
    final wat = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 1));

    final month =
        wat.month.toString().padLeft(2, '0');

    final day =
        wat.day.toString().padLeft(2, '0');

    return '${wat.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context) {
    final userData = context.watch<UserDataProvider>();

    final animeCoins = userData.animeCoins;
    final premiumActive = userData.premiumActive;
    final createdToday = userData.challengesCreatedToday;
    final weeklyPoints = userData.weeklyPoints;
    final wpStakedToday = userData.wpStakedToday;
    final wpStakedDate = userData.wpStakedDate;

    final maxACStake = premiumActive ? kAcMaxStakePremium : kAcMaxStakeFree;
    final maxWPStake = premiumActive ? kWpMaxStakePremium : kWpMaxStakeFree;

    final dailyCreateLimit = premiumActive ? kDailyCreatePremium : kDailyCreateFree;
    final dailyLimitReached = createdToday >= dailyCreateLimit;

    final acError = _validateAC(
      animeCoins,
      premiumActive: premiumActive,
    );

    final wpError = isRivalChallenge
        ? _validateWP(
            weeklyPoints: weeklyPoints,
            wpStakedToday: wpStakedToday,
            premiumActive: premiumActive,
            wpStakedDate: wpStakedDate,
          )
        : null;

    final canAffordAC = _acStake > 0 && _acStake <= animeCoins;
    final canAffordWP = !isRivalChallenge ||
        (_wpStake > 0 && _wpStake <= weeklyPoints);

    final validStake = acError == null && wpError == null;

    final canCreate = !_creating &&
        !dailyLimitReached &&
        validStake &&
        canAffordAC &&
        canAffordWP;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _StakeAppBar(
                  animeTitle: widget.animeTitle,
                  opponentUsername: widget.opponentUsername,
                  enabled: !_creating,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(16.r, 4.r, 16.r, 118.r),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _BalanceStrip(
                          animeCoins: animeCoins,
                          weeklyPoints: weeklyPoints,
                          acStake: _acStake,
                          wpStake: _wpStake,
                          showWP: isRivalChallenge,
                          premiumActive: premiumActive,
                        ),
                        if (dailyLimitReached) ...[
                          SizedBox(height: 10.h),
                          _LimitBanner(
                            createdToday: createdToday,
                            dailyLimit: dailyCreateLimit,
                          ),
                        ],
                        SizedBox(height: 12.h),
                        _PremiumStakeBanner(
                          premiumActive: premiumActive,
                          maxACStake: maxACStake,
                          maxWPStake: maxWPStake,
                        ),
                        SizedBox(height: 14.h),
                        _StakePanel(
                          label: 'Anime Coin stake',
                          helper: 'Required for every challenge',
                          ctrl: _acCtrl,
                          enabled: !_creating && !dailyLimitReached,
                          inlineError: acError,
                          quickStakes: premiumActive
                              ? const [100, 250, 500, 1000, 2000, 5000]
                              : const [50, 100, 250, 500, 1000, 2000],
                          maxStake: maxACStake,
                          minStake: kAcMinStake,
                          step: kAcStakeStep,
                          suffix: 'AC',
                          premiumActive: premiumActive,
                          onQuickStake: _setQuickACStake,
                          onChanged: (_) {
                            if (_inlineError != null) {
                              setState(() => _inlineError = null);
                            } else {
                              setState(() {});
                            }
                          },
                        ),
                        if (isRivalChallenge) ...[
                          SizedBox(height: 10.h),
                          _RivalContext(
                            username: widget.opponentUsername ?? 'Opponent',
                            acStake: _acStake,
                            wpStake: _wpStake,
                          ),
                          SizedBox(height: 10.h),
                          _StakePanel(
                            label: 'Weekly Points stake',
                            helper: 'Available for rival challenges',
                            ctrl: _wpCtrl,
                            enabled: !_creating && !dailyLimitReached,
                            inlineError: wpError,
                            quickStakes: premiumActive ? const [25, 50, 100, 200, 400] : const [10, 25, 50, 100, 200],
                            maxStake: maxWPStake,
                            minStake: kWpMinStake,
                            step: 5,
                            suffix: 'WP',
                            premiumActive: premiumActive,
                            onQuickStake: _setQuickWPStake,
                            onChanged: (_) {
                              if (_inlineError != null) {
                                setState(() => _inlineError = null);
                              } else {
                                setState(() {});
                              }
                            },
                          ),
                        ],
                        if (_inlineError != null) ...[
                          SizedBox(height: 10.h),
                          _InlineMessage(
                            icon: Icons.error_outline_rounded,
                            message: _inlineError!,
                            isError: true,
                          ),
                        ],
                        SizedBox(height: 10.h),
                        _ChallengeRules(
                          expanded: _rulesExpanded,
                          onToggle: () {
                            if (_creating) return;
                            HapticFeedback.selectionClick();
                            setState(() {
                              _rulesExpanded = !_rulesExpanded;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _StakeCta(
                stakeValue: _acStake,
                wpStake: _wpStake,
                loading: _creating,
                canAfford:
                    canAffordAC && canAffordWP && validStake,
                dailyLimitReached: dailyLimitReached,
                isRivalChallenge: isRivalChallenge,
                onTap: canCreate
                    ? () {
                        _createChallenge(
                          animeCoins: animeCoins,
                          premiumActive: premiumActive,
                          weeklyPoints: weeklyPoints,
                          wpStakedToday: wpStakedToday,
                          wpStakedDate: wpStakedDate,
                        );
                      }
                    : null,
              ),
            ),
            if (_creating)
              _CreatingOverlay(
                animeTitle: widget.animeTitle,
                opponentUsername: widget.opponentUsername,
              ),
          ],
        ),
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// COMPACT APP HEADER
// ─────────────────────────────────────────────────────────────────────────────

class _StakeAppBar extends StatelessWidget {
  final String animeTitle;
  final String? opponentUsername;
  final bool enabled;

  const _StakeAppBar({
    required this.animeTitle,
    required this.enabled,
    this.opponentUsername,
  });

  @override
  Widget build(BuildContext context) {
    final hasRival = opponentUsername != null &&
        opponentUsername!.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.fromLTRB(6.r, 10.r, 16.r, 8.r),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            splashRadius: 20,
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary,
              size: 19.r,
            ),
            onPressed: enabled ? () => Navigator.pop(context) : null,
          ),
          SizedBox(width: 2.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Set Your Stake',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 21.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                SizedBox(height: 1.h),
                Text(
                  hasRival
                      ? '$animeTitle  •  vs ${opponentUsername!}'
                      : '$animeTitle  •  Solo challenge',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.5.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (hasRival)
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: 9.r,
                vertical: 5.r,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(9.r),
                border: Border.all(
                  color: AppColors.primary.withOpacity(0.22),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bolt_rounded,
                    color: AppColors.primary,
                    size: 13.r,
                  ),
                  SizedBox(width: 4.w),
                  Text(
                    'RIVAL',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 9.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
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

// ─────────────────────────────────────────────────────────────────────────────
// TOP BALANCE STRIP
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceStrip extends StatelessWidget {
  final int animeCoins;
  final int weeklyPoints;
  final int acStake;
  final int wpStake;
  final bool showWP;
  final bool premiumActive;

  const _BalanceStrip({
    required this.animeCoins,
    required this.weeklyPoints,
    required this.acStake,
    required this.wpStake,
    required this.showWP,
    required this.premiumActive,
  });

  @override
  Widget build(BuildContext context) {
    final afterAC = (animeCoins - acStake).clamp(0, animeCoins);
    final afterWP = (weeklyPoints - wpStake).clamp(0, weeklyPoints);

    return Row(
      children: [
        Expanded(
          child: _BalanceChip(
            emoji: '🪙',
            label: 'AC',
            value: animeCoins,
            after: afterAC,
            accent: AppColors.secondary,
          ),
        ),
        if (showWP) ...[
          SizedBox(width: 8.w),
          Expanded(
            child: _BalanceChip(
              emoji: '⭐',
              label: 'WP',
              value: weeklyPoints,
              after: afterWP,
              accent: AppColors.primary,
            ),
          ),
        ],
        if (premiumActive) ...[
          SizedBox(width: 8.w),
          Container(
            height: 42.h,
            width: 42.w,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12.r),
              color: const Color(0xFFFFD700).withOpacity(0.10),
              border: Border.all(
                color: const Color(0xFFFFD700).withOpacity(0.25),
              ),
            ),
            child: Text(
              '★',
              style: TextStyle(
                color: Color(0xFFFFD700),
                fontSize: 19.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _BalanceChip extends StatelessWidget {
  final String emoji;
  final String label;
  final int value;
  final int after;
  final Color accent;

  const _BalanceChip({
    required this.emoji,
    required this.label,
    required this.value,
    required this.after,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final hasStake = value != after;

    return Container(
      height: 42.h,
              padding: EdgeInsets.symmetric(horizontal: 11.r),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.88),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: accent.withOpacity(0.18),
        ),
      ),
      child: Row(
        children: [
          Text(
            emoji,
            style: TextStyle(fontSize: 18.sp),
          ),
          SizedBox(width: 7.w),
          Expanded(
            child: Text(
              '$value $label',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          if (hasStake)
            Text(
              '→ $after',
              style: TextStyle(
                color: accent,
                fontSize: 10.5.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DAILY LIMIT / STATUS
// ─────────────────────────────────────────────────────────────────────────────

class _LimitBanner extends StatelessWidget {
  final int createdToday;
  final int dailyLimit;

  const _LimitBanner({required this.createdToday, required this.dailyLimit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
      decoration: BoxDecoration(
        color: AppColors.wrong.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: AppColors.wrong.withOpacity(0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.block_rounded,
            color: AppColors.wrong,
            size: 17.r,
          ),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              'Daily challenge limit reached. You cannot create another challenge today.',
              style: TextStyle(
                color: AppColors.wrong,
                fontSize: 11.5.sp,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
          ),
          Text(
            '$createdToday/$dailyLimit',
            style: TextStyle(
              color: AppColors.wrong,
              fontSize: 11.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// COMBINED STAKE PANEL
// ─────────────────────────────────────────────────────────────────────────────

class _StakePanel extends StatelessWidget {
  final String label;
  final String helper;
  final TextEditingController ctrl;
  final bool enabled;
  final String? inlineError;
  final List<int> quickStakes;
  final int maxStake;
  final int minStake;
  final int step;
  final String suffix;
  final bool premiumActive;
  final ValueChanged<int> onQuickStake;
  final ValueChanged<String> onChanged;

  const _StakePanel({
    required this.label,
    required this.helper,
    required this.ctrl,
    required this.enabled,
    required this.inlineError,
    required this.quickStakes,
    required this.maxStake,
    required this.minStake,
    required this.step,
    required this.suffix,
    required this.premiumActive,
    required this.onQuickStake,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hasError = inlineError != null;

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.90),
        borderRadius: BorderRadius.circular(17.r),
        border: Border.all(
          color: hasError
              ? AppColors.wrong.withOpacity(0.50)
              : AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      helper,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10.5.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (premiumActive)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 7.r,
                    vertical: 4.r,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD700).withOpacity(0.10),
                    borderRadius: BorderRadius.circular(7.r),
                    border: Border.all(
                      color: const Color(0xFFFFD700).withOpacity(0.22),
                    ),
                  ),
                  child: Text(
                    'PREMIUM',
                    style: TextStyle(
                      color: Color(0xFFFFD700),
                      fontSize: 8.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: 10.h),
          TextFormField(
            controller: ctrl,
            enabled: enabled,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            onChanged: onChanged,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 25.sp,
              fontWeight: FontWeight.w900,
            ),
            decoration: InputDecoration(
              hintText: '0',
              hintStyle: TextStyle(
                color: AppColors.textMuted.withOpacity(0.30),
                fontSize: 25.sp,
                fontWeight: FontWeight.w800,
              ),
              suffixText: suffix,
              suffixStyle: TextStyle(
                color: AppColors.primary,
                fontSize: 14.sp,
                fontWeight: FontWeight.w900,
              ),
              filled: true,
              fillColor: AppColors.surfaceDim,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 14.r,
                vertical: 13.r,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13.r),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13.r),
                borderSide: const BorderSide(
                  color: AppColors.divider,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13.r),
                borderSide: const BorderSide(
                  color: AppColors.primary,
                  width: 1.2,
                ),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13.r),
                borderSide: BorderSide(
                  color: AppColors.divider.withOpacity(0.5),
                ),
              ),
            ),
          ),
          if (inlineError != null) ...[
            SizedBox(height: 8.h),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: AppColors.wrong,
                  size: 15.r,
                ),
                SizedBox(width: 6.w),
                Expanded(
                  child: Text(
                    inlineError!,
                    style: TextStyle(
                      color: AppColors.wrong,
                      fontSize: 10.5.sp,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          ],
          SizedBox(height: 10.h),
          SizedBox(
            height: 33.h,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: quickStakes.length,
              separatorBuilder: (_, __) => SizedBox(width: 7.w),
              itemBuilder: (_, index) {
                final amount = quickStakes[index];
                return _QuickStakeChip(
                  amount: amount,
                  suffix: suffix,
                  selected: ctrl.text == '$amount',
                  enabled: enabled,
                  onTap: () => onQuickStake(amount),
                );
              },
            ),
          ),
          SizedBox(height: 7.h),
          Text(
            'Min $minStake $suffix  •  Max $maxStake $suffix  •  Step $step',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 9.5.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// QUICK STAKE CHIP
// ─────────────────────────────────────────────────────────────────────────────

class _QuickStakeChip extends StatelessWidget {
  final int amount;
  final String suffix;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _QuickStakeChip({
    required this.amount,
    required this.suffix,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(horizontal: 10.r),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withOpacity(0.13)
              : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(9.r),
          border: Border.all(
            color: selected
                ? AppColors.primary.withOpacity(0.65)
                : AppColors.divider,
          ),
        ),
        child: Text(
          '$amount $suffix',
          style: TextStyle(
            color: !enabled
                ? AppColors.textMuted
                : selected
                    ? AppColors.primary
                    : AppColors.textSecondary,
            fontWeight: FontWeight.w800,
            fontSize: 10.5.sp,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RIVAL CONTEXT STRIP
// ─────────────────────────────────────────────────────────────────────────────

class _RivalContext extends StatelessWidget {
  final String username;
  final int acStake;
  final int wpStake;

  const _RivalContext({
    required this.username,
    required this.acStake,
    required this.wpStake,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.055),
        borderRadius: BorderRadius.circular(13.r),
        border: Border.all(
          color: AppColors.primary.withOpacity(0.18),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 30.w,
            height: 30.h,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.sports_esports_rounded,
              color: AppColors.primary,
              size: 16.r,
            ),
          ),
          SizedBox(width: 9.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Challenging $username',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.5.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  'Both stakes are locked when the challenge is created.',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 9.5.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (acStake > 0 || wpStake > 0)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (acStake > 0)
                  Text(
                    '$acStake AC',
                    style: TextStyle(
                      color: AppColors.secondary,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                if (wpStake > 0)
                  Text(
                    '$wpStake WP',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// INLINE ERROR / INFO
// ─────────────────────────────────────────────────────────────────────────────

class _InlineMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final bool isError;

  const _InlineMessage({
    required this.icon,
    required this.message,
    required this.isError,
  });

  @override
  Widget build(BuildContext context) {
    final color = isError ? AppColors.wrong : AppColors.primary;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: color.withOpacity(0.24),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16.r),
          SizedBox(width: 7.w),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: color,
                fontSize: 10.5.sp,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHALLENGE RULES
// ─────────────────────────────────────────────────────────────────────────────

class _ChallengeRules extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;

  const _ChallengeRules({
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.78),
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(14.r),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12.r,
                vertical: 11.r,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    color: AppColors.primary,
                    size: 16.r,
                  ),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(
                      'Challenge rules',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: AppColors.textMuted,
                      size: 19.r,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            child: expanded
                ? Padding(
                    padding: EdgeInsets.fromLTRB(12.r, 0, 12.r, 12.r),
                    child: Column(
                      children: [
                        Divider(
                          color: AppColors.divider,
                          height: 1,
                        ),
                        SizedBox(height: 10.h),
                        _RuleStep(
                          n: '1',
                          text:
                              'Both players stake AC upfront. Rival challenges can also include a WP stake.',
                        ),
                        SizedBox(height: 7.h),
                        _RuleStep(
                          n: '2',
                          text:
                              'The winner receives the challenge rewards according to the challenge payout rules.',
                        ),
                        SizedBox(height: 7.h),
                        _RuleStep(
                          n: '3',
                          text:
                              'If the challenge expires or is cancelled according to the system rules, eligible stakes are refunded.',
                        ),
                        SizedBox(height: 7.h),
                        _RuleStep(
                          n: '4',
                          text:
                              'Up to $kDailyCreateFree challenges created per day '
                              '($kDailyCreatePremium with Premium) and up to '
                              '$kActiveChallengesFree active at once '
                              '($kActiveChallengesPremium with Premium).',
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
  final bool last;

  const _RuleStep({
    required this.n,
    required this.text,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 21.w,
          height: 21.h,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Text(
            n,
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 9.5.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        SizedBox(width: 8.w),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10.5.sp,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOTTOM CTA
// ─────────────────────────────────────────────────────────────────────────────

class _StakeCta extends StatelessWidget {
  final int stakeValue;
  final int wpStake;
  final bool loading;
  final bool canAfford;
  final bool dailyLimitReached;
  final bool isRivalChallenge;
  final VoidCallback? onTap;

  const _StakeCta({
    required this.stakeValue,
    required this.wpStake,
    required this.loading,
    required this.canAfford,
    required this.dailyLimitReached,
    required this.isRivalChallenge,
    required this.onTap,
  });

  String get _label {
    if (loading) return 'Creating challenge…';
    if (dailyLimitReached) return 'Daily limit reached';
    if (!canAfford) return 'Enter a valid stake';

    if (stakeValue > 0) {
      if (isRivalChallenge && wpStake > 0) {
        return 'Stake $stakeValue AC  +  $wpStake WP';
      }
      return 'Stake $stakeValue AC  &  Play';
    }

    return 'Set your entry amount';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16.r,
        11.r,
        16.r,
        14.r + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.surfaceDim.withOpacity(0),
            AppColors.surfaceDim.withOpacity(0.96),
            AppColors.surfaceDim,
          ],
          stops: const [0.0, 0.35, 1.0],
        ),
      ),
      child: AppButton(
        variant: AppButtonVariant.gradient,
        label: _label,
        icon: loading ? null : const Icon(Icons.flash_on_rounded),
        onPressed: onTap,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CREATING OVERLAY
// ─────────────────────────────────────────────────────────────────────────────

class _CreatingOverlay extends StatelessWidget {
  final String animeTitle;
  final String? opponentUsername;

  const _CreatingOverlay({
    required this.animeTitle,
    this.opponentUsername,
  });

  @override
  Widget build(BuildContext context) {
    final hasRival = opponentUsername != null &&
        opponentUsername!.trim().isNotEmpty;

    final heading = hasRival
        ? 'Challenging $opponentUsername…'
        : 'Building your challenge…';

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.72),
        child: Center(
          child: Container(
            margin: EdgeInsets.symmetric(horizontal: 34.r),
            padding: EdgeInsets.all(24.r),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20.r),
              border: Border.all(
                color: AppColors.primary.withOpacity(0.28),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.14),
                  blurRadius: 34,
                  spreadRadius: 3,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 54.w,
                  height: 54.h,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [
                        AppColors.primary,
                        Color(0xFFFF6B6B),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16.r),
                  ),
                  child: const Center(
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.4,
                    ),
                  ),
                ),
                SizedBox(height: 16.h),
                Text(
                  heading,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 17.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: 7.h),
                Text(
                  hasRival
                      ? 'Securing your AC and WP stakes…'
                      : 'Preparing your questions and securing your stake…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.sp,
                    height: 1.35,
                  ),
                ),
                SizedBox(height: 15.h),
                Text(
                  animeTitle,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.sp,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PREMIUM STAKE BANNER
// One widget, two faces:
//   - premiumActive:  gold affirmation with the boosted caps you currently get
//   - !premiumActive: gold upsell that names the caps Premium would unlock
// Both navigate to PremiumUpsellScreen so the free user can act on the hint.
// ─────────────────────────────────────────────────────────────────────────────

class _PremiumStakeBanner extends StatelessWidget {
  final bool premiumActive;
  final int  maxACStake;
  final int  maxWPStake;

  const _PremiumStakeBanner({
    required this.premiumActive,
    required this.maxACStake,
    required this.maxWPStake,
  });

  static const _gold = Color(0xFFFFB300);

  @override
  Widget build(BuildContext context) {
    final wpHint = maxWPStake >= 200
        ? '200 WP / stake (vs 100)'
        : null;

    final acLine = premiumActive
        ? 'Premium caps active · '
            '$maxACStake AC / stake · '
            '${wpHint ?? '$maxWPStake WP / stake'}'
        : 'Stakes capped at 2,000 AC · 100 WP · '
            'Premium unlocks 5,000 AC · 200 WP';

    final headline = premiumActive
        ? 'PREMIUM BENEFITS ACTIVE'
        : 'GO PREMIUM · BIGGER STAKES';

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PremiumUpsellScreen()),
      ),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
        decoration: BoxDecoration(
          color: _gold.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12.r),
          border: Border.all(color: _gold.withOpacity(0.28)),
        ),
        child: Row(
          children: [
            Container(
              width: 30.r,
              height: 30.r,
              decoration: BoxDecoration(
                color: _gold.withOpacity(0.18),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Center(
                child: Text(
                  '👑',
                  style: TextStyle(fontSize: 15.sp),
                ),
              ),
            ),
            SizedBox(width: 10.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    headline,
                    style: TextStyle(
                      color: _gold,
                      fontSize: 9.sp,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    acLine,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.sp,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 6.w),
            Icon(
              premiumActive
                  ? Icons.verified_rounded
                  : Icons.arrow_forward_ios_rounded,
              color: _gold,
              size: 14.r,
            ),
          ],
        ),
      ),
    );
  }
}