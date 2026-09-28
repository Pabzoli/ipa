// lib/features/player/pi_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/widgets/coin_earn_animation.dart';
import '../../core/widgets/insufficient_coins_sheet.dart';
import '../../core/providers/user_data_provider.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/firestore_service.dart';
import '../../core/constants/app_constants.dart';
import '../auth/auth_service.dart';
import '../auth/delete_account_flow.dart';
import '../prizes/bank_selector_sheet.dart';
import '../multiplayer/challenge_model.dart';
import '../../features/coins/earn_coins_screen.dart';
import '../../features/premium/premium_upsell_screen.dart';
import 'player_statistics_provider.dart';
import 'package:url_launcher/url_launcher.dart';

// ═══════════════════════════════════════════════════════════════════════════
// PInform — Profile tab (root tab, no back button)
// ═══════════════════════════════════════════════════════════════════════════
class PInform extends StatefulWidget {
  const PInform({super.key});

  @override
  State<PInform> createState() => _PInformState();
}

class _PInformState extends State<PInform> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  String _username = 'Trainer';
  bool _usernameLoading = true;

  // ── Weekly rank cache ───────────────────────────────────────────────────
  // Recreating the rank future on every provider-driven rebuild re-queries
  // Firestore and flickers the badge. Keyed on week · eligibility · points.
  Future<int>? _rankFuture;
  String _rankKey = '';
  int _lastKnownRank = 0;

  Future<int> _rankFutureFor(UserDataProvider udp) {
    final key =
        '${udp.leaderboardEntryWeekId ?? ""}_${udp.isLeaderboardEligible}'
        '_${udp.weeklyPoints}';
    if (key != _rankKey || _rankFuture == null) {
      _rankKey = key;
      _rankFuture = FirestoreService.instance
          .getCurrentUserWeeklyRank(
        entryWeekId: udp.leaderboardEntryWeekId,
        eligible: udp.isLeaderboardEligible,
      )
          .then((r) {
        _lastKnownRank = r;
        return r;
      });
    }
    return _rankFuture!;
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _loadUsername();
  }

  Future<void> _loadUsername() async {
    final name = await FirestoreService.instance.getUsername();
    if (mounted) {
      setState(() {
        _username = name;
        _usernameLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── Username edit ──────────────────────────────────────────────────────────
  Future<void> _showEditUsername() async {
    final nextDate = await FirestoreService.instance.nextUsernameChangeDate();
    if (!mounted) return;

    if (nextDate != null) {
      final daysLeft = nextDate.difference(DateTime.now()).inDays + 1;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Username Locked',
              style: TextStyle(color: AppColors.textPrimary)),
          content: Text(
            'You can change your username again in $daysLeft '
            'day${daysLeft == 1 ? '' : 's'}.',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final ctrl = TextEditingController(text: _username);
    showDialog(
      context: context,
      builder: (_) => _EditUsernameDialog(
        controller: ctrl,
        onSave: (newName) async {
          try {
            await FirestoreService.instance.updateUsername(newName);
            if (mounted) setState(() => _username = newName);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Username updated!')));
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(e.toString().replaceFirst('Exception: ', '')),
                backgroundColor: AppColors.wrong,
              ));
            }
          }
        },
      ),
    );
  }

  // ── Sign out ──────────────────────────────────────────────────────────────
  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Sign out?',
            style: TextStyle(
                color: AppColors.textPrimary, fontWeight: FontWeight.w800)),
        content: const Text('You can sign back in at any time.',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out',
                style: TextStyle(
                    color: AppColors.wrong, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed == true) await AuthService.instance.signOut();
  }

  // ── Delete account (NDPA/GDPR right to erasure) ──────────────────────────
  // The flow itself lives in delete_account_flow.dart so the Android "Update
  // required" wall can offer the same right without a second copy drifting.
  // This surface keeps the modal-dialog presentation it has always had.
  Future<void> _deleteAccount() async {
    if (!await confirmAccountDeletion(context)) return;
    if (!mounted) return;

    // Busy indicator while the server cascades the deletion.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );

    // Never throws: the error policy lives in the shared flow.
    final result = await performAccountDeletion(onBusy: (_) {});
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close spinner

    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.error!, style: const TextStyle(fontFamily: 'Nunito')),
          backgroundColor: AppColors.wrong,
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Account deleted',
            style: TextStyle(
                color: AppColors.correct, fontWeight: FontWeight.w900)),
        content: Text(
          deletionSuccessMessage(result.retainedCount),
          style: const TextStyle(color: AppColors.textSecondary, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    // AuthGate reacts to the now-signed-out auth state and returns to login.
  }


  @override
  Widget build(BuildContext context) {
    final stats = context.watch<PlayerStatisticsProvider>().playerStatistics;
    final udp = context.watch<UserDataProvider>();
    final animeCoins = udp.animeCoins;
    final uid = AuthService.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Header ─────────────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 10.r),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Profile',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 26.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                    height: 1.05,
                  ),
                ),
              ),
            ),

            // ── Identity card ─────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.r),
              child: _IdentityCard(
                username: _usernameLoading ? '...' : _username,
                animeCoins: animeCoins,
                premiumActive: udp.premiumActive,
                rankFuture: _rankFutureFor(udp),
                lastKnownRank: _lastKnownRank,
                onOpenPremium: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PremiumUpsellScreen(),
                  ),
                ),
                onCopyCode: () async {
                  await Clipboard.setData(ClipboardData(text: uid));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Referral code copied!')),
                  );
                },
                onEditName: _showEditUsername,
              ),
            ),

            // ── Tab bar ───────────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(20.r, 14.r, 20.r, 0),
              child: _ProfileTabBar(controller: _tabCtrl),
            ),

            SizedBox(height: 4.h),

            // ── Tab content ───────────────────────────────────────────────
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  _StatisticsTab(
                    stats: stats,
                    onEarnCoins: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const EarnCoinsScreen(),
                      ),
                    ),
                    onSignOut: _signOut,
                    onDeleteAccount: _deleteAccount,
                  ),
                  const _AchievementsTab(),
                  const _HistoryTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Identity Card ──────────────────────────────────────────────────────────
class _IdentityCard extends StatelessWidget {
  final String username;
  final int animeCoins;
  final bool premiumActive;
  final Future<int> rankFuture;
  final int lastKnownRank;
  final VoidCallback onCopyCode;
  final VoidCallback onEditName;
  final VoidCallback onOpenPremium;

  const _IdentityCard({
    required this.username,
    required this.animeCoins,
    required this.premiumActive,
    required this.rankFuture,
    required this.lastKnownRank,
    required this.onCopyCode,
    required this.onEditName,
    required this.onOpenPremium,
  });

  @override
  Widget build(BuildContext context) {
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Avatar with decorative ring ───────────────────────────────
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 60.r,
                height: 60.r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.primary.withOpacity(0.18),
                    width: 1.5,
                  ),
                ),
              ),
              Container(
                width: 52.r,
                height: 52.r,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primary.withOpacity(0.30),
                      AppColors.primary.withOpacity(0.08),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.primary.withOpacity(0.35),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    initial,
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 24.sp,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: _PremiumStatusCard(
                  active: premiumActive,
                  onOpenPremium: onOpenPremium,
                ),
              ),
            ],
          ),
          SizedBox(width: 12.w),

          // ── Text info ────────────────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Username + edit
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17.sp,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                          height: 1.1,
                        ),
                      ),
                    ),
                    SizedBox(width: 2.w),
                    InkWell(
                      onTap: onEditName,
                      borderRadius: BorderRadius.circular(6.r),
                      child: Padding(
                        padding: EdgeInsets.all(4.r),
                        child: Icon(
                          Icons.edit_rounded,
                          color: AppColors.textMuted,
                          size: 13.r,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 7.h),

                // Rank + AC + Invite
                FutureBuilder<int>(
                  future: rankFuture,
                  builder: (context, snapshot) {
                    final rank = snapshot.data ?? lastKnownRank;
                    return Row(
                      children: [
                        _RankPill(rank: rank, coins: animeCoins),
                        const Spacer(),
                        _InviteCopyChip(onTap: onCopyCode),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Rank + AC pill ─────────────────────────────────────────────────────────
class _RankPill extends StatelessWidget {
  final int rank;
  final int coins;
  const _RankPill({required this.rank, required this.coins});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rank > 0) ...[
            Icon(Icons.leaderboard_rounded,
                color: AppColors.secondary, size: 11.r),
            SizedBox(width: 3.w),
            Text(
              '#$rank',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 10.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
            Container(
              width: 1,
              height: 10.h,
              margin: EdgeInsets.symmetric(horizontal: 6.w),
              color: AppColors.divider,
            ),
          ],
          Text(
            '$coins',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 11.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(width: 2.w),
          Text(
            'AC',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 9.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Referral Copy Chip ───────────────────────────────────────────────────────
class _InviteCopyChip extends StatelessWidget {
  final VoidCallback onTap;

  const _InviteCopyChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 4.r),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.10),
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.primary.withOpacity(0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.share_rounded, color: AppColors.primary, size: 11.r),
            SizedBox(width: 3.w),
            Text(
              'Invite',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 10.sp,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tab Bar ──────────────────────────────────────────────────────────────────
class _ProfileTabBar extends StatelessWidget {
  final TabController controller;
  const _ProfileTabBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: EdgeInsets.all(3.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: TabBar(
        controller: controller,
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: EdgeInsets.zero,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: AppColors.textMuted,
        labelStyle: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w800),
        unselectedLabelStyle:
            TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w700),
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicator: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(9.r),
        ),
        tabs: const [
          Tab(text: 'Stats'),
          Tab(text: 'Achievements'),
          Tab(text: 'History'),
        ],
      ),
    );
  }
}

// ─── Edit Username Dialog ──────────────────────────────────────────────────
class _EditUsernameDialog extends StatefulWidget {
  final TextEditingController controller;
  final Future<void> Function(String) onSave;
  const _EditUsernameDialog({required this.controller, required this.onSave});

  @override
  State<_EditUsernameDialog> createState() => _EditUsernameDialogState();
}

class _EditUsernameDialogState extends State<_EditUsernameDialog> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Edit Username',
          style: TextStyle(
              color: AppColors.textPrimary, fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.controller,
            style: const TextStyle(color: AppColors.textPrimary),
            maxLength: 20,
            decoration: const InputDecoration(
              hintText: 'Enter new username',
              counterStyle: TextStyle(color: AppColors.textMuted),
            ),
          ),
          SizedBox(height: 6.h),
          Text(
            '⚠ Username can only be changed once every 7 days.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11.sp),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving
              ? null
              : () async {
                  final name = widget.controller.text.trim();
                  if (name.length < 3) return;
                  setState(() => _saving = true);
                  await widget.onSave(name);
                  if (mounted) Navigator.pop(context);
                },
          child: _saving
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: const CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ─── Premium Status Badge ────────────────────────────────────────────────────
class _PremiumStatusCard extends StatefulWidget {
  final bool active;
  final VoidCallback onOpenPremium;

  const _PremiumStatusCard({
    required this.active,
    required this.onOpenPremium,
  });

  @override
  State<_PremiumStatusCard> createState() => _PremiumStatusCardState();
}

class _PremiumStatusCardState extends State<_PremiumStatusCard> {
  Future<DateTime?>? _expiryFuture;
  String? _readUid;

  @override
  void initState() {
    super.initState();
    _maybeLoadExpiry();
  }

  @override
  void didUpdateWidget(covariant _PremiumStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _maybeLoadExpiry();
  }

  void _maybeLoadExpiry() {
    if (!widget.active) return;
    final uid = AuthService.instance.currentUser?.uid;
    if (uid == null) return;
    if (uid == _readUid && _expiryFuture != null) return;

    _readUid = uid;
    _expiryFuture = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('premiumReceipts')
        .orderBy('expiresAt', descending: true)
        .limit(1)
        .get()
        .then((snap) {
      if (snap.docs.isEmpty) return null;
      final expiresAt = snap.docs.first.data()['expiresAt'];
      return expiresAt is Timestamp ? expiresAt.toDate() : null;
    }).catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = widget.active
        ? FutureBuilder<DateTime?>(
            future: _expiryFuture,
            builder: (context, snapshot) {
              final expiry = snapshot.data;
              return Text(
                expiry == null ? '⭐' : '⭐ ${_formatPremiumDate(expiry)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 8.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.1,
                ),
              );
            },
          )
        : Text(
            '⭐',
            maxLines: 1,
            style: TextStyle(
              color: Colors.white,
              fontSize: 9.sp,
              fontWeight: FontWeight.w900,
            ),
          );

    return GestureDetector(
      onTap: widget.active ? null : widget.onOpenPremium,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 3.r),
        decoration: BoxDecoration(
          color: const Color(0xFFFFB300),
          borderRadius: BorderRadius.circular(20.r),
          border: Border.all(color: AppColors.surface, width: 2),
        ),
        child: content,
      ),
    );
  }
}

String _formatPremiumDate(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = d.toLocal();
  return '${months[local.month - 1]} ${local.day}';
}

// ─── Redeem Code Card ─────────────────────────────────────────────────────────
class _RedeemCodeCard extends StatefulWidget {
  const _RedeemCodeCard();

  @override
  State<_RedeemCodeCard> createState() => _RedeemCodeCardState();
}

class _RedeemCodeCardState extends State<_RedeemCodeCard> {
  final TextEditingController _controller = TextEditingController();
  bool _redeeming = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final code = _controller.text.trim().toUpperCase();
    if (code.isEmpty || _redeeming) return;

    setState(() => _redeeming = true);
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('redeemCode')
          .call<Map<String, dynamic>>(<String, dynamic>{
        'code': code,
        // Forced-update gate: the server refuses an outdated Android client
        // before it opens the redemption transaction. Web clients report
        // platform 'web' and are exempt.
        ...AppUpdateService.instance.clientBuildStamp,
      });

      final type = result.data['type'] as String?;

      if (!mounted) return;
      _controller.clear();

      if (type == 'leaderboard_entry') {
        final weekId =
            (result.data['weekId'] ?? result.data['value']) as String?;
        _showSnack(weekId != null
            ? '🎉 Leaderboard entry activated for $weekId!'
            : '🎉 Leaderboard entry activated!');
      } else {
        final value = (result.data['value'] as num?)?.toInt() ?? 0;
        if (type == 'ac' && value > 0) {
          try {
            CoinEarnAnimation.show(context, amount: value);
          } catch (e) {
            debugPrint('[RedeemCode] animation skipped: $e');
          }
          _showSnack('🎉 +$value AC added!');
        } else if (type == 'premium') {
          _showSnack('🎉 Premium activated!');
        } else {
          _showSnack('Code redeemed successfully.');
        }
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      _showSnack(_errorMessage(e));
    } catch (e) {
      debugPrint('[RedeemCode] error: $e');
      if (!mounted) return;
      _showSnack('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  String _errorMessage(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'not-found':
        return 'Invalid code.';
      case 'failed-precondition':
        final msg = (e.message ?? '').toLowerCase();
        if (msg.contains('expired')) return 'This code has expired.';
        if (msg.contains('redeemed')) return 'This code has already been used.';
        return "This code can't be used.";
      case 'unauthenticated':
        return 'Sign in to redeem a code.';
      case 'permission-denied':
        return "This account can't redeem codes.";
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontFamily: 'Nunito'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tint = AppColors.secondary;
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: tint.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Center(
                  child: Text('🎟️', style: TextStyle(fontSize: 16.sp)),
                ),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Redeem Code',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      'Turn a code into AC, Premium, or a weekly entry.',
                      style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10.sp,
                          height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12.h),
          TextField(
            controller: _controller,
            enabled: !_redeeming,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13.sp,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9-]')),
              _UpperTextFormatter(),
              LengthLimitingTextInputFormatter(14),
            ],
            decoration: InputDecoration(
              hintText: 'XXXX-XXXX-XXXX',
              hintStyle: TextStyle(
                color: AppColors.textMuted,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w700,
                fontSize: 12.sp,
              ),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              contentPadding:
                  EdgeInsets.symmetric(vertical: 12.r, horizontal: 12.r),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11.r),
                borderSide: BorderSide(color: AppColors.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11.r),
                borderSide: BorderSide(color: AppColors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11.r),
                borderSide: BorderSide(color: tint, width: 1.5),
              ),
            ),
          ),
          SizedBox(height: 10.h),
          SizedBox(
            width: double.infinity,
            height: 42,
            child: ElevatedButton(
              onPressed: _redeeming ? null : _redeem,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11.r),
                ),
                elevation: 0,
              ),
              child: _redeeming
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      'Redeem',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13.sp,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Uppercases input as it's typed, matching the server-side normalization.
class _UpperTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.text == newValue.text.toUpperCase()
        ? newValue
        : TextEditingValue(
            text: newValue.text.toUpperCase(),
            selection: newValue.selection,
          );
  }
}

// ─── Statistics Tab ──────────────────────────────────────────────────────────
class _StatisticsTab extends StatelessWidget {
  final PlayerStatistics stats;
  final VoidCallback onEarnCoins;
  final VoidCallback onSignOut;
  final VoidCallback onDeleteAccount;

  const _StatisticsTab({
    required this.stats,
    required this.onEarnCoins,
    required this.onSignOut,
    required this.onDeleteAccount,
  });

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 32.r + keyboardHeight),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Hero: match record ─────────────────────────────────────────
          _MatchRecordCard(
            wins: stats.gamesWon,
            draws: stats.gamesDraw,
            losses: stats.gamesLost,
            total: stats.gamesPlayed,
          ),

          SizedBox(height: 18.h),

          _SectionLabel(title: 'Best Records'),
          SizedBox(height: 8.h),
          _BestRecordsGrid(stats: stats),

          SizedBox(height: 18.h),

          _SectionLabel(title: 'WP Stats'),
          SizedBox(height: 8.h),
          _WPStatsCard(stats: stats),

          SizedBox(height: 18.h),

          _SectionLabel(title: 'Match Breakdown'),
          SizedBox(height: 8.h),
          _MatchBreakdownCard(stats: stats),

          SizedBox(height: 18.h),

          _SectionLabel(title: 'Account'),
          SizedBox(height: 8.h),
          const _RedeemCodeCard(),
          SizedBox(height: 8.h),
          // Phase 3: reusable masked payout destination (owner-read only).
          const _PayoutDetailsCard(),
          SizedBox(height: 8.h),
          _SimpleActionRow(
            icon: Icons.play_circle_outline_rounded,
            label: 'Earn Coins',
            onTap: onEarnCoins,
          ),
          _SimpleActionRow(
            icon: Icons.logout_rounded,
            label: 'Sign out',
            onTap: onSignOut,
            destructive: true,
          ),

          SizedBox(height: 18.h),

          _SectionLabel(title: 'Legal'),
          SizedBox(height: 8.h),
          _LegalLinkRow(
            icon: Icons.privacy_tip_outlined,
            label: 'Privacy Policy',
            url: '$kShopUrl/privacy.html',
          ),
          _LegalLinkRow(
            icon: Icons.description_outlined,
            label: 'Terms of Service',
            url: '$kShopUrl/terms.html',
          ),
          _LegalLinkRow(
            icon: Icons.currency_exchange_rounded,
            label: 'Refund Policy',
            url: '$kShopUrl/refund.html',
          ),

          SizedBox(height: 18.h),

          _SectionLabel(title: 'Danger zone'),
          SizedBox(height: 8.h),
          _SimpleActionRow(
            icon: Icons.delete_forever_rounded,
            label: 'Delete account',
            onTap: onDeleteAccount,
            destructive: true,
          ),
        ],
      ),
    );
  }
}

// ─── Compact Grid for Best Records (foldable) ──────────────────────────────
class _BestRecordsGrid extends StatefulWidget {
  final PlayerStatistics stats;
  const _BestRecordsGrid({required this.stats});

  @override
  State<_BestRecordsGrid> createState() => _BestRecordsGridState();
}

class _BestRecordsGridState extends State<_BestRecordsGrid> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    final items = <_BestRecordItem>[
      _BestRecordItem(
        icon: Icons.trending_up_rounded,
        label: 'Best AC win',
        value: '+${stats.hseWon} AC',
        color: AppColors.correct,
      ),
      _BestRecordItem(
        icon: Icons.trending_down_rounded,
        label: 'Worst AC loss',
        value: '−${stats.hseLost} AC',
        color: AppColors.wrong,
      ),
      _BestRecordItem(
        icon: Icons.casino_rounded,
        label: 'Highest AC stake',
        value: '${stats.hseStaked} AC',
        color: AppColors.accent,
      ),
      if (stats.wpStakedTotal > 0 || stats.hseWpWon > 0) ...[
        _BestRecordItem(
          icon: Icons.trending_up_rounded,
          label: 'Best WP win',
          value: '+${stats.hseWpWon} WP',
          color: AppColors.correct,
        ),
        _BestRecordItem(
          icon: Icons.trending_down_rounded,
          label: 'Worst WP loss',
          value: '−${stats.hseWpLost} WP',
          color: AppColors.wrong,
        ),
        _BestRecordItem(
          icon: Icons.casino_rounded,
          label: 'Highest WP stake',
          value: '${stats.hseWpStaked} WP',
          color: AppColors.accent,
        ),
      ],
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: tap to fold/unfold ──────────────────────────────
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(14.r),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12.r,
                vertical: 10.r,
              ),
              child: Row(
                children: [
                  Container(
                    width: 28.r,
                    height: 28.r,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(9.r),
                    ),
                    child: Icon(
                      Icons.military_tech_rounded,
                      color: AppColors.accent,
                      size: 15.r,
                    ),
                  ),
                  SizedBox(width: 9.w),
                  Expanded(
                    child: Text(
                      'Best Records',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  Text(
                    '${items.length}',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(width: 5.w),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    child: Icon(
                      Icons.expand_more_rounded,
                      color: AppColors.textMuted,
                      size: 18.r,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Collapsible body ────────────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: _expanded
                ? Padding(
                    padding: EdgeInsets.fromLTRB(12.r, 0, 12.r, 12.r),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: items
                          .map((item) => _BestRecordChip(item: item))
                          .toList(),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _BestRecordItem {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _BestRecordItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
}

class _BestRecordChip extends StatelessWidget {
  final _BestRecordItem item;
  const _BestRecordChip({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 6.r),
      decoration: BoxDecoration(
        color: item.color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(9.r),
        border: Border.all(color: item.color.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(item.icon, color: item.color, size: 13.r),
          SizedBox(width: 5.w),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                item.label,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 9.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          SizedBox(width: 5.w),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                item.value,
                style: TextStyle(
                  color: item.color,
                  fontSize: 10.sp,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Match Record Card (Hero) ───────────────────────────────────────────────
class _MatchRecordCard extends StatelessWidget {
  final int wins, draws, losses, total;
  const _MatchRecordCard({
    required this.wins,
    required this.draws,
    required this.losses,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final winRate = total == 0 ? 0.0 : wins / total;

    return Container(
      padding: EdgeInsets.all(16.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'MATCH RECORD',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10.sp,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                ),
              ),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(20.r),
                ),
                child: Text(
                  '${(winRate * 100).round()}% win rate',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 14.h),
          Row(
            children: [
              Expanded(
                child: _HeroStat(
                  value: '$wins',
                  label: 'Wins',
                  color: AppColors.correct,
                ),
              ),
              _VerticalDivider(),
              Expanded(
                child: _HeroStat(
                  value: '$draws',
                  label: 'Draws',
                  color: AppColors.secondary,
                ),
              ),
              _VerticalDivider(),
              Expanded(
                child: _HeroStat(
                  value: '$losses',
                  label: 'Losses',
                  color: AppColors.wrong,
                ),
              ),
            ],
          ),
          SizedBox(height: 14.h),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 11.r, vertical: 9.r),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(11.r),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.sports_esports_rounded,
                  color: AppColors.textMuted,
                  size: 14.r,
                ),
                SizedBox(width: 7.w),
                Text(
                  'Games played',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '$total',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.sp,
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

class _HeroStat extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _HeroStat({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 32.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
            height: 1,
          ),
        ),
        SizedBox(height: 3.h),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.sp,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.7,
          ),
        ),
      ],
    );
  }
}

// ─── WP Stats Card ──────────────────────────────────────────────────────────
class _WPStatsCard extends StatelessWidget {
  final PlayerStatistics stats;
  const _WPStatsCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          _WPRow(
            icon: Icons.emoji_events_rounded,
            label: 'WP Won',
            value: stats.wpWon,
            color: AppColors.correct,
          ),
          SizedBox(height: 8.h),
          _WPRow(
            icon: Icons.shield_rounded,
            label: 'WP Lost',
            value: stats.wpLost,
            color: AppColors.wrong,
          ),
          SizedBox(height: 8.h),
          _WPRow(
            icon: Icons.casino_rounded,
            label: 'WP Staked',
            value: stats.wpStakedTotal,
            color: AppColors.accent,
            showDivider: false,
          ),
        ],
      ),
    );
  }
}

class _WPRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;
  final Color color;
  final bool showDivider;

  const _WPRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Container(
              width: 28.r,
              height: 28.r,
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Icon(icon, color: color, size: 15.r),
            ),
            SizedBox(width: 10.w),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              value.toString(),
              style: TextStyle(
                color: color,
                fontSize: 13.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        if (showDivider)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8.r),
            child: const Divider(color: AppColors.divider, height: 1),
          ),
      ],
    );
  }
}

// ─── Match Breakdown Card ──────────────────────────────────────────────────
class _MatchBreakdownCard extends StatelessWidget {
  final PlayerStatistics stats;
  const _MatchBreakdownCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          _BreakdownRow(
            icon: Icons.flash_on_rounded,
            label: 'Quick Match',
            wins: stats.quickWins,
            draws: stats.quickDraws,
            losses: stats.quickLosses,
            color: AppColors.primary,
          ),
          SizedBox(height: 12.h),
          _BreakdownRow(
            icon: Icons.sports_kabaddi_rounded,
            label: 'Rival Challenges',
            wins: stats.rivalWins,
            draws: stats.rivalDraws,
            losses: stats.rivalLosses,
            color: const Color(0xFFFF6B00),
            showDivider: false,
          ),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final int wins, draws, losses;
  final Color color;
  final bool showDivider;

  const _BreakdownRow({
    required this.icon,
    required this.label,
    required this.wins,
    required this.draws,
    required this.losses,
    required this.color,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Container(
              width: 28.r,
              height: 28.r,
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Icon(icon, color: color, size: 15.r),
            ),
            SizedBox(width: 9.w),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            _BreakdownPill(
              label: 'W',
              count: wins,
              color: AppColors.correct,
            ),
            SizedBox(width: 5.w),
            _BreakdownPill(
              label: 'D',
              count: draws,
              color: AppColors.secondary,
            ),
            SizedBox(width: 5.w),
            _BreakdownPill(
              label: 'L',
              count: losses,
              color: AppColors.wrong,
            ),
          ],
        ),
        if (showDivider)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8.r),
            child: const Divider(color: AppColors.divider, height: 1),
          ),
      ],
    );
  }
}

class _BreakdownPill extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _BreakdownPill({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7.r, vertical: 3.r),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6.r),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
          color: color,
          fontSize: 9.sp,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

// ─── Simple Action Row ──────────────────────────────────────────────────────
class _SimpleActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _SimpleActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.wrong : AppColors.textPrimary;
    return Padding(
      padding: EdgeInsets.only(bottom: 8.r),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12.r),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                Container(
                  width: 28.r,
                  height: 28.r,
                  decoration: BoxDecoration(
                    color: (destructive ? AppColors.wrong : AppColors.primary)
                        .withOpacity(0.10),
                    borderRadius: BorderRadius.circular(9.r),
                  ),
                  child: Icon(
                    icon,
                    color: destructive ? AppColors.wrong : AppColors.primary,
                    size: 15.r,
                  ),
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textMuted,
                  size: 18.r,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Legal link row ─────────────────────────────────────────────────────────
// Opens a policy page (Privacy / Terms / Refund) in the browser. These are
// legal documents — NOT a purchase path — so a browser launch is safe on all
// platforms (including Play-distributed Android builds).
class _LegalLinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String url;

  const _LegalLinkRow({
    required this.icon,
    required this.label,
    required this.url,
  });

  Future<void> _open(BuildContext context) async {
    final uri = Uri.parse(url);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not open the link. Check your connection.',
                style: TextStyle(fontFamily: 'Nunito')),
          ),
        );
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not open the link. Check your connection.',
              style: TextStyle(fontFamily: 'Nunito')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8.r),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12.r),
        child: InkWell(
          onTap: () => _open(context),
          borderRadius: BorderRadius.circular(12.r),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                Container(
                  width: 28.r,
                  height: 28.r,
                  decoration: BoxDecoration(
                    color: AppColors.textMuted.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(9.r),
                  ),
                  child: Icon(icon, color: AppColors.textMuted, size: 15.r),
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Icon(
                  Icons.open_in_new_rounded,
                  color: AppColors.textMuted,
                  size: 16.r,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 38,
        color: AppColors.divider,
      );
}

class _SectionLabel extends StatelessWidget {
  final String title;
  const _SectionLabel({required this.title});

  @override
  Widget build(BuildContext context) => Text(
        title.toUpperCase(),
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.9,
        ),
      );
}

// ─── Achievements Tab ────────────────────────────────────────────────────────
class _AchievementTier {
  final int threshold;
  final int ac;
  final String? frame;
  const _AchievementTier(this.threshold, this.ac, [this.frame]);
}

class _AchievementDef {
  final String statKey;
  final String title;
  final String desc;
  final IconData icon;
  final Color color;
  final String unit;
  final List<_AchievementTier> tiers;

  const _AchievementDef({
    required this.statKey,
    required this.title,
    required this.desc,
    required this.icon,
    required this.color,
    required this.unit,
    required this.tiers,
  });

  int get totalAc => tiers.fold(0, (sum, t) => sum + t.ac);
}

class _AchievementsTab extends StatefulWidget {
  const _AchievementsTab();

  @override
  State<_AchievementsTab> createState() => _AchievementsTabState();
}

class _AchievementsTabState extends State<_AchievementsTab> {
  static const List<_AchievementDef> _defs = [
    _AchievementDef(
      statKey: 'gamesPlayed',
      title: 'Games Played',
      desc: 'Across solo quizzes, Gauntlet, Quick Matches & challenges',
      icon: Icons.sports_esports_rounded,
      color: AppColors.primary,
      unit: 'games',
      tiers: [
        _AchievementTier(10, 20),
        _AchievementTier(50, 75),
        _AchievementTier(100, 150),
        _AchievementTier(500, 500),
      ],
    ),
    _AchievementDef(
      statKey: 'gamesWon',
      title: 'Victories',
      desc: 'Matches won across Quick Matches, Rival & Code challenges',
      icon: Icons.emoji_events_rounded,
      color: AppColors.accent,
      unit: 'wins',
      tiers: [
        _AchievementTier(10, 30),
        _AchievementTier(50, 100),
        _AchievementTier(200, 400, 'frame_victory'),
      ],
    ),
    _AchievementDef(
      statKey: 'perfectQuizzes',
      title: 'Perfect Quizzes',
      desc: 'Answered every question correctly in one sitting',
      icon: Icons.stars_rounded,
      color: AppColors.secondary,
      unit: 'perfects',
      tiers: [
        _AchievementTier(5, 20),
        _AchievementTier(25, 80),
        _AchievementTier(100, 300),
      ],
    ),
    _AchievementDef(
      statKey: 'rivalWins',
      title: 'Rival Slayer',
      desc: 'Win WP-staked Rival Challenges',
      icon: Icons.sports_kabaddi_rounded,
      color: AppColors.primary,
      unit: 'rival wins',
      tiers: [
        _AchievementTier(10, 50),
        _AchievementTier(50, 250, 'frame_rival_slayer'),
      ],
    ),
    _AchievementDef(
      statKey: 'careerWpEarned',
      title: 'WP Warrior',
      desc: 'Total WP earned over your career (all modes)',
      icon: Icons.star_rounded,
      color: AppColors.secondary,
      unit: 'WP',
      tiers: [
        _AchievementTier(500, 30),
        _AchievementTier(2500, 150),
        _AchievementTier(10000, 600),
      ],
    ),
  ];

  final Map<String, List<int>> _animated = {};
  bool _seeded = false;

  @override
  Widget build(BuildContext context) {
    final p = context.watch<PlayerStatisticsProvider>();

    final cards = _defs.map((def) {
      final current = p.achievementStatValue(def.statKey);
      final granted = p.grantedThresholds(def.statKey);
      return Padding(
        padding: EdgeInsets.only(bottom: 8.r),
        child: _AchievementCard(
          item: def,
          current: current,
          granted: granted,
        ),
      );
    }).toList();

    final totalGranted = _defs.fold<int>(
      0,
      (sum, def) => sum + p.grantedThresholds(def.statKey).length,
    );
    final totalTiers = _defs.fold<int>(0, (sum, d) => sum + d.tiers.length);
    final acEarned = _defs.fold<int>(0, (sum, def) {
      var earned = 0;
      for (final t in def.tiers) {
        if (p.grantedThresholds(def.statKey).contains(t.threshold)) {
          earned += t.ac;
        }
      }
      return sum + earned;
    });

    _notifyNewlyGranted(p);

    return ListView(
      padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 32.r),
      children: [
        _buildSummaryCard(
          totalGranted: totalGranted,
          totalTiers: totalTiers,
          acEarned: acEarned,
        ),
        SizedBox(height: 14.h),
        ...cards,
      ],
    );
  }

  Widget _buildSummaryCard({
    required int totalGranted,
    required int totalTiers,
    required int acEarned,
  }) {
    final pct = totalTiers == 0 ? 0.0 : totalGranted / totalTiers;
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$totalGranted / $totalTiers tiers',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 17.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 9.r, vertical: 4.r),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(20.r),
                  border: Border.all(
                    color: AppColors.accent.withOpacity(0.30),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.stars_rounded,
                        size: 12.r, color: AppColors.accent),
                    SizedBox(width: 4.w),
                    Text(
                      '$acEarned AC',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 11.sp,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          Text(
            '${(pct * 100).round()}% complete',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: 8.h),
          ClipRRect(
            borderRadius: BorderRadius.circular(6.r),
            child: LinearProgressIndicator(
              value: pct,
              backgroundColor: AppColors.divider,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
              minHeight: 7,
            ),
          ),
        ],
      ),
    );
  }

  void _notifyNewlyGranted(PlayerStatisticsProvider p) {
    if (!_seeded) {
      _seeded = true;
      for (final def in _defs) {
        _animated[def.statKey] =
            List<int>.from(p.grantedThresholds(def.statKey));
      }
      return;
    }

    for (final def in _defs) {
      final already = _animated[def.statKey] ?? const <int>[];
      final granted = p.grantedThresholds(def.statKey);

      int newAc = 0;
      for (final tier in def.tiers) {
        if (granted.contains(tier.threshold) &&
            !already.contains(tier.threshold)) {
          newAc += tier.ac;
        }
      }
      if (newAc <= 0) continue;

      _animated[def.statKey] =
          <int>{...already, ...granted}.toList(growable: false);

      final amount = newAc;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        CoinEarnAnimation.showAchievement(context, amount: amount);
      });
    }
  }
}

// ── Achievement Card (foldable) ──────────────────────────────────────────────
class _AchievementCard extends StatefulWidget {
  final _AchievementDef item;
  final int current;
  final List<int> granted;

  const _AchievementCard({
    required this.item,
    required this.current,
    required this.granted,
  });

  @override
  State<_AchievementCard> createState() => _AchievementCardState();
}

class _AchievementCardState extends State<_AchievementCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final current = widget.current;
    final granted = widget.granted;
    final allTiers = item.tiers;
    final isMaxed = !allTiers.any((t) => !granted.contains(t.threshold));
    final _AchievementTier? nextTier = isMaxed
        ? null
        : allTiers.firstWhere((t) => !granted.contains(t.threshold));
    final barValue = isMaxed ? 1.0 : _clamp01(current / nextTier!.threshold);

    return Container(
      padding: EdgeInsets.all(12.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(
          color: isMaxed ? item.color.withOpacity(0.45) : AppColors.divider,
          width: isMaxed ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10.r),
            child: Row(
              children: [
                _AchievementIcon(item: item, active: current > 0 || isMaxed),
                SizedBox(width: 10.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        item.desc,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10.sp,
                          height: 1.35,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 6.w),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$current',
                      style: TextStyle(
                        color: current > 0 || isMaxed
                            ? item.color
                            : AppColors.textMuted,
                        fontSize: 20.sp,
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
                    SizedBox(height: 1.h),
                    Text(
                      item.unit,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 9.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                SizedBox(width: 2.w),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  child: Icon(
                    Icons.expand_more_rounded,
                    color: AppColors.textMuted,
                    size: 20.r,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: _expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: 12.h),
                      if (nextTier != null) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$current / ${nextTier.threshold} ${item.unit}',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11.sp,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              'Next  +${nextTier.ac} AC${nextTier.frame != null ? ' · ${_frameLabel(nextTier.frame)}' : ''}',
                              style: TextStyle(
                                color: item.color,
                                fontSize: 11.sp,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 6.h),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4.r),
                          child: LinearProgressIndicator(
                            value: barValue,
                            backgroundColor: AppColors.divider,
                            valueColor: AlwaysStoppedAnimation(item.color),
                            minHeight: 6,
                          ),
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Icon(Icons.emoji_events_rounded,
                                size: 16.r, color: AppColors.accent),
                            SizedBox(width: 5.w),
                            Text(
                              'Maxed out  ·  +${item.totalAc} AC',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 12.sp,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ],
                      SizedBox(height: 10.h),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: allTiers.map((tier) {
                          return _TierPip(
                            tier: tier,
                            earned: granted.contains(tier.threshold),
                            isNext: tier == nextTier,
                            color: item.color,
                          );
                        }).toList(),
                      ),
                    ],
                  )
                : Padding(
                    padding: EdgeInsets.only(top: 10.r),
                    child: Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3.r),
                            child: LinearProgressIndicator(
                              value: allTiers.isEmpty
                                  ? 0
                                  : granted.length / allTiers.length,
                              minHeight: 5,
                              backgroundColor: AppColors.divider,
                              valueColor: AlwaysStoppedAnimation(item.color),
                            ),
                          ),
                        ),
                        SizedBox(width: 8.w),
                        Text(
                          '${granted.length}/${allTiers.length} tiers',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10.sp,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _AchievementIcon extends StatelessWidget {
  final _AchievementDef item;
  final bool active;

  const _AchievementIcon({required this.item, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40.w,
      height: 40.h,
      decoration: BoxDecoration(
        color: active ? item.color.withOpacity(0.14) : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Icon(
        item.icon,
        color: active ? item.color : AppColors.textMuted,
        size: 19.r,
      ),
    );
  }
}

class _TierPip extends StatelessWidget {
  final _AchievementTier tier;
  final bool earned;
  final bool isNext;
  final Color color;

  const _TierPip({
    required this.tier,
    required this.earned,
    required this.isNext,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final inactive = !earned && !isNext;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 38.w,
          padding: EdgeInsets.symmetric(vertical: 6.r),
          decoration: BoxDecoration(
            color: earned
                ? color.withOpacity(0.18)
                : (isNext ? color.withOpacity(0.10) : AppColors.surfaceAlt),
            borderRadius: BorderRadius.circular(7.r),
            border: Border.all(
              color: earned
                  ? color
                  : (isNext ? color.withOpacity(0.7) : AppColors.divider),
              width: earned || isNext ? 1.5 : 1,
            ),
          ),
          child: Text(
            '${tier.threshold}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: inactive ? AppColors.textMuted : color,
              fontSize: 10.sp,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        SizedBox(height: 3.h),
        Text(
          '+${tier.ac} AC',
          style: TextStyle(
            color: inactive ? AppColors.textMuted : color,
            fontSize: 8.sp,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

// ── Small helpers ────────────────────────────────────────────────────────
double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

String _frameLabel(String? frameId) {
  switch (frameId) {
    case 'frame_victory':
      return 'Victory Frame';
    case 'frame_rival_slayer':
      return 'Rival Slayer Frame';
    default:
      return 'Profile Frame';
  }
}

// ─── History Tab ────────────────────────────────────────────────────────────
class _HistoryTab extends StatelessWidget {
  const _HistoryTab();

  /// Only the N most recent matches are rendered. Note that the stream itself
  /// is already capped by `FirestoreService.matchHistoryStream` — this is a
  /// second, tighter cap on widget construction, not a window onto an
  /// otherwise unbounded list.
  static const int maxItems = 10;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: FirestoreService.instance.matchHistoryStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        final allMatches = snap.data ?? [];

        if (allMatches.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 32.r),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72.r,
                    height: 72.r,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Icon(
                      Icons.history_rounded,
                      size: 34.r,
                      color: AppColors.textMuted,
                    ),
                  ),
                  SizedBox(height: 14.h),
                  Text(
                    'No match history yet',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16.sp,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 6.h),
                  Text(
                    'Your multiplayer results will appear here.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.sp,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        // Cap rendered items — the stream order is already newest-first.
        final matches = allMatches.take(maxItems).toList(growable: false);

        return ListView.separated(
          padding: EdgeInsets.fromLTRB(20.r, 12.r, 20.r, 32.r),
          itemCount: matches.length,
          separatorBuilder: (_, __) => SizedBox(height: 8.h),
          itemBuilder: (_, i) => _HistoryCard(match: matches[i]),
        );
      },
    );
  }
}

// ─── History Card (non-interactive) ────────────────────────────────────────
/// Tall, non-tappable history row. Mirrors the folded achievement card's
/// footprint: 14.r padding · 14.r radius · 44×44 leading · 15.sp title ·
/// 17.sp right-aligned value · footer meta row.
///
/// Both money columns are *net balance deltas*, not settlement credits — see
/// `ChallengeModel.acLedgerDelta` / `wpLedgerDelta`. That is what makes a
/// rival loss render `−40 WP`: the stake was debited when the challenge was
/// created, so the loss has to carry it, and the row has to combine it with
/// the flat participation bonus and the stake refund rather than reading the
/// stored settlement credit on its own.
///
///   ┌──┐  Opponent · RIVAL              +50 AC
///   │L │  8 – 5 · Naruto                 −40 WP
///   └──┘                                2h ago
class _HistoryCard extends StatelessWidget {
  final Map<String, dynamic> match;
  const _HistoryCard({required this.match});

  static int _int(dynamic v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final outcome = match['outcome'] as String? ?? 'lose';
    final opponent = match['opponent'] as String? ?? 'Unknown';
    final playerScore = _int(match['playerScore']);
    final opponentScore = _int(match['opponentScore']);
    final isQuickMatch = match['isQuickMatch'] as bool? ?? false;
    final animeTitle = match['animeTitle'] as String? ?? '';
    final timestamp = match['timestamp'];

    final stakeAmount = _int(match['stakeAmount']);
    final wpStake = _int(match['wpStake']);
    final isRivalChallenge = wpStake > 0;
    final isCodeMatch = !isQuickMatch && !isRivalChallenge;

    final isWin = outcome == 'win';
    final isDraw = outcome == 'draw';

    // `wpChange` is the stored stake-settlement credit, NOT a balance delta,
    // and `pointsChange` is an Anime Coins value. Neither may be read straight
    // into a currency-labelled figure; the ledger helpers do the conversion.
    // `wpAwarded` is absent on matches resolved before that field existed.
    final acDelta = ChallengeModel.acLedgerDelta(
      isQuickMatch: isQuickMatch,
      stakeAmount: stakeAmount,
      pointsChange: _int(match['pointsChange']),
      won: isWin,
      isDraw: isDraw,
    );
    final wpDelta = ChallengeModel.wpLedgerDelta(
      isQuickMatch: isQuickMatch,
      wpStake: wpStake,
      wpChange: _int(match['wpChange']),
      wpAwarded: (match['wpAwarded'] as num?)?.toInt(),
      won: isWin,
      isDraw: isDraw,
    );

    final outcomeColor =
        isWin ? AppColors.correct : (isDraw ? Colors.amber : AppColors.wrong);
    final outcomeLetter = isWin
        ? 'W'
        : isDraw
            ? 'D'
            : 'L';

    String timeStr = '';
    if (timestamp != null) {
      try {
        final dt = (timestamp as dynamic).toDate() as DateTime;
        final diff = DateTime.now().difference(dt);
        // A serverTimestamp can resolve marginally ahead of the device clock,
        // which would otherwise render as "-4m ago".
        if (diff.isNegative) {
          timeStr = 'just now';
        } else if (diff.inMinutes < 60) {
          timeStr = '${diff.inMinutes}m ago';
        } else if (diff.inHours < 24) {
          timeStr = '${diff.inHours}h ago';
        } else {
          timeStr = '${diff.inDays}d ago';
        }
      } catch (_) {}
    }

    final acColor = acDelta > 0
        ? AppColors.accent
        : (acDelta < 0 ? AppColors.wrong : AppColors.textMuted);
    final wpColor = wpDelta > 0
        ? AppColors.secondary
        : (wpDelta < 0 ? AppColors.wrong : AppColors.textMuted);

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Outcome badge (W / D / L) ─────────────────────────────
          Container(
            width: 44.r,
            height: 44.r,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: outcomeColor.withOpacity(0.14),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Text(
              outcomeLetter,
              style: TextStyle(
                color: outcomeColor,
                fontSize: 20.sp,
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
          ),
          SizedBox(width: 12.w),

          // ── Opponent + type badges, then score · title line ───────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        opponent,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                          height: 1.15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(width: 6.w),
                    if (isRivalChallenge) _HistoryTypeBadge(label: 'RIVAL'),
                    if (isQuickMatch) _HistoryTypeBadge(label: 'QUICK'),
                    if (isCodeMatch) _HistoryTypeBadge(label: 'CODE'),
                  ],
                ),
                SizedBox(height: 6.h),
                Text(
                  animeTitle.isEmpty
                      ? '$playerScore – $opponentScore'
                      : '$playerScore – $opponentScore · $animeTitle',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          SizedBox(width: 12.w),

          // ── Right column: AC / WP / time, all right-aligned ───────
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${acDelta > 0 ? '+' : acDelta < 0 ? '−' : ''}${acDelta.abs()} AC',
                style: TextStyle(
                  color: acColor,
                  fontSize: 17.sp,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              if (wpDelta != 0) ...[
                SizedBox(height: 4.h),
                Text(
                  '${wpDelta > 0 ? '+' : '−'}${wpDelta.abs()} WP',
                  style: TextStyle(
                    color: wpColor,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ],
              if (timeStr.isNotEmpty) ...[
                SizedBox(height: 4.h),
                Text(
                  timeStr,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryTypeBadge extends StatelessWidget {
  final String label;
  const _HistoryTypeBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5.r, vertical: 2.r),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(5.r),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.primary,
          fontSize: 7.sp,
          fontWeight: FontWeight.w900,
          letterSpacing: .5,
        ),
      ),
    );
  }
}

// ─── Payout Details Card (Phase 3 — reusable masked destination) ─────────────
// Shows ONLY masked account information from the owner's `payoutDetails`
// subcollection. After a completed payout the server purges sensitive fields,
// leaving just `accountMask` — this card renders whatever is present without
// ever expecting full details. Editing is disabled while any claim is locked
// (submitted/approved and unpaid); the server independently rejects changes
// made after approval.
class _PayoutDetailsCard extends StatelessWidget {
  const _PayoutDetailsCard();

  static String _mask(Map<String, dynamic> d) {
    final stored = d['accountMask'] as String?;
    if (stored != null && stored.isNotEmpty) return stored;
    final full = (d['accountNumber'] as String?) ?? '';
    final digits = full.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 4) return '****';
    return '****${digits.substring(digits.length - 4)}';
  }

  Future<void> _onEdit(
    BuildContext context,
    Map<String, dynamic> doc,
  ) async {
    final cycles = await FirestoreService.instance.getMyWinnerCycles();
    if (!context.mounted) return;
    final locked = cycles.any((c) => c.isLocked);
    if (locked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A submitted payout is locked and cannot be changed right now.',
            style: TextStyle(fontFamily: 'Nunito'),
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (_) => _EditPayoutDialog(doc: doc),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: FirestoreService.instance.payoutDetailsStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        final docs = snap.data ?? const <Map<String, dynamic>>[];
        final tint = AppColors.accent;

        if (docs.isEmpty) {
          return Container(
            padding: EdgeInsets.all(14.r),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16.r),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: tint.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(10.r),
                  ),
                  child: Center(
                    child: Text('🏦', style: TextStyle(fontSize: 16.sp)),
                  ),
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Payout Destination',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        'No bank saved yet. One is stored automatically when you claim a prize.',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10.sp,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        final doc = docs.first;
        final bankLabel = ((doc['bankName'] as String?)?.isNotEmpty == true)
            ? doc['bankName'] as String
            : ((doc['bankCode'] as String?) ?? '');
        final beneficiary = (doc['beneficiaryName'] as String?) ?? '';

        return Container(
          padding: EdgeInsets.all(14.r),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: tint.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(10.r),
                    ),
                    child: Center(
                      child: Text('🏦', style: TextStyle(fontSize: 16.sp)),
                    ),
                  ),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Payout Destination',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15.sp,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.2,
                          ),
                        ),
                        SizedBox(height: 2.h),
                        Text(
                          'Only a masked reference is kept on this device.',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10.sp,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _onEdit(context, doc),
                    child: Text(
                      'Edit',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 13.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12.h),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12.r),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(11.r),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (bankLabel.isNotEmpty)
                      Text(
                        bankLabel,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    if (bankLabel.isNotEmpty) SizedBox(height: 3.h),
                    Text(
                      _mask(doc),
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    if (beneficiary.isNotEmpty) ...[
                      SizedBox(height: 3.h),
                      Text(
                        beneficiary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Edit Payout Dialog ───────────────────────────────────────────────────────
class _EditPayoutDialog extends StatefulWidget {
  final Map<String, dynamic> doc;

  const _EditPayoutDialog({required this.doc});

  @override
  State<_EditPayoutDialog> createState() => _EditPayoutDialogState();
}

class _EditPayoutDialogState extends State<_EditPayoutDialog> {
  NigerianBank? _bank;
  late final TextEditingController _accountCtrl;
  late final TextEditingController _nameCtrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final code = (widget.doc['bankCode'] as String?) ?? '';
    final bankName = (widget.doc['bankName'] as String?) ?? '';
    if (code.isNotEmpty) {
      _bank = NigerianBank(
        name: bankName.isNotEmpty ? bankName : code,
        code: code,
      );
    }
    _accountCtrl = TextEditingController(
      text: (widget.doc['accountNumber'] as String?) ?? '',
    );
    _nameCtrl = TextEditingController(
      text: (widget.doc['beneficiaryName'] as String?) ?? '',
    );
  }

  @override
  void dispose() {
    _accountCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickBank() async {
    if (_saving) return;
    final bank = await showBankSelectorSheet(context, selected: _bank);
    if (bank != null && mounted) setState(() => _bank = bank);
  }

  Future<void> _save() async {
    if (_saving) return;
    final account = _accountCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    if (_bank == null) {
      setState(() => _error = 'Select your bank from the verified list.');
      return;
    }
    if (!RegExp(r'^\d{10}$').hasMatch(account)) {
      setState(() => _error = 'Enter the 10-digit account number.');
      return;
    }
    if (name.length < 3) {
      setState(() => _error = 'Enter the beneficiary name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await FirestoreService.instance.updatePayoutDetail(
        widget.doc['id'] as String,
        accountNumber: account,
        bankCode: _bank!.code,
        beneficiaryName: name,
      );
      if (mounted) Navigator.pop(context);
      // The stream rebuilds the card; no extra refresh needed.
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text(
        'Edit payout destination',
        style: TextStyle(
            color: AppColors.textPrimary, fontWeight: FontWeight.w800),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: _saving ? null : _pickBank,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 12.r),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(11.r),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.account_balance_rounded,
                        color: AppColors.textMuted),
                    SizedBox(width: 10.w),
                    Expanded(
                      child: Text(
                        _bank?.name ?? 'Select your bank…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _bank == null
                              ? AppColors.textMuted
                              : AppColors.textPrimary,
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 10.h),
            TextField(
              controller: _accountCtrl,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                hintText: '10-digit account number',
              ),
            ),
            SizedBox(height: 10.h),
            TextField(
              controller: _nameCtrl,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                hintText: 'Beneficiary name',
              ),
            ),
            if (_error != null) ...[
              SizedBox(height: 8.h),
              Text(
                _error!,
                style: TextStyle(color: AppColors.wrong, fontSize: 11.sp),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
